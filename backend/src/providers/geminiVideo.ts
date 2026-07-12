/**
 * Google Gemini API video provider - routes between Omni Flash (cheap/fast
 * drafts) and Veo 3.1 (final, higher-res renders).
 *
 * IMPORTANT: Omni Flash only just reached API access (early July 2026) and
 * Veo 3.1 is in paid preview. Endpoint shapes, model IDs, and pricing are
 * moving targets right now - treat the request/response shapes below as a
 * best-effort scaffold and confirm against https://ai.google.dev/gemini-api/docs
 * before wiring this against a live key.
 */

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";

export type VideoTier = "draft" | "final";

export interface VideoGenRequest {
  prompt: string;
  /** Reference images that lock the subject (ambassador) or anchor the
   *  mood (logo / product / other). First entry is treated as primary. */
  referenceImageUrls: string[];
  tier: VideoTier;
  durationSeconds?: number; // 3-10s
  /** Veo 3.1 only: explicit first/last-frame interpolation. */
  firstFrameUrl?: string;
  lastFrameUrl?: string;
}

export interface VideoGenResult {
  operationId: string; // provider is async - poll for completion
  model: string;
}

function log(stage: string, message: string) {
  const ts = new Date().toISOString().slice(11, 19);
  console.log(`[${ts}] [${stage}] ${message}`);
}

function modelForTier(tier: VideoTier): string {
  // draft => Omni Flash (~$0.10/sec, 720p, up to 7 reference images + 3 clips)
  // final => Veo 3.1 (up to 4K, reference images, first/last-frame control)
  return tier === "draft" ? "gemini-omni-flash" : "veo-3.1-generate-preview";
}

export async function generateVideo(req: VideoGenRequest): Promise<VideoGenResult> {
  const model = modelForTier(req.tier);
  const apiKey = process.env.GEMINI_API_KEY;

  // Gemini's referenceImages slot accepts up to N image URLs/parts. We
  // pass them as plain URLs - the API is expected to fetch them
  // server-side. If this proves brittle, we can switch to a multipart
  // upload via the files API and pass file names instead.
  const body: Record<string, unknown> = {
    prompt: req.prompt,
    referenceImages: req.referenceImageUrls,
    durationSeconds: req.durationSeconds ?? 8,
  };

  if (req.tier === "final") {
    // Veo 3.1 supports first/last-frame interpolation. We treat
    // firstFrameUrl as the strongest single-character anchor, falling
    // back to references[0] if it isn't set.
    const firstFrame = req.firstFrameUrl ?? req.referenceImageUrls[0];
    if (firstFrame) body.firstFrame = firstFrame;
    if (req.lastFrameUrl) body.lastFrame = req.lastFrameUrl;
  }

  const res = await fetch(`${GEMINI_API_BASE}/models/${model}:generateVideo`, {
    method: "POST",
    headers: {
      "x-goog-api-key": apiKey ?? "",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    throw new Error(`Gemini video generation failed: ${res.status} ${await res.text()}`);
  }

  const data = (await res.json()) as { name: string };
  log("gemini", `submitted operationId=${data.name} model=${model}`);
  return { operationId: data.name, model };
}

export interface VideoOperationStatus {
  done: boolean;
  videoUrl?: string;
  error?: string;
}

export async function pollVideoOperation(operationId: string): Promise<VideoOperationStatus> {
  const apiKey = process.env.GEMINI_API_KEY;
  const res = await fetch(`${GEMINI_API_BASE}/${operationId}`, {
    headers: { "x-goog-api-key": apiKey ?? "" },
  });

  if (!res.ok) {
    // Transient poll failure shouldn't kill the worker - signal "still
    // running" so the caller keeps looping.
    if (res.status >= 500 || res.status === 429) {
      log("gemini-poll", `transient ${res.status} - retry`);
      return { done: false };
    }
    log("gemini-poll", `hard fail ${res.status}`);
    return { done: true, error: `Poll failed: ${res.status}` };
  }

  const data = (await res.json()) as {
    done: boolean;
    response?: {
      // Gemini returns either a videoUri or, sometimes, an array of
      // generated samples depending on the model.
      videoUrl?: string;
      videos?: Array<{ uri?: string }>;
    };
    error?: { message: string };
  };

  // Some models wrap the output under `videos[]` instead of `videoUrl`.
  const videoUrl =
    data.response?.videoUrl ?? data.response?.videos?.[0]?.uri ?? undefined;

  return {
    done: data.done,
    videoUrl,
    error: data.error?.message,
  };
}
