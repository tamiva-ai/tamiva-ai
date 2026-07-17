/**
 * Google Gemini API video provider - submits Veo generation requests,
 * polls the long-running operation to completion, and (NEW in this
 * revision) downloads the resulting MP4 to disk so Asset.url is a
 * stable URL on our own backend instead of a short-lived Google
 * file URI.
 *
 * v38 base behaviour preserved:
 *   - wraps every outbound fetch in `withProviderCall` so the admin
 *     dashboard can inspect prompts, responses, status, timing.
 *   - signature is `generateVideo({ ... , projectId?, jobId? })` and
 *     `pollVideoOperation(operationId, projectId?, jobId?)` so callers
 *     can correlate provider-call rows to a generation job.
 *
 * REST surface corrected against the current public Gemini API:
 *   - submit endpoint: POST .../v1beta/models/{model}:generateVideos
 *     (the previous `:generateVideo` (singular) URL 404s on Google's
 *     side - this is why AI Studio logs showed zero traffic).
 *   - model IDs: veo-3.0-fast-generate-preview (draft) and
 *     veo-3.0-generate-preview (final). veo-3.1-generate-preview and
 *     gemini-omni-flash are NOT exposed on the public Gemini API
 *     today; Veo 3.1 lives on Vertex AI under a different URL/auth
 *     and Omni Flash was a speculative label that hasn't shipped.
 *   - request body: `{ instances: [{ prompt, image? }], parameters:
 *     { aspectRatio, durationSeconds, personGeneration } }`. Images
 *     are inline base64 - the API does not fetch URLs server-side.
 *   - poll URL: GET /v1beta/{name} where {name} is the full operation
 *     name returned at submit (e.g. models/veo-3.0-fast-generate-
 *     preview/operations/<uuid>).
 *   - success shape: response.generateVideoResponse.generatedSamples
 *     [0].video.uri (NOT response.videoUrl and NOT
 *     response.videos[0].uri - those never existed).
 *
 * Source: https://ai.google.dev/gemini-api/docs/video and
 * https://ai.google.dev/api/rest/v1beta/models/generateVideos.
 */

import { promises as fs } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  withProviderCall,
  defaultClassifyError,
} from "../util/providerLog.js";

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";

const REQUEST_TIMEOUT_MS = 30_000;
const POLL_TIMEOUT_MS = 60_000;
const DOWNLOAD_TIMEOUT_MS = 120_000;
const MAX_INLINE_IMAGE_BYTES = 4 * 1024 * 1024; // 4 MB

export type VideoTier = "draft" | "final";

export interface VideoGenRequest {
  prompt: string;
  referenceImageUrls: string[];
  tier: VideoTier;
  durationSeconds?: number;
  firstFrameUrl?: string;
  lastFrameUrl?: string;
  /** v38: piped through so the ProviderCall row links to a job. */
  projectId?: string;
  /** v38: piped through so the ProviderCall row links to a job. */
  jobId?: string;
}

export interface VideoGenResult {
  operationId: string;
  model: string;
}

export interface VideoOperationStatus {
  done: boolean;
  videoUrl?: string;
  error?: string;
}

/**
 * Maps our product tier to a model name on the public Gemini API.
 * Fast variant for drafts; full Veo 3.0 for final renders.
 *
 * Note: v38 had this mapped to fabricated IDs. The previous values
 * (`gemini-omni-flash`, `veo-3.1-generate-preview`) 404 on Google's
 * side - see audit story in ACTIVITY_B_SUMMARY.md.
 */
export function modelForTier(tier: VideoTier): string {
  return tier === "draft"
    ? "veo-3.0-fast-generate-preview"
    : "veo-3.0-generate-preview";
}

/**
 * Timestamped log line. One event per call with a stage tag so the
 * Railway log tail is grep-friendly. We never log the API key.
 */
function log(stage: string, message: string): void {
  const ts = new Date().toISOString().slice(11, 19);
  console.log(`[${ts}] [${stage}] ${message}`);
}

function truncate(s: string, n: number): string {
  return s.length <= n ? s : `${s.slice(0, n)}...`;
}

/**
 * Fetches an image URL and returns inline-base64 + sniffed mime.
 * The Gemini REST API does not accept public URLs server-side - we
 * have to inline the bytes here. Returns null on any failure so the
 * caller can fall back to text-only generation rather than fail the
 * whole video.
 */
async function urlToImageBase64(
  url: string,
): Promise<{ base64: string; mimeType: string } | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) {
      log("gemini-ref", `fetch failed url=${truncate(url, 200)} status=${res.status}`);
      return null;
    }
    const mime = res.headers.get("content-type") ?? "image/jpeg";
    if (!mime.startsWith("image/")) {
      log("gemini-ref", `non-image mime url=${truncate(url, 200)} mime=${mime}`);
      return null;
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.byteLength === 0) {
      log("gemini-ref", `empty body url=${truncate(url, 200)}`);
      return null;
    }
    if (buf.byteLength > MAX_INLINE_IMAGE_BYTES) {
      log("gemini-ref", `oversize ref url=${truncate(url, 200)} bytes=${buf.byteLength}`);
      return null;
    }
    return { base64: buf.toString("base64"), mimeType: mime };
  } catch (e) {
    log("gemini-ref", `fetch threw url=${truncate(url, 200)} err=${(e as Error).message}`);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function getApiKey(): string {
  const k = process.env.GEMINI_API_KEY;
  if (!k) {
    throw new Error(
      "GEMINI_API_KEY is not configured. Set it in Railway -> Variables.",
    );
  }
  return k;
}

/**
 * Submit an async video generation request. Returns the operation
 * name; the caller must poll via {@link pollVideoOperation}.
 *
 * v38 contract preserved: returns `{ operationId, model }`. Worker
 * callers pass `projectId` / `jobId` so the ProviderCall row is
 * correlatable.
 */
export async function generateVideo(req: VideoGenRequest): Promise<VideoGenResult> {
  const model = modelForTier(req.tier);
  const startedAt = Date.now();

  return withProviderCall({
    provider: "gemini",
    operation: "gemini.generateVideo",
    projectId: req.projectId,
    jobId: req.jobId,
    request: {
      model,
      tier: req.tier,
      promptLen: req.prompt.length,
      promptPreview: req.prompt.slice(0, 240),
      referenceCount: req.referenceImageUrls.length,
      durationSeconds: req.durationSeconds ?? 8,
      hasFirstFrame: Boolean(req.firstFrameUrl),
      hasLastFrame: Boolean(req.lastFrameUrl),
    },
    fn: async () => {
      const apiKey = getApiKey();

      // Build the single instance. Image-to-video via inline base64
      // is the only documented shape. We take the first reference
      // only because Gemini takes one image per instance - extras
      // would just inflate the request body.
      //
      // VideoJobData.referenceImageUrls is typed `string[]` so each
      // entry is always a plain string URL.
      const primaryRefUrl = req.referenceImageUrls[0];
      let imagePart: { bytesBase64Encoded: string; mimeType: string } | undefined;
      if (primaryRefUrl) {
        const inlined = await urlToImageBase64(primaryRefUrl);
        if (inlined) {
          imagePart = {
            bytesBase64Encoded: inlined.base64,
            mimeType: inlined.mimeType,
          };
          log(
            "gemini",
            `inlined 1 reference mime=${inlined.mimeType} bytes=${Math.floor(
              (Buffer.from(inlined.base64, "base64").byteLength * 3) / 4,
            )}`,
          );
        } else {
          log(
            "gemini",
            `reference unavailable, falling back to text-only; prompt=${truncate(req.prompt, 80)}`,
          );
        }
      }

      const instance: Record<string, unknown> = { prompt: req.prompt };
      if (imagePart) instance.image = imagePart;

      const body = {
        instances: [instance],
        parameters: {
          aspectRatio: "16:9",
          durationSeconds: req.durationSeconds ?? 8,
          personGeneration: "dont_allow",
        },
      };

      const url =
        `${GEMINI_API_BASE}/models/${model}:generateVideos?key=${encodeURIComponent(apiKey)}`;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

      log("gemini", `submit model=${model} promptLen=${req.prompt.length} hasImage=${!!imagePart}`);

      try {
        const res = await fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
          signal: controller.signal,
        });
        const text = await res.text();
        if (!res.ok) {
          log(
            "gemini",
            `submit FAIL status=${res.status} body=${truncate(text, 500)} ms=${Date.now() - startedAt}`,
          );
          throw new Error(
            `Gemini video generation failed: ${res.status} ${truncate(text, 300)}`,
          );
        }

        let data: { name?: string };
        try {
          data = JSON.parse(text);
        } catch {
          log("gemini", `submit returned non-JSON body=${truncate(text, 300)}`);
          throw new Error(
            `Gemini submit returned non-JSON response (${text.length} bytes)`,
          );
        }
        if (!data.name) {
          log("gemini", `submit missing name field body=${truncate(text, 300)}`);
          throw new Error(`Gemini submit response missing 'name' field`);
        }

        log(
          "gemini",
          `submitted operationId=${data.name} model=${model} ms=${Date.now() - startedAt}`,
        );
        return { operationId: data.name, model };
      } catch (e) {
        if ((e as Error).name === "AbortError") {
          log("gemini", `submit TIMEOUT ms=${REQUEST_TIMEOUT_MS}`);
        }
        throw e;
      } finally {
        clearTimeout(timer);
      }
    },
    classifyError: (e: unknown) => {
      const msg = e instanceof Error ? e.message : String(e);
      const m = msg.match(/Gemini video generation failed: (\d+)/);
      const status = m ? parseInt(m[1], 10) : null;
      return {
        status,
        kind:
          status === 429
            ? "rate_limit"
            : status && status >= 500
              ? "rate_limit"
              : status && status >= 400
                ? "bad_status"
                : "exception",
        response: { error: msg.slice(0, 2000) },
      };
    },
    extractResponse: (r: VideoGenResult) => ({
      operationId: r.operationId,
      model: r.model,
    }),
    storeFullResponse: false,
  });
}

/**
 * Poll the long-running operation once. Callers wrap this in a loop.
 *
 * Decision matrix for non-2xx responses:
 *   - 2xx with done=false: still running
 *   - 2xx with done=true and error: permanent failure
 *   - 2xx with done=true and samples: success
 *   - 404: the operation name is bad or it expired; treat as failure
 *   - 429 / 5xx: transient, return done=false so caller keeps looping
 */
export async function pollVideoOperation(
  operationId: string,
  projectId?: string,
  jobId?: string,
): Promise<VideoOperationStatus> {
  return withProviderCall({
    provider: "gemini",
    operation: "gemini.pollVideoOperation",
    projectId,
    jobId,
    request: { operationId },
    fn: async () => {
      const apiKey = getApiKey();
      const url =
        `${GEMINI_API_BASE}/${operationId}?key=${encodeURIComponent(apiKey)}`;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), POLL_TIMEOUT_MS);

      try {
        const res = await fetch(url, { signal: controller.signal });
        const text = await res.text();

        if (!res.ok) {
          if (res.status === 429 || res.status >= 500) {
            log("gemini-poll", `transient status=${res.status} op=${operationId} retry`);
            return { done: false };
          }
          log(
            "gemini-poll",
            `hard fail status=${res.status} op=${operationId} body=${truncate(text, 300)}`,
          );
          return {
            done: true,
            error: `Poll failed: HTTP ${res.status} ${truncate(text, 200)}`,
          };
        }

        let data: {
          done?: boolean;
          response?: {
            generateVideoResponse?: {
              generatedSamples?: Array<{ video?: { uri?: string } }>;
            };
          };
          error?: { message?: string; code?: number };
        };
        try {
          data = JSON.parse(text);
        } catch {
          log("gemini-poll", `non-JSON body op=${operationId} body=${truncate(text, 200)}`);
          return { done: false };
        }

        if (data.error?.message) {
          log(
            "gemini-poll",
            `op-error op=${operationId} code=${data.error.code ?? "?"} msg=${truncate(data.error.message, 200)}`,
          );
          return { done: true, error: data.error.message };
        }

        if (!data.done) {
          return { done: false };
        }

        const samples = data.response?.generateVideoResponse?.generatedSamples;
        const videoUri = samples?.[0]?.video?.uri;
        if (!videoUri) {
          log(
            "gemini-poll",
            `done but no video uri op=${operationId} body=${truncate(JSON.stringify(data.response ?? {}), 300)}`,
          );
          return {
            done: true,
            error: "Gemini returned done=true but no video URI",
          };
        }

        log("gemini-poll", `op=${operationId} done=true uri=${truncate(videoUri, 200)}`);
        return { done: true, videoUrl: videoUri };
      } catch (e) {
        if ((e as Error).name === "AbortError") {
          log("gemini-poll", `op=${operationId} timeout ms=${POLL_TIMEOUT_MS}`);
          return { done: false };
        }
        log("gemini-poll", `op=${operationId} threw err=${(e as Error).message}`);
        return { done: false };
      } finally {
        clearTimeout(timer);
      }
    },
    classifyError: (e: unknown) => {
      const msg = e instanceof Error ? e.message : String(e);
      const m = msg.match(/Gemini poll failed: (\d+)/);
      const status = m ? parseInt(m[1], 10) : null;
      return {
        status,
        kind:
          status === 429 || (status && status >= 500)
            ? "rate_limit"
            : status && status >= 400
              ? "bad_status"
              : "exception",
        response: { error: msg.slice(0, 2000) },
      };
    },
    extractResponse: (r: VideoOperationStatus) => ({
      done: r.done,
      hasVideoUrl: Boolean(r.videoUrl),
      hasError: Boolean(r.error),
    }),
    storeFullResponse: false,
  });
}

/**
 * NEW in this revision: downloads the generated video bytes from the
 * file URI returned by a completed operation, writes them to
 * backend/uploads/<uuid>.mp4, and returns the stable public URL.
 *
 * On any failure, throws - the worker marks the project failed.
 *
 * Also wrapped in withProviderCall so the admin dashboard sees the
 * download timing and any HTTP errors.
 */
export async function downloadVideo(
  videoUri: string,
  projectId?: string,
  jobId?: string,
): Promise<{ filePath: string; publicUrl: string; byteLength: number }> {
  return withProviderCall({
    provider: "gemini",
    operation: "gemini.downloadVideo",
    projectId,
    jobId,
    request: { uri: truncate(videoUri, 200) },
    fn: async () => {
      const apiKey = getApiKey();
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), DOWNLOAD_TIMEOUT_MS);
      const startedAt = Date.now();

      log("gemini-download", `start uri=${truncate(videoUri, 200)}`);

      try {
        const res = await fetch(videoUri, {
          headers: { "x-goog-api-key": apiKey },
          signal: controller.signal,
        });
        if (!res.ok) {
          const text = await res.text().catch(() => "");
          throw new Error(
            `Download failed: HTTP ${res.status} ${truncate(text, 200)}`,
          );
        }
        const contentType = res.headers.get("content-type") ?? "";
        if (
          !contentType.startsWith("video/") &&
          contentType !== "application/octet-stream"
        ) {
          log("gemini-download", `unexpected content-type=${contentType} - proceeding`);
        }

        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.byteLength === 0) {
          throw new Error("Downloaded 0 bytes");
        }

        const filename = `video-${randomUUID()}.mp4`;
        const uploadsDir = path.join(process.cwd(), "uploads");
        await fs.mkdir(uploadsDir, { recursive: true });
        const filePath = path.join(uploadsDir, filename);
        await fs.writeFile(filePath, buf);

        const publicBase =
          process.env.PUBLIC_BASE_URL ?? "http://localhost:4000";
        const publicUrl = `${publicBase.replace(/\/$/, "")}/uploads/${filename}`;

        log(
          "gemini-download",
          `ok bytes=${buf.byteLength} path=${truncate(filePath, 200)} ms=${Date.now() - startedAt}`,
        );

        return { filePath, publicUrl, byteLength: buf.byteLength };
      } catch (e) {
        if ((e as Error).name === "AbortError") {
          log("gemini-download", `TIMEOUT ms=${DOWNLOAD_TIMEOUT_MS}`);
        } else {
          log("gemini-download", `FAIL err=${(e as Error).message}`);
        }
        throw e;
      } finally {
        clearTimeout(timer);
      }
    },
    classifyError: defaultClassifyError,
    extractResponse: (r: { filePath: string; publicUrl: string; byteLength: number }) => ({
      byteLength: r.byteLength,
      publicUrl: truncate(r.publicUrl, 200),
    }),
    storeFullResponse: false,
  });
}