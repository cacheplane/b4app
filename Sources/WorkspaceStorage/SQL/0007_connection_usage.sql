-- Usage the phone shows (settings connections, usage on the phone): each connection's latest plan
-- reading and B4 token totals, kept in step by the coordinator from the local tables of 0006. Unlike
-- those, this table syncs: its trigger logs every change for the hub.
CREATE TABLE "connectionUsage" (
  "connectionId" text PRIMARY KEY REFERENCES "connections"("id") ON DELETE CASCADE,
  "reading" jsonb,
  "tokens" jsonb,
  "updatedAt" text NOT NULL
);

CREATE TRIGGER "connectionUsageChanges" AFTER INSERT OR UPDATE OR DELETE ON "connectionUsage"
  FOR EACH ROW EXECUTE FUNCTION b4app_record_change('connectionId');
