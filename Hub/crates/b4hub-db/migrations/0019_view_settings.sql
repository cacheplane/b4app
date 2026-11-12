-- View settings: how an account's thread list is arranged, kept in one synced row whose id is the
-- literal `view`, so every device of the account shows the same arrangement. `arrangement`
-- (`needsYouFirst`, `byEnvironment`), `quietThreads` (`small`, `tiny`, `collapsed`, `hidden`) and
-- `showArchived` are what the devices read; the hub stores whatever text arrives and never checks
-- it, so a value a newer device writes is kept for the devices that know it.
--
-- Like `drafts`, a phone may insert the row and write its columns, which merge by clock; nobody
-- deletes it. Like every synced table it carries the tenancy columns, `owner_device_id` (0003),
-- `deleted_at` (0009) and forced row-level security.
--
-- Rows are keyed (org_id, "id") like every synced table, and an upsert applies only for the row's
-- own user, so in an org with several users only the first user's `view` row is stored. Every
-- account today is a single-user org; lifting that needs a per-user key.
CREATE TABLE "viewSettings" (
    "id" text NOT NULL,
    "arrangement" text,
    "quietThreads" text,
    "showArchived" boolean,
    "updatedAt" text,
    org_id          uuid NOT NULL REFERENCES orgs (id),
    user_id         uuid NOT NULL REFERENCES users (id),
    device_id       uuid NOT NULL REFERENCES devices (id),
    owner_device_id uuid NOT NULL REFERENCES devices (id),
    deleted_at      timestamptz,
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "viewSettings_by_user" ON "viewSettings" (org_id, user_id);
ALTER TABLE "viewSettings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "viewSettings" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "viewSettings"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
