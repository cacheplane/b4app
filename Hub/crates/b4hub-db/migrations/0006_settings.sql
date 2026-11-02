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
