-- The change log every synced write feeds (design "Sync model"). Written by triggers so no Swift
-- path can forget it; read and replicated by the coordinator. Scope: local and hub.

CREATE TABLE "devices" (
  "id" text PRIMARY KEY,
  "name" text NOT NULL DEFAULT '',
  "createdAt" text NOT NULL
);

CREATE TABLE "changes" (
  "seq" bigserial PRIMARY KEY,
  "deviceId" text NOT NULL,
  -- Milliseconds since the epoch on the origin device when the change was recorded.
  "wall" bigint NOT NULL,
  "table" text NOT NULL,
  "rowId" text NOT NULL,
  "op" text NOT NULL CHECK ("op" IN ('insert', 'update', 'delete')),
  -- update: the column that changed; insert and delete: NULL.
  "column" text,
  -- insert: the whole row; update: the column's new value; delete: NULL.
  "value" jsonb,
  "synced" boolean NOT NULL DEFAULT false
);
CREATE INDEX "changesUnsynced" ON "changes" ("synced", "seq");

-- Records inserts as whole rows, updates per changed column, deletes as tombstones. The device id
-- comes from the session setting b4app.device_id (the coordinator sets it per connection); a session
-- replaying changes from elsewhere sets b4app.replaying = 'on' and is not recorded again.
CREATE FUNCTION b4app_record_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  device text := coalesce(nullif(current_setting('b4app.device_id', true), ''), 'local');
  wall bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  key text := TG_ARGV[0];
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
    INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "value")
      VALUES (device, wall, TG_TABLE_NAME, newj ->> key, 'insert', newj);
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    newj := to_jsonb(NEW);
    oldj := to_jsonb(OLD);
    FOR k, v IN SELECT * FROM jsonb_each(newj) LOOP
      IF oldj -> k IS DISTINCT FROM v THEN
        INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "column", "value")
          VALUES (device, wall, TG_TABLE_NAME, newj ->> key, 'update', k, v);
      END IF;
    END LOOP;
    RETURN NEW;
  ELSE
    oldj := to_jsonb(OLD);
    INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op")
      VALUES (device, wall, TG_TABLE_NAME, oldj ->> key, 'delete');
    RETURN OLD;
  END IF;
END
$$;

CREATE TRIGGER "connectionsChanges" AFTER INSERT OR UPDATE OR DELETE ON "connections"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "threadsChanges" AFTER INSERT OR UPDATE OR DELETE ON "threads"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "turnsChanges" AFTER INSERT OR UPDATE OR DELETE ON "turns"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "displayItemsChanges" AFTER INSERT OR UPDATE OR DELETE ON "displayItems"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "runtimeRequestsChanges" AFTER INSERT OR UPDATE OR DELETE ON "runtimeRequests"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('id');
CREATE TRIGGER "draftsChanges" AFTER INSERT OR UPDATE OR DELETE ON "drafts"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('threadId');
