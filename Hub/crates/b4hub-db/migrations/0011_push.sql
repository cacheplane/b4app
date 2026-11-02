-- M8f: attention on the phone. The hub decides, in the push transaction, which applied changes
-- notify which phones (decisions D-110 and D-111).
--
-- This is 0011 because open work already claims the numbers below it: 0005 and 0007 belong to the
-- sign-in branch, 0009 is `0009_soft_delete.sql` (PR #45), and 0010 is `0010_connection_usage.sql`
-- (PR #46). Each branch numbers its own migrations; sqlx applies whichever versions the ledger
-- lacks, in order, so the gaps are fine.
--
-- `push_tokens` holds one APNs device token per iOS device, replaced on each registration. The
-- bundle id comes from the phone, so the hub needs no per-flavour configuration.
CREATE TABLE push_tokens (
    org_id      uuid NOT NULL REFERENCES orgs (id),
    device_id   uuid PRIMARY KEY REFERENCES devices (id),
    token       text NOT NULL,
    environment text NOT NULL CHECK (environment IN ('sandbox', 'production')),
    bundle_id   text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_by_org ON push_tokens (org_id);
ALTER TABLE push_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON push_tokens
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);

-- The at-most-once ledger: one row per request id or turn id the hub has decided to notify
-- about, written in the push transaction whether or not a phone has a token or a sender is
-- configured. A retried batch or a later update to the same row finds the row and notifies
-- nobody. `kind` is the mirrored table the row id belongs to; `reason` is the wire reason.
CREATE TABLE notifications_sent (
    org_id    uuid NOT NULL REFERENCES orgs (id),
    kind      text NOT NULL CHECK (kind IN ('request', 'turn')),
    row_id    text NOT NULL,
    user_id   uuid NOT NULL,
    thread_id text NOT NULL,
    reason    text NOT NULL,
    sent_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (org_id, kind, row_id)
);
CREATE INDEX notifications_sent_by_age ON notifications_sent (org_id, sent_at);
ALTER TABLE notifications_sent ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications_sent FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON notifications_sent
    USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
