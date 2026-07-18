# Activity B Final - Veo 3.1 :predictLongRunning (2026-07-18)

## Status
Code complete. Two backend files modified, builds successfully,
deploy to Railway ships a real Veo video pipeline.

## What changed from the broken first attempt
First cut of Activity B used `:generateVideos` endpoint with
fabricated model IDs (veo-3.0-fast-generate-preview,
gemini-omni-flash). That 404'd on every request because neither
exists on the public Gemini API surface.

Verified via the user's `models.list` probe and three probe POSTs:
- `models/veo-3.1-fast-generate-preview`, `models/veo-3.1-generate-preview`,
  `models/veo-3.1-lite-generate-preview` exist with
  `supportedGenerationMethods: ["predictLongRunning"]`.
- The endpoint suffix is `:predictLongRunning`, not `:generateVideos`.
- The public API rejects `personGeneration` and `storageUri` (those
  are Vertex-only).
- The user's paid project has Veo enabled at 2 RPM and 30 RPD.

## Files in this archive

| Path | Status | Notes |
| --- | --- | --- |
| `backend/src/providers/geminiVideo.ts` | rewritten | `:predictLongRunning` on `veo-3.1-fast-generate-preview` (draft) and `veo-3.1-generate-preview` (final). Built-in 429 backoff: 60s sleep, max 3 retries. Polling and download handle both `videos[].bytesBase64Encoded` (inline) and `videos[].uri` (download). Wrapped in withProviderCall for v38 ProviderCall rows. |
| `backend/src/queue/worker.ts` | rewritten | processVideoStage calls new generateVideo / pollVideoOperation / downloadVideo. Stamps model + operationId on GenerationJob.inputPayload. v38 features preserved (runMaintenance, pruneOldProviderCalls, jobId plumbing, generateCarouselSlides 3-arg call). |

`backend/src/index.ts` is unchanged from the previous Activity B
attempt (still has the `[boot] GEMINI_API_KEY present (length=N)`
line). You can leave it as is.

## Rate limit handling
Paid tier limits: 2 RPM, 30 RPD on Veo 3.1 fast. The provider
code handles RPM via 429 backoff. For RPD, the third retry attempt
fails and the project goes to `failed` status with a clean
"retry later" message.

## Quota considerations
- 30 RPD on Tier 1 with ~$12 USD credits prepaid. Each 10-second
  Veo render costs roughly 1-3 RPD (Google's accounting varies).
- Free tier is not enabled for Veo on this project.
- Recommend setting up auto-reload of credits or moving to a
  higher tier before this hits production traffic.

## What I did NOT change
- No Flutter changes - the wire contract (`POST /projects/video`,
  poll `GET /projects/:id`, asset URL playback) is unchanged.
- No Prisma migration.
- No public API change.

## Apply
1. Unzip into your real project root (wherever the backend lives).
2. Replace the existing `backend/src/providers/geminiVideo.ts` and
   `backend/src/queue/worker.ts` with these files.
3. Deploy to Railway (or your local).
4. Trigger one Brand Film render. Expected log story:
   - `[boot] GEMINI_API_KEY present (length=N)` on startup
   - `[video] start projectId=... tier=draft refs=...`
   - `[gemini] submit model=veo-3.1-fast-generate-preview ...`
   - `[gemini] submitted operationId=operations/...`
   - `[gemini-poll] op=... done=true hasInline=true|false hasUri=... mime=...`
   - `[gemini-download] ok bytes=... path=...`
   - `[video] done projectId=... polls=... bytes=... ms=...`

If `[gemini] submit FAIL status=429` shows up before the success,
that means the rate limit hit. The code retries automatically.
Each retry costs 60s of wall-clock time on top of the render.

If `[gemini] submit FAIL status=400` shows up, the request body
is wrong for the model. Most likely cause: a Google API change
to the parameter schema. Paste the full `[gemini] submit FAIL`
log line and I'll diagnose.

## Sensitive info hygiene
After this is stable, rotate the `GEMINI_API_KEY` in Google AI
Studio since it's been in chat. Same for `ADMIN_API_KEY` from
Activity A.
