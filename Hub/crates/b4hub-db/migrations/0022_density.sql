-- Density: the settings row's four-way `quietThreads` (`small`, `tiny`, `collapsed`, `hidden`)
-- is split into `density` (`normal`, `dense`) and a three-way `quietThreads` (`shown`,
-- `collapsed`, `hidden`). This adds the column and converts the rows a hub already holds:
--
--   small     -> density normal, quietThreads shown
--   tiny      -> density dense,  quietThreads shown
--   collapsed -> density normal, quietThreads collapsed
--   hidden    -> density normal, quietThreads hidden
--
-- A row whose `quietThreads` is null or any other value is left as it is, and a row whose
-- `density` is already set keeps it. Each `density` set here takes the clock of the row's
-- `quietThreads`, so a write made before the upgrade cannot win over it; a row with no
-- `quietThreads` clock gets none. The `quietThreads` clock is unchanged. `changes` is left alone:
-- every current reader understands the old values.
--
-- After one run no row holds an old value, so a second run would change nothing.
--
-- The rewrites touch rows under forced row-level security without a tenant, so forcing is lifted
-- for those two tables and then put back as it was found, as in 0020.

ALTER TABLE public."viewSettings" ADD COLUMN "density" text;

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

    INSERT INTO public.column_clocks (org_id, "table", row_id, "column", hlc)
        SELECT c.org_id, c."table", c.row_id, 'density', c.hlc
        FROM public.column_clocks c
        JOIN public."viewSettings" v ON v.org_id = c.org_id AND v."id" = c.row_id
        WHERE c."table" = 'viewSettings' AND c."column" = 'quietThreads'
              AND v."density" IS NULL
              AND v."quietThreads" IN ('small', 'tiny', 'collapsed', 'hidden')
        ON CONFLICT DO NOTHING;

    UPDATE public."viewSettings"
        SET "density" = COALESCE("density",
                                 CASE "quietThreads" WHEN 'tiny' THEN 'dense' ELSE 'normal' END),
            "quietThreads" = CASE "quietThreads"
                                 WHEN 'small' THEN 'shown'
                                 WHEN 'tiny' THEN 'shown'
                                 ELSE "quietThreads"
                             END
        WHERE "quietThreads" IN ('small', 'tiny', 'collapsed', 'hidden');

    IF settings_forced THEN
        ALTER TABLE public."viewSettings" FORCE ROW LEVEL SECURITY;
    END IF;
    IF clocks_forced THEN
        ALTER TABLE public.column_clocks FORCE ROW LEVEL SECURITY;
    END IF;
END $$;
