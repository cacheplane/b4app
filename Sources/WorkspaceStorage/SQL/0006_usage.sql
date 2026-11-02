-- Plan usage and B4 token counts (settings connections design). Local only: no change-log trigger,
-- so nothing here reaches the hub or the phone.

-- The latest plan reading per connection (Codex, Claude), a JSON `UsageReading`.
CREATE TABLE "usageReadings" (
  "connectionId" text PRIMARY KEY REFERENCES "connections"("id") ON DELETE CASCADE,
  "reading" text NOT NULL,
  "observedAt" text NOT NULL
);

-- Tokens per finished B4 turn, keyed by the turn so a turn re-finished after reconcile counts once.
CREATE TABLE "tokenUsage" (
  "turnId" text PRIMARY KEY,
  "connectionId" text NOT NULL REFERENCES "connections"("id") ON DELETE CASCADE,
  "recordedAt" text NOT NULL,
  "totalTokens" bigint NOT NULL
);
CREATE INDEX "tokenUsageByConnection" ON "tokenUsage" ("connectionId", "recordedAt");
