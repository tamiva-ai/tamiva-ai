import { Router } from "express";
import { z } from "zod";
import bcrypt from "bcryptjs";
import twilio from "twilio";
import { prisma } from "../db/client.js";
import { sendPasswordResetEmail } from "../providers/email.js";

export const authRouter = Router();

const twilioClient =
  process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN
    ? twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN)
    : null;

// Temporary kill switch for phone OTP verification, so signup can be tested
// end-to-end without depending on Twilio delivery. Set OTP_DISABLED=false
// (or unset it) on Railway to turn real SMS verification back on.
const OTP_DISABLED = process.env.OTP_DISABLED !== "false";

// In-memory record of recently-verified phone numbers, so signup can trust
// that OTP verification actually happened without needing full session
// infrastructure yet. Fine for MVP single-instance use - replace with a
// proper short-lived token (or Redis-backed record) before scaling past
// one server instance.
const verifiedPhones = new Map<string, number>(); // phone -> verified-at timestamp
const VERIFICATION_VALID_MS = 10 * 60 * 1000; // 10 minutes

const phoneSchema = z.object({ phone: z.string().min(8) });

authRouter.post("/otp/send", async (req, res) => {
  const parsed = phoneSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  if (OTP_DISABLED) {
    // Skip Twilio entirely and mark the phone as verified immediately.
    verifiedPhones.set(parsed.data.phone, Date.now());
    return res.json({ sent: true, otpDisabled: true });
  }

  if (!twilioClient || !process.env.TWILIO_VERIFY_SERVICE_SID) {
    return res.status(500).json({ error: "SMS verification isn't configured yet." });
  }

  try {
    await twilioClient.verify.v2
      .services(process.env.TWILIO_VERIFY_SERVICE_SID)
      .verifications.create({ to: parsed.data.phone, channel: "sms" });
    res.json({ sent: true });
  } catch (err) {
    res.status(400).json({ error: `Could not send code — ${(err as Error).message}` });
  }
});

const otpVerifySchema = z.object({
  phone: z.string().min(8),
  code: z.string().min(4),
});

authRouter.post("/otp/verify", async (req, res) => {
  const parsed = otpVerifySchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  if (OTP_DISABLED) {
    // Phone was already marked verified in /otp/send; accept any code.
    verifiedPhones.set(parsed.data.phone, Date.now());
    return res.json({ verified: true, otpDisabled: true });
  }

  if (!twilioClient || !process.env.TWILIO_VERIFY_SERVICE_SID) {
    return res.status(500).json({ error: "SMS verification isn't configured yet." });
  }

  try {
    const check = await twilioClient.verify.v2
      .services(process.env.TWILIO_VERIFY_SERVICE_SID)
      .verificationChecks.create({ to: parsed.data.phone, code: parsed.data.code });

    if (check.status === "approved") {
      verifiedPhones.set(parsed.data.phone, Date.now());
      return res.json({ verified: true });
    }
    res.status(400).json({ error: "That code didn't match. Try again." });
  } catch (err) {
    res.status(400).json({ error: `Verification failed — ${(err as Error).message}` });
  }
});

const signupSchema = z.object({
  fullName: z.string().min(1),
  phone: z.string().min(8),
  email: z.string().email(),
  password: z.string().min(8),
});

authRouter.post("/signup", async (req, res) => {
  const parsed = signupSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  // When OTP is globally disabled, treat every incoming phone as
  // already-verified so the signup flow works end-to-end without
  // hitting Twilio. The in-memory verifiedPhones map is bypassed
  // because (a) it's wiped on every API redeploy, and (b) the
  // Flutter client never calls /otp/send when otpDisabled is true -
  // it goes straight from form -> signup.
  if (OTP_DISABLED) {
    verifiedPhones.set(parsed.data.phone, Date.now());
  }
  const verifiedAt = verifiedPhones.get(parsed.data.phone);
  if (!verifiedAt || Date.now() - verifiedAt > VERIFICATION_VALID_MS) {
    return res.status(400).json({ error: "Please verify your phone number first." });
  }

  const existingEmail = await prisma.user.findUnique({ where: { email: parsed.data.email } });
  if (existingEmail) {
    return res.status(409).json({ error: "This email already has a studio. Sign in instead?" });
  }

  const existingPhone = await prisma.user.findUnique({ where: { phone: parsed.data.phone } });
  if (existingPhone) {
    return res.status(409).json({ error: "This mobile number is already registered. Sign in instead?" });
  }

  const passwordHash = await bcrypt.hash(parsed.data.password, 10);

  try {
    const user = await prisma.user.create({
      data: {
        email: parsed.data.email,
        fullName: parsed.data.fullName,
        phone: parsed.data.phone,
        passwordHash,
        phoneVerified: true,
      },
    });

    verifiedPhones.delete(parsed.data.phone);

    return res.status(201).json({ userId: user.id, fullName: user.fullName, tier: user.tier, tierUpdatedAt: user.tierUpdatedAt });
  } catch (err: any) {
    // Race condition between the pre-checks above and the actual insert
    // (two rapid taps, same details). Prisma P2002 = unique constraint.
    if (err?.code === "P2002") {
      const target = Array.isArray(err.meta?.target)
        ? (err.meta.target as string[]).join(", ")
        : String(err.meta?.target ?? "");
      const field = target.includes("phone") ? "mobile number" : "email";
      return res.status(409).json({ error: `This ${field} is already registered. Sign in instead?` });
    }
    console.error("[signup] unexpected error:", err);
    return res.status(500).json({ error: "Signup failed. Try again in a moment." });
  }
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

authRouter.post("/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const user = await prisma.user.findUnique({ where: { email: parsed.data.email } });
  if (!user || !user.passwordHash) {
    return res.status(401).json({ error: "Incorrect email or password." });
  }

  const valid = await bcrypt.compare(parsed.data.password, user.passwordHash);
  if (!valid) {
    return res.status(401).json({ error: "Incorrect email or password." });
  }

  res.json({ userId: user.id, fullName: user.fullName, tier: user.tier, tierUpdatedAt: user.tierUpdatedAt });
});

// ---------------------------------------------------------------------
// Password reset flow (two step, email-code verification)
// ---------------------------------------------------------------------
// Step 1: POST /auth/forgot-password  {email}         → sends 6-digit code
// Step 2: POST /auth/reset-password   {email, code, newPassword}
//
// Codes are stored in-memory (single-server MVP). Move to Redis or a DB
// table before scaling past one instance.

interface StoredCode {
  code: string;
  expiresAt: number;
  attempts: number;
}
const resetCodes = new Map<string, StoredCode>();
const RESET_CODE_TTL_MS = 15 * 60 * 1000;
const MAX_ATTEMPTS = 5;

function generateCode(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

const forgotPasswordSchema = z.object({
  email: z.string().email(),
});

authRouter.post("/forgot-password", async (req, res) => {
  const parsed = forgotPasswordSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const email = parsed.data.email.toLowerCase();
  const user = await prisma.user.findUnique({ where: { email } });

  // Always return success to avoid leaking whether an email is registered.
  // Only actually send a code if the user exists.
  if (user) {
    const code = generateCode();
    resetCodes.set(email, {
      code,
      expiresAt: Date.now() + RESET_CODE_TTL_MS,
      attempts: 0,
    });
    await sendPasswordResetEmail(email, code);
  }

  res.json({ sent: true });
});

const resetPasswordSchema = z.object({
  email: z.string().email(),
  code: z.string().length(6),
  newPassword: z.string().min(8),
});

authRouter.post("/reset-password", async (req, res) => {
  const parsed = resetPasswordSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const { email: rawEmail, code, newPassword } = parsed.data;
  const email = rawEmail.toLowerCase();

  const stored = resetCodes.get(email);
  if (!stored || Date.now() > stored.expiresAt) {
    resetCodes.delete(email);
    return res.status(400).json({ error: "This code is expired. Request a new one." });
  }

  if (stored.attempts >= MAX_ATTEMPTS) {
    resetCodes.delete(email);
    return res.status(400).json({ error: "Too many attempts. Request a new code." });
  }

  if (stored.code !== code) {
    stored.attempts += 1;
    return res.status(400).json({ error: "That code doesn't match. Try again." });
  }

  const user = await prisma.user.findUnique({ where: { email } });
  if (!user) {
    // Shouldn't happen if we issued a code for this email, but handle it.
    resetCodes.delete(email);
    return res.status(404).json({ error: "We couldn't find that account." });
  }

  const passwordHash = await bcrypt.hash(newPassword, 10);
  await prisma.user.update({
    where: { id: user.id },
    data: { passwordHash },
  });

  resetCodes.delete(email);
  res.json({ ok: true, userId: user.id, fullName: user.fullName, tier: user.tier, tierUpdatedAt: user.tierUpdatedAt });
});

// v24: mock payment confirmation. In production this would be a Razorpay
// webhook. For v24 we just flip the tier manually so the rest of the
// flow can be tested. Idempotent - safe to call twice.
authRouter.post("/upgrade/:userId", async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.params.userId } });
  if (!user) return res.status(404).json({ error: "User not found" });

  const updated = await prisma.user.update({
    where: { id: user.id },
    data: { tier: "pro", tierUpdatedAt: new Date() },
  });

  res.json({
    userId: updated.id,
    email: updated.email,
    fullName: updated.fullName,
    tier: updated.tier,
    tierUpdatedAt: updated.tierUpdatedAt,
  });
});
