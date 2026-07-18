# Activity B v3 — x-goog-api-key header auth (2026-07-18)

## What changed in this revision

Two-line auth swap. The Railway log lines `ACCESS_TOKEN_TYPE_UNSUPPORTED`
on `:predictLongRunning` confirmed that the `?key=` query parameter is
**rejected** for this method, even though the same key works on other
Gemini methods (`generateContent`, etc.).

Fix: send the API key in the `x-goog-api-key` HTTP header instead of
the `?key=` query string.

### geminiVideo.ts

| Before | After |
| --- | --- |
| `?key=${encodeURIComponent(apiKey)}` on submit URL | removed; key sent via header |
| `?key=${encodeURIComponent(apiKey)}` on poll URL | removed; key sent via header |
| `headers: { "Content-Type": "application/json" }` on submit | `headers: { "Content-Type": "application/json", "x-goog-api-key": apiKey }` |
| `headers: {}` on poll | `headers: { "x-goog-api-key": apiKey }` |

`downloadVideo()` already used the `x-goog-api-key` header, no change.

### worker.ts

No change from the previous Activity B build. Calls the same
generateVideo / pollVideoOperation / downloadVideo exports.

## Files

- `backend/src/providers/geminiVideo.ts` (modified)
- `backend/src/queue/worker.ts` (carried from prior step, no change)

## Expected log after deploy

```
[boot] GEMINI_API_KEY present (length=22)
[video] start projectId=... tier=draft refs=0
[gemini] submit model=veo-3.1-fast-generate-preview promptLen=...
[gemini] submitted operationId=operations/... ms=...
[gemini-poll] op=operations/... done=false
... polling every 5s for 30-90s ...
[gemini-poll] op=operations/... done=true hasInline=true|false hasUri=true|false mime=video/mp4
[gemini-download] ... ok bytes=...
[video] done projectId=... polls=... bytes=... ms=...
```

## Failure modes to watch for

| Log | Cause | Next step |
| --- | --- | --- |
| `[gemini] submit FAIL status=401 ACCESS_TOKEN_TYPE_UNSUPPORTED` | Header form also rejected on this surface. | Vertex AI auth required. Open path 2. |
| `[gemini] submit FAIL status=400` | Body shape / field rejected (e.g. durationSeconds still off). | Inspect the response body in the log; most likely `durationSeconds` issue — change default to 6 instead of 8. |
| `[gemini] submit FAIL status=429 ... retry` | RPM rate-limit hit. | Wait, retry built in. |
| `[gemini-poll] op=... done=true hasInline=true hasUri=true` | Both shapes returned. We prefer `bytesBase64` (smaller, no extra fetch). | If `bytesBase64` is empty we fall back to `uri`. |
| `[video] done projectId=... bytes=0` | Bytes were empty after decode. | Server-side bug; paste log. |

## Apply

1. Unzip into your project root.
2. Replace `backend/src/providers/geminiVideo.ts` (and worker.ts if not already replaced).
3. Push to git, deploy to Railway.
4. Trigger one Brand Film render.
