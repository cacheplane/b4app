-- M8b: projects, the read marker, and hybrid logical clocks in the change log. Scope: local and hub.
--
-- A clock is "<12 hex digits of epoch milliseconds>-<4 hex digits of counter>-<device id>", compared
-- as plain strings. Every SQL comparison or ordering of one uses COLLATE "C" so a cluster's locale
-- can never reorder them.

CREATE TABLE "projects" (
  "id" text PRIMARY KEY,
  "name" text NOT NULL DEFAULT '',
  -- true when a person created the project; false when the backfill derived it from a folder.
  "manual" boolean NOT NULL DEFAULT false,
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL
);

CREATE TABLE "projectFolders" (
  "id" text PRIMARY KEY,
  "projectId" text NOT NULL REFERENCES "projects" ("id") ON DELETE CASCADE,
  -- A SessionService.canonicalDirectory form.
  "path" text NOT NULL UNIQUE,
  "createdAt" text NOT NULL
);
CREATE INDEX "projectFoldersByProject" ON "projectFolders" ("projectId", "createdAt");

ALTER TABLE "threads" ADD COLUMN "projectId" text REFERENCES "projects" ("id") ON DELETE SET NULL;
ALTER TABLE "threads" ADD COLUMN "readTurnId" text;
CREATE INDEX "threadsByProject" ON "threads" ("projectId");

-- Every change carries the clock of the transaction that wrote it. Older rows get the wall-derived form
-- the trigger uses when no clock was set, with a zero counter.
ALTER TABLE "changes" ADD COLUMN "hlc" text;
UPDATE "changes" SET "hlc" = lpad(to_hex("wall"), 12, '0') || '-0000-' || "deviceId";
ALTER TABLE "changes" ALTER COLUMN "hlc" SET NOT NULL;

-- The clock of each column's latest local write, for the columns that merge last-writer-wins.
CREATE TABLE "columnClocks" (
  "table" text NOT NULL,
  "rowId" text NOT NULL,
  "column" text NOT NULL,
  "hlc" text NOT NULL,
  PRIMARY KEY ("table", "rowId", "column")
);

-- The 0002 trigger function, now stamping each change with b4app.hlc (set once per transaction by the
-- coordinator, so one transaction's changes share it) and keeping columnClocks current. The clocked
-- column lists below must equal SyncColumns.clocked in WorkspaceProtocol; a test reads them back.
CREATE OR REPLACE FUNCTION b4app_record_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  device text := coalesce(nullif(current_setting('b4app.device_id', true), ''), 'local');
  wall bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  stamp text := coalesce(
    nullif(current_setting('b4app.hlc', true), ''), lpad(to_hex(wall), 12, '0') || '-0000-' || device);
  key text := TG_ARGV[0];
  clocked text[] := CASE TG_TABLE_NAME
    WHEN 'threads' THEN ARRAY['title', 'pinned', 'archived', 'readTurnId', 'projectId']
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

-- Every thread's activity reads its pending requests (and its latest one) by thread.
CREATE INDEX "runtimeRequestsByThread" ON "runtimeRequests" ("threadId", "state");

-- Replies that existed before the read marker were all seen: mark each thread read at its latest turn
-- when that turn is terminal (latest = greatest createdAt, then greatest id, as the activity query
-- orders them), so the upgrade does not turn every old thread unread. A thread whose latest turn is
-- still running keeps a null marker and stays working. It runs after the trigger function above, so
-- the log records each update (and its readTurnId clock) and the hub receives it.
UPDATE "threads" AS t SET "readTurnId" = latest."id"
  FROM (
    SELECT DISTINCT ON ("threadId") "threadId", "id", "status"
      FROM "turns"
      ORDER BY "threadId", "createdAt" COLLATE "C" DESC, "id" COLLATE "C" DESC
  ) AS latest
  WHERE latest."threadId" = t."id" AND latest."status" = 'terminal';

CREATE TRIGGER "projectsChanges" AFTER INSERT OR UPDATE OR DELETE ON "projects"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "projectFoldersChanges" AFTER INSERT OR UPDATE OR DELETE ON "projectFolders"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
