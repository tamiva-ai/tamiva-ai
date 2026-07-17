# Activity B - Gemini Video Pipeline Fix (applied 2026-07-18)

Applied directly to your source folder. Three backend files modified,
all v38 features preserved.

## Files changed
- backend/src/providers/geminiVideo.ts  - new :generateVideos REST
  surface, real Veo 3.0 model names, inline-base64 image input,
  downloadVideo() helper, AbortController timeouts, structured logs.
  Wrapped in withProviderCall as v38 requires.
- backend/src/queue/worker.ts  - calls downloadVideo, persists
  model + operationId on GenerationJob. Preserves v38
  runMaintenance() / pruneOldProviderCalls / jobId plumbing.
- backend/src/index.ts  - boot-time GEMINI_API_KEY presence check.

## Root cause
Provider called POST ...:generateVideo (singular, doesn't exist) with
model IDs veo-3.1-generate-preview and gemini-omni-flash (fabricated).
Public Gemini API supports POST ...:generateVideos with
veo-3.0-fast-generate-preview (draft) and veo-3.0-generate-preview
(final). Every request 404'd; AI Studio saw zero traffic.

## Files added
- backend/.env.example (not auto-applied; you can copy to .env)
- backend/.gitignore (already existed in your repo as Flutter-only)
- activity-b.diff (this folder)
