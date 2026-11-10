-- The hub device this Mac last announced its own rows as (D-184). A row's owner, on the hub and in
-- the phone's mirror, is the device of its latest insert, so when this Mac's device changes (a join
-- after a leave or a revocation, a sign-in that gets a new device) the rows it already had would stay
-- owned by the old one. `claimOwnedRows` re-announces them when this differs from `deviceId`; null
-- (every link before this migration) re-announces once.
ALTER TABLE "hubLink" ADD COLUMN "ownedAs" text;
