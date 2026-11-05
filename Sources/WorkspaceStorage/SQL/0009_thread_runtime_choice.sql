-- The new-thread composer: a thread's chosen model and permission mode, and the models each
-- connection offers. Both thread columns are null until a choice is made (the runtime's default model
-- and its own permission configuration apply); a value is a `RuntimeModel.id` or a
-- `PermissionOption.id`. `models` is the list read when the connection is inspected, null for B4 and
-- until the first inspection.
ALTER TABLE "threads" ADD COLUMN "model" text, ADD COLUMN "permission" text;
ALTER TABLE "connections" ADD COLUMN "models" jsonb;

-- The 0008 trigger function again, with `model` and `permission` clocked: the phone can change them,
-- and they merge by clock like the thread's other phone-writable columns. The lists must equal
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
      'title', 'pinned', 'archived', 'readTurnId', 'projectId', 'userDeletedAt', 'model', 'permission']
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
