-- v24: tier system on User + palette + font preferences on BusinessProfile.
-- Non-breaking: defaults backfill existing rows.

-- User tier + tierUpdatedAt
ALTER TABLE "User" ADD COLUMN "tier" TEXT NOT NULL DEFAULT 'free';
ALTER TABLE "User" ADD COLUMN "tierUpdatedAt" TIMESTAMP(3);

-- BusinessProfile palette + font preferences
ALTER TABLE "BusinessProfile" ADD COLUMN "palettePreference" TEXT;
ALTER TABLE "BusinessProfile" ADD COLUMN "fontPreference" TEXT;
