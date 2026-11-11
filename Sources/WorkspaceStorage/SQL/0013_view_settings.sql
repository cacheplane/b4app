-- View settings: how the account's thread list is arranged, in one synced row whose id is always the
-- literal `view` (the hub's 0019_view_settings.sql). `arrangement` (`needsYouFirst`, `byEnvironment`),
-- `quietThreads` (`small`, `tiny`, `collapsed`, `hidden`) and `showArchived` are nullable: a missing
-- row, a null, or a value this build does not know reads as the default, and the store keeps whatever
-- text arrives, so a value a newer device writes survives here. Like `drafts`, any device may insert
-- the row and write its columns, which merge by clock; nobody deletes it.
CREATE TABLE "viewSettings" (
  "id" text PRIMARY KEY,
  "arrangement" text,
  "quietThreads" text,
  "showArchived" boolean,
  "updatedAt" text
);

CREATE TRIGGER "viewSettingsChanges" AFTER INSERT OR UPDATE OR DELETE ON "viewSettings"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');

-- The 0011 trigger function again, with `viewSettings` in its clocked lists. The lists must equal
-- SyncColumns.clocked in WorkspaceProtocol; a test reads them back.
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
    WHEN 'viewSettings' THEN ARRAY['id', 'arrangement', 'quietThreads', 'showArchived', 'updatedAt']
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
