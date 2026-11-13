-- Density: how tall the thread list's rows are (`normal`, `dense`), split out of `quietThreads`, which
-- now holds only where the quiet threads go (`shown`, `collapsed`, `hidden`). Nullable, read leniently
-- and kept whatever text arrives, like the other columns of the row (0013).
ALTER TABLE "viewSettings" ADD COLUMN "density" text;

-- The 0013 trigger function again, with `density` in the `viewSettings` clocked list; nothing else
-- changes. The lists must equal SyncColumns.clocked in WorkspaceProtocol; a test reads them back.
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
    WHEN 'viewSettings' THEN ARRAY['id', 'arrangement', 'quietThreads', 'showArchived', 'updatedAt', 'density']
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
    IF TG_TABLE_NAME = 'viewSettings' THEN newj := jsonb_strip_nulls(newj); END IF;
    INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "value", "hlc")
      VALUES (device, wall, TG_TABLE_NAME, newj ->> key, 'insert', newj, stamp);
    FOREACH k IN ARRAY clocked LOOP
      CONTINUE WHEN TG_TABLE_NAME = 'viewSettings' AND NOT newj ? k;
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

-- The stored row's old sidebar values, converted: `small` is shown at normal density, `tiny` shown and
-- dense, `collapsed` and `hidden` keep their place at normal density; a density already stored is kept.
-- A null or unknown value, or no row, is left alone. The migrator runs this file in one transaction, so
-- `SET LOCAL` ends with it at the latest; with replaying on, the rewrite logs no change and claims no
-- clock (every device converts its own copy, and the hub its own).
SET LOCAL b4app.replaying = 'on';
UPDATE "viewSettings" SET
  "density" = coalesce("density", CASE "quietThreads" WHEN 'tiny' THEN 'dense' ELSE 'normal' END),
  "quietThreads" = CASE "quietThreads" WHEN 'small' THEN 'shown' WHEN 'tiny' THEN 'shown' ELSE "quietThreads" END
WHERE "quietThreads" IN ('small', 'tiny', 'collapsed', 'hidden');
RESET b4app.replaying;
