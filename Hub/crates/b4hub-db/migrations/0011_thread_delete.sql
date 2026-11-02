-- Deleting threads: a thread deleted on the Mac or the phone keeps its row (the hub never hard-deletes
-- data unless the owner asks for a full delete), marked by `userDeletedAt`, an ISO timestamp. It is
-- phone-writable and merges by clock like the thread's other phone-writable columns. Unlike the
-- soft-delete work's `deleted_at`, a thread with `userDeletedAt` is still served, so devices learn it
-- is gone.
ALTER TABLE "threads" ADD COLUMN "userDeletedAt" text;
