-- M8c: the relay. A connection names the project it serves, and a Mac mints the codes that pair
-- a phone.
--
-- `connections."projectId"` is the Mac's project a B4 connection serves (null for the others and
-- for rows from before). Only the Mac writes it, and like `threads."projectId"` it has no foreign
-- key: the hub mirrors whatever the Mac sent.
ALTER TABLE "connections" ADD COLUMN "projectId" text;

-- Which Mac minted an enrollment code, when one did (`b4hub enroll` codes have none).
ALTER TABLE enrollment_codes ADD COLUMN created_by_device_id uuid REFERENCES devices (id);

-- One row per pairing code a user minted, to limit minting to ten an hour. Unlike
-- `enrollment_codes` this is looked up by user after authentication, so it is a tenant table.
CREATE TABLE pairing_mints (
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    minted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pairing_mints_by_user ON pairing_mints (org_id, user_id, minted_at);
ALTER TABLE pairing_mints ENABLE ROW LEVEL SECURITY;
ALTER TABLE pairing_mints FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON pairing_mints
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
