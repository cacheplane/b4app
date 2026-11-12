-- Runtime commands: the commands a connection's runtime runs from a message that starts with
-- `/name`, as it last reported them (a JSON list of `RuntimeCommand`). Null for B4 and until the
-- runtime has reported. Written only by the Mac that owns the connection, so it is not clocked and
-- the 0009 trigger function stands as it is.
ALTER TABLE "connections" ADD COLUMN "commands" jsonb;
