-- Folders the app made for threads started with no folder. Local to this Mac: never synced, no
-- change-log trigger. The cleanup service (a later design) reads it.
CREATE TABLE "appFolders" (
  "path" TEXT PRIMARY KEY,
  "threadId" TEXT NOT NULL UNIQUE,
  "createdAt" TEXT NOT NULL
);
