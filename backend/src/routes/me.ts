import { Router, type Request, type Response, type NextFunction } from "express";
import { prisma } from "../db/client.js";
import { getEffectiveTier } from "../util/tier.js";

export const meRouter = Router();

/**
 * GET /auth/me
 *
 * v36 / S2.8 — token validation on cold start. Returns the
 * authoritative current user state so the client can decide:
 *   - "do I have a session?" (200 vs 401/404)
 *   - "what tier am I?" (post-expiry downgrade)
 *   - "does the persisted user still match what the server has?"
 *
 * The MVP uses x-user-id as a soft "session token" — production will
 * swap this for a real JWT and the route shape doesn't change.
 */
meRouter.get(
  "/me",
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const headerId = req.headers["x-user-id"];
      if (typeof headerId !== "string" || headerId.length === 0) {
        return res
          .status(401)
          .json({ error: "Missing x-user-id header." });
      }
      const user = await prisma.user.findUnique({
        where: { id: headerId },
        select: {
          id: true,
          email: true,
          fullName: true,
          phone: true,
          tier: true,
          tierUpdatedAt: true,
          tierExpiresAt: true,
        },
      });
      if (!user) return res.status(404).json({ error: "User not found." });

      // Reconcile tier in case Pro expired since the last call.
      const tier = await getEffectiveTier(user.id);

      res.json({
        userId: user.id,
        email: user.email,
        fullName: user.fullName,
        phone: user.phone,
        tier: tier.tier,
        tierUpdatedAt: tier.tierUpdatedAt,
        tierExpiresAt: tier.tierExpiresAt,
      });
    } catch (err) {
      next(err);
    }
  },
);