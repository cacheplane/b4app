-- The hub never deletes a synced row (D-089). A `delete` change sets the row's `deleted_at`
-- instead of removing it, and keeps its column clocks; the change itself is still recorded in the
-- feed, so a pull delivers it and a phone's mirror drops the row as before. Every read of the
-- mirrored tables (the snapshot, the relay's owner lookups, a parent check) leaves out rows with
-- `deleted_at` set, and a later insert of the same key revives the row by clearing it. Only a
-- future full delete, requested by the owner of the data, may remove rows.
--
-- The column is the hub's own, like `owner_device_id`: it is never sent to a client.
--
-- Numbered 0009 because 0005 and 0007 are claimed by the unmerged sign-in branch; sqlx applies
-- whatever the ledger lacks, in version order.

ALTER TABLE "connections" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "projects" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "projectFolders" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "threads" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "turns" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "displayItems" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "runtimeRequests" ADD COLUMN deleted_at timestamptz;
ALTER TABLE "drafts" ADD COLUMN deleted_at timestamptz;
