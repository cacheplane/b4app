-- The link to a hub this Mac has joined (M8a). One row at most; written by `hub join`, removed by
-- `hub leave`. The device token itself lives in the secret store; "tokenRef" names it.
-- Scope: local only (the hub never carries this table).

CREATE TABLE "hubLink" (
  "id" integer PRIMARY KEY CHECK ("id" = 1),
  "url" text NOT NULL,
  "deviceId" text NOT NULL,
  "deviceName" text NOT NULL,
  "tokenRef" text NOT NULL,
  "orgSlug" text NOT NULL,
  "username" text NOT NULL,
  -- The hub feed position this device has pulled through (the Mac does not pull in M8a).
  "cursor" bigint NOT NULL DEFAULT 0,
  "lastPushAt" text,
  "lastError" text,
  "joinedAt" text NOT NULL
);
