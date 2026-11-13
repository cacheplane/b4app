-- User settings rows: each user's `viewSettings` row is stored under the id `view:<userId>`
-- instead of the literal `view`, so several users of one org each keep their own. Devices still
-- send and receive `view`; the hub maps the id when it applies a change and when it serves a
-- snapshot. This moves the rows a hub already holds, with their column clocks, to the new id, so
-- a write that arrives after the upgrade still merges against the clock that came with the row.
--
-- A row whose id is not `view` was never reachable by a device (the id was fixed), and the clocks
-- of such a row go with it, as do clocks left under `view` with no row (an update for a missing row
-- can have claimed one). `changes` is left alone: the log keeps `view`, the id devices use.
--
-- The rewrites touch rows under forced row-level security without a tenant, so forcing is lifted
-- for those two tables and then put back as it was found: a table that was not forced before
-- stays unforced (the 0018 runner's controls keep each table's flags, and so does this). DDL is
-- transactional here, so a failure leaves the flags untouched.

DO $$
DECLARE
    settings_forced boolean;
    clocks_forced boolean;
BEGIN
    SELECT relforcerowsecurity INTO settings_forced
        FROM pg_class WHERE oid = 'public."viewSettings"'::regclass;
    SELECT relforcerowsecurity INTO clocks_forced
        FROM pg_class WHERE oid = 'public.column_clocks'::regclass;
    ALTER TABLE public."viewSettings" NO FORCE ROW LEVEL SECURITY;
    ALTER TABLE public.column_clocks NO FORCE ROW LEVEL SECURITY;

    DELETE FROM public.column_clocks WHERE "table" = 'viewSettings' AND row_id <> 'view';
    DELETE FROM public."viewSettings" WHERE "id" <> 'view';

    UPDATE public.column_clocks c
        SET row_id = 'view:' || v.user_id::text
        FROM public."viewSettings" v
        WHERE c.org_id = v.org_id AND c."table" = 'viewSettings' AND c.row_id = 'view'
              AND v."id" = 'view';
    UPDATE public."viewSettings" SET "id" = 'view:' || user_id::text WHERE "id" = 'view';
    DELETE FROM public.column_clocks WHERE "table" = 'viewSettings' AND row_id = 'view';

    IF settings_forced THEN
        ALTER TABLE public."viewSettings" FORCE ROW LEVEL SECURITY;
    END IF;
    IF clocks_forced THEN
        ALTER TABLE public.column_clocks FORCE ROW LEVEL SECURITY;
    END IF;
END $$;
