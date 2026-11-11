-- Environments: the Mac's "project" (a set of folders threads work in) is now an "environment".
-- A pure rename. The tables, the three `projectId` columns and the two hub indexes are renamed in
-- place; row-level security, its forced flag and the policies follow a renamed table. The names
-- are also stored as data: `changes` and `column_clocks` hold the table and column of every
-- change, and an insert's `value` holds the row's columns as keys, so those are rewritten too.
-- (`value_bytes`, the stored size of the rendered value, is recomputed for the rows rewritten.)
-- Without that, an unpulled change would name a table the hub no longer has, and the per-column
-- clocks of `projects.name` and `threads.projectId` would be lost, so an older write could win.
--
-- The rewrites touch rows under forced row-level security without a tenant, so it is switched
-- off for those two tables and on again before the migration ends (DDL is transactional here).

ALTER TABLE "projects" RENAME TO "environments";
ALTER TABLE "projectFolders" RENAME TO "environmentFolders";
ALTER TABLE "environmentFolders" RENAME COLUMN "projectId" TO "environmentId";
ALTER TABLE "threads" RENAME COLUMN "projectId" TO "environmentId";
ALTER TABLE "connections" RENAME COLUMN "projectId" TO "environmentId";
ALTER INDEX "projects_by_user" RENAME TO "environments_by_user";
ALTER INDEX "projectFolders_by_user" RENAME TO "environmentFolders_by_user";

ALTER TABLE changes NO FORCE ROW LEVEL SECURITY;
ALTER TABLE column_clocks NO FORCE ROW LEVEL SECURITY;

UPDATE changes SET "table" = 'environments' WHERE "table" = 'projects';
UPDATE changes SET "table" = 'environmentFolders' WHERE "table" = 'projectFolders';
UPDATE changes SET "column" = 'environmentId' WHERE "column" = 'projectId';
UPDATE changes
    SET value = (value - 'projectId') || jsonb_build_object('environmentId', value -> 'projectId'),
        value_bytes = octet_length(((value - 'projectId')
            || jsonb_build_object('environmentId', value -> 'projectId'))::text)
    WHERE jsonb_typeof(value) = 'object' AND value ? 'projectId';

UPDATE column_clocks SET "table" = 'environments' WHERE "table" = 'projects';
UPDATE column_clocks SET "table" = 'environmentFolders' WHERE "table" = 'projectFolders';
UPDATE column_clocks SET "column" = 'environmentId' WHERE "column" = 'projectId';

ALTER TABLE changes FORCE ROW LEVEL SECURITY;
ALTER TABLE column_clocks FORCE ROW LEVEL SECURITY;
