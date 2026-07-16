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
 * Returns the full history of every Project ever produced for this
 * business profile, one entry per project (most recent first). Used by
 * the Flutter "Artifacts" screen to render four folders (one per
 * generation type) and let the user re-open any past artifact.
 *
 * The shape mirrors the Flutter BusinessProfileProjectSummary class
 * (flutter_app/lib/services/api_client.dart). Fields:
 *   id, type, status, createdAt, updatedAt,
 *   assetCount, firstAssetUrlSample, durationSeconds, jobs[]
 *
 * `firstAssetUrlSample` is the URL of the first asset (sorted by
 * createdAt then id for determinism). It's null if the project has no
 * assets yet — useful for in-progress/failed projects where we still
 * want to render the row but show a "broken image" placeholder.
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
      assets: { orderBy: [{ createdAt: "asc" }, { id: "asc" }] },
      jobs: { orderBy: { createdAt: "asc" } },
    },
    orderBy: { createdAt: "desc" },
  });

  res.json({
    projects: projects.map((p) => {
      const firstAsset = p.assets[0] ?? null;
      return {
        id: p.id,
        type: p.type,
        status: p.status,
        createdAt: p.createdAt.toISOString(),
        updatedAt: p.updatedAt.toISOString(),
        assetCount: p.assets.length,
        firstAssetUrlSample: firstAsset ? firstAsset.url : null,
        // Wall-clock duration the project spent in flight. Matches the
        // shape returned by /admin/projects so the client can render
        // both endpoints interchangeably.
        durationSeconds: Math.max(
          0,
          Math.floor((p.updatedAt.getTime() - p.createdAt.getTime()) / 1000),
        ),
        jobs: p.jobs.map((j) => ({
          stage: j.stage,
          provider: j.provider,
          status: j.status,
          error: j.error ?? null,
        })),
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
 