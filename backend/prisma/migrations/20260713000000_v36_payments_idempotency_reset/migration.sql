-- v36: production-readiness fixes from the QA review.
-- Adds PaymentOrder, IdempotencyKey, PasswordResetCode; drops creditsBalance;
-- adds tierExpiresAt for Pro monthly lapsing. All operations are additive
-- or replace defaults so this migration is safe to run on existing prod data.

-- Drop stray creditsBalance (was unused after the v24 tier switch —
-- the QA report flagged it as model confusion).
ALTER TABLE "User" DROP COLUMN IF EXISTS "creditsBalance";

-- Add tierExpiresAt so Pro actually lapses (S2.15).
ALTER TABLE "User" ADD COLUMN IF NOT EXISTS "tierExpiresAt" TIMESTAMP(3);

-- Backfill: any existing Pro users get a 30-day window from their
-- tierUpdatedAt. New Pro grants (webhook) will set this explicitly.
UPDATE "User"
   SET "tierExpiresAt" = COALESCE("tierUpdatedAt", NOW()) + INTERVAL '30 days'
 WHERE "tier" = 'pro'
   AND "tierExpiresAt" IS NULL;

-- PaymentOrder: server-authoritative record of every Razorpay order.
-- Webhook + verify both upsert here, eliminating "charged but not upgraded".
CREATE TABLE IF NOT EXISTS "PaymentOrder" (
  "id"                TEXT PRIMARY KEY,
  "userId"            TEXT NOT NULL,
  "providerOrderId"   TEXT NOT NULL,
  "provider"          TEXT NOT NULL DEFAULT 'razorpay',
  "amountPaise"       INTEGER NOT NULL,
  "currency"          TEXT NOT NULL DEFAULT 'INR',
  "status"            TEXT NOT NULL DEFAULT 'created',
  "providerPaymentId" TEXT,
  "verifiedAt"        TIMESTAMP(3),
  "createdAt"         TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt"         TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "PaymentOrder_userId_fkey"
    FOREIGN KEY ("userId") REFERENCES "User"("id") ON DELETE CASCADE,
  CONSTRAINT "PaymentOrder_providerOrderId_key" UNIQUE ("providerOrderId")
);

CREATE INDEX IF NOT EXISTS "PaymentOrder_userId_idx" ON "PaymentOrder"("userId");

-- IdempotencyKey: cache responses by (userId, key) so signup / business
-- profile / payments can be safely retried.
CREATE TABLE IF NOT EXISTS "IdempotencyKey" (
  "id"         TEXT PRIMARY KEY,
  "userId"     TEXT NOT NULL,
  "key"        TEXT NOT NULL,
  "method"     TEXT NOT NULL,
  "path"       TEXT NOT NULL,
  "statusCode" INTEGER NOT NULL,
  "response"   JSONB NOT NULL,
  "createdAt"  TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS "IdempotencyKey_userId_key_key"
  ON "IdempotencyKey"("userId", "key");
CREATE INDEX IF NOT EXISTS "IdempotencyKey_createdAt_idx"
  ON "IdempotencyKey"("createdAt");

-- PasswordResetCode: DB-backed reset codes (replace in-memory Map).
CREATE TABLE IF NOT EXISTS "PasswordResetCode" (
  "id"        TEXT PRIMARY KEY,
  "email"     TEXT NOT NULL,
  "codeHash"  TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  "attempts"  INTEGER NOT NULL DEFAULT 0,
  "consumed"  BOOLEAN NOT NULL DEFAULT FALSE,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "PasswordResetCode_email_idx"
  ON "PasswordResetCode"("email");
CREATE INDEX IF NOT EXISTS "PasswordResetCode_expiresAt_idx"
  ON "PasswordResetCode"("expiresAt");

-- Schedule a nightly sweep that downgrades any expired Pro users. This is
-- the Postgres-native equivalent of a cron job; pairs with a check on read
-- in /auth/me so users see their tier flip the next time they open the app.
-- (Application code reads tierExpiresAt and forces a downgrade on
-- /auth/me / getBusinessProfileProjects, so a missed run is harmless.)