-- Environments: the Mac's "project" (a set of folders threads work in) is now an "environment". A
-- pure rename (the second `projectId` column, on `connections`, is the same concept). The tables, the
-- three `projectId` columns, the three indexes and the two triggers are renamed in place. The names
-- are also stored as data: `changes` and `columnClocks` hold the table and column of every change
-- and every clocked column, and an insert's `value` holds the row's columns as keys, so those are
-- rewritten too. Without that, a change not yet pushed would name a table the hub no longer knows
-- and the per-column clocks of `projects.name` and `threads.projectId` would be lost, so an older
-- write could win. Renames and the rewrites of `changes` and `columnClocks` fire no change-log
-- trigger (those tables have none), so the migration logs nothing of its own.

ALTER TABLE "projects" RENAME TO "environments";
ALTER TABLE "projectFolders" RENAME TO "environmentFolders";
ALTER TABLE "environmentFolders" RENAME COLUMN "projectId" TO "environmentId";
ALTER TABLE "threads" RENAME COLUMN "projectId" TO "environmentId";
ALTER TABLE "connections" RENAME COLUMN "projectId" TO "environmentId";
ALTER INDEX "projectFoldersByProject" RENAME TO "environmentFoldersByEnvironment";
ALTER INDEX "threadsByProject" RENAME TO "threadsByEnvironment";
ALTER INDEX "connectionsByProject" RENAME TO "connectionsByEnvironment";
ALTER TRIGGER "projectsChanges" ON "environments" RENAME TO "environmentsChanges";
ALTER TRIGGER "projectFoldersChanges" ON "environmentFolders" RENAME TO "environmentFoldersChanges";

UPDATE "changes" SET "table" = 'environments' WHERE "table" = 'projects';
UPDATE "changes" SET "table" = 'environmentFolders' WHERE "table" = 'projectFolders';
UPDATE "changes" SET "column" = 'environmentId' WHERE "column" = 'projectId';
UPDATE "changes"
  SET "value" = ("value" - 'projectId') || jsonb_build_object('environmentId', "value" -> 'projectId')
  WHERE jsonb_typeof("value") = 'object' AND "value" ? 'projectId';

UPDATE "columnClocks" SET "table" = 'environments' WHERE "table" = 'projects';
UPDATE "columnClocks" SET "table" = 'environmentFolders' WHERE "table" = 'projectFolders';
UPDATE "columnClocks" SET "column" = 'environmentId' WHERE "column" = 'projectId';

-- The 0009 trigger function again, naming the renamed table and column in its clocked lists. The
-- lists must equal SyncColumns.clocked in WorkspaceProtocol; a test reads them back.
CREATE OR REPLACE FUNCTION b4app_record_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  device text := coalesce(nullif(current_setting('b4app.device_id', true), ''), 'local');
  wall bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  stamp text := coalesce(
    nullif(current_setting('b4app.hlc', true), ''), lpad(to_hex(wall), 12, '0') || '-0000-' || device);
  key text := TG_ARGV[0];
  clocked text[] := CASE TG_TABLE_NAME
    WHEN 'threads' THEN ARRAY[
      'title', 'pinned', 'archived', 'readTurnId', 'environmentId', 'userDeletedAt', 'model', 'permission']
    WHEN 'environments' THEN ARRAY['name']
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
