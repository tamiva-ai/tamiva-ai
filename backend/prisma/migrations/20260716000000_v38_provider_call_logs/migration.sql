-- Provider call logs (admin debugging). Records every outbound HTTP
-- exchange with OpenAI / Gemini so admins can inspect prompts, request
-- bodies, response bodies, status, timing, and errors from the admin
-- dashboard. 3-day retention; pruned by the worker on boot and every
-- 6h.
CREATE TABLE IF NOT EXISTS "ProviderCall" (
  "id"            TEXT PRIMARY KEY,
  "operation"     TEXT NOT NULL,
  "provider"      TEXT NOT NULL,
  "projectId"     TEXT,
  "jobId"         TEXT,
  "status"        INTEGER,
  "durationMs"    INTEGER NOT NULL,
  "errorKind"     TEXT,
  "requestSummary"  JSONB NOT NULL,
  "responseSummary" JSONB,
  "createdAt"     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "ProviderCall_createdAt_idx" ON "ProviderCall"("createdAt");
CREATE INDEX IF NOT EXISTS "ProviderCall_projectId_idx" ON "ProviderCall"("projectId");
CREATE INDEX IF NOT EXISTS "ProviderCall_operation_idx" ON "ProviderCall"("operation");
CREATE INDEX IF NOT EXISTS "ProviderCall_status_idx" ON "ProviderCall"("status");
