// v38: Provider call logger. Wraps every outbound HTTP call into
// OpenAI / Gemini so we can inspect prompts, responses, status,
// timing, and errors from the admin dashboard.
//
// Privacy: a real response body can be megabytes (e.g. base64
// images from gpt-image-1). We always persist the full body so
// admins can debug without false hope - the admin UI truncates for
// display. The 3-day retention (pruned on worker boot + every 6h)
// keeps the table from ballooning.

import { prisma } from "../db/client.js";

export type ErrorKind =
  | "timeout"
  | "rate_limit"
  | "bad_status"
  | "decode"
  | "network"
  | "exception";

export interface ProviderCallInput {
  provider: "openai" | "gemini" | string;
  operation: string; // e.g. "openai.generateImage", "gemini.pollVideoOperation"
  projectId?: string;
  jobId?: string;
  request: unknown; // capture the input verbatim - Prisma stores it as JSONB
}

/**
 * Wrap a provider call. Returns the call's return value on success,
 * or rethrows the error on failure. The error itself is not mutated.
 *
 * Usage:
 *   return withProviderCall({
 *     provider: 'openai',
 *     operation: 'openai.generateImage',
 *     projectId,
 *     request: { prompt, referenceCount: refFiles.length, size },
 *     fn: () => client.images.generate(...),
 *     classifyError: (e) => classifyOpenAIError(e),
 *     extractResponse: (res) => ({ urls: res.data?.length ?? 0 }),
 *   });
 */
export async function withProviderCall<T>(args: {
  provider: ProviderCallInput["provider"];
  operation: string;
  projectId?: string;
  jobId?: string;
  request: unknown;
  fn: () => Promise<T>;
  /** Map a thrown error to (status, errorKind, responseSummary). Status may be null. */
  classifyError: (err: unknown) => {
    status: number | null;
    kind: ErrorKind;
    response?: unknown;
  };
  /** Pull a small summary out of the success value to avoid storing megabytes of response b64. */
  extractResponse?: (value: T) => unknown;
  /** If true, store the full success value (may be megabytes). Default false. */
  storeFullResponse?: boolean;
}): Promise<T> {
  const startedAt = Date.now();
  try {
    const value = await args.fn();
    const durationMs = Date.now() - startedAt;
    const responseSummary =
      args.storeFullResponse === true
        ? args.extractResponse
          ? safeJson(args.extractResponse(value))
          : undefined
        : args.extractResponse
          ? safeJson(args.extractResponse(value))
          : { ok: true };
    // For success, write the log row but DON'T block - fire-and-forget.
    void prisma.providerCall
      .create({
        data: {
          operation: args.operation,
          provider: args.provider,
          projectId: args.projectId,
          jobId: args.jobId,
          status: 200,
          durationMs,
          requestSummary: safeJson(args.request) as any,
          responseSummary: responseSummary as any,
        },
      })
      .catch((err) => {
        // Logging itself must never crash the caller. Best-effort.
        console.error(`[providerLog] failed to persist success log:`, err);
      });
    return value;
  } catch (err) {
    const durationMs = Date.now() - startedAt;
    const { status, kind, response } = args.classifyError(err);
    void prisma.providerCall
      .create({
        data: {
          operation: args.operation,
          provider: args.provider,
          projectId: args.projectId,
          jobId: args.jobId,
          status,
          durationMs,
          errorKind: kind,
          requestSummary: safeJson(args.request) as any,
          responseSummary: safeJson(response ?? { error: String(err) }) as any,
        },
      })
      .catch((logErr) => {
        console.error(`[providerLog] failed to persist error log:`, logErr);
      });
    throw err;
  }
}

/**
 * Convenience: summarise an unknown error into (status, kind, response).
 * Use as a default when the caller doesn't have richer classification.
 */
export function defaultClassifyError(err: unknown): {
  status: number | null;
  kind: ErrorKind;
  response?: unknown;
} {
  if (err && typeof err === "object" && "name" in err) {
    const name = (err as { name: string }).name;
    const message =
      "message" in err && typeof (err as { message: unknown }).message === "string"
        ? (err as { message: string }).message
        : String(err);
    if (name === "TimeoutError" || /timeout/i.test(message))
      return { status: null, kind: "timeout", response: { name, message } };
    if (/4\d\d/.test(message))
      return { status: 4_00, kind: "bad_status", response: { name, message } };
    if (/5\d\d|429/.test(message))
      return { status: 5_00, kind: "rate_limit", response: { name, message } };
    return { status: null, kind: "exception", response: { name, message } };
  }
  return { status: null, kind: "exception", response: { error: String(err) } };
}

/**
 * Best-effort JSON-safe container: If a value can't be JSON-stringified
 * (e.g. circular structure), fall back to a `{ serialized: String(v) }`
 * snippet. Never throws.
 */
function safeJson(v: unknown): unknown {
  try {
    return JSON.parse(JSON.stringify(v));
  } catch (_) {
    return { serialized: String(v).slice(0, 500) };
  }
}

/**
 * Prune logs older than 3 days. Idempotent. Runs on worker boot and
 * every 6 hours via the existing sweep interval.
 */
export async function pruneOldProviderCalls(): Promise<number> {
  const cutoff = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);
  const { count } = await prisma.providerCall.deleteMany({
    where: { createdAt: { lt: cutoff } },
  });
  return count;
}
