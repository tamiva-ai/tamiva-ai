-- v37: three-tier pricing (Launch / Business / Premium).
-- Adds plan to PaymentOrder so the verify + webhook paths can flip the
-- user to the correct tier (launch / pro / premium). Nullable for back-
-- compatibility with orders created before this migration; the application
-- falls back to "pro" when the column is null.

ALTER TABLE "PaymentOrder" ADD COLUMN IF NOT EXISTS "plan" TEXT;