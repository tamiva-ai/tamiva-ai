import { Router } from "express";
import type { Response } from "express";
import { z } from "zod";
import crypto from "node:crypto";
import Razorpay from "razorpay";
import { prisma } from "../db/client.js";

export const paymentsRouter = Router();

// Credentials come ONLY from the environment (set these in Railway):
//   RAZORPAY_KEY_ID       - public key id (rzp_live_... / rzp_test_...)
//   RAZORPAY_KEY_SECRET   - SECRET. Never commit this or ship it in the app.
// The secret never leaves the backend; the app only ever receives the key id.
const keyId = process.env.RAZORPAY_KEY_ID;
const keySecret = process.env.RAZORPAY_KEY_SECRET;

// Tamiva Pro price in paise. Default ₹5000 = 500000. Override with
// RAZORPAY_PRO_AMOUNT_PAISE if the price changes.
const PRO_AMOUNT_PAISE = Number(process.env.RAZORPAY_PRO_AMOUNT_PAISE ?? 500000);

const razorpay =
  keyId && keySecret
    ? new Razorpay({ key_id: keyId, key_secret: keySecret })
    : null;

// If the env vars aren't set the whole payment surface degrades to a clean
// 503 instead of crashing the process on boot.
function ensureConfigured(res: Response): boolean {
  if (!razorpay || !keyId || !keySecret) {
    res
      .status(503)
      .json({ error: "Payments aren't set up yet. Please try again later." });
    return false;
  }
  return true;
}

const createOrderSchema = z
  .object({
    userId: z.string().min(1).optional(),
    businessProfileId: z.string().min(1).optional(),
  })
  .refine((d) => Boolean(d.userId || d.businessProfileId), {
    message: "userId or businessProfileId is required",
  });

paymentsRouter.post("/order", async (req, res) => {
  if (!ensureConfigured(res)) return;

  const parsed = createOrderSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }

  // Resolve the user from whichever identifier the caller has on hand.
  // The brand-kit screen only knows the businessProfileId; the business
  // info screen knows the userId.
  let user: Awaited<ReturnType<typeof prisma.user.findUnique>> = null;
  if (parsed.data.userId) {
    user = await prisma.user.findUnique({ where: { id: parsed.data.userId } });
  } else {
    const profile = await prisma.businessProfile.findUnique({
      where: { id: parsed.data.businessProfileId! },
      include: { user: true },
    });
    user = profile?.user ?? null;
  }

  if (!user) return res.status(404).json({ error: "User not found." });
  if (user.tier === "pro") {
    return res.status(409).json({ error: "You're already on Tamiva Pro." });
  }

  try {
    const order = await razorpay!.orders.create({
      amount: PRO_AMOUNT_PAISE,
      currency: "INR",
      // Razorpay caps receipt at 40 chars. A UUID alone is 36, so we
      // keep the receipt short (timestamp-based) and carry the userId
      // in notes instead.
      receipt: `pro_${Date.now()}`,
      notes: { userId: user.id, plan: "tamiva_pro_monthly" },
    });

    return res.json({
      orderId: order.id,
      amount: order.amount,
      currency: order.currency,
      keyId, // public key id — safe to hand to the app
      userId: user.id, // echo the resolved user so /verify is unambiguous
    });
  } catch (err) {
    console.error("[payments/order] error:", err);
    // Surface the Razorpay reason (e.g. auth/receipt errors) so the app
    // can show something actionable instead of a generic failure.
    const anyErr = err as {
      error?: { description?: string };
      message?: string;
    };
    const detail =
      anyErr?.error?.description ||
      anyErr?.message ||
      "Couldn't start checkout. Try again.";
    return res.status(502).json({ error: detail });
  }
});

const verifySchema = z.object({
  userId: z.string().min(1),
  razorpay_order_id: z.string().min(1),
  razorpay_payment_id: z.string().min(1),
  razorpay_signature: z.string().min(1),
});

paymentsRouter.post("/verify", async (req, res) => {
  if (!ensureConfigured(res)) return;

  const parsed = verifySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }

  const { userId, razorpay_order_id, razorpay_payment_id, razorpay_signature } =
    parsed.data;

  // Razorpay signature = HMAC_SHA256(order_id + "|" + payment_id, secret).
  const expected = crypto
    .createHmac("sha256", keySecret!)
    .update(`${razorpay_order_id}|${razorpay_payment_id}`)
    .digest("hex");

  const expectedBuf = Buffer.from(expected);
  const gotBuf = Buffer.from(razorpay_signature);
  const valid =
    expectedBuf.length === gotBuf.length &&
    crypto.timingSafeEqual(expectedBuf, gotBuf);

  if (!valid) {
    return res.status(400).json({ error: "Payment couldn't be verified." });
  }

  const user = await prisma.user.update({
    where: { id: userId },
    data: { tier: "pro", tierUpdatedAt: new Date() },
  });

  return res.json({ tier: user.tier, tierUpdatedAt: user.tierUpdatedAt });
});
