import { Router, type Request, type Response, type NextFunction } from "express";
import express from "express";
import { z } from "zod";
import crypto from "node:crypto";
import Razorpay from "razorpay";
import { prisma } from "../db/client.js";
import { idempotency } from "../middleware/idempotency.js";
import {
  getEffectiveTier,
  proExpiryFromNow,
} from "../util/tier.js";

export const paymentsRouter = Router();

// v36: raw-body capture is required so the webhook signature can be
// verified against the exact bytes Razorpay sent. JSON-body parsing is
// disabled on this route and re-enabled with `verify` below.
paymentsRouter.use("/webhook", express.raw({ type: "*/*" }));

// Credentials come ONLY from the environment (set these in Railway):
//   RAZORPAY_KEY_ID       - public key id (rzp_live_... / rzp_test_...)
//   RAZORPAY_KEY_SECRET   - SECRET. Never commit this or ship it in the app.
//   RAZORPAY_WEBHOOK_SECRET - separate secret used to sign webhook payloads.
//     Generate under Razorpay Dashboard → Webhooks → Create webhook.
const keyId = process.env.RAZORPAY_KEY_ID;
const keySecret = process.env.RAZORPAY_KEY_SECRET;
const webhookSecret = process.env.RAZORPAY_WEBHOOK_SECRET;

const PRO_AMOUNT_PAISE = Number(
  process.env.RAZORPAY_PRO_AMOUNT_PAISE ?? 500000,
);

const razorpay =
  keyId && keySecret
    ? new Razorpay({ key_id: keyId, key_secret: keySecret })
    : null;

function ensureConfigured(res: Response): boolean {
  if (!razorpay || !keyId || !keySecret) {
    res.status(503).json({
      error: "Payments aren't set up yet. Please try again later.",
    });
    return false;
  }
  return true;
}

// ---------------------------------------------------------------
// Order creation (POST /payments/order)
// ---------------------------------------------------------------
// S1.6 (IDOR fix): callers can no longer pass an arbitrary userId or
// businessProfileId and have the order billed against someone else.
// We resolve the user from an x-user-id header (preferred) or the body
// userId, and require it to match a real user. businessProfileId is
// only used as a *hint* to look up the user; the resolved user.id is
// the authority that owns the order.

const createOrderSchema = z
  .object({
    businessProfileId: z.string().min(1).optional(),
  })
  .strict();

paymentsRouter.post(
  "/order",
  idempotency,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      if (!ensureConfigured(res)) return;

      const parsed = createOrderSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        return res.status(400).json({ error: parsed.error.flatten() });
      }

      const headerId = req.headers["x-user-id"];
      if (typeof headerId !== "string" || headerId.length === 0) {
        return res.status(401).json({ error: "Missing x-user-id header." });
      }
      const userId = headerId;

      const user = await prisma.user.findUnique({ where: { id: userId } });
      if (!user) return res.status(404).json({ error: "User not found." });

      const effective = await getEffectiveTier(user.id);
      if (effective.tier === "pro") {
        return res.status(409).json({ error: "You're already on Tamiva Pro." });
      }

      if (parsed.data.businessProfileId) {
        const profile = await prisma.businessProfile.findUnique({
          where: { id: parsed.data.businessProfileId },
          select: { userId: true },
        });
        if (!profile) {
          return res.status(404).json({ error: "Business profile not found." });
        }
        if (profile.userId !== user.id) {
          return res.status(403).json({ error: "Profile doesn't belong to this user." });
        }
      }

      try {
        const order = await razorpay!.orders.create({
          amount: PRO_AMOUNT_PAISE,
          currency: "INR",
          receipt: `pro_${Date.now()}`,
          notes: { userId: user.id, plan: "tamiva_pro_monthly" },
        });

        await prisma.paymentOrder.upsert({
          where: { providerOrderId: order.id },
          create: {
            userId: user.id,
            providerOrderId: order.id,
            amountPaise: PRO_AMOUNT_PAISE,
            currency: "INR",
            status: "created",
          },
          update: {},
        });

        return res.json({
          orderId: order.id,
          amount: order.amount,
          currency: order.currency,
          keyId,
          userId: user.id,
        });
      } catch (err) {
        console.error("[payments/order] error:", err);
        const anyErr = err as { error?: { description?: string }; message?: string };
        const detail =
          anyErr?.error?.description ||
          anyErr?.message ||
          "Couldn't start checkout. Try again.";
        return res.status(502).json({ error: detail });
      }
    } catch (err) {
      next(err);
    }
  },
);

// ---------------------------------------------------------------
// Client-side verification (POST /payments/verify)
// ---------------------------------------------------------------
const verifySchema = z.object({
  razorpay_order_id: z.string().min(1),
  razorpay_payment_id: z.string().min(1),
  razorpay_signature: z.string().min(1),
});

paymentsRouter.post(
  "/verify",
  idempotency,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      if (!ensureConfigured(res)) return;

      const parsed = verifySchema.safeParse(req.body);
      if (!parsed.success) {
        return res.status(400).json({ error: parsed.error.flatten() });
      }

      const headerId = req.headers["x-user-id"];
      if (typeof headerId !== "string" || headerId.length === 0) {
        return res.status(401).json({ error: "Missing x-user-id header." });
      }
      const userId = headerId;

      const {
        razorpay_order_id,
        razorpay_payment_id,
        razorpay_signature,
      } = parsed.data;

      const expected = crypto
        .createHmac("sha256", keySecret!)
        .update(`${razorpay_order_id}|${razorpay_payment_id}`)
        .digest("hex");

      const expectedBuf = Buffer.from(expected);
      const gotBuf = Buffer.from(razorpay_signature);
      if (
        expectedBuf.length !== gotBuf.length ||
        !crypto.timingSafeEqual(expectedBuf, gotBuf)
      ) {
        return res.status(400).json({
          error: "Payment couldn't be verified.",
        });
      }

      const order = await prisma.paymentOrder.findUnique({
        where: { providerOrderId: razorpay_order_id },
      });
      if (!order) {
        return res.status(404).json({
          error: "Order not found. If you were charged, contact support.",
        });
      }
      if (order.userId !== userId) {
        return res.status(403).json({
          error: "Order doesn't belong to this user.",
        });
      }
      if (order.status === "paid") {
        const tier = await getEffectiveTier(userId);
        return res.json({
          tier: tier.tier,
          tierUpdatedAt: tier.tierUpdatedAt,
          tierExpiresAt: tier.tierExpiresAt,
        });
      }

      const now = new Date();
      await prisma.$transaction([
        prisma.paymentOrder.update({
          where: { providerOrderId: razorpay_order_id },
          data: {
            status: "paid",
            providerPaymentId: razorpay_payment_id,
            verifiedAt: now,
          },
        }),
        prisma.user.update({
          where: { id: userId },
          data: {
            tier: "pro",
            tierUpdatedAt: now,
            tierExpiresAt: proExpiryFromNow(now),
          },
        }),
      ]);

      const tier = await getEffectiveTier(userId);
      return res.json({
        tier: tier.tier,
        tierUpdatedAt: tier.tierUpdatedAt,
        tierExpiresAt: tier.tierExpiresAt,
      });
    } catch (err) {
      next(err);
    }
  },
);

// ---------------------------------------------------------------
// Self-heal: GET /payments/status
// ---------------------------------------------------------------
paymentsRouter.get(
  "/status",
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const headerId = req.headers["x-user-id"];
      if (typeof headerId !== "string" || headerId.length === 0) {
        return res.status(401).json({ error: "Missing x-user-id header." });
      }
      const user = await prisma.user.findUnique({
        where: { id: headerId },
        select: { id: true },
      });
      if (!user) return res.status(404).json({ error: "User not found." });
      const tier = await getEffectiveTier(user.id);
      res.json(tier);
    } catch (err) {
      next(err);
    }
  },
);

// ---------------------------------------------------------------
// Webhook (POST /payments/webhook)
// ---------------------------------------------------------------
const webhookEventSchema = z.object({
  event: z.string(),
  payload: z
    .object({
      payment: z
        .object({
          entity: z.object({
            id: z.string(),
            order_id: z.string().optional(),
            amount: z.number().optional(),
          }),
        })
        .optional(),
    })
    .passthrough(),
});

paymentsRouter.post("/webhook", async (req: Request, res: Response) => {
  if (!webhookSecret) {
    return res.status(503).json({ error: "RAZORPAY_WEBHOOK_SECRET not configured." });
  }
  const sig = req.headers["x-razorpay-signature"];
  if (typeof sig !== "string" || sig.length === 0) {
    return res.status(400).json({ error: "Missing signature." });
  }
  const raw = (req.body as Buffer) ?? Buffer.alloc(0);
  const expected = crypto
    .createHmac("sha256", webhookSecret)
    .update(raw)
    .digest("hex");
  const expectedBuf = Buffer.from(expected);
  const gotBuf = Buffer.from(sig);
  if (
    expectedBuf.length !== gotBuf.length ||
    !crypto.timingSafeEqual(expectedBuf, gotBuf)
  ) {
    return res.status(400).json({ error: "Invalid signature." });
  }

  let parsed;
  try {
    parsed = webhookEventSchema.parse(JSON.parse(raw.toString("utf8")));
  } catch (err) {
    return res.status(400).json({ error: "Invalid webhook payload." });
  }

  if (parsed.event !== "payment.captured" && parsed.event !== "order.paid") {
    return res.json({ ok: true, ignored: true });
  }

  const payment = parsed.payload.payment?.entity;
  if (!payment?.order_id) {
    return res.status(400).json({ error: "Missing order_id." });
  }

  const order = await prisma.paymentOrder.findUnique({
    where: { providerOrderId: payment.order_id },
  });
  if (!order) {
    console.warn(
      `[payments/webhook] payment for unknown order ${payment.order_id}`,
    );
    return res.json({ ok: true, orphan: true });
  }

  if (order.status === "paid") {
    return res.json({ ok: true, alreadyPaid: true });
  }

  const now = new Date();
  await prisma.$transaction([
    prisma.paymentOrder.update({
      where: { providerOrderId: payment.order_id },
      data: {
        status: "paid",
        providerPaymentId: payment.id,
        verifiedAt: now,
      },
    }),
    prisma.user.update({
      where: { id: order.userId },
      data: {
        tier: "pro",
        tierUpdatedAt: now,
        tierExpiresAt: proExpiryFromNow(now),
      },
    }),
  ]);

  return res.json({ ok: true });
});
