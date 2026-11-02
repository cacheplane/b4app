-- Sign-in: accounts that sign up on their own, their identities (Apple ID, passkeys), personal
-- orgs, and the ceremonies and handoffs a sign-in passes through.
--
-- Numbered after M8c's `0004_relay.sql`, which another branch adds; sqlx applies versions in
-- order and a fresh database tolerates the gap.
--
-- A sign-up creates a personal org with one user. Its slug (`o-` and 8 random base32 characters)
-- and the user's username (`u-` and 8) are generated and never shown; the user names themself
-- once, at onboarding (`full_name`, `onboarded_at`). Users that exist when this runs were set up
-- by an operator and count as onboarded with their display name; their orgs stay non-personal.

-- `email` is optional now: an account made by signing in has none of its own (Apple's relay
-- address is kept on the identity and never used to match accounts).
ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
ALTER TABLE users ADD COLUMN full_name text;
ALTER TABLE users ADD COLUMN onboarded_at timestamptz;
ALTER TABLE users ADD COLUMN deleted_at timestamptz;

-- The backfill touches `users` under forced row-level security without a tenant, so it is
-- switched off for the statement and on again before the migration ends (DDL is transactional).
ALTER TABLE users NO FORCE ROW LEVEL SECURITY;
UPDATE users SET onboarded_at = created_at, full_name = display_name;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

-- `orgs` still carries no row-level security. `owner_user_id` is the one user of a personal org;
-- deleting that user clears it.
ALTER TABLE orgs ADD COLUMN personal boolean NOT NULL DEFAULT false;
ALTER TABLE orgs ADD COLUMN owner_user_id uuid REFERENCES users (id) ON DELETE SET NULL;

-- No row-level security on `user_identities`, `auth_ceremonies`, and `auth_handoffs`: each is
-- looked up before the org is known, so there is no tenant context to filter by, the same as
-- `device_tokens`. An identity is found by an Apple `sub` the hub read from a token it verified,
-- or by the credential id of a WebAuthn assertion it is about to verify; a ceremony by an id the
-- hub handed out, and finishing one still needs Apple's or the authenticator's signature; a
-- handoff by the hash of a 256-bit code, and only together with the hash of the verifier the
-- client kept. The rows carry no tenant data beyond ids, an Apple relay email, and a passkey's
-- public half; the Apple refresh token is stored encrypted with `B4HUB_SECRET_KEY`.
CREATE TABLE user_identities (
    id                      uuid PRIMARY KEY,
    org_id                  uuid NOT NULL REFERENCES orgs (id),
    user_id                 uuid NOT NULL REFERENCES users (id),
    kind                    text NOT NULL CHECK (kind IN ('apple', 'passkey')),
    created_at              timestamptz NOT NULL DEFAULT now(),
    last_used_at            timestamptz,
    -- kind = 'apple'
    apple_sub               text UNIQUE,
    apple_email             text,
    apple_refresh_token_enc bytea,
    -- kind = 'passkey': webauthn-rs's serialised `Passkey` (public key, counter, backup flags).
    credential_id           bytea UNIQUE,
    passkey                 jsonb,
    user_handle             bytea,
    name                    text,
    CHECK ((kind = 'apple') = (apple_sub IS NOT NULL)),
    CHECK ((kind = 'passkey') = (credential_id IS NOT NULL AND passkey IS NOT NULL
                                 AND user_handle IS NOT NULL))
);
CREATE INDEX user_identities_by_user ON user_identities (user_id);

-- A sign-in in progress: webauthn-rs's registration and authentication state, or the Apple nonce
-- and verifier hash. In the database rather than in memory so any hub instance can finish a
-- ceremony another began. Single use (`used_at`), five minutes.
CREATE TABLE auth_ceremonies (
    id         uuid PRIMARY KEY,
    kind       text NOT NULL,
    state      jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);

-- The web Apple flow's result, waiting for the app that began it: redeemed once, within two
-- minutes, with the code from the redirect and the verifier whose hash the ceremony recorded.
CREATE TABLE auth_handoffs (
    code_hash     bytea PRIMARY KEY,
    ceremony_id   uuid NOT NULL REFERENCES auth_ceremonies (id),
    org_id        uuid NOT NULL REFERENCES orgs (id),
    user_id       uuid NOT NULL REFERENCES users (id),
    verifier_hash bytea NOT NULL,
    expires_at    timestamptz NOT NULL,
    used_at       timestamptz
);
CREATE INDEX auth_handoffs_by_ceremony ON auth_handoffs (ceremony_id);
