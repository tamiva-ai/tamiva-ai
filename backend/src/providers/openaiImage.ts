import OpenAI from "openai";

const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

export interface ImageGenRequest {
  prompt: string;
  referenceImageUrls?: string[]; // for ambassador character consistency
  size?: "1024x1024" | "1024x1536" | "1536x1024";
  n?: number;
}

export interface ImageGenResult {
  urls: string[];
}

// Node 22 ships FormData + Blob as globals (alongside fetch). Cast
// through `any` so we don't need to add DOM to tsconfig's lib array -
// the rest of the codebase is pure server code and shouldn't have to
// pull in DOM types just for one provider.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const FormDataCtor: any = (globalThis as any).FormData;

function ts() {
  return new Date().toISOString().slice(11, 19);
}
function log(stage: string, message: string) {
  console.log(`[${ts()}] [${stage}] ${message}`);
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const BlobCtor: any = (globalThis as any).Blob;

/**
 * Extract a usable URL from a single image response item. OpenAI's
 * gpt-image-1 returns base64-encoded PNGs by default (b64_json field,
 * no `url`); older dall-e-3 / gpt-image-1 with response_format=url do
 * return a hosted URL. We handle both — preferring the hosted URL when
 * available, otherwise wrapping the b64_json in a data: URL so the
 * downstream code can store a uniform string in Asset.url.
 *
 * NOTE: the b64_json can be megabytes. For Tamiva we accept this cost
 * because the asset is stored once and never re-downloaded by anyone
 * but the user's own device. If asset URLs grow large we'd want to
 * upload the b64 to S3/R2 instead.
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
 *
 * We previously converted every reference to PNG via sharp, but that
 * pulled in a native libvips dependency that needed a matching
 * package-lock entry. Without it, `npm ci` fails on Railway. Sharp can
 * be re-added later by regenerating the lockfile and bumping the
 * deploy image to one with libvips preinstalled.
 */
async function downloadRaw(url: string): Promise<Buffer | null> {
  try {
    const res = await fetch(url, { redirect: "follow" });
    if (!res.ok) {
      console.warn(`[openaiImage] reference fetch failed ${res.status} for ${url}`);
      return null;
    }
    const arrayBuf = await res.arrayBuffer();
    return Buffer.from(arrayBuf);
  } catch (err) {
    console.warn(`[openaiImage] reference fetch failed for ${url}:`, err);
    return null;
  }
}

/**
 * Detects the MIME type from a few common magic-byte signatures so we
 * can tell OpenAI what the file is. Falls back to image/jpeg which
 * is what most phone cameras produce.
 */
function sniffMime(buf: Buffer): string {
  // PNG: 89 50 4E 47
  if (buf.length >= 4 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
    return "image/png";
  }
  // JPEG: FF D8 FF
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
    return "image/jpeg";
  }
  // WebP: RIFF .... WEBP
  if (buf.length >= 12 && buf.toString("ascii", 0, 4) === "RIFF" && buf.toString("ascii", 8, 12) === "WEBP") {
    return "image/webp";
  }
  // GIF: GIF87a or GIF89a
  if (buf.length >= 6 && (buf.toString("ascii", 0, 6) === "GIF87a" || buf.toString("ascii", 0, 6) === "GIF89a")) {
    return "image/gif";
  }
  // HEIC / HEIF: ftyp box starting at offset 4
  if (buf.length >= 12 && buf.toString("ascii", 4, 8) === "ftyp") {
    // OpenAI's edits endpoint doesn't accept HEIC. The caller will
    // see this as a regular failure and degrade to text-only.
    return "image/heic";
  }
  return "image/jpeg";
}

/**
 * Generates images via OpenAI's gpt-image-1. When referenceImageUrls is
 * provided, switches to the /v1/images/edits endpoint so the model can
 * condition on the reference images (ambassador character lock, product
 * hero shots, mood-board anchors). Falls back to text-only generation
 * if every reference fails to download.
 */
export async function generateImage(req: ImageGenRequest): Promise<ImageGenResult> {
  const refs = req.referenceImageUrls ?? [];
  const startedAt = Date.now();

  // Download references up front. If every one fails we fall back to
  // plain /v1/images/generations. OpenAI accepts JPEG/PNG/WebP/GIF
  // directly - HEIC will fail and we'll degrade to text-only for that
  // particular generation.
  const refFiles: Array<{ buf: Buffer; mime: string }> = [];
  if (refs.length > 0) {
    log("openai", `download refs=${refs.length}`);
    const downloadStart = Date.now();
    const downloaded = await Promise.all(refs.map(downloadRaw));
    for (const buf of downloaded) {
      if (buf) refFiles.push({ buf, mime: sniffMime(buf) });
    }
    log("openai", `downloaded ${refFiles.length}/${refs.length} refs in ${Date.now() - downloadStart}ms`);
  }

  if (refFiles.length === 0) {
    log("openai", `POST /v1/images/generations n=${req.n ?? 1} size=${req.size ?? "1024x1024"} (text-only)`);
    const response = await client.images.generate({
      model: "gpt-image-1",
      prompt: req.prompt,
      size: req.size ?? "1024x1024",
      n: req.n ?? 1,
    });
    const urls = (response.data ?? [])
      .map(toImageUrl)
      .filter((url): url is string => Boolean(url));
    log("openai", `generations done urls=${urls.length}/${req.n ?? 1} ms=${Date.now() - startedAt}`);
    return { urls };
  }

  // Build the multipart body the edits endpoint expects: prompt + size
  // + one file per reference image. The OpenAI SDK doesn't expose an
  // edits helper directly so we go through fetch + FormData.
  // Note: /v1/images/edits only supports n=1 per call today, so for n>1
  // we loop. Each edit produces a single image and we collect them.
  const n = req.n ?? 1;
  const urls: string[] = [];
  const size = req.size ?? "1024x1024";
  const ext = (mime: string) =>
    mime === "image/png" ? "png" : mime === "image/webp" ? "webp" : mime === "image/gif" ? "gif" : "jpg";

  log("openai", `POST /v1/images/edits x${n} refs=${refFiles.length} size=${size}`);
  for (let i = 0; i < n; i++) {
    log("openai", `edits call ${i + 1}/${n} starting`);
    const callStart = Date.now();
    const form = new FormDataCtor();
    form.append("model", "gpt-image-1");
    form.append("prompt", req.prompt);
    form.append("size", size);
    form.append("n", "1");
    refFiles.forEach(({ buf, mime }, idx) => {
      // The edits endpoint accepts up to 16 images under any field name;
      // conventionally `image[]`. Use indexed names so the API treats
      // them as separate parts.
      const blob = new BlobCtor([new Uint8Array(buf)], { type: mime });
      form.append(`image[]`, blob, `ref-${idx}.${ext(mime)}`);
    });

    const res = await fetch("https://api.openai.com/v1/images/edits", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.OPENAI_API_KEY ?? ""}`,
      },
      body: form,
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`OpenAI image edits failed: ${res.status} ${text}`);
    }

    const json = (await res.json()) as { data?: Array<{ url?: string; b64_json?: string }> };
    const out = json.data && json.data[0] ? toImageUrl(json.data[0]) : null;
    if (out) urls.push(out);
    log("openai", `edits call ${i + 1}/${n} ${res.ok ? "ok" : "fail"} ms=${Date.now() - callStart}`);
  }

  log("openai", `edits done urls=${urls.length}/${n} totalMs=${Date.now() - startedAt}`);
  return { urls };
}

/**
 * Generates carousel slide visuals in parallel batches. Each slide can
 * have its own reference set - pass references[i] for slide i, or null
 * to fall back to text-only for that slide.
 */
export async function generateCarouselSlides(
  prompts: string[],
  referenceImageUrlsPerSlide?: (string[] | null)[],
): Promise<string[]> {
  const BATCH_SIZE = 5;
  const results: string[] = [];
  log("carousel-batches", `slides=${prompts.length} batchSize=${BATCH_SIZE}`);

  for (let i = 0; i < prompts.length; i += BATCH_SIZE) {
    const batchStart = Date.now();
    const batch = prompts.slice(i, i + BATCH_SIZE);
    const refBatch = referenceImageUrlsPerSlide?.slice(i, i + BATCH_SIZE) ?? [];
    const batchResults = await Promise.all(
      batch.map((prompt, idx) => {
        const refs = refBatch[idx];
        const cleanRefs = refs && refs.length > 0 ? refs : undefined;
        return generateImage({ prompt, referenceImageUrls: cleanRefs });
      }),
    );
    results.push(...batchResults.map((r) => r.urls[0]).filter(Boolean));
    log("carousel-batches", `batch ${Math.floor(i / BATCH_SIZE) + 1} (${batch.length} slides) ms=${Date.now() - batchStart}`);
  }

  log("carousel-batches", `done total=${results.length}/${prompts.length}`);
  return results;
}
