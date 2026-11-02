-- Deleting threads. A deleted thread is kept, marked by `userDeletedAt` (synced, so every device hides
-- it), and never shown or used for personal memory. Once set, nothing clears it.
ALTER TABLE "threads" ADD COLUMN "userDeletedAt" text;

-- Progress of deleting the runtime's copy of a deleted thread. Local only: no change-log trigger.
-- A deleted thread with no row here has not been tried yet.
CREATE TABLE "threadDeletes" (
  "threadId" text PRIMARY KEY REFERENCES "threads"("id") ON DELETE CASCADE,
  "state" text NOT NULL CHECK ("state" IN ('waiting', 'done', 'unsupported')),
  "attempts" integer NOT NULL DEFAULT 0,
  "nextAttemptAt" text,
  "lastError" text,
  "updatedAt" text NOT NULL
);
