import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db/client.js";
import { idempotency } from "../middleware/idempotency.js";
import { getEffectiveTier, isPaidTier } from "../util/tier.js";

export const businessRouter = Router();

const createProfileSchema = z.object({
  userId: z.string().uuid(),
  name: z.string().min(1),
  industry: z.string().min(1),
  tagline: z.string().optional(),
  tone: z.string().optional(),
  brandColors: z.array(z.string()).optional(),
  targetAudience: z.string().optional(),
  // v24: palette + font preferences. CSVs of keys validated against the
  // fixed lists on the Flutter side. Both default to null (no preference).
  palettePreference: z.string().max(100).nullable().optional(),
  fontPreference: z.string().max(100).nullable().optional(),
});

businessRouter.post(
  "/",
  idempotency,
  async (req, res) => {
  const parsed = createProfileSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: parsed.error.flatten() });
  }

  // NOTE: there's no real signup/auth flow yet, so we upsert a placeholder
  // user record here. Replace this once real auth is wired up - this is a
  // stand-in so the MVP flow works end-to-end without a login screen.
  await prisma.user.upsert({
    where: { id: parsed.data.userId },
    update: {},
    create: {
      id: parsed.data.userId,
      email: `${parsed.data.userId}@placeholder.tamiva.app`,
    },
  });

  const profile = await prisma.businessProfile.create({
    data: {
      ...parsed.data,
      brandColors: parsed.data.brandColors ?? [],
      palettePreference: parsed.data.palettePreference ?? null,
      fontPreference: parsed.data.fontPreference ?? null,
    },
  });

  res.status(201).json(profile);
  },
);

businessRouter.get("/:id", async (req, res) => {
  const profile = await prisma.businessProfile.findUnique({
    where: { id: req.params.id },
    include: { ambassadors: true },
  });

  if (!profile) return res.status(404).json({ error: "Not found" });
  res.json(profile);
});

/**
 * GET /business-profiles/:id/projects
 *
 * Returns the most-recent Project of each type (logo / carousel / video)
 * for a given business profile. Used by the brand-kit screen to render a
 * live status board so the user can see exactly which generation is
 * taking how long.
 */
businessRouter.get("/:id/projects", async (req, res) => {
  const profile = await prisma.businessProfile.findUnique({
    where: { id: req.params.id },
    select: { id: true },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });

  const allProjects = await prisma.project.findMany({
    where: { businessProfileId: req.params.id },
    include: { assets: true, jobs: true },
    orderBy: { createdAt: "desc" },
  });

  const latestOfType = (type: "logo" | "carousel" | "video") =>
    allProjects.find((p) => p.type === type) ?? null;

  res.json({
    projects: {
      logo: latestOfType("logo"),
      carousel: latestOfType("carousel"),
      video: latestOfType("video"),
    },
  });
});

/**
 * GET /business-profiles/:id/projects/all
 *
 * Powers the Artifacts screen (flutter_app/lib/screens/artifacts_screen.dart):
 * returns every project for the profile, ordered most-recent first, with
 * the shape expected by BusinessProfileProjectSummary on the client:
 *   id, type, status, createdAt, updatedAt, assetCount,
 *   firstAssetUrlSample (the first asset's url, may be data: or http),
 *   durationSeconds, jobs[] (latest job's stage / provider / status / error).
 *
 * The endpoint is read-only. No auth beyond what's already in the system.
 */
businessRouter.get("/:id/projects/all", async (req, res) => {
  const profile = await prisma.businessProfile.findUnique({
    where: { id: req.params.id },
    select: { id: true },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });

  const projects = await prisma.project.findMany({
    where: { businessProfileId: req.params.id },
    include: {
      assets: { orderBy: { createdAt: "asc" } },
      jobs: { orderBy: { createdAt: "desc" } },
    },
    orderBy: { updatedAt: "desc" },
  });

  res.json({
    projects: projects.map((p) => {
      // The "sample" is the first asset's URL so the Artifacts grid
      // can show a thumbnail without a second round-trip per row.
      // Asset.url is either a hosted URL or "data:image/png;base64,..." -
      // both pass through unchanged so the client's NetImage can render
      // either path.
      const sampleAsset = p.assets[0] ?? null;
      const latestJob = p.jobs[0] ?? null;
      return {
        id: p.id,
        type: p.type,
        status: p.status,
        createdAt: p.createdAt.toISOString(),
        updatedAt: p.updatedAt.toISOString(),
        assetCount: p.assets.length,
        firstAssetUrlSample: sampleAsset ? sampleAsset.url : null,
        durationSeconds: 0,
        jobs: latestJob
          ? [
              {
                stage: latestJob.stage,
                provider: latestJob.provider,
                status: latestJob.status,
                error: latestJob.error,
              },
            ]
          : [],
      };
    }),
  });
});

/**
 * GET /business-profiles/by-user/:userId
 *
 * Returns the user's primary business profile. 404 if none exists.
 * Used by the Flutter client after signup/login to decide whether to
 * show the form (new user) or the brand kit (returning user).
 */
businessRouter.get("/by-user/:userId", async (req, res) => {
  const profile = await prisma.businessProfile.findFirst({
    where: { userId: req.params.userId },
    include: { ambassadors: { select: { id: true } } },
    orderBy: { createdAt: "asc" },
  });
  if (!profile) return res.status(404).json({ error: "No profile for this user yet" });
  res.json(profile);
});

/**
 * v24: PUT /business-profiles/by-user/:userId
 *
 * Lets a Pro user edit their BusinessProfile (text + reference photos).
 * Wipes existing BrandAmbassador photos and replaces them. Called
 * after a mock payment screen, in lockstep with the user's Pro
 * regeneration cycle.
 *
 * Auth: caller must own this userId. Tier must be 'pro'. Tier flips
 * back to 'free' after PUT so the user can't immediately re-edit
 * without paying again.
 */
const putProfileSchema = z.object({
  name: z.string().min(1),
  industry: z.string().min(1),
  tagline: z.string().nullable().optional(),
  tone: z.string().nullable().optional(),
  palettePreference: z.string().max(100).nullable().optional(),
  fontPreference: z.string().max(100).nullable().optional(),
  // Reference photos in their original upload order. Empty list = wipe.
  photoUrls: z.array(z.string().url()).optional(),
  angleLabels: z.array(z.string()).optional(),
});

businessRouter.put("/by-user/:userId", async (req, res) => {
  const parsed = putProfileSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const user = await prisma.user.findUnique({ where: { id: req.params.userId } });
  if (!user) return res.status(404).json({ error: "User not found" });
  const effective = await getEffectiveTier(user.id);
  // v37: any paid tier unlocks editing.
  if (!isPaidTier(effective.tier)) {
    return res.status(403).json({
      error: "Editing your business info requires a paid plan. Tap Upgrade to choose one.",
    });
  }

  const existing = await prisma.businessProfile.findFirst({
    where: { userId: req.params.userId },
    orderBy: { created