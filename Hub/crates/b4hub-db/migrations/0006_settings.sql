-- M8e: hub-wide settings, not tenant-scoped.
--
-- One row per key. Nothing here belongs to an org, so there is no org_id and no row-level
-- security; `migrate` grants the application role SELECT only (see grant_table_access), and the
-- operator commands write it as the owner. The first key is `maintenance`:
-- {"mode": "read_only", "message": "<optional operator text>", "since": "<RFC 3339 UTC>"}, present
-- while writes are paused and absent otherwise.
--
-- Numbered 0006 because 0004 (the relay) and 0005 (accounts) are claimed by branches that have not
-- merged; sqlx applies whatever the ledger lacks in version order, so they can land afterwards.

CREATE TABLE hub_settings (
    key        text PRIMARY KEY,
    value      jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- `migrate` revokes writes from the application role after every run; this does the same here, so
-- the split holds even if `migrate` fails between the migrator and that step. The role does not
-- exist yet on a fresh database (it is provisioned after the migrations), hence the condition.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'b4hub_app') THEN
        REVOKE INSERT, UPDATE, DELETE ON hub_settings FROM b4hub_app;
    END IF;
END
$$;
