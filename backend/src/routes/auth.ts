import { Router } from "express";
import { z } from "zod";
import bcrypt from "bcryptjs";
import twilio from "twilio";
import crypto from "node:crypto";
import { prisma } from "../db/client.js";
import { sendPasswordResetEmail } from "../providers/email.js";
import { idempotency } from "../middleware/idempotency.js";
import { getEffectiveTier } from "../util/tier.js";

export const authRouter = Router();

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

function findUserByEmail(email: string) {
  return prisma.user.findFirst({
    where: {
      email: { equals: normalizeEmail(email), mode: "insensitive" },
    },
  });
}

const twilioClient =
  process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN
    ? twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN)
    : null;

const OTP_DISABLED = process.env.OTP_DISABLED !== "false";

const verifiedPhones = new Map<string, number>();
const VERIFICATION_VALID_MS = 10 * 60 * 1000;

const phoneSchema = z.object({ phone: z.string().min(8) });

authRouter.post("/otp/send", async (req, res) => {
  const parsed = phoneSchema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  if (OTP_DISABLED) {
    verifiedPhones.set(parsed.data.phone, Date.now());
    return res.json({ sent: true, otpDisabled: true });
  }

  if (!twilioClient || !process.env.TWILIO_VERIFY_SERVICE_SID) {
    return res
      .status(500)
      .json({ error: "SMS verification isn't configured yet." });
  }

  try {
    await twilioClient.verify.v2
      .services(process.env.TWILIO_VERIFY_SERVICE_SID)
      .verifications.create({
        to: parsed.data.phone,
        channel: "sms",
      });
    res.json({ sent: true });
  } catch (err) {
    res
      .status(400)
      .json({ error: `Could not send code — ${(err as Error).message}` });
  }
});

const otpVerifySchema = z.object({
  phone: z.string().min(8),
  code: z.string().min(4),
});

authRouter.post("/otp/verify", async (req, res) => {
  const parsed = otpVerifySchema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  if (OTP_DISABLED) {
    verifiedPhones.set(parsed.data.phone, Date.now());
    return res.json({ verified: true, otpDisabled: true });
  }

  if (!twilioClient || !process.env.TWILIO_VERIFY_SERVICE_SID) {
    return res
      .status(500)
      .json({ error: "SMS verification isn't configured yet." });
  }

  try {
    const check = await twilioClient.verify.v2
      .services(process.env.TWILIO_VERIFY_SERVICE_SID)
      .verificationChecks.create({
        to: parsed.data.phone,
        code: parsed.data.code,
      });

    if (check.status === "approved") {
      verifiedPhones.set(parsed.data.phone, Date.now());
      return res.json({ verified: true });
    }
    res.status(400).json({ error: "That code didn't match. Try again." });
  } catch (err) {
    res
      .status(400)
      .json({ error: `Verification failed — ${(err as Error).message}` });
  }
});

const signupSchema = z.object({
  fullName: z.string().min(1),
  phone: z.string().min(8),
  email: z.string().email(),
  password: z.string().min(8),
});

authRouter.post(
  "/signup",
  idempotency,
  async (req, res) => {
    const parsed = signupSchema.safeParse(req.body);
    if (!parsed.success)
      return res
        .status(400)
        .json({ error: parsed.error.flatten() });

    if (OTP_DISABLED) {
      verifiedPhones.set(parsed.data.phone, Date.now());
    }
    const verifiedAt = verifiedPhones.get(parsed.data.phone);
    if (!verifiedAt || Date.now() - verifiedAt > VERIFICATION_VALID_MS) {
      return res
        .status(400)
        .json({ error: "Please verify your phone number first." });
    }

    const existingEmail = await findUserByEmail(parsed.data.email);
    if (existingEmail) {
      return res.status(409).json({
        error:
          "This email already has a studio. Sign in instead?",
      });
    }

    const existingPhone = await prisma.user.findUnique({
      where: { phone: parsed.data.phone },
    });
    if (existingPhone) {
      return res.status(409).json({
        error:
          "This mobile number is already registered. Sign in instead?",
      });
    }

    const passwordHash = await bcrypt.hash(parsed.data.password, 10);

    try {
      const user = await prisma.user.create({
        data: {
          email: normalizeEmail(parsed.data.email),
          fullName: parsed.data.fullName,
          phone: parsed.data.phone,
          passwordHash,
          phoneVerified: true,
        },
      });

      verifiedPhones.delete(parsed.data.phone);

      return res.status(201).json({
        userId: user.id,
        fullName: user.fullName,
        tier: user.tier,
        tierUpdatedAt: user.tierUpdatedAt,
        tierExpiresAt: user.tierExpiresAt,
      });
    } catch (err: any) {
      if (err?.code === "P2002") {
        const target = Array.isArray(err.meta?.target)
          ? (err.meta.target as string[]).join(", ")
          : String(err.meta?.target ?? "");
        const field = target.includes("phone") ? "mobile number" : "email";
        return res.status(409).json({
          error: `This ${field} is already registered. Sign in instead?`,
        });
      }
      console.error("[signup] unexpected error:", err);
      return res
        .status(500)
        .json({ error: "Signup failed. Try again in a moment." });
    }
  },
);

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

authRouter.post("/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  const user = await findUserByEmail(parsed.data.email);
  if (!user) {
    return res
      .status(404)
      .json({ error: "This email isn't registered." });
  }
  if (!user.passwordHash) {
    return res
      .status(401)
      .json({ error: "Incorrect email or password." });
  }

  const valid = await bcrypt.compare(
    parsed.data.password,
    user.passwordHash,
  );
  if (!valid) {
    return res
      .status(401)
      .json({ error: "Incorrect email or password." });
  }

  const tier = await getEffectiveTier(user.id);
  res.json({
    userId: user.id,
    fullName: user.fullName,
    tier: tier.tier,
    tierUpdatedAt: tier.tierUpdatedAt,
    tierExpiresAt: tier.tierExpiresAt,
  });
});

// ---------------------------------------------------------------------
// Password reset flow (v36 — DB-backed codes with TTL + cooldown)
// ---------------------------------------------------------------------
const RESET_CODE_TTL_MS = 15 * 60 * 1000;
const RESET_RESEND_COOLDOWN_MS = 60 * 1000;
const MAX_RESET_ATTEMPTS = 5;

function generateCode(): string {
  const buf = crypto.randomBytes(4);
  const n = buf.readUInt32BE(0) % 1_000_000;
  return String(n).padStart(6, "0");
}

const forgotPasswordSchema = z.object({
  email: z.string().email(),
});

authRouter.post("/forgot-password", async (req, res) => {
  const parsed = forgotPasswordSchema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  const email = normalizeEmail(parsed.data.email);
  const user = await findUserByEmail(email);

  if (!user) {
    return res
      .status(404)
      .json({ error: "This email isn't registered." });
  }

  const mostRecent = await prisma.passwordResetCode.findFirst({
    where: { email },
    orderBy: { createdAt: "desc" },
  });
  if (
    mostRecent &&
    Date.now() - mostRecent.createdAt.getTime() < RESET_RESEND_COOLDOWN_MS
  ) {
    const wait = Math.ceil(
      (RESET_RESEND_COOLDOWN_MS -
        (Date.now() - mostRecent.createdAt.getTime())) /
        1000,
    );
    return res.status(429).json({
      error: `Please wait ${wait}s before requesting another code.`,
    });
  }

  const code = generateCode();
  const codeHash = await bcrypt.hash(code, 8);

  await prisma.passwordResetCode.create({
    data: {
      email,
      codeHash,
      expiresAt: new Date(Date.now() + RESET_CODE_TTL_MS),
    },
  });

  await sendPasswordResetEmail(email, code);

  res.json({ sent: true });
});

const resetPasswordSchema = z.object({
  email: z.string().email(),
  code: z.string().length(6),
  newPassword: z.string().min(8),
});

authRouter.post("/reset-password", async (req, res) => {
  const parsed = resetPasswordSchema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  const { email: rawEmail, code, newPassword } = parsed.data;
  const email = normalizeEmail(rawEmail);

  const candidates = await prisma.passwordResetCode.findMany({
    where: {
      email,
      consumed: false,
      expiresAt: { gt: new Date() },
    },
    orderBy: { createdAt: "desc" },
    take: 5,
  });
  const stored = candidates.find((c) => c.attempts < MAX_RESET_ATTEMPTS);
  if (!stored) {
    return res.status(400).json({
      error: "This code is expired. Request a new one.",
    });
  }

  await prisma.passwordResetCode.update({
    where: { id: stored.id },
    data: { attempts: { increment: 1 } },
  });

  if (stored.attempts + 1 > MAX_RESET_ATTEMPTS) {
    return res.status(400).json({
      error: "Too many attempts. Request a new code.",
    });
  }

  const valid = await bcrypt.compare(code, stored.codeHash);
  if (!valid) {
    return res.status(400).json({
      error: "That code doesn't match. Try again.",
    });
  }

  const user = await findUserByEmail(email);
  if (!user) {
    await prisma.passwordResetCode.update({
      where: { id: stored.id },
      data: { consumed: true },
    });
    return res.status(404).json({
      error: "We couldn't find that account.",
    });
  }

  const passwordHash = await bcrypt.hash(newPassword, 10);
  await prisma.$transaction([
    prisma.user.update({
      where: { id: user.id },
      data: { passwordHash },
    }),
    prisma.passwordResetCode.updateMany({
      where: { email, consumed: false },
      data: { consumed: true },
    }),
  ]);

  const tier = await getEffectiveTier(user.id);
  res.json({
    ok: true,
    userId: user.id,
    fullName: user.fullName,
    tier: tier.tier,
    tierUpdatedAt: tier.tierUpdatedAt,
    tierExpiresAt: tier.tierExpiresAt,
  });
});

authRouter.post("/upgrade/:userId", async (req, res) => {
  const user = await prisma.user.findUnique({
    where: { id: req.params.userId },
  });
  if (!user) return res.status(404).json({ error: "User not found" });

  const now = new Date();
  const updated = await prisma.user.update({
    where: { id: user.id },
    data: {
      tier: "pro",
      tierUpdatedAt: now,
      tierExpiresAt: new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000),
    },
  });

  res.json({
    userId: updated.id,
    email: updated.email,
    fullName: updated.fullName,
    tier: updated.tier,
    tierUpdatedAt: updated.tierUpdatedAt,
    tierExpiresAt: updated.tierExpiresAt,
  });
});
