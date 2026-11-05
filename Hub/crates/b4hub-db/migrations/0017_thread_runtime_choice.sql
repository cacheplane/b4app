-- The new-thread composer: a thread's chosen model and permission mode, and the models each
-- connection offers (a JSON list, null for B4 and until the Mac inspects the connection). Both thread
-- columns are null until a choice is made; they are phone-writable and merge by clock like the
-- thread's other phone-writable columns.
ALTER TABLE "threads" ADD COLUMN "model" text, ADD COLUMN "permission" text;
ALTER TABLE "connections" ADD COLUMN "models" jsonb;
