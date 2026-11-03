-- Step-up grants (D-150): proof that the signed-in user just finished a passkey or Apple assertion
-- on this device, which adding or removing a sign-in method and deleting the account require.
--
-- A grant is a 256-bit random token handed to the device once; only its SHA-256 is kept, as for a
-- device token. It is bound to the user and the device that made the assertion, lives two minutes,
-- and is taken once (`used_at`). No row-level security, the same as `device_tokens`: a grant is
-- found by the hash of a secret the caller presents, and the row carries no tenant data beyond ids.
-- Deleting the account removes its grants with its other rows; pruning removes expired ones.
CREATE TABLE step_up_grants (
    token_hash bytea PRIMARY KEY,
    org_id     uuid NOT NULL REFERENCES orgs (id),
    user_id    uuid NOT NULL REFERENCES users (id),
    device_id  uuid NOT NULL REFERENCES devices (id),
    method     text NOT NULL CHECK (method IN ('passkey', 'apple')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);
CREATE INDEX step_up_grants_by_user ON step_up_grants (user_id);
