/**
 * Google Gemini API video provider - routes between Omni Flash
 * (cheap/fast drafts) and Veo 3.1 (final, higher-res renders).
 *
 * v38: every outbound fetch is wrapped in `withProviderCall` so the
 *      admin dashboard can inspect prompts, responses, status, and
 *      timing. See backend/src/util/providerLog.ts.
 */

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";

import { withProviderCall, defaultClassifyError } from "../util/providerLog.js";

export type VideoTier = "draft" | "final";

export interface VideoGenRequest {
  prompt: string;
  referenceImageUrls: string[];
  tier: VideoTier;
  durationSeconds?: number;
  firstFrameUrl?: string;
  lastFrameUrl?: string;
  projectId?: string;
  jobId?: string;
}

export interface VideoGenResult {
  operationId: string;
  model: string;
}

export function modelForTier(tier: VideoTier): string {
  return tier === "draft" ? "gemini-omni-flash" : "veo-3.1-generate-preview";
}

export async function generateVideo(req: VideoGenRequest): Promise<VideoGenResult> {
  return withProviderCall({
    provider: "gemini",
    operation: "gemini.generateVideo",
    projectId: req.projectId,
    jobId: req.jobId,
    request: {
      model: modelForTier(req.tier),
      tier: req.tier,
      promptLen: req.prompt.length,
      promptPreview: req.prompt.slice(0, 240),
      referenceCount: req.referenceImageUrls.length,
      durationSeconds: req.durationSeconds ?? 8,
      hasFirstFrame: Boolean(req.firstFrameUrl),
      hasLastFrame: Boolean(req.lastFrameUrl),
    },
    fn: async () => {
      const model = modelForTier(req.tier);
      const apiKey = process.env.GEMINI_API_KEY;

      const body: Record<string, unknown> = {
        prompt: req.prompt,
        referenceImages: req.referenceImageUrls,
        durationSeconds: req.durationSeconds ?? 8,
      };

      if (req.tier === "final") {
        const firstFrame = req.firstFrameUrl ?? req.referenceImageUrls[0];
        if (firstFrame) body.firstFrame = firstFrame;
        if (req.lastFrameUrl) body.lastFrameUrl = req.lastFrameUrl;
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
        const text = await res.text();
        throw new Error(`Gemini video generation failed: ${res.status} ${text}`);
      }

      const data = (await res.json()) as { name: string };
      return { operationId: data.name, model };
    },
    classifyError: (e) => {
      const msg = e instanceof Error ? e.message : String(e);
      const m = msg.match(/Gemini video generation failed: (\d+)/);
      const status = m ? parseInt(m[1], 10) : null;
      return {
        status,
        kind: status === 429 ? "rate_limit" : status && status >= 500 ? "rate_limit" : status && status >= 400 ? "bad_status" : "exception",
        response: { error: msg.slice(0, 2000) },
      };
    },
    extractResponse: (r: VideoGenResult) => ({ operationId: r.operationId, model: r.model }),
    storeFullResponse: false,
  });
}

export interface VideoOperationStatus {
  done: boolean;
  videoUrl?: string;
  error?: string;
}

export async function pollVideoOperation(operationId: string, projectId?: string, jobId?: string): Promise<VideoOperationStatus> {
  return withProviderCall({
    provider: "gemini",
    operation: "gemini.pollVideoOperation",
    projectId,
    jobId,
    request: { operationId },
    fn: async () => {
      const apiKey = process.env.GEMINI_API_KEY;
      const res = await fetch(`${GEMINI_API_BASE}/${operationId}`, {
        headers: { "x-goog-api-key": apiKey ?? "" },
      });

      if (!res.ok) {
        const text = await res.text();
        throw new Error(`Gemini poll failed: ${res.status} ${text}`);
      }

      const data = (await res.json()) as {
        done: boolean;
        response?: {
          videoUrl?: string;
          videos?: Array<{ uri?: string }>;
        };
        error?: { message: string };
      };

      const videoUrl =
        data.response?.videoUrl ?? data.response?.videos?.[0]?.uri ?? undefined;

      return {
        done: data.done,
        videoUrl,
        error: data.error?.message,
      };
    },
    classifyError: (e) => {
      const msg = e instanceof Error ? e.message : String(e);
      const m = msg.match(/Gemini poll failed: (\d+)/);
      const status = m ? parseInt(m[1], 10) : null;
      return {
        status,
        kind: status === 429 || (status && status >= 500) ? "rate_limit" : status && status >= 400 ? "bad_status" : "exception",
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
