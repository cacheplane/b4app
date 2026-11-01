-- M8b: hybrid logical clocks, row ownership, projects, and the thread read marker.
--
-- `changes.hlc` is the clock the writing device stamped on a change (after the hub's clamp), in
-- the form "<12 hex digits of epoch milliseconds>-<4 hex digits of counter>-<device id>". Clocks
-- compare as plain strings, so every SQL comparison or ordering of one uses COLLATE "C". Changes
-- the hub already holds get the form a clockless change is given: their wall time, counter 0,
-- and the device that wrote them.
--
-- `column_clocks` holds, per mirrored column that merges last-writer-wins, the clock of the
-- change that last set it. A change applies to such a column only when its clock is greater.
--
-- `owner_device_id` is the device of a row's latest insert (`device_id` stays the last writer).
-- Existing rows are backfilled from the feed. The backfill and the clock update touch rows under
-- forced row-level security without a tenant, so it is switched off for those statements and on
-- again before the migration ends (DDL is transactional here).

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['changes', 'connections', 'threads', 'turns', 'displayItems',
                             'runtimeRequests', 'drafts']
    LOOP
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END
$$;

ALTER TABLE changes ADD COLUMN hlc text;
UPDATE changes
    SET hlc = lpad(to_hex(greatest(wall, 0)), 12, '0') || '-0000-' || device_id::text;
ALTER TABLE changes ALTER COLUMN hlc SET NOT NULL;

DO $$
DECLARE
    spec text[];
BEGIN
    FOREACH spec SLICE 1 IN ARRAY ARRAY[
        ['connections', 'id'], ['threads', 'id'], ['turns', 'id'], ['displayItems', 'id'],
        ['runtimeRequests', 'id'], ['drafts', 'threadId']]
    LOOP
        EXECUTE format('ALTER TABLE %1$I ADD COLUMN owner_device_id uuid REFERENCES devices (id)',
                       spec[1]);
        -- The latest recorded insert of each (row, user), in one pass over the feed. Matching the
        -- user means another user's insert of the same row id never makes their device the owner.
        EXECUTE format(
            'WITH latest AS ('
            '    SELECT DISTINCT ON (org_id, row_id, user_id) org_id, row_id, user_id, device_id'
            '    FROM changes WHERE "table" = %1$L AND op = ''insert'''
            '    ORDER BY org_id, row_id, user_id, hub_seq DESC)'
            ' UPDATE %1$I m SET owner_device_id = latest.device_id FROM latest'
            ' WHERE latest.org_id = m.org_id AND latest.row_id = m.%2$I'
            '   AND latest.user_id = m.user_id',
            spec[1], spec[2]);
        -- A row whose insert was never recorded is owned by its last writer.
        EXECUTE format('UPDATE %1$I SET owner_device_id = device_id WHERE owner_device_id IS NULL',
                       spec[1]);
        EXECUTE format('ALTER TABLE %1$I ALTER COLUMN owner_device_id SET NOT NULL', spec[1]);
    END LOOP;
END
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['changes', 'connections', 'threads', 'turns', 'displayItems',
                             'runtimeRequests', 'drafts']
    LOOP
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    END LOOP;
END
$$;

ALTER TABLE "threads" ADD COLUMN "projectId" text;
ALTER TABLE "threads" ADD COLUMN "readTurnId" text;

-- The Mac's projects and their folders, with the Mac's column names. Like the other mirrored
-- tables every column is nullable except the key, and rows are keyed (org_id, key).
CREATE TABLE "projects" (
    "id" text NOT NULL,
    "name" text,
    "manual" boolean,
    "createdAt" text,
    "updatedAt" text,
    org_id          uuid NOT NULL REFERENCES orgs (id),
    user_id         uuid NOT NULL REFERENCES users (id),
    device_id       uuid NOT NULL REFERENCES devices (id),
    owner_device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "projects_by_user" ON "projects" (org_id, user_id);
ALTER TABLE "projects" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "projects" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "projects"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "projectFolders" (
    "id" text NOT NULL,
    "projectId" text,
    "path" text,
    "createdAt" text,
    org_id          uuid NOT NULL REFERENCES orgs (id),
    user_id         uuid NOT NULL REFERENCES users (id),
    device_id       uuid NOT NULL REFERENCES devices (id),
    owner_device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "projectFolders_by_user" ON "projectFolders" (org_id, user_id);
ALTER TABLE "projectFolders" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "projectFolders" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "projectFolders"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE column_clocks (
    org_id  uuid NOT NULL REFERENCES orgs (id),
    "table" text NOT NULL,
    row_id  text NOT NULL,
    "column" text NOT NULL,
    hlc     text NOT NULL,
    PRIMARY KEY (org_id, "table", row_id, "column")
);
ALTER TABLE column_clocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE column_clocks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON column_clocks
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
