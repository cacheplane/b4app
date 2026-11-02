-- The Mac's account registry (sign-in design, "The Mac's accounts"): one row per hub user who has
-- signed in on this Mac, in the `registry` database beside the per-account `workspace_<id>` databases.
-- Scope: local only (the hub never carries this table). The token itself lives in the secret store;
-- "token_ref" names it and is null while the account is signed out.

CREATE TABLE "accounts" (
  -- The local account id: 16 lowercase hex characters, also the suffix of the database name.
  "id" text PRIMARY KEY,
  "hub_url" text NOT NULL,
  "hub_user_id" text NOT NULL,
  -- This Mac's device on that hub, reused at every sign-in.
  "device_id" text NOT NULL,
  "database" text NOT NULL UNIQUE,
  "display_name" text NOT NULL,
  "org_name" text NOT NULL,
  "token_ref" text,
  -- An ISO 8601 UTC timestamp with milliseconds (`Timestamp.now()`), like every other timestamp here.
  "last_signed_in_at" text,
  "active" boolean NOT NULL DEFAULT false,
  UNIQUE ("hub_url", "hub_user_id")
);

-- At most one account is active at a time.
CREATE UNIQUE INDEX "accounts_one_active" ON "accounts" ("active") WHERE "active";
