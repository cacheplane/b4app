-- User settings rows: each user's `viewSettings` row is stored under the id `view:<userId>`
-- instead of the literal `view`, so several users of one org each keep their own. Devices still
-- send and receive `view`; the hub maps the id when it applies a change and when it serves a
-- snapshot. This moves the rows a hub already holds, with their column clocks, to the new id, so
-- a write that arrives after the upgrade still merges against the clock that came with the row.
--
-- A row whose id is not `view` was never reachable by a device (the id was fixed), and the clocks
-- of such a row go with it. `changes` is left alone: the log keeps `view`, the id devices use.
-- (Migration 0020 is held by another branch; the gap is intended.)
--
-- The rewrites touch rows under forced row-level security without a tenant, so it is switched
-- off for those two tables and on again before the migration ends (DDL is transactional here).

ALTER TABLE "viewSettings" NO FORCE ROW LEVEL SECURITY;
ALTER TABLE column_clocks NO FORCE ROW LEVEL SECURITY;

DELETE FROM column_clocks WHERE "table" = 'viewSettings' AND row_id <> 'view';
DELETE FROM "viewSettings" WHERE "id" <> 'view';

UPDATE column_clocks c
    SET row_id = 'view:' || v.user_id::text
    FROM "viewSettings" v
    WHERE c.org_id = v.org_id AND c."table" = 'viewSettings' AND c.row_id = 'view' AND v."id" = 'view';
UPDATE "viewSettings" SET "id" = 'view:' || user_id::text WHERE "id" = 'view';

ALTER TABLE "viewSettings" FORCE ROW LEVEL SECURITY;
ALTER TABLE column_clocks FORCE ROW LEVEL SECURITY;
