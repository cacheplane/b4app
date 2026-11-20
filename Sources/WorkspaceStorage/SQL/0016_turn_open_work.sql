-- Open work and origin (the runtime turns design, 2026-11-19): `openWork` is how many agents the turn
-- started are still running; `origin` is null for a turn the owner sent and the runtime's word for one
-- it started itself. Written only by the Mac that owns the thread, so neither is clocked and the 0015
-- trigger function stands as it is.
ALTER TABLE "turns" ADD COLUMN "openWork" integer NOT NULL DEFAULT 0;
ALTER TABLE "turns" ADD COLUMN "origin" text;
