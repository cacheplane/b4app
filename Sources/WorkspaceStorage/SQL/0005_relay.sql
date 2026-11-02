-- M8c: the project a local B4 connection serves, and the Mac's own settings. Scope: local; the column
-- also travels to the hub.

-- The project of a managed B4 connection's server folder (null for every other connection). The 0002
-- change-log trigger on "connections" records the column like every other: an insert carries it in the
-- row, a later move is an update of this column alone. The project's deletion leaves the connection.
ALTER TABLE "connections" ADD COLUMN "projectId" text REFERENCES "projects" ("id") ON DELETE SET NULL;
CREATE INDEX "connectionsByProject" ON "connections" ("projectId");

-- Settings that belong to this Mac alone ("Keep the Mac awake"). No change-log trigger: never synced.
CREATE TABLE "settings" (
  "key" text PRIMARY KEY,
  "value" jsonb NOT NULL
);
