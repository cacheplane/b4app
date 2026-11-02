-- Usage on the phone: each connection's latest plan reading and B4 token totals, as the Mac keeps
-- them in its own `connectionUsage` table. Only the Mac writes it (it is not phone-writable), and like
-- every synced table it is tenant-private under row-level security.
--
-- Numbered 0010, after the soft-delete work's 0009: like every synced table it has `deleted_at`, so a
-- `delete` change marks the row instead of removing it (D-089).
CREATE TABLE "connectionUsage" (
    "connectionId" text NOT NULL,
    "reading" jsonb,
    "tokens" jsonb,
    "updatedAt" text,
    org_id          uuid NOT NULL REFERENCES orgs (id),
    user_id         uuid NOT NULL REFERENCES users (id),
    device_id       uuid NOT NULL REFERENCES devices (id),
    owner_device_id uuid NOT NULL REFERENCES devices (id),
    deleted_at      timestamptz,
    PRIMARY KEY (org_id, "connectionId")
);
CREATE INDEX "connectionUsage_by_user" ON "connectionUsage" (org_id, user_id);
ALTER TABLE "connectionUsage" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "connectionUsage" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "connectionUsage"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
