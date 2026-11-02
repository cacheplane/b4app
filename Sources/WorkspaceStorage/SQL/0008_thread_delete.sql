-- Deleting threads. A deleted thread is kept, marked by `userDeletedAt` (synced, so every device hides
-- it), and never shown or used for personal memory. Once set, nothing clears it.
ALTER TABLE "threads" ADD COLUMN "userDeletedAt" text;

-- The 0004 trigger function again, with `userDeletedAt` clocked: the phone can delete a thread, and the
-- column merges by clock like the thread's other phone-writable columns. The lists must equal
-- SyncColumns.clocked in WorkspaceProtocol; a test reads them back.
CREATE OR REPLACE FUNCTION b4app_record_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  device text := coalesce(nullif(current_setting('b4app.device_id', true), ''), 'local');
  wall bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  stamp text := coalesce(
    nullif(current_setting('b4app.hlc', true), ''), lpad(to_hex(wall), 12, '0') || '-0000-' || device);
  key text := TG_ARGV[0];
  clocked text[] := CASE TG_TABLE_NAME
    WHEN 'threads' THEN ARRAY['title', 'pinned', 'archived', 'readTurnId', 'projectId', 'userDeletedAt']
    WHEN 'projects' THEN ARRAY['name']
    WHEN 'drafts' THEN ARRAY['threadId', 'text', 'updatedAt']
    ELSE ARRAY[]::text[]
  END;
  newj jsonb;
  oldj jsonb;
  k text;
  v jsonb;
BEGIN
  IF coalesce(current_setting('b4app.replaying', true), '') = 'on' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;
  IF TG_OP = 'INSERT' THEN
    newj := to_jsonb(NEW);
    INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "value", "hlc")
      VALUES (device, wall, TG_TABLE_NAME, newj ->> key, 'insert', newj, stamp);
    FOREACH k IN ARRAY clocked LOOP
      INSERT INTO "columnClocks" ("table", "rowId", "column", "hlc")
        VALUES (TG_TABLE_NAME, newj ->> key, k, stamp)
        ON CONFLICT ("table", "rowId", "column") DO UPDATE SET "hlc" = EXCLUDED."hlc"
        WHERE "columnClocks"."hlc" COLLATE "C" < EXCLUDED."hlc" COLLATE "C";
    END LOOP;
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    newj := to_jsonb(NEW);
    oldj := to_jsonb(OLD);
    FOR k, v IN SELECT * FROM jsonb_each(newj) LOOP
      IF oldj -> k IS DISTINCT FROM v THEN
        INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "column", "value", "hlc")
          VALUES (device, wall, TG_TABLE_NAME, newj ->> key, 'update', k, v, stamp);
        IF k = ANY (clocked) THEN
          INSERT INTO "columnClocks" ("table", "rowId", "column", "hlc")
            VALUES (TG_TABLE_NAME, newj ->> key, k, stamp)
            ON CONFLICT ("table", "rowId", "column") DO UPDATE SET "hlc" = EXCLUDED."hlc"
            WHERE "columnClocks"."hlc" COLLATE "C" < EXCLUDED."hlc" COLLATE "C";
        END IF;
      END IF;
    END LOOP;
    RETURN NEW;
  ELSE
    oldj := to_jsonb(OLD);
    INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "hlc")
      VALUES (device, wall, TG_TABLE_NAME, oldj ->> key, 'delete', stamp);
    RETURN OLD;
  END IF;
END
$$;

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
