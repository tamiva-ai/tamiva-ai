/**
 * Google Gemini API video provider.
 *
 * Activity B (2026-07-18): rewrote against the REAL public Gemini API
 * surface for Veo. Endpoints + models confirmed by:
 *   - GET /v1beta/models on user's key → veo-3.1-fast-generate-preview,
 *     veo-3.1-generate-preview, veo-3.1-lite-generate-preview listed
 *     with supportedGenerationMethods=["predictLongRunning"].
 *   - POST :predictLongRunning on veo-3.1-fast-generate-preview returns
 *     HTTP 200 with {"name":"operations/..."} when not throttle
 *     (HTTP 429 with RESOURCE_EXHAUSTED when throttled).
 *
 * Earlier versions of this file used a fabricated :generateVideos
 * endpoint and made-up model IDs (veo-3.0-*, gemini-omni-flash) that
 * 404'd on every request. That's why AI Studio showed zero traffic.
 *
 * Wire shape:
 *   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:predictLongRunning
 *        header x-goog-api-key: <API_KEY>
 *   body: { instances: [{ prompt }], parameters: { aspectRatio, durationSeconds } }
 *   response: { name: "operations/<uuid>" or "models/.../operations/<uuid>" }
 *
 * Polling:
 *   GET https://generativelanguage.googleapis.com/v1beta/{name}
 *       header x-goog-api-key: <API_KEY>
 *   response (when done): { name, done: true, response: { videos: [{ uri?, bytesBase64Encoded?, mimeType? }] } }
 *
 * Auth: API key via `x-goog-api-key` header (paid tier, ~2 RPM and
 * 30 RPD on veo-3.1-fast-generate-preview as of 2026-07-18 on Tier 1).
 * Note: ?key= query param works for most Gemini API methods but is
 * rejected (401 ACCESS_TOKEN_TYPE_UNSUPPORTED) by :predictLongRunning.
 * The header form is what Google accepts.
 *
 * Quotas to respect:
 *   - 2 RPM: at most one render every 30s on average. The submit
 *     handler retries on 429 with a 60s sleep, max 3 retries.
 *   - 30 RPD: at most ~30 Veo renders per day per project. Each
 *     10-second Veo render consumes 1 RPD.
 *
 * v38 base features preserved:
 *   - withProviderCall(...) wrapper on every outbound call.
 *   - generateVideo takes (projectId?, jobId?) for ProviderCall
 *     correlation.
 *   - pollVideoOperation(operationId, projectId?, jobId?) signature.
 *   - returns { operationId, model } (was operationName in my first
 *     pass; renamed to operationId to match the rest of the worker).
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

// 429 backoff. Google's per-minute rate limit on Veo is 2 RPM on
// paid tier, so we sleep ~60s on 429 before retrying. Cap at 3
// retries so a real quota exhaustion (30 RPD) surfaces to the user
// as a clean failure instead of an infinite retry loop.
const RATE_LIMIT_RETRY_DELAY_MS = 60_000;
const RATE_LIMIT_MAX_RETRIES = 3;

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
  /** Populated only when done && error. */
  error?: string;
  /** Populated only when done && !error && bytesBase64Encoded present. */
  videoBytesBase64?: string;
  /** Populated only when done && !error && uri present. */
  videoUri?: string;
  /** Best-effort MIME type hint from Google's response. */
  videoMimeType?: string;
}

/**
 * Maps our product tier to a model name on the public Gemini API.
 * Fast variant for drafts; full Veo 3.1 for final renders. Both
 * confirmed available on user's paid project as of 2026-07-18.
 */
export function modelForTier(tier: VideoTier): string {
  return tier === "draft"
    ? "veo-3.1-fast-generate-preview"
    : "veo-3.1-generate-preview";
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

function getApiKey(): string {
  const k = process.env.GEMINI_API_KEY;
  if (!k) {
    throw new Error(
      "GEMINI_API_KEY is not configured. Set it in Railway -> Variables.",
    );
  }
  return k;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Submit an async video generation request via :predictLongRunning.
 * Returns the operation name; the caller must poll via
 * {@link pollVideoOperation}.
 *
 * 429 retry: on RESOURCE_EXHAUSTED, sleep 60s and retry up to
 * RATE_LIMIT_MAX_RETRIES times. After that, the error propagates so
 * the worker marks the project failed (the user sees a "try again
 * later" message, not a hung spinner).
 *
 * v38 contract preserved: returns `{ operationId, model }`.
 */
export async function generateVideo(req: VideoGenRequest): Promise<VideoGenResult> {
  const model = modelForTier(req.tier);
  const durationSeconds = req.durationSeconds ?? 8;
  const startedAt = Date.now();

  // The withProviderCall wrapper makes ProviderCall rows for billing
  // and observability. We retry on 429 OUTSIDE the wrapper so each
  // retry attempt is its own ProviderCall row (not one big row that
  // spans the whole retry sequence).
  for (let attempt = 1; attempt <= RATE_LIMIT_MAX_RETRIES + 1; attempt++) {
    try {
      const result = await withProviderCall({
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
          durationSeconds,
          attempt,
        },
        fn: () => submitOnce(req, model, durationSeconds, startedAt),
        classifyError: (e: unknown) => {
          const msg = e instanceof Error ? e.message : String(e);
          const m = msg.match(/Gemini video generation failed: (\d+)/);
          const status = m ? parseInt(m[1], 10) : null;
          // Distinguish 429 (rate-limit) so the operator can grep it.
          const kind: "rate_limit" | "bad_status" | "timeout" | "exception" =
            status === 429
              ? "rate_limit"
              : status === 408 || status === null && /timeout/i.test(msg)
                ? "timeout"
                : status && status >= 500
                  ? "rate_limit"
                  : status && status >= 400
                    ? "bad_status"
                    : "exception";
          return {
            status,
            kind,
            response: { error: msg.slice(0, 2000) },
          };
        },
        extractResponse: (r: VideoGenResult) => ({
          operationId: r.operationId,
          model: r.model,
        }),
        storeFullResponse: false,
      });
      return result;
    } catch (e) {
      const isRateLimit = isRateLimitError(e);
      if (isRateLimit && attempt <= RATE_LIMIT_MAX_RETRIES) {
        log(
          "gemini",
          `429 retry attempt=${attempt}/${RATE_LIMIT_MAX_RETRIES} sleeping ${RATE_LIMIT_RETRY_DELAY_MS / 1000}s`,
        );
        await sleep(RATE_LIMIT_RETRY_DELAY_MS);
        continue;
      }
      throw e;
    }
  }

  // Defensive: should never reach here. If we do, surface a clear error.
  throw new Error("Gemini video generation: exceeded retry budget");
}

function isRateLimitError(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const msg = "message" in e && typeof (e as { message: unknown }).message === "string"
    ? (e as { message: string }).message
    : "";
  // The thrown Error from submitOnce() includes the HTTP status code
  // in the message format "Gemini video generation failed: 429 <body>".
  return /Gemini video generation failed: 429\b/.test(msg);
}

/**
 * Single submit attempt. Throws on non-2xx so the retry loop in
 * {@link generateVideo} can catch and back off on 429.
 */
async function submitOnce(
  req: VideoGenRequest,
  model: string,
  durationSeconds: number,
  startedAt: number,
): Promise<VideoGenResult> {
const apiKey = getApiKey();

console.log("ENV GEMINI_API_KEY =", process.env.GEMINI_API_KEY);
console.log("getApiKey() =", apiKey);

  // Public Gemini REST surface for Veo accepts only these parameter
  // fields. personGeneration and storageUri are Vertex-only and
  // cause 400 on this endpoint.
  const body = {
    instances: [{ prompt: req.prompt }],
    parameters: {
      aspectRatio: "16:9",
      durationSeconds,
    },
  };

  const url = `${GEMINI_API_BASE}/models/${model}:predictLongRunning`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  log("gemini", `submit model=${model} promptLen=${req.prompt.length}`);
  console.log("===== FINAL REQUEST =====");
console.log("URL:", url);
console.log("Method:", "POST");
console.log("Headers:", {
  "Content-Type": "application/json",
  "x-goog-api-key": apiKey.substring(0, 8) + "...",
});
console.log("Body:");
console.log(JSON.stringify(body, null, 2));
console.log("=========================");
  try {
    const request = new Request(url, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-goog-api-key": apiKey,
  },
  body: JSON.stringify(body),
  signal: controller.signal,
});

console.log("===== REQUEST HEADERS ACTUALLY SENT =====");
for (const [k, v] of request.headers.entries()) {
  console.log(`${k}: ${v}`);
}
console.log("========================================");

const res = await fetch(request);
    console.log("===== RESPONSE =====");
console.log("Status:", res.status);

for (const [k, v] of res.headers.entries()) {
  console.log(`${k}: ${v}`);
}

console.log("====================");
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
      throw new Error("Gemini submit response missing 'name' field");
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
}

/**
 * Poll the long-running operation once. Callers wrap this in a loop.
 *
 * Decision matrix for non-2xx responses:
 *   - 2xx with done=false: still running
 *   - 2xx with done=true and error: permanent failure
 *   - 2xx with done=true and a video: success
 *   - 404: the operation name is bad or it expired; treat as failure
 *   - 429 / 5xx: transient, return done=false so caller keeps looping
 *
 * Response shape (when done):
 *   { name, done: true, response: { videos: [{ uri?, bytesBase64Encoded?, mimeType? }] } }
 *
 * Both shapes are supported:
 *   - `videos[].bytesBase64Encoded`: inline base64 MP4. Common on the
 *     public Gemini API when the model is allowed to return bytes
 *     directly.
 *   - `videos[].uri`: signed URI that the same API key can fetch.
 *     We download via downloadVideo() and stream to disk.
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
      const url = `${GEMINI_API_BASE}/${operationId}`;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), POLL_TIMEOUT_MS);

      try {
        const res = await fetch(url, {
          headers: {
            "x-goog-api-key": apiKey,
          },
          signal: controller.signal,
        });
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
  name?: string;
  done?: boolean;

  response?: {
    videos?: Array<{
      uri?: string;
      bytesBase64Encoded?: string;
      mimeType?: string;
    }>;
  };

  generateVideoResponse?: {
    generatedSamples?: Array<{
      video: {
        uri?: string;
        bytesBase64Encoded?: string;
        mimeType?: string;
      };
    }>;
  };

  error?: {
    message?: string;
    code?: number;
  };
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

        // Success path: response.videos[0]. Either bytesBase64Encoded
        // (inline) or uri (download needed). Both are valid.
        console.log("===== POLL RESPONSE OBJECT =====");
console.log(JSON.stringify(data, null, 2));
console.log("================================");

const video =
  data.response?.videos?.[0] ??
  data.generateVideoResponse?.generatedSamples?.[0]?.video;

console.log("VIDEO OBJECT =", video);

if (!video) {
  log(
    "gemini-poll",
    `done but no video in response op=${operationId} body=${truncate(JSON.stringify(data), 1000)}`,
  );
  return {
    done: true,
    error: "Gemini returned done=true but no video in response",
  };
}

        log(
          "gemini-poll",
          `op=${operationId} done=true hasInline=${Boolean(video.bytesBase64Encoded)} hasUri=${Boolean(video.uri)} mime=${video.mimeType ?? "?"}`,
        );
        return {
          done: true,
          videoBytesBase64: video.bytesBase64Encoded,
          videoUri: video.uri,
          videoMimeType: video.mimeType,
        };
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
    classifyError: defaultClassifyError,
    extractResponse: (r: VideoOperationStatus) => ({
      done: r.done,
      hasInlineBytes: Boolean(r.videoBytesBase64),
      hasUri: Boolean(r.videoUri),
      hasError: Boolean(r.error),
    }),
    storeFullResponse: false,
  });
}

/**
 * Persist the generated video bytes to disk.
 *
 * Two input modes:
 *   - { bytesBase64 }: write directly to disk after base64 decode.
 *   - { uri }: fetch from Google's file URI with the same API key.
 *
 * Either way we land on `backend/uploads/video-<uuid>.mp4`. The
 * `Asset.url` is then `${PUBLIC_BASE_URL}/uploads/video-<uuid>.mp4`.
 *
 * Wrapped in withProviderCall so the download timing and any HTTP
 * errors are logged as their own ProviderCall row.
 */
export async function downloadVideo(args: {
  uri?: string;
  bytesBase64?: string;
  mimeType?: string;
  projectId?: string;
  jobId?: string;
}): Promise<{ filePath: string; publicUrl: string; byteLength: number }> {
  return withProviderCall({
    provider: "gemini",
    operation: "gemini.downloadVideo",
    projectId: args.projectId,
    jobId: args.jobId,
    request: {
      hasUri: Boolean(args.uri),
      hasInline: Boolean(args.bytesBase64),
      mimeType: args.mimeType ?? null,
    },
    fn: async () => {
      const apiKey = getApiKey();
      const startedAt = Date.now();
      let buf: Buffer;

      if (args.bytesBase64) {
        // Inline path: decode base64 directly. No network.
        log("gemini-download", `inline path mime=${args.mimeType ?? "?"}`);
        buf = Buffer.from(args.bytesBase64, "base64");
      } else if (args.uri) {
        // URI path: fetch from Google's file URI with the API key.
        // Same abort / timeout pattern as the submit / poll paths.
        log("gemini-download", `uri path uri=${truncate(args.uri, 200)}`);
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), DOWNLOAD_TIMEOUT_MS);
        try {
          const res = await fetch(args.uri, {
            headers: { "x-goog-api-key": apiKey },
            signal: controller.signal,
          });
          if (!res.ok) {
            const text = await res.text().catch(() => "");
            throw new Error(
              `Download failed: HTTP ${res.status} ${truncate(text, 200)}`,
            );
          }
          buf = Buffer.from(await res.arrayBuffer());
        } finally {
          clearTimeout(timer);
        }
      } else {
        throw new Error("downloadVideo called with neither uri nor bytesBase64");
      }

      if (buf.byteLength === 0) {
        throw new Error("Video bytes empty after decode / fetch");
      }

      // Filename uses the same convention as the original Activity B code:
      // video-<uuid>.mp4 in the backend/uploads directory. We default
      // the extension to .mp4 because Veo output is MP4. If Google's
      // mimeType disagrees we could suffix differently; for v1 we
      // trust MP4.
      const filename = `video-${randomUUID()}.mp4`;
      const uploadsDir = path.join(process.cwd(), "uploads");
      await fs.mkdir(uploadsDir, { recursive: true });
      const filePath = path.join(uploadsDir, filename);
      await fs.writeFile(filePath, buf);

      const publicBase = process.env.PUBLIC_BASE_URL ?? "http://localhost:4000";
      const publicUrl = `${publicBase.replace(/\/$/, "")}/uploads/${filename}`;

      log(
        "gemini-download",
        `ok bytes=${buf.byteLength} path=${truncate(filePath, 200)} ms=${Date.now() - startedAt}`,
      );

      return { filePath, publicUrl, byteLength: buf.byteLength };
    },
    classifyError: defaultClassifyError,
    extractResponse: (r) => ({
      byteLength: r.byteLength,
      publicUrl: truncate(r.publicUrl, 200),
    }),
    storeFullResponse: false,
  });
}
