-- Tenancy: organisations, their users, enrolled devices, device tokens, enrollment codes.
--
-- Row-level security: every tenant-private table is ENABLEd and FORCEd (the owner is subject to
-- the policy too) with the policy `org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid`.
-- A transaction that has not set `b4hub.org_id` sees and writes nothing. The application role
-- `b4hub_app` is created by `b4hub migrate` (roles are cluster-global, not per-database); it does
-- not own these tables and has no BYPASSRLS.

-- `orgs` is the tenant directory (id, slug, name) and holds nothing tenant-private, so it carries
-- no row-level security: operator commands (`seed`, `enroll`) must resolve an org by slug before
-- any tenant context exists.
CREATE TABLE orgs (
    id         uuid PRIMARY KEY,
    slug       text NOT NULL UNIQUE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE users (
    id           uuid PRIMARY KEY,
    org_id       uuid NOT NULL REFERENCES orgs (id),
    username     text NOT NULL,
    display_name text NOT NULL,
    email        text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (org_id, username)
);
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON users
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

CREATE TABLE devices (
    id           uuid PRIMARY KEY,
    org_id       uuid NOT NULL REFERENCES orgs (id),
    user_id      uuid NOT NULL REFERENCES users (id),
    name         text NOT NULL,
    platform     text NOT NULL CHECK (platform IN ('macos', 'ios', 'cli')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz,
    revoked_at   timestamptz
);
ALTER TABLE devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON devices
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

-- No row-level security on `device_tokens` and `enrollment_codes`: both are looked up by the hash
-- of a secret the caller presents, before the org is known, so there is no tenant context to
-- filter by. The hash is unguessable (256-bit token, or a single-use eight-character code that
-- expires in ten minutes) and the rows carry no tenant data beyond ids.
CREATE TABLE device_tokens (
    id         uuid PRIMARY KEY,
    org_id     uuid NOT NULL REFERENCES orgs (id),
    device_id  uuid NOT NULL REFERENCES devices (id),
    token_hash bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);

CREATE TABLE enrollment_codes (
    code_hash  bytea PRIMARY KEY,
    org_id     uuid NOT NULL REFERENCES orgs (id),
    user_id    uuid NOT NULL REFERENCES users (id),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);
