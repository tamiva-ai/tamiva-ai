import { Router } from "express";
import { z } from "zod";
import { prisma } from "../db/client.js";
import {
  enqueueLogoJob,
  enqueueCarouselJob,
  enqueueVideoStage,
} from "../queue/index.js";
import {
  buildLogoPrompt,
  buildCarouselSlidePrompt,
  buildFilmPrompt,
  categorizeReferences,
  pickCarouselCampaignForFreeTier,
  pickFilmConceptForFreeTier,
  CAROUSEL_SLIDES,
  LOGO_CONCEPTS,
  type BusinessContext,
  type ReferenceBundle,
} from "../prompts/index.js";
import { idempotency } from "../middleware/idempotency.js";
import { getEffectiveTier } from "../util/tier.js";

export const projectsRouter = Router();

/**
 * Loads uploaded reference photos for a business profile and
 * categorizes them by their angleLabel prefix ("Logo 1", "Ambassador 1",
 * "Product N", "Other N") so the prompt builder can address each type
 * independently.
 */
async function loadReferences(businessProfileId: string): Promise<ReferenceBundle> {
  const ambassadors = await prisma.brandAmbassador.findMany({
    where: { businessProfileId },
    select: { photoUrls: true, angleLabels: true },
  });
  const urls: string[] = [];
  const labels: string[] = [];
  for (const a of ambassadors) {
    for (let i = 0; i < a.photoUrls.length; i++) {
      urls.push(a.photoUrls[i]);
      labels.push(a.angleLabels[i] ?? "");
    }
  }
  return categorizeReferences(urls, labels);
}

function contextFromProfile(profile: {
  name: string;
  industry: string;
  tagline: string | null;
  tone: string | null;
  palettePreference: string | null;
  fontPreference: string | null;
}): BusinessContext {
  return {
    name: profile.name,
    industry: profile.industry,
    tagline: profile.tagline,
    tone: profile.tone,
    palettePreference: profile.palettePreference,
    fontPreference: profile.fontPreference,
  };
}

/**
 * v36 / S2.9 — free quota now produces copy that matches the model:
 *   "You've used your 1 free <type>. Upgrade for unlimited." instead
 *   of the stale "refreshes at midnight" line. Tier reads from the
 *   effective (post-expiry-downgrade) user tier so the message is
 *   honest even right after lapse.
 */
async function enforceFreeQuota(
  businessProfileId: string,
  type: "logo" | "carousel" | "video",
): Promise<
  | { allowed: true }
  | { allowed: false; status: 429 | 404; message: string; upgradeCopy: boolean }
> {
  const profile = await prisma.businessProfile.findUnique({
    where: { id: businessProfileId },
    include: { user: { select: { id: true, tier: true } } },
  });
  if (!profile)
    return {
      allowed: false,
      status: 404,
      message: "Business profile not found",
      upgradeCopy: false,
    };

  // Reconcile tier first so an expired Pro user gets free-tier copy.
  const effective = await getEffectiveTier(profile.user.id);
  if (effective.tier === "pro") return { allowed: true };

  // Count Projects already in flight OR finished for this type.
  const activeCount = await prisma.project.count({
    where: {
      businessProfileId,
      type,
      status: { in: ["queued", "generating", "ready"] },
    },
  });
  if (activeCount >= 1) {
    const label =
      type === "logo"
        ? "logo"
        : type === "carousel"
        ? "carousel"
        : "brand film";
    return {
      allowed: false,
      status: 429,
      message: `You've used your 1 free ${label}. Upgrade to Tamiva Pro for unlimited.`,
      upgradeCopy: true,
    };
  }

  return { allowed: true };
}

// ---------------------------------------------------------------------
// LOGO
// ---------------------------------------------------------------------

const createLogoProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  stylePrompt: z.string().min(1),
});

projectsRouter.post(
  "/logo",
  idempotency,
  async (req, res) => {
    const parsed = createLogoProjectSchema.safeParse(req.body);
    if (!parsed.success)
      return res.status(400).json({ error: parsed.error.flatten() });

    const profile = await prisma.businessProfile.findUnique({
      where: { id: parsed.data.businessProfileId },
    });
    if (!profile)
      return res
        .status(404)
        .json({ error: "Business profile not found" });

    const gate = await enforceFreeQuota(parsed.data.businessProfileId, "logo");
    if (!gate.allowed) {
      return res
        .status(gate.status)
        .json({ error: gate.message, upgradeCopy: gate.upgradeCopy });
    }

    const refs = await loadReferences(profile.id);
    const ctx = contextFromProfile(profile);

    const conceptIndex =
      LOGO_CONCEPTS[LOGO_CONCEPTS.length - 1].index;
    const prompt = buildLogoPrompt(ctx, refs, conceptIndex);

    const project = await prisma.project.create({
      data: {
        businessProfileId: profile.id,
        type: "logo",
        status: "queued",
      },
    });

    await prisma.generationJob.create({
      data: {
        projectId: project.id,
        stage: "hero_image",
        provider: "gpt_image",
        status: "queued",
        inputPayload: {
          prompt,
          conceptIndex,
          refCount: refs.logoUrl ? 1 : 0,
        },
      },
    });

    await enqueueLogoJob({
      projectId: project.id,
      prompt,
      referenceImageUrls: refs.logoUrl ? [refs.logoUrl] : [],
    });

    res.status(202).json({ projectId: project.id, status: "queued" });
  },
);

// ---------------------------------------------------------------------
// CAROUSEL
// ---------------------------------------------------------------------

const createCarouselProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  slideCount: z.number().int().min(1).max(30).default(5),
  topic: z.string().min(1).optional(),
});

projectsRouter.post(
  "/carousel",
  idempotency,
  async (req, res) => {
    const parsed = createCarouselProjectSchema.safeParse(req.body);
    if (!parsed.success)
      return res.status(400).json({ error: parsed.error.flatten() });

    const profile = await prisma.businessProfile.findUnique({
      where: { id: parsed.data.businessProfileId },
    });
    if (!profile)
      return res
        .status(404)
        .json({ error: "Business profile not found" });

    const gate = await enforceFreeQuota(
      parsed.data.businessProfileId,
      "carousel",
    );
    if (!gate.allowed) {
      return res
        .status(gate.status)
        .json({ error: gate.message, upgradeCopy: gate.upgradeCopy });
    }

    const refs = await loadReferences(profile.id);
    const ctx = contextFromProfile(profile);

    const profileWithTier = await prisma.businessProfile.findUnique({
      where: { id: profile.id },
      include: { user: { select: { id: true, tier: true } } },
    });
    const effective = await getEffectiveTier(profileWithTier!.user.id);
    const isPro = effective.tier === "pro";

    const campaignIndex = isPro ? undefined : pickCarouselCampaignForFreeTier();
    const effectiveSlideCount = isPro ? parsed.data.slideCount : 1;

    const slides = Array.from(
      { length: effectiveSlideCount },
      (_, i) =>
        buildCarouselSlidePrompt(ctx, refs, campaignIndex ?? 1, i + 1),
    );

    const project = await prisma.project.create({
      data: {
        businessProfileId: profile.id,
        type: "carousel",
        status: "queued",
      },
    });

    await prisma.generationJob.create({
      data: {
        projectId: project.id,
        stage: "copy_generation",
        provider: "gpt_image",
        status: "queued",
        inputPayload: {
          slideCount: effectiveSlideCount,
          campaignIndex,
        },
      },
    });

    await enqueueCarouselJob({
      projectId: project.id,
      slidePrompts: slides,
      slideReferenceImageUrls: slides.map(() =>
        refs.ambassadorUrl ? [refs.ambassadorUrl] : [],
      ),
    });

    res.status(202).json({ projectId: project.id, status: "queued" });
  },
);

// ---------------------------------------------------------------------
// VIDEO
// ---------------------------------------------------------------------

const createVideoProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  tier: z.enum(["draft", "final"]).default("draft"),
});

projectsRouter.post(
  "/video",
  idempotency,
  async (req, res) => {
    const parsed = createVideoProjectSchema.safeParse(req.body);
    if (!parsed.success)
      return res.status(400).json({ error: parsed.error.flatten() });

    const profile = await prisma.businessProfile.findUnique({
      where: { id: parsed.data.businessProfileId },
    });
    if (!profile)
      return res
        .status(404)
        .json({ error: "Business profile not found" });

    const gate = await enforceFreeQuota(
      parsed.data.businessProfileId,
      "video",
    );
    if (!gate.allowed) {
      return res
        .status(gate.status)
        .json({ error: gate.message, upgradeCopy: gate.upgradeCopy });
    }

    const refs = await loadReferences(profile.id);
    const ctx = contextFromProfile(profile);

    const profileWithTier = await prisma.businessProfile.findUnique({
      where: { id: profile.id },
      include: { user: { select: { id: true, tier: true } } },
    });
    const effective = await getEffectiveTier(profileWithTier!.user.id);
    const isPro = effective.tier === "pro";

    const conceptIndex = isPro ? 1 : pickFilmConceptForFreeTier();
    const prompt = buildFilmPrompt(ctx, refs, conceptIndex);

    const project = await prisma.project.create({
      data: {
        businessProfileId: profile.id,
        type: "video",
        status: "queued",
      },
    });

    await prisma.generationJob.create({
      data: {
        projectId: project.id,
        stage: "render",
        provider:
          parsed.data.tier === "final" ? "veo_3_1" : "omni_flash",
        status: "queued",
        inputPayload: {
          prompt,
          conceptIndex,
          tier: parsed.data.tier,
          durationSeconds: 10,
        },
      },
    });

    await enqueueVideoStage({
      projectId: project.id,
      stage: "render",
      prompt,
      referenceImageUrls: refs.ambassadorUrl ? [refs.ambassadorUrl] : [],
      tier: parsed.data.tier,
    });

    res.status(202).json({
      projectId: project.id,
      status: "queued",
      conceptIndex,
    });
  },
);

// ---------------------------------------------------------------------
// BULK GENERATION (Pro only)
// ---------------------------------------------------------------------

projectsRouter.post("/bulk", async (req, res) => {
  const schema = z.object({ businessProfileId: z.string().uuid() });
  const parsed = schema.safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: parsed.error.flatten() });

  const profile = await prisma.businessProfile.findUnique({
    where: { id: parsed.data.businessProfileId },
    include: { user: { select: { id: true, tier: true } } },
  });
  if (!profile)
    return res.status(404).json({ error: "Business profile not found" });
  const effective = await getEffectiveTier(profile.user.id);
  if (effective.tier !== "pro") {
    return res.status(403).json({
      error: "Bulk generation requires Tamiva Pro. Pay ₹5000 to unlock.",
    });
  }

  const refs = await loadReferences(profile.id);
  const ctx = contextFromProfile(profile);

  const projectIds: {
    logo: string[];
    carousel: string[];
    video: string[];
  } = { logo: [], carousel: [], video: [] };

  for (let conceptIndex = 1; conceptIndex <= 5; conceptIndex++) {
    const project = await prisma.project.create({
      data: { businessProfileId: profile.id, type: "logo", status: "queued" },
    });
    const prompt = buildLogoPrompt(ctx, refs, conceptIndex);
    await prisma.generationJob.create({
      data: {
        projectId: project.id,
        stage: "hero_image",
        provider: "gpt_image",
        status: "queued",
        inputPayload: { prompt, conceptIndex, refCount: refs.logoUrl ? 1 : 0 },
      },
    });
    await enqueueLogoJob({
      projectId: project.id,
      prompt,
      referenceImageUrls: refs.logoUrl ? [refs.logoUrl] : [],
    });
    projectIds.logo.push(project.id);
  }

  for (let campaignIndex = 1; campaignIndex <= 5; campaignIndex++) {
    for (let dup = 0; dup < 2; dup++) {
      const project = await prisma.project.create({
        data: {
          businessProfileId: profile.id,
          type: "carousel",
          status: "queued",
        },
      });
      const slidePrompts = CAROUSEL_SLIDES.map((s) =>
        buildCarouselSlidePrompt(ctx, refs, campaignIndex, s.position),
      );
      await prisma.generationJob.create({
        data: {
          projectId: project.id,
          stage: "copy_generation",
          provider: "gpt_image",
          status: "queued",
          inputPayload: { slideCount: 5, campaignIndex },
        },
      });
      await enqueueCarouselJob({
        projectId: project.id,
        slidePrompts,
        slideReferenceImageUrls: slidePrompts.map(() =>
          refs.ambassadorUrl ? [refs.ambassadorUrl] : [],
        ),
      });
      projectIds.carousel.push(project.id);
    }
  }

  for (let conceptIndex = 1; conceptIndex <= 5; conceptIndex++) {
    const project = await prisma.project.create({
      data: { businessProfileId: profile.id, type: "video", status: "queued" },
    });
    const prompt = buildFilmPrompt(ctx, refs, conceptIndex);
    await prisma.generationJob.create({
      data: {
        projectId: project.id,
        stage: "render",
        provider: "omni_flash",
        status: "queued",
        inputPayload: {
          prompt,
          conceptIndex,
          tier: "draft",
          durationSeconds: 10,
        },
      },
    });
    await enqueueVideoStage({
      projectId: project.id,
      stage: "render",
      prompt,
      referenceImageUrls: refs.ambassadorUrl ? [refs.ambassadorUrl] : [],
      tier: "draft",
    });
    projectIds.video.push(project.id);
  }

  res.status(202).json({ projectIds });
});

// ---------------------------------------------------------------------
// GET /projects/:id
// ---------------------------------------------------------------------

projectsRouter.get("/:id", async (req, res) => {
  const project = await prisma.project.findUnique({
    where: { id: req.params.id },
    include: { assets: true, jobs: true },
  });
  if (!project) return res.status(404).json({ error: "Not found" });
  res.json(project);
});                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   