-- v39: Client-side HTTP logs. Records every outbound request the
-- Flutter app makes to the backend (auth, business profile, generation
-- request, status polls, payment). The LoggingHttpClient on the client
-- POSTs each call to /admin/logs; we persist it here.
--
-- Each row is one HTTP round-trip. Request and response are stored
-- together (correlated by client_correlation_id) so the admin UI can
-- show "request body → response body" as one bundle, not as a
-- stream of unrelated events.
CREATE TABLE IF NOT EXISTS "ClientLog" (
  "id"                TEXT PRIMARY KEY,
  "level"             TEXT NOT NULL,        -- "request" | "response" | "error"
  "method"            TEXT NOT NULL,        -- "POST" / "GET" / "PUT"
  "url"               TEXT NOT NULL,
  "statusCode"        INTEGER,
  "elapsedMs"         INTEGER,
  "requestBody"       TEXT,                 -- clipped client-side to 4 KB
  "responseBody"      TEXT,                 -- clipped client-side to 4 KB
  "errorType"         TEXT,                 -- e.g. "SocketException"
  "errorMessage"      TEXT,
  "userId"            TEXT,
  "businessProfileId" TEXT,
  "clientCorrelationId" TEXT,               -- groups request+response+error
  "createdAt"         TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS "ClientLog_createdAt_idx" ON "ClientLog"("createdAt");
CREATE INDEX IF NOT EXISTS "ClientLog_url_idx" ON "ClientLog"("url");
CREATE INDEX IF NOT EXISTS "ClientLog_userId_idx" ON "ClientLog"("userId");
CREATE INDEX IF NOT EXISTS "ClientLog_statusCode_idx" ON "ClientLog"("statusCode");
CREATE INDEX IF NOT EXISTS "ClientLog_correlationId_idx" ON "ClientLog"("clientCorrelationId");
