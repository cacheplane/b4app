-- Sync: the change feed and the read-only mirror of the Mac's synced tables.
--
-- `changes` is the org's append-only feed, ordered by `hub_seq`. A device's upload is idempotent
-- on (org_id, device_id, device_seq): the unique constraint turns a retried batch into a no-op.
-- The mirrored tables carry the Mac's quoted camelCase columns (see the Mac's 0001_init.sql),
-- every one nullable except the key, because an insert carries whatever the row had and the hub
-- never enforces the Mac's referential or uniqueness rules (a missing parent is skipped at apply
-- time instead). Each also records `org_id`, `user_id` and `device_id` (the last writer); rows
-- are keyed (org_id, key) because the client's text ids are only unique per org.
--
-- Row-level security is enabled and forced on all seven tables with the same policy as `users`
-- and `devices`: a transaction that has not set `b4hub.org_id` sees and writes nothing.

CREATE TABLE changes (
    org_id     uuid NOT NULL REFERENCES orgs (id),
    hub_seq    bigserial NOT NULL,
    device_id  uuid NOT NULL REFERENCES devices (id),
    device_seq bigint NOT NULL,
    user_id    uuid NOT NULL REFERENCES users (id),
    wall       bigint NOT NULL,
    "table"    text NOT NULL,
    row_id     text NOT NULL,
    op         text NOT NULL CHECK (op IN ('insert', 'update', 'delete')),
    "column"   text,
    value      jsonb,
    PRIMARY KEY (org_id, hub_seq),
    UNIQUE (org_id, device_id, device_seq)
);
CREATE INDEX changes_by_user ON changes (org_id, user_id, hub_seq);
ALTER TABLE changes ENABLE ROW LEVEL SECURITY;
ALTER TABLE changes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON changes
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "connections" (
    "id" text NOT NULL,
    "kind" text,
    "label" text,
    "enabled" boolean,
    "profileRevision" integer,
    "target" text,
    "routeKey" text,
    "b4Mode" text,
    "localServerId" text,
    "authReference" text,
    "nativeScope" text,
    "capabilities" jsonb,
    "status" text,
    "authStatus" text,
    "createdAt" text,
    "updatedAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "connections_by_user" ON "connections" (org_id, user_id);
ALTER TABLE "connections" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "connections" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "connections"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "threads" (
    "id" text NOT NULL,
    "connectionId" text,
    "nativeThreadId" text,
    "nativeScope" text,
    "title" text,
    "context" text,
    "pinned" boolean,
    "archived" boolean,
    "continuity" text,
    "createdAt" text,
    "updatedAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "threads_by_user" ON "threads" (org_id, user_id);
ALTER TABLE "threads" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "threads" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "threads"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "turns" (
    "id" text NOT NULL,
    "threadId" text,
    "operationId" text,
    "nativeTurnId" text,
    "inputRef" text,
    "status" text,
    "submission" text,
    "outcome" text,
    "createdAt" text,
    "updatedAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "turns_by_user" ON "turns" (org_id, user_id);
ALTER TABLE "turns" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "turns" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "turns"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "displayItems" (
    "id" text NOT NULL,
    "threadId" text,
    "turnId" text,
    "nativeItemId" text,
    "role" text,
    "type" text,
    "payload" jsonb,
    "sequence" integer,
    "provenance" text,
    "createdAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "displayItems_by_user" ON "displayItems" (org_id, user_id);
ALTER TABLE "displayItems" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "displayItems" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "displayItems"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "runtimeRequests" (
    "id" text NOT NULL,
    "nativeRequestId" text,
    "threadId" text,
    "turnId" text,
    "adapterGeneration" integer,
    "kind" text,
    "state" text,
    "payload" jsonb,
    "createdAt" text,
    "updatedAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "id")
);
CREATE INDEX "runtimeRequests_by_user" ON "runtimeRequests" (org_id, user_id);
ALTER TABLE "runtimeRequests" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "runtimeRequests" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "runtimeRequests"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE "drafts" (
    "threadId" text NOT NULL,
    "text" text,
    "updatedAt" text,
    org_id    uuid NOT NULL REFERENCES orgs (id),
    user_id   uuid NOT NULL REFERENCES users (id),
    device_id uuid NOT NULL REFERENCES devices (id),
    PRIMARY KEY (org_id, "threadId")
);
CREATE INDEX "drafts_by_user" ON "drafts" (org_id, user_id);
ALTER TABLE "drafts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "drafts" FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON "drafts"
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
