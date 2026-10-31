-- Logical schema from spec section 5.1 (the SQLite v1 to v3 schema, now native to PostgreSQL).
-- Column names equal the protocol structs' property names and are always quoted.
-- Scope: local and hub, except where noted.

CREATE TABLE "localServers" (            -- local only
  "id" text PRIMARY KEY,
  "name" text NOT NULL DEFAULT '',
  "projectPath" text NOT NULL UNIQUE,
  "nodePath" text NOT NULL,
  "cliPath" text NOT NULL,
  "cliVersion" text,
  "launchMode" text NOT NULL CHECK ("launchMode" IN ('development', 'source')),
  "envFilePath" text,
  "requestedPort" integer,
  "actualPort" integer,
  "generation" integer NOT NULL DEFAULT 0,
  "pid" integer,
  "processStartedAt" double precision,
  "ownershipVerified" boolean NOT NULL DEFAULT false,
  "health" text NOT NULL,
  "statusMessage" text,
  "routes" jsonb NOT NULL DEFAULT '[]',
  "logPath" text,
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL
);
CREATE UNIQUE INDEX "localServersByName" ON "localServers" ("name");

CREATE TABLE "connections" (
  "id" text PRIMARY KEY,
  "kind" text NOT NULL CHECK ("kind" IN ('codex', 'claude', 'b4')),
  "label" text NOT NULL,
  "enabled" boolean NOT NULL DEFAULT true,
  "profileRevision" integer NOT NULL DEFAULT 0,
  "target" text NOT NULL,
  "routeKey" text,
  "b4Mode" text,
  "localServerId" text REFERENCES "localServers" ("id") ON DELETE SET NULL,
  "authReference" text,
  "nativeScope" text,
  "capabilities" jsonb NOT NULL,
  "status" text NOT NULL,
  "authStatus" text NOT NULL,
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL
);

CREATE TABLE "threads" (
  "id" text PRIMARY KEY,
  "connectionId" text NOT NULL REFERENCES "connections" ("id") ON DELETE RESTRICT,
  "nativeThreadId" text NOT NULL,
  "nativeScope" text NOT NULL DEFAULT '',
  "title" text NOT NULL DEFAULT '',
  "context" text,
  "pinned" boolean NOT NULL DEFAULT false,
  "archived" boolean NOT NULL DEFAULT false,
  "continuity" text NOT NULL DEFAULT 'available' CHECK ("continuity" IN ('available', 'missing', 'identity_changed')),
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL,
  UNIQUE ("connectionId", "nativeScope", "nativeThreadId")
);
CREATE INDEX "threadsByConnection" ON "threads" ("connectionId", "updatedAt");

CREATE TABLE "turns" (
  "id" text PRIMARY KEY,
  "threadId" text NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
  "operationId" text NOT NULL UNIQUE,
  "nativeTurnId" text,
  "inputRef" text,
  "status" text NOT NULL,
  "submission" text NOT NULL,
  "outcome" text,
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL
);
CREATE INDEX "turnsByThread" ON "turns" ("threadId", "createdAt");

CREATE TABLE "displayItems" (
  "id" text PRIMARY KEY,
  "threadId" text NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
  "turnId" text REFERENCES "turns" ("id") ON DELETE SET NULL,
  "nativeItemId" text,
  "role" text NOT NULL,
  "type" text NOT NULL,
  "payload" jsonb NOT NULL,
  "sequence" integer NOT NULL,
  "provenance" text NOT NULL CHECK ("provenance" IN ('live', 'snapshot', 'cache')),
  "createdAt" text NOT NULL,
  UNIQUE ("threadId", "sequence")
);

CREATE TABLE "runtimeRequests" (
  "id" text PRIMARY KEY,
  "nativeRequestId" text NOT NULL,
  "threadId" text NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
  "turnId" text REFERENCES "turns" ("id") ON DELETE SET NULL,
  "adapterGeneration" integer NOT NULL,
  "kind" text NOT NULL,
  "state" text NOT NULL CHECK ("state" IN ('pending', 'resolved', 'expired')),
  "payload" jsonb NOT NULL,
  "createdAt" text NOT NULL,
  "updatedAt" text NOT NULL,
  UNIQUE ("threadId", "adapterGeneration", "nativeRequestId")
);

CREATE TABLE "drafts" (
  "threadId" text PRIMARY KEY REFERENCES "threads" ("id") ON DELETE CASCADE,
  "text" text NOT NULL,
  "updatedAt" text NOT NULL
);
