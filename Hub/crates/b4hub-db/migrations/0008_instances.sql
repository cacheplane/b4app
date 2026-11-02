-- M8e Part B: the relay on more than one hub instance.
--
-- `hub_instances` is one row per running `serve`: it registers on start and refreshes
-- `heartbeat_at` every few seconds; a row whose heartbeat is older than the liveness window (20 s
-- in production) is a dead instance. `user_links` names the instance that serves a user's links:
-- every link of one user is served by one instance, so the relay's in-memory routing never crosses
-- instances. A live owner keeps its claim; a dead owner's claim is taken over by the next instance
-- a link of that user reaches, and a draining instance deletes its own claims on shutdown.
--
-- Both tables are hub-internal, like `device_tokens`: no org_id and no row-level security, and the
-- application role reads and writes them (the blanket grant in `migrate` covers them). There is no
-- foreign key from `user_links.user_id` to `users`, which is a tenant table: a claim is a routing
-- hint, and the prune removes the claims of dead instances.
--
-- Numbered 0008 because 0005 and 0007 are claimed by the unmerged sign-in branch; sqlx applies
-- whatever the ledger lacks, in version order.

CREATE TABLE hub_instances (
    instance_id  uuid PRIMARY KEY,
    started_at   timestamptz NOT NULL,
    heartbeat_at timestamptz NOT NULL,
    public_url   text
);

CREATE TABLE user_links (
    user_id     uuid PRIMARY KEY,
    instance_id uuid NOT NULL,
    claimed_at  timestamptz NOT NULL
);
CREATE INDEX user_links_by_instance ON user_links (instance_id);
