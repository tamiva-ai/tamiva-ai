import type { Request, Response, NextFunction } from "express";
import { prisma } from "../db/client.js";

/**
 * Idempotency middleware (v36 / S3.18).
 *
 * Clients attach `Idempotency-Key: <uuid>` to mutating requests
 * (signup, create-business-profile, payment-order). We look up the
 * key; if we've already cached a response for it, return that
 * response byte-for-byte. Otherwise, intercept res.json / res.status
 * to capture the response, persist it, and return it.
 *
 * Safe defaults:
 *   - key required only if header is sent (opt-in)
 *   - TTL: 24h (cleaned by a job, but we also accept keys older than that)
 *   - keyed by (userId, key) — if the userId changes between attempts
 *     (e.g. someone replays a key with a different session), treat as a
 *     fresh request rather than overwriting the cached one.
 *   - matches method+path so a POST and a PUT can't collide on the
 *     same key.
 */
const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;

export interface IdempotencyRequest extends Request {
  _idempotencyKey?: string;
}

function extractUserId(req: Request): string {
  // Auth is not yet wired in MVP — the auth middleware doesn't run on
  // /auth/* and the business route accepts userId in the body. We try
  // (in order): header x-user-id, body.userId, query.userId. This keeps
  // idempotency useful even before the JWT middleware lands.
  const headerId = req.headers["x-user-id"];
  if (typeof headerId === "string" && headerId.length > 0) return headerId;
  const body = (req.body ?? {}) as { userId?: string };
  if (typeof body.userId === "string" && body.userId.length > 0) {
    return body.userId;
  }
  const queryId = req.query.userId;
  if (typeof queryId === "string" && queryId.length > 0) return queryId;
  return "anonymous";
}

export async function idempotency(
  req: IdempotencyRequest,
  res: Response,
  next: NextFunction,
): Promise<void> {
  const headerVal = req.headers["idempotency-key"];
  if (typeof headerVal !== "string" || headerVal.length === 0) {
    return next();
  }
  const key = headerVal;
  const userId = extractUserId(req);
  const method = req.method.toUpperCase();
  const path = req.originalUrl.split("?")[0] ?? req.path;

  // Look for a cached response.
  const cached = await prisma.idempotencyKey.findUnique({
    where: { userId_key: { userId, key } },
  }).catch(() => null);

  if (cached) {
    const ageMs = Date.now() - cached.createdAt.getTime();
    if (ageMs < IDEMPOTENCY_TTL_MS && cached.method === method && cached.path === path) {
      res.status(cached.statusCode).json(cached.response);
      return;
    }
  }

  // Capture res.json / res.status so we can persist the eventual response.
  const originalJson = res.json.bind(res);
  let capturedStatus = res.statusCode;
  res.status = (code: number) => {
    capturedStatus = code;
    return res;
  };
  res.json = (body: unknown) => {
    // Persist asynchronously; don't block the response.
    prisma.idempotencyKey
      .upsert({
        where: { userId_key: { userId, key } },
        update: {
          method,
          path,
          statusCode: capturedStatus,
          response: body as object,
        },
        create: {
          userId,
          key,
          method,
          path,
          statusCode: capturedStatus,
          response: body as object,
        },
      })
      .catch(() => {
        // Idempotency persistence is best-effort; never fail the user.
      });
    return originalJson(body);
  };

  next();
}

/**
 * Background sweep — call once per day from the worker entrypoint.
 * Drops idempotency keys older than the TTL so the table stays small.
 */
export async function sweepStaleIdempotencyKeys(): Promise<number> {
  const cutoff = new Date(Date.now() - IDEMPOTENCY_TTL_MS);
  const { count } = await prisma.idempotencyKey.deleteMany({
    where: { createdAt: { lt: cutoff } },
  });
  return count;
}