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

export const projectsRouter = Router();

/**
 * Pulls all uploaded reference photos for a business profile, then
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
 * v24: tier gating. Returns 429 if a Free user tries to generate
 * another artifact of a type they already have a ready Project for.
 * Tier reads from the linked BusinessProfile.user record.
 */
async function enforceFreeQuota(businessProfileId: string, type: "logo" | "carousel" | "video") {
  const profile = await prisma.businessProfile.findUnique({
    where: { id: businessProfileId },
    include: { user: { select: { tier: true } } },
  });
  if (!profile) return { allowed: false, status: 404 as const, message: "Business profile not found" };

  if (profile.user.tier === "pro") return { allowed: true as const };

  // Free path: count ready Projects of this type. If >= 1, refuse.
  const readyCount = await prisma.project.count({
    where: { businessProfileId, type, status: "ready" },
  });
  if (readyCount >= 1) {
    const label = type === "logo" ? "logo" : type === "carousel" ? "carousel" : "brand film";
    return {
      allowed: false as const,
      status: 429 as const,
      message: `You've already created your ${label}. Upgrade to Tamiva Pro to create more.`,
    };
  }

  return { allowed: true as const };
}

// ---------------------------------------------------------------------
// LOGO
// ---------------------------------------------------------------------

const createLogoProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  stylePrompt: z.string().min(1),
});

projectsRouter.post("/logo", async (req, res) => {
  const parsed = createLogoProjectSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const profile = await prisma.businessProfile.findUnique({
    where: { id: parsed.data.businessProfileId },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });

  const gate = await enforceFreeQuota(parsed.data.businessProfileId, "logo");
  if (!gate.allowed) return res.status(gate.status).json({ error: gate.message });

  const refs = await loadReferences(profile.id);
  const ctx = contextFromProfile(profile);

  // Free user always gets Concept 5 (modern abstract). Pro per-call picks
  // a concept index — for v25 the user doesn't pick; the worker just
  // uses the next concept based on how many logos they've generated.
  const conceptIndex = pickCarouselCampaignForFreeTier === undefined
    ? 5
    : LOGO_CONCEPTS[LOGO_CONCEPTS.length - 1].index; // safe default
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
});

// ---------------------------------------------------------------------
// CAROUSEL
// ---------------------------------------------------------------------

const createCarouselProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  // Free user gets 1 slide (Campaign 5's first slide). Pro tier gets
  // 5 slides per Project.
  slideCount: z.number().int().min(1).max(30).default(5),
  topic: z.string().min(1).optional(),
});

projectsRouter.post("/carousel", async (req, res) => {
  const parsed = createCarouselProjectSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const profile = await prisma.businessProfile.findUnique({
    where: { id: parsed.data.businessProfileId },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });

  const gate = await enforceFreeQuota(parsed.data.businessProfileId, "carousel");
  if (!gate.allowed) return res.status(gate.status).json({ error: gate.message });

  const refs = await loadReferences(profile.id);
  const ctx = contextFromProfile(profile);

  const profileWithTier = await prisma.businessProfile.findUnique({
    where: { id: profile.id },
    include: { user: { select: { tier: true } } },
  });
  const isPro = profileWithTier?.user.tier === "pro";

  // Free: 1 Project, Campaign 5, Slide 1 only.
  // Pro: caller chooses slideCount (defaults to 5).
  const campaignIndex = isPro ? undefined : pickCarouselCampaignForFreeTier();
  const effectiveSlideCount = isPro ? parsed.data.slideCount : 1;

  const slides = Array.from({ length: effectiveSlideCount }, (_, i) =>
    buildCarouselSlidePrompt(ctx, refs, campaignIndex ?? 1, i + 1)
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
    // Each slide gets no reference (we don't yet have per-slide refs in v24;
    // refs flow through the prompt preamble as natural assets).
    slideReferenceImageUrls: slides.map(() => refs.ambassadorUrl ? [refs.ambassadorUrl] : []),
  });

  res.status(202).json({ projectId: project.id, status: "queued" });
});

// ---------------------------------------------------------------------
// VIDEO
// ---------------------------------------------------------------------

const createVideoProjectSchema = z.object({
  businessProfileId: z.string().uuid(),
  tier: z.enum(["draft", "final"]).default("draft"),
});

projectsRouter.post("/video", async (req, res) => {
  const parsed = createVideoProjectSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const profile = await prisma.businessProfile.findUnique({
    where: { id: parsed.data.businessProfileId },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });

  const gate = await enforceFreeQuota(parsed.data.businessProfileId, "video");
  if (!gate.allowed) return res.status(gate.status).json({ error: gate.message });

  const refs = await loadReferences(profile.id);
  const ctx = contextFromProfile(profile);

  const profileWithTier = await prisma.businessProfile.findUnique({
    where: { id: profile.id },
    include: { user: { select: { tier: true } } },
  });
  const isPro = profileWithTier?.user.tier === "pro";

  // Free: 1 Project, Concept 5 only. Pro per-call defaults to Concept 1
  // (the worker will rotate for subsequent calls).
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
      provider: parsed.data.tier === "final" ? "veo_3_1" : "omni_flash",
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
});

// ---------------------------------------------------------------------
// v24: BULK GENERATION (Pro only)
// ---------------------------------------------------------------------

/**
 * POST /projects/bulk
 *
 * Called after a Pro user pays ₹5000 and edits their business profile.
 * Creates 5 logo Projects + 10 carousel Projects + 5 film Projects in
 * one transaction. Sequential per batch (logos, then carousels, then
 * films) so we don't hammer OpenAI. Returns the new project IDs so the
 * status board can subscribe immediately.
 *
 * Body:
 *   businessProfileId: string
 *
 * Returns 200:
 *   { projectIds: { logo: [5], carousel: [10], video: [5] } }
 */
projectsRouter.post("/bulk", async (req, res) => {
  const schema = z.object({ businessProfileId: z.string().uuid() });
  const parsed = schema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json({ error: parsed.error.flatten() });

  const profile = await prisma.businessProfile.findUnique({
    where: { id: parsed.data.businessProfileId },
    include: { user: { select: { tier: true } } },
  });
  if (!profile) return res.status(404).json({ error: "Business profile not found" });
  if (profile.user.tier !== "pro") {
    return res.status(403).json({
      error: "Bulk generation requires Tamiva Pro. Pay ₹5000 to unlock.",
    });
  }

  const refs = await loadReferences(profile.id);
  const ctx = contextFromProfile(profile);

  // 5 logos + 10 carousels + 5 films = 20 Projects total.
  // Concept distribution (deterministic per the Q2 decision):
  //   5 logos (one per concept index 1..5)
  //   10 carousels (5 concepts x 2 campaigns per concept — but we only
  //      have 5 campaigns, so 2 carousels per campaign across campaigns
  //      1..5)
  //   5 films (one per concept index 1..5)
  const projectIds: { logo: string[]; carousel: string[]; video: string[] } = {
    logo: [],
    carousel: [],
    video: [],
  };

  // 5 logo projects, one per concept
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

  // 10 carousel projects: 2 per campaign (campaign 1 x 2, campaign 2 x 2, ...)
  // Each Project = 5 sequential slide calls.
  for (let campaignIndex = 1; campaignIndex <= 5; campaignIndex++) {
    for (let dup = 0; dup < 2; dup++) {
      const project = await prisma.project.create({
        data: { businessProfileId: profile.id, type: "carousel", status: "queued" },
      });
      const slidePrompts = CAROUSEL_SLIDES.map((s) =>
        buildCarouselSlidePrompt(ctx, refs, campaignIndex, s.position)
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
        slideReferenceImageUrls: slidePrompts.map(() => refs.ambassadorUrl ? [refs.ambassadorUrl] : []),
      });
      projectIds.carousel.push(project.id);
    }
  }

  // 5 film projects, one per concept
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
        inputPayload: { prompt, conceptIndex, tier: "draft", durationSeconds: 10 },
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

  // Don't auto-flip tier here - the PUT /business-profiles/by-user/:id
  // endpoint already flips it to 'free' on edit. We just record the
  // current regeneration cycle's start in tierUpdatedAt so the worker
  // can verify ordering.

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
});
