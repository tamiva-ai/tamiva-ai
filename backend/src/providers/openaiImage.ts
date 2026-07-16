import OpenAI from "openai";
import { withProviderCall, defaultClassifyError } from "../util/providerLog.js";

const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

export interface ImageGenRequest {
  prompt: string;
  referenceImageUrls?: string[]; // for ambassador character consistency
  size?: "1024x1024" | "1024x1536" | "1536x1024";
  n?: number;
  /** Optional context for the admin log row. */
  projectId?: string;
  jobId?: string;
}

export interface ImageGenResult {
  urls: string[];
}

// Note: a real response body can be a megabyte-sized data: URL
// (gpt-image-1 returns b64_json by default). We *want* that fidelity
// in the admin log, so storeFullResponse is true. The admin UI
// truncates for display.

/**
 * Extracts a tiny, useful summary from an OpenAI images response
 * without pulling the b64 payload.
 */
function summariseOpenAIGenerate(
  res: OpenAI.Images.ImagesResponse | { data?: Array<{ url?: string; b64_json?: string }> },
): unknown {
  const arr = (res as { data?: unknown[] }).data ?? [];
  return {
    count: arr.length,
    sample: arr[0]
      ? {
          hasUrl: "url" in (arr[0] as Record<string, unknown>),
          hasB64: "b64_json" in (arr[0] as Record<string, unknown>),
          b64Bytes:
            typeof (arr[0] as { b64_json?: string }).b64_json === "string"
              ? (arr[0] as { b64_json: string }).b64_json.length
              : 0,
        }
      : null,
  };
}

/**
 * Generates images via OpenAI's gpt-image-1. When referenceImageUrls is
 * provided, switches to the /v1/images/edits endpoint so the model can
 * condition on the reference images (ambassador character lock, product
 * hero shots, mood-board anchors). Falls back to text-only generation
 * if every reference fails to download.
 */
export async function generateImage(req: ImageGenRequest): Promise<ImageGenResult> {
  const projectId = (req as { projectId?: string }).projectId;
  const jobId = (req as { jobId?: string }).jobId;
  const refs = req.referenceImageUrls ?? [];
  const n = req.n ?? 1;
  const size = req.size ?? "1024x1024";

  return withProviderCall({
    provider: "openai",
    operation: "openai.generateImage",
    projectId: req.projectId,
    jobId: req.jobId,
    request: {
      promptLen: req.prompt.length,
      promptPreview: req.prompt.slice(0, 240),
      referenceCount: refs.length,
      size,
      n,
    },
    fn: async () => {
      if (refs.length === 0) {
        const response = await client.images.generate({
          model: "gpt-image-1",
          prompt: req.prompt,
          size,
          n,
        });
        return response;
      }
      // Edits path requires raw bytes - download each reference.
      const refFiles: Array<{ buf: Buffer; mime: string }> = [];
      for (const url of refs) {
        const buf = await downloadRaw(url);
        if (buf) refFiles.push({ buf, mime: sniffMime(buf) });
      }
      if (refFiles.length === 0) {
        const response = await client.images.generate({
          model: "gpt-image-1",
          prompt: req.prompt,
          size,
          n,
        });
        return response;
      }
      // /v1/images/edits only supports n=1 today, so loop if n>1.
      const responses: unknown[] = [];
      for (let i = 0; i < n; i++) {
        const form = new FormData();
        form.append("model", "gpt-image-1");
        form.append("prompt", req.prompt);
        form.append("size", size);
        form.append("n", "1");
        refFiles.forEach(({ buf, mime }, idx) => {
          const ext = mime === "image/png" ? "png" : "jpg";
          form.append(
            `image[]`,
            new Blob([new Uint8Array(buf)], { type: mime }),
            `ref-${idx}.${ext}`,
          );
        });
        const res = await fetch(
          "https://api.openai.com/v1/images/edits",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${process.env.OPENAI_API_KEY ?? ""}`,
            },
            body: form,
          },
        );
        if (!res.ok) {
          const text = await res.text();
          throw new Error(`OpenAI image edits failed: ${res.status} ${text}`);
        }
        responses.push(await res.json());
      }
      // Combine into a single shape that downstream code can parse.
      return { data: responses.flatMap((r: any) => (r as any).data ?? []) };
    },
    classifyError: (e) => {
      const msg = e instanceof Error ? e.message : String(e);
      const m = msg.match(/OpenAI image edits failed: (\d+)/);
      const status = m ? parseInt(m[1], 10) : null;
      return {
        status,
        kind: status === 429 ? "rate_limit" : status && status >= 400 ? "bad_status" : "exception",
        response: { error: msg.slice(0, 1000) },
      };
    },
    extractResponse: summariseOpenAIGenerate,
    storeFullResponse: false,
  }).then((response: any) => {
    const urls = (response.data ?? [])
      .map(toImageUrl)
      .filter((u: string | null): u is string => Boolean(u));
    return { urls };
  });
}

/**
 * Generates carousel slide visuals in parallel batches. Each slide can
 * have its own reference set - pass references[i] for slide i, or null
 * to fall back to text-only for that slide.
 */
export async function generateCarouselSlides(
  prompts: string[],
  referenceImageUrlsPerSlide?: (string[] | null)[],
  { projectId, jobId }: { projectId?: string; jobId?: string } = {},
): Promise<string[]> {
  const refsPerSlide = referenceImageUrlsPerSlide ?? [];
  const results: string[] = [];
  const BATCH_SIZE = 5;

  for (let i = 0; i < prompts.length; i += BATCH_SIZE) {
    const batch = prompts.slice(i, i + BATCH_SIZE);
    const refBatch = refsPerSlide.slice(i, i + BATCH_SIZE) ?? [];
    const batchResults = await Promise.all(
      batch.map(async (prompt, idx): Promise<string> => {
        const refs = refBatch[idx];
        const cleanRefs = refs && refs.length > 0 ? refs : undefined;
        const r = await generateImage({
          prompt,
          referenceImageUrls: cleanRefs,
          projectId,
          jobId,
        });
        return r.urls[0] ?? "";
      }),
    );
    results.push(...batchResults.filter((u) => u.length > 0));
  }

  return results;
}

// ---------------------------------------------------------------------
// Helpers (unchanged behavior - these don't go through withProviderCall
// because they don't make outbound HTTP they fail silently, by design).
// ---------------------------------------------------------------------

/**
 * Extract a usable URL from a single image response item. OpenAI's
 * gpt-image-1 returns base64-encoded PNGs by default (b64_json field,
 * no `url`); older dall-e-3 / gpt-image-1 with response_format=url do
 * return a hosted URL. We handle both - preferring the hosted URL when
 * available, otherwise wrapping the b64_json in a data: URL so the
 * downstream code can store a uniform string in Asset.url.
 */
function toImageUrl(item: { url?: string; b64_json?: string }): string | null {
  if (item.url) return item.url;
  if (item.b64_json) return `data:image/png;base64,${item.b64_json}`;
  return null;
}

/**
 * Downloads a remote image and returns the raw buffer.
 *
 * NOTE: the OpenAI /v1/images/edits endpoint accepts JPEG and PNG
 * inputs but rejects HEIC (iPhone's default camera format) and a few
 * other formats. If the buffer is in a format OpenAI can't read, the
 * edits call will fail and the caller should fall back to text-only
 * generation.
 */
async function downloadRaw(url: string): Promise<Buffer | null> {
  return withProviderCall({
    provider: "openai",
    operation: "openai.downloadRaw",
    request: { url },
    fn: async () => {
      try {
        const res = await fetch(url, { redirect: "follow" });
        if (!res.ok) return null;
        const arrayBuf = await res.arrayBuffer();
        return Buffer.from(arrayBuf);
      } catch (err) {
        console.warn(`[openaiImage] reference fetch failed for ${url}:`, err);
        return null;
      }
    },
    classifyError: (e) => {
      const msg = e instanceof Error ? e.message : String(e);
      return {
        status: null,
        kind: /timeout/i.test(msg) ? "timeout" : "network",
        response: { error: msg.slice(0, 500) },
      };
    },
    // Success path returns either Buffer or null (when fetch returned
    // a non-OK status). Capture both.
    extractResponse: (v: Buffer | null) => ({
      ok: v !== null,
      bytes: v ? v.length : 0,
    }),
    storeFullResponse: false,
  });
}

/**
 * Detects the MIME type from a few common magic-byte signatures so we
 * can tell OpenAI what the file is. Falls back to image/jpeg which
 * is what most phone cameras produce.
 */
function sniffMime(buf: Buffer): string {
  if (buf.length >= 4 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    return "image/png";
  }
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    return "image/jpeg";
  }
  if (buf.length >= 12 && buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") {
    return "image/webp";
  }
  if (buf.length >= 6 && (buf.toString("ascii", 0, 6) === "GIF87a" || buf.toString("ascii", 0, 6) === "GIF89a")) {
    return "image/gif";
  }
  if (buf.length >= 12 && buf.toString("ascii", 4, 8) === "ftyp") {
    return "image/heic";
  }
  return "image/jpeg";
}
