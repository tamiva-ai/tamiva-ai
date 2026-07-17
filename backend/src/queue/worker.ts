import "dotenv/config";
import { Worker, Job } from "bullmq";
import { connection, LogoJobData, CarouselJobData, VideoJobData } from "./index.js";
import { generateImage, generateCarouselSlides } from "../providers/openaiImage.js";
import { generateVideo, pollVideoOperation, downloadVideo } from "../providers/geminiVideo.js";
import { prisma } from "../db/client.js";
import { pruneOldProviderCalls } from "../util/providerLog.js";

/**
 * Timestamped log lines so a long generation is easy to read in the
 * Railway console. Format: [HH:MM:SS] [generation] <message>
 * Cheap to add - just console.log - and only invoked when a job is
 * actually running, so they don't spam the logs at rest.
 */
function log(stage: string, message: string) {
  const ts = new Date().toISOString().slice(11, 19);
  console.log(`[${ts}] [${stage}] ${message}`);
}

/**
 * Per-artifact daily rate limit. Counts the number of Project rows for
 * a given businessProfile+type pair created since the start of the
 * user's local day (UTC midnight is a fine approximation; refine to a
 * per-user TZ once we have one).
 *
 * IMPORTANT: this check MUST run in the route handler BEFORE creating
 * the new Project row. If it runs in the worker after the project is
 * already created, the just-created project gets counted and the check
 * always fails. See projects.ts where the rate limit is now enforced
 * up front.
 */
const DAILY_LIMIT_PER_ARTIFACT = 1;

async function processLogo(job: Job<LogoJobData>) {
  const { projectId, prompt, referenceImageUrls } = job.data;
  const startedAt = Date.now();
  const refCount = referenceImageUrls?.length ?? 0;
  log("logo", `start projectId=${projectId} refs=${refCount} n=4`);

  const project = await prisma.project.findUnique({ where: { id: projectId } });
  if (!project) throw new Error(`Project ${projectId} not found`);

  await prisma.project.update({
    where: { id: projectId },
    data: { status: "generating" },
  });

  const jobId = job.id;
  const result = await generateImage({
    prompt,
    referenceImageUrls,
    n: 1,
    projectId,
    jobId: String(jobId),
  });

  await prisma.asset.createMany({
    data: result.urls.map((url) => ({
      projectId,
      type: "logo_variant",
      url,
    })),
  });

  await prisma.project.update({
    where: { id: projectId },
    data: { status: "ready" },
  });
  log("logo", `done projectId=${projectId} urls=${result.urls.length} ms=${Date.now() - startedAt}`);
}

async function processCarousel(job: Job<CarouselJobData>) {
  const { projectId, slidePrompts, slideReferenceImageUrls } = job.data;
  const startedAt = Date.now();
  const refTotal = (slideReferenceImageUrls ?? []).reduce(
    (n, r) => n + r.length,
    0,
  );
  log("carousel", `start projectId=${projectId} slides=${slidePrompts.length} refs=${refTotal}`);

  const project = await prisma.project.findUnique({ where: { id: projectId } });
  if (!project) throw new Error(`Project ${projectId} not found`);

  await prisma.project.update({
    where: { id: projectId },
    data: { status: "generating" },
  });

  // Pad the per-slide ref array so it's always the same length as
  // slidePrompts - missing entries degrade to text-only.
  const refList = (slideReferenceImageUrls ?? []).slice();
  while (refList.length < slidePrompts.length) refList.push([]);

  const jobId = job.id;
  const urls = await generateCarouselSlides(slidePrompts, refList, { projectId, jobId: String(jobId) });

  await prisma.asset.createMany({
    data: urls.map((url, index) => ({
      projectId,
      type: "carousel_slide",
      slideIndex: index,
      url,
    })),
  });

  // Compositing (text/logo overlay via Sharp/Puppeteer) happens as a
  // follow-up step - see src/render/compositeCarousel.ts (TODO).
  // For now we mark the project ready once all slide images are saved;
  // the front-end reads slideIndex to order them in the reveal.
  await prisma.project.update({
    where: { id: projectId },
    data: { status: "ready" },
  });
  log("carousel", `done projectId=${projectId} urls=${urls.length}/${slidePrompts.length} ms=${Date.now() - startedAt}`);
}

async function processVideoStage(job: Job<VideoJobData>) {
  const { projectId, prompt, referenceImageUrls, tier, firstFrameUrl, lastFrameUrl } = job.data;
  const startedAt = Date.now();
  log("video", `start projectId=${projectId} tier=${tier} refs=${referenceImageUrls.length}`);

  const project = await prisma.project.findUnique({ where: { id: projectId } });
  if (!project) throw new Error(`Project ${projectId} not found`);

  await prisma.project.update({
    where: { id: projectId },
    data: { status: "generating" },
  });

  const jobId = job.id;
  // v38-compatible signature: provider calls record ProviderCall rows
  // with projectId + jobId. The new code uses the real Veo 3.0 model
  // IDs and the correct `:generateVideos` REST endpoint.
  const { operationId, model } = await generateVideo({
    prompt,
    referenceImageUrls: referenceImageUrls ?? [],
    tier,
    firstFrameUrl,
    lastFrameUrl,
    projectId,
    jobId: String(jobId),
  });
  log("video", `submitted projectId=${projectId} operationId=${operationId} model=${model}`);

  // Persist the chosen model + operation id on GenerationJob.inputPayload
  // so the admin portal / debug view shows what we actually called. We
  // update the most-recent job row (not all rows for the project) to
  // avoid clobbering earlier stages.
  await prisma.generationJob.updateMany({
    where: { projectId, status: { in: ["queued", "running"] } },
    data: {
      status: "running",
      inputPayload: {
        // Prisma's Json type doesn't accept a typed spread on
        // VideoJobData (no index signature) - cast through unknown.
        ...(job.data as unknown as Record<string, unknown>),
        model,
        operationId,
      } as object,
    },
  });

  // Simple inline poll loop. In production this should be a separate
  // delayed requeue so the worker thread isn't held for the full video
  // render (~30-90s).
  let status = await pollVideoOperation(operationId, projectId, String(jobId));
  let attempts = 0;
  const MAX_POLL_ATTEMPTS = 240; // ~20 minutes at 5s intervals
  const POLL_INTERVAL_MS = 5_000;
  while (!status.done && attempts < MAX_POLL_ATTEMPTS) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    attempts++;
    status = await pollVideoOperation(operationId, projectId, String(jobId));
    // Heartbeat every 6 polls (30s) so an idle worker doesn't look frozen
    // in the logs without spamming them on every single tick.
    if (attempts % 6 === 0) {
      log(
        "video",
        `polling projectId=${projectId} op=${operationId} attempt=${attempts}/${MAX_POLL_ATTEMPTS} done=${status.done} ms=${Date.now() - startedAt}`,
      );
    }
  }

  if (!status.done) {
    throw new Error(`Video generation timed out after ${attempts} polls`);
  }
  if (status.error) {
    throw new Error(status.error);
  }
  if (!status.videoUrl) {
    throw new Error("Video reported done but no video URL");
  }

  // NEW: download the MP4 bytes from Google's file URI to disk. The
  // raw URI is short-lived (~1h) and the Flutter client expects a
  // stable URL on our own backend. downloadVideo() writes to
  // uploads/<uuid>.mp4 and returns the persistent public URL.
  const downloaded = await downloadVideo(status.videoUrl, projectId, String(jobId));
  log(
    "video",
    `downloaded projectId=${projectId} bytes=${downloaded.byteLength} url=${downloaded.publicUrl}`,
  );

  await prisma.asset.create({
    data: {
      projectId,
      type: "video_final",
      url: downloaded.publicUrl,
    },
  });

  await prisma.project.update({
    where: { id: projectId },
    data: { status: "ready" },
  });
  log(
    "video",
    `done projectId=${projectId} polls=${attempts} bytes=${downloaded.byteLength} ms=${Date.now() - startedAt}`,
  );
}

export const worker = new Worker(
  "generation",
  async (job) => {
    if (job.name === "logo") return processLogo(job as Job<LogoJobData>);
    if (job.name === "carousel") return processCarousel(job as Job<CarouselJobData>);
    if (job.name.startsWith("video:")) return processVideoStage(job as Job<VideoJobData>);
    throw new Error(`Unknown job type: ${job.name}`);
  },
  { connection },
);

worker.on("failed", async (job, err) => {
  console.error(`Job ${job?.id} (${job?.name}) failed:`, err.message);
  // Surface the failure to the front-end so it doesn't sit in an
  // infinite spinner. The route already created the Project row;
  // flip its status to "failed" and persist the error so the UI can
  // show a meaningful retry button.
  if (!job?.data?.projectId) return;
  try {
    await prisma.project.update({
      where: { id: job.data.projectId },
      data: { status: "failed" },
    });
    // Also record the error on the GenerationJob row so it shows up
    // in the admin / debug view.
    const generationJob = await prisma.generationJob.findFirst({
      where: { projectId: job.data.projectId },
      orderBy: { createdAt: "desc" },
    });
    if (generationJob) {
      await prisma.generationJob.update({
        where: { id: generationJob.id },
        data: {
          status: "failed",
          error: err.message.slice(0, 500),
        },
      });
    }
  } catch (e) {
    console.error("Failed to mark project as failed:", e);
  }
});
// v38: Background maintenance for provider-call logs. Prune the
// ProviderCall table on boot and every 6 hours to keep the 3-day
// retention promise. Idempotent; failure is logged but doesn't kill
// the worker.
async function runMaintenance() {
  try {
    const pruned = await pruneOldProviderCalls();
    if (pruned > 0) console.log(`[maintenance] pruned ${pruned} old provider call log(s)`);
  } catch (err) {
    console.error("[maintenance] pruneOldProviderCalls failed:", err);
  }
}

void runMaintenance();
setInterval(runMaintenance, 6 * 60 * 60 * 1000).unref();

console.log("Worker started, listening on 'generation' queue");