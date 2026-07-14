import { prisma } from "../db/client.js";

/**
 * v36: Tier helper (S2.15).
 *
 * - Returns the effective tier, downgrading an expired Pro user in place.
 * - The downgrade is idempotent and safe to call on every read; it sets
 *   tierExpiresAt = null so the next upgrade starts clean.
 * - Call from any endpoint that returns tier to the client (e.g. /auth/me,
 *   /payments/verify, /projects/*).
 */
export type TierName = "free" | "launch" | "pro" | "premium";

export const PAID_TIERS: readonly TierName[] = ["launch", "pro", "premium"] as const;

/** True when the tier grants paid features (any non-free plan). */
export function isPaidTier(tier: string | null | undefined): boolean {
  return tier != null && tier !== "free";
}

export async function getEffectiveTier(userId: string): Promise<{
  tier: TierName;
  tierUpdatedAt: Date | null;
  tierExpiresAt: Date | null;
  downgraded: boolean;
}> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { tier: true, tierUpdatedAt: true, tierExpiresAt: true },
  });
  if (!user) {
    return {
      tier: "free",
      tierUpdatedAt: null,
      tierExpiresAt: null,
      downgraded: false,
    };
  }

  const userTier = (user.tier ?? "free") as TierName;

  if (
    isPaidTier(userTier) &&
    user.tierExpiresAt &&
    user.tierExpiresAt.getTime() <= Date.now()
  ) {
    await prisma.user.update({
      where: { id: userId },
      data: {
        tier: "free",
        tierExpiresAt: null,
        tierUpdatedAt: new Date(),
      },
    });
    return {
      tier: "free",
      tierUpdatedAt: new Date(),
      tierExpiresAt: null,
      downgraded: true,
    };
  }

  return {
    tier: userTier,
    tierUpdatedAt: user.tierUpdatedAt,
    tierExpiresAt: user.tierExpiresAt,
    downgraded: false,
  };
}

/**
 * Background sweep — call once per day. Downgrades every Pro user whose
 * tierExpiresAt has elapsed. Idempotent.
 */
export async function sweepExpiredProUsers(): Promise<number> {
  const cutoff = new Date();
  const { count } = await prisma.user.updateMany({
    where: {
      tier: { in: [...PAID_TIERS] },
      tierExpiresAt: { lte: cutoff },
    },
    data: {
      tier: "free",
      tierExpiresAt: null,
      tierUpdatedAt: cutoff,
    },
  });
  return count;
}

/**
 * 30-day Pro window. Centralised so the webhook, /verify, and admin
 * manual-flip all produce the same expiry.
 */
export const PRO_DURATION_MS = 30 * 24 * 60 * 60 * 1000;

export function proExpiryFromNow(now: Date = new Date()): Date {
  return new Date(now.getTime() + PRO_DURATION_MS);
}