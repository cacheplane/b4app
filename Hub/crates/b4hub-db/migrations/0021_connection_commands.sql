-- Runtime commands: the commands a connection's runtime runs from a message that starts with
-- `/name` (a JSON list, null for B4 and until the Mac's runtime has reported). Written only by the
-- Mac that owns the connection; a phone reads it for its composer.
ALTER TABLE "connections" ADD COLUMN "commands" jsonb;
