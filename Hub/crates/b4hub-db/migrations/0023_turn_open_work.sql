-- Open work and origin on a turn (the Mac's migration 0016): how many agents the turn started are
-- still running, and the runtime's word for a turn it started itself (null for one the owner sent).
-- Both are nullable: a Mac that predates them sends neither.
ALTER TABLE "turns" ADD COLUMN "openWork" integer;
ALTER TABLE "turns" ADD COLUMN "origin" text;
