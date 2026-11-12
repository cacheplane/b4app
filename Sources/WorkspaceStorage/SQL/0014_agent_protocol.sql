-- A3 local profile storage only. This unpublished migration is still incomplete until the
-- separately tested owner-private obligation/grant/archive work is incorporated before release.
-- Existing connection rows keep their kind/native identity/credentials and gain NULL metadata.
ALTER TABLE "connections"
  ADD COLUMN "peerProfile" text,
  ADD COLUMN "agentId" text,
  ADD COLUMN "authMode" text,
  ADD COLUMN "authHeaderName" text,
  ADD COLUMN "protocolRetiredAt" text,
  ADD COLUMN "protocolRetiredReason" text;

-- The inline kind CHECK in canonical 0001_init is named connections_kind_check by PostgreSQL.
ALTER TABLE "connections" DROP CONSTRAINT "connections_kind_check";
ALTER TABLE "connections" ADD CONSTRAINT "connections_kind_check"
  CHECK ("kind" IN ('codex', 'claude', 'b4', 'agentProtocol'));

-- Public AP identity stays complete even when this device has no private authentication bundle.
-- Both auth fields NULL means unconfigured here, never an implicit explicit-none selection.
-- Historical kinds remain valid with all new fields absent.
ALTER TABLE "connections" ADD CONSTRAINT "connections_protocol_profile_check" CHECK (
  "kind" <> 'agentProtocol' OR (
    "peerProfile" IS NOT NULL AND "peerProfile" IN ('b4', 'agentProtocol') AND
    "agentId" IS NOT NULL AND "agentId" <> '' AND
    "nativeScope" IS NOT NULL AND "nativeScope" <> '' AND
    (
      ("authMode" IS NULL AND "authHeaderName" IS NULL) OR
      (
        "authMode" IS NOT NULL AND "authMode" IN ('none', 'bearer', 'header') AND
        (
          ("authMode" = 'header' AND "authHeaderName" IS NOT NULL AND "authHeaderName" <> '') OR
          ("authMode" IN ('none', 'bearer') AND "authHeaderName" IS NULL)
        )
      )
    )
  )
);

-- Schema validity does not activate retirement. A4 alone may persist these facts after its
-- verified v2 boundary; this migration never supplies a timestamp, reason or UPDATE statement.
ALTER TABLE "connections" ADD CONSTRAINT "connections_protocol_retirement_check" CHECK (
  ("protocolRetiredAt" IS NULL AND "protocolRetiredReason" IS NULL) OR
  (
    "protocolRetiredAt" IS NOT NULL AND "protocolRetiredAt" <> '' AND
    "protocolRetiredReason" IS NOT NULL AND "protocolRetiredReason" = 'agent_protocol_cutover'
  )
);

-- A3 owner-private schema allocation. No sync triggers, row rewrites or authority values.
-- Grant credential APIs, sanitized failure boundaries and self-contained archive4 remain separate
-- tested stages; this whole migration remains unpublished and unshippable until A3 is complete.
CREATE FUNCTION b4app_protocol_string_array(candidate jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT jsonb_typeof(candidate) = 'array' AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
    ) AS item(element) WHERE jsonb_typeof(item.element) <> 'string'
  )
$$;

CREATE FUNCTION b4app_protocol_namespace_array(candidate jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT jsonb_typeof(candidate) = 'array' AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
    ) AS item(element) WHERE NOT b4app_protocol_string_array(item.element)
  )
$$;

-- Match SecretRef(rawValue:) exactly: prefix plus a nonempty opaque tail, not UUID-only.
CREATE FUNCTION b4app_protocol_secret_reference(candidate text) RETURNS boolean
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT left(candidate, 7) = 'secret:' AND char_length(candidate) > 7
$$;

CREATE FUNCTION b4app_protocol_secret_references(candidate jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT b4app_protocol_string_array(candidate) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
    ) AS item(element)
    WHERE jsonb_typeof(item.element) <> 'string'
      OR NOT b4app_protocol_secret_reference(item.element #>> '{}')
  )
$$;

-- Redundant unique keys permit exact owner-bound foreign keys; existing row IDs do not change.
ALTER TABLE "threads" ADD CONSTRAINT "threads_protocol_owner_key" UNIQUE ("id", "connectionId");
ALTER TABLE "turns" ADD CONSTRAINT "turns_protocol_owner_key" UNIQUE ("id", "threadId");

CREATE TABLE "protocolSubscriptions" (
  "threadId" text PRIMARY KEY CHECK ("threadId" <> ''),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "nativeThreadId" text NOT NULL CHECK ("nativeThreadId" <> ''),
  "generation" text CHECK ("generation" IS NULL OR "generation" <> ''),
  -- Generic observation identity is local; it is never an upstream generation or replay promise.
  "localObservationEpoch" text CHECK ("localObservationEpoch" IS NULL OR "localObservationEpoch" <> ''),
  "channels" jsonb NOT NULL CHECK (b4app_protocol_string_array("channels")),
  "namespaces" jsonb NOT NULL CHECK (b4app_protocol_namespace_array("namespaces")),
  "appliedEventId" text CHECK ("appliedEventId" IS NULL OR "appliedEventId" <> ''),
  "appliedSeq" bigint CHECK ("appliedSeq" >= 0),
  "coverage" jsonb NOT NULL CHECK (jsonb_typeof("coverage") = 'object'),
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  CHECK (("generation" IS NULL) <> ("localObservationEpoch" IS NULL)),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
);

CREATE TABLE "protocolRunSegments" (
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  -- b4 uses the native Thread generation; local uses a distinct generic observation epoch.
  -- Old segments outlive subscription changes, so this is not a foreign key to the current epoch.
  "identityEpochKind" text NOT NULL CHECK ("identityEpochKind" IN ('b4', 'local')),
  "identityEpochId" text NOT NULL CHECK ("identityEpochId" <> ''),
  "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
  "nativeRunId" text NOT NULL CHECK ("nativeRunId" <> ''),
  "rootRunId" text CHECK ("rootRunId" IS NULL OR "rootRunId" <> ''),
  "predecessorRunId" text CHECK ("predecessorRunId" IS NULL OR "predecessorRunId" <> ''),
  "localTurnId" text CHECK ("localTurnId" IS NULL OR "localTurnId" <> ''),
  "submissionId" text CHECK ("submissionId" IS NULL OR "submissionId" <> ''),
  "facts" jsonb NOT NULL CHECK (jsonb_typeof("facts") = 'object'),
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  PRIMARY KEY ("connectionId", "threadId", "identityEpochKind", "identityEpochId", "namespace", "nativeRunId"),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT,
  FOREIGN KEY ("localTurnId", "threadId") REFERENCES "turns" ("id", "threadId") ON DELETE RESTRICT
);

CREATE TABLE "protocolOperations" (
  "operationId" text PRIMARY KEY CHECK ("operationId" <> ''),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  "kind" text NOT NULL CHECK ("kind" <> ''),
  "operationThreadId" text NOT NULL CHECK ("operationThreadId" <> ''),
  "targetRunId" text CHECK ("targetRunId" IS NULL OR "targetRunId" <> ''),
  "payload" jsonb NOT NULL,
  "grantReferences" jsonb NOT NULL CHECK (b4app_protocol_secret_references("grantReferences")),
  "expectations" jsonb NOT NULL CHECK (jsonb_typeof("expectations") = 'object'),
  "fingerprint" text NOT NULL CHECK ("fingerprint" <> ''),
  "status" text NOT NULL CHECK ("status" <> ''),
  "acceptedRunId" text CHECK ("acceptedRunId" IS NULL OR "acceptedRunId" <> ''),
  "receipt" jsonb CHECK ("receipt" IS NULL OR jsonb_typeof("receipt") = 'object'),
  "createdAt" text NOT NULL CHECK ("createdAt" <> ''),
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
);

-- Internal credential-value store schema ONLY. Metadata carries typed SecretRef; values may be
-- written/read only by the later dedicated same-transaction credential component, never RPC/UI/sync.
CREATE TABLE "protocolGrantSecrets" (
  "reference" text PRIMARY KEY CHECK (b4app_protocol_secret_reference("reference")),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  "material" text NOT NULL CHECK ("material" <> ''),
  "createdAt" text NOT NULL CHECK ("createdAt" <> ''),
  UNIQUE ("reference", "threadId", "connectionId"),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
);

CREATE TABLE "protocolGrants" (
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  "pausedGeneration" text NOT NULL CHECK ("pausedGeneration" <> ''),
  "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
  "interruptId" text NOT NULL CHECK ("interruptId" <> ''),
  "proposalHash" text NOT NULL CHECK ("proposalHash" <> ''),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "grantReference" text CHECK ("grantReference" IS NULL OR b4app_protocol_secret_reference("grantReference")),
  "disposition" text NOT NULL CHECK ("disposition" <> ''),
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  PRIMARY KEY ("threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT,
  FOREIGN KEY ("grantReference", "threadId", "connectionId")
    REFERENCES "protocolGrantSecrets" ("reference", "threadId", "connectionId") ON DELETE RESTRICT
);

CREATE TABLE "protocolPromptAnswers" (
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  "pausedGeneration" text NOT NULL CHECK ("pausedGeneration" <> ''),
  "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
  "interruptId" text NOT NULL CHECK ("interruptId" <> ''),
  "proposalHash" text NOT NULL CHECK ("proposalHash" <> ''),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  -- Opaque JSON values, including JSON null, are valid; only SQL NULL is absent.
  "answer" jsonb NOT NULL,
  "status" text NOT NULL CHECK ("status" <> ''),
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  PRIMARY KEY ("threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
);

CREATE TABLE "protocolHistoryAnchors" (
  "threadId" text NOT NULL CHECK ("threadId" <> ''),
  "generation" text NOT NULL CHECK ("generation" <> ''),
  "anchor" text NOT NULL CHECK ("anchor" <> ''),
  "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
  "coverage" jsonb NOT NULL CHECK (jsonb_typeof("coverage") = 'object'),
  "revision" text NOT NULL CHECK ("revision" <> ''),
  "nextBefore" text,
  "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
  PRIMARY KEY ("threadId", "generation", "anchor"),
  FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
);
