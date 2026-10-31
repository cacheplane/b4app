# M3 B4 Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B4 threads (attached local server or remote HTTPS endpoint) stream, park on permissions, stop, survive stream loss and coordinator restart, and sit beside Codex and Claude threads.

**Architecture:** `B4Adapter` is an actor per connection over `B4HTTPClient` (JSON + SSE, redirects refused); `B4TurnTranslator` turns SSE events into `AdapterEvent`s; the coordinator gains `credential.add` and B4 connection parameters; the CLI and UI add the B4 forms. No child process: the owner runs the server.

**Tech Stack:** Swift 6.3, Foundation `URLSession` (`bytes(for:)` for SSE), existing `SSEParser`, GRDB, Swift Testing, a Python fixture server.

**Spec:** `docs/superpowers/specs/2026-10-31-m3-b4-conversation-design.md`

## Global Constraints

- Plain `http` only for loopback hosts; everything else HTTPS (`B4HTTPClient.assertAllowedOrigin`).
- Secrets never in arguments, JSON results, events, logs, or UI state; only `secret:<uuid>` references.
- Prompts are never resubmitted by reattachment or reconciliation.
- Unimplemented behavior throws `unsupported_capability` naming the milestone (M4 for managed servers).
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; docs updated.

## Review Focus

1. Stream drops mid-turn while the server keeps running: the turn must reattach and finish without a second prompt (fixture `drop`).
2. Server restart while a thread is parked: the prompt must still be answerable from durable state (fixture restart with `FAKE_B4_STATE`).
3. A 401 from the app middleware on the first turn: the turn fails with `auth_required` and the connection reports it; the health check must not have claimed auth was fine.
4. Cancel racing a natural finish: `no_run_in_flight` must not be reported as a failure, and the stream's `done` decides.
5. A route of kind `workflow`: the connection is `incompatible` with an explanation and no turn is attempted.

---

### Task 1: Protocol additions

**Files:** Modify `Sources/WorkspaceProtocol/Commands.swift`, `Sources/WorkspaceProtocol/Adapter.swift`; Test `Tests/WorkspaceProtocolTests/ConversationCommandTests.swift`.

**Produces:** `ConnectionAdd.Params(kind:label:executablePath:url:route:authReference:)`; `ThreadCreate.Params.workingDirectory: String?`; `Method.credentialAdd = "credential.add"` (mutation); `enum CredentialAdd { Params(label, value) Result(reference, label) }`; `NewSessionInput.routeKey` already exists.

- [ ] Test: `credential.add` without `operationId` is `protocol_invalid`; `ConnectionAdd.Params` round-trips `url`/`route`/`authReference`; `ThreadCreate.Params` decodes without `workingDirectory`.
- [ ] Implement; run `swift test --filter WorkspaceProtocolTests`.

### Task 2: B4 wire helpers and translator

**Files:** Modify `Sources/B4Adapter/B4HTTPClient.swift`, `Sources/B4Adapter/B4Events.swift`; Create `Sources/B4Adapter/B4Protocol.swift`, `Sources/B4Adapter/B4TurnTranslator.swift`; Test `Tests/B4AdapterTests/B4TranslatorTests.swift`, extend `B4AdapterTests.swift`.

**Produces:**
- `B4RouteKey { id, kind; init?(_ text: String); var isAgent }`.
- `B4HTTPClient.json(_ method:_ path:body:) async throws -> (Int, JSONValue)`, `stream(_ method:_ path:body:) async throws -> B4HTTPClient.StreamHandle { status: Int, bytes: AsyncThrowingStream<[UInt8], Error> }`, `authorizationHeader(secret:)`, redirect-refusing delegate, separate long-idle session for streams.
- `B4Protocol.runBody(route:text:)`, `resumeBody(route:interruptId:decision:grant:)`, `error(status:body:)` → `WorkspaceError` mapping (`401/403` → `authRequired`, `404 Unknown route` → `incompatibleVersion`, `404 thread` → `nativeSessionMissing`, `409 run_in_flight` → `protocolInvalid` reason `turn_active`, other 4xx → `protocolInvalid`, 5xx → `internal`), `snapshotItems(stateValues:)`.
- `B4StreamEvent.interrupt` gains `raw: JSONValue`.
- `struct B4TurnTranslator { init(connectionId:threadId:turnId:generation:); mutating translate(_ event: B4StreamEvent) -> [AdapterEvent]; var parked: Bool; var finished: Bool; mutating transportLost() -> [AdapterEvent]; static requestKind(_ b4Kind: String) -> RuntimeRequestKind }`.

- [ ] Tests: ordered events for a streamed turn, tool turn, park (request opened, turn not finished), failed, cancelled, capability event, final message from `done.output.messages`, snapshot from LangChain envelopes, error mapping, route key parsing.
- [ ] Implement; `swift test --filter B4AdapterTests`.

### Task 3: Fixture server

**Files:** Create `Tests/B4AdapterTests/Fixtures/fake-b4.py` (executable).

Behavior: `--port N` (0 = ephemeral), prints `fake-b4 listening on http://127.0.0.1:<port>`; env `FAKE_B4_ROUTE` (default `/chat#agent`), `FAKE_B4_TOKEN` (bearer required on middleware paths), `FAKE_B4_STATE` (JSON file; threads, turns, pending interrupts persist across restarts). Scripts by user text: default stream, `tool`, `approve`, `hang`, `fail`, `drop` (close the response after the first chunk, keep running 1.5 s, reattachable), `slow` (3 s). Endpoints per the design.

- [ ] Smoke-run with `curl` through a scratch shell script; keep nothing in the repo but the fixture.

### Task 4: B4Adapter actor and adapter tests

**Files:** Rewrite `Sources/B4Adapter/B4Adapter.swift`; Test `Tests/B4AdapterTests/B4AdapterSessionTests.swift`, `Tests/B4AdapterTests/B4LiveTests.swift`.

**Produces:** `actor B4Adapter: AgentAdapter` with `init(connectionId:baseURL:routeKey:authorization: @Sendable () async throws -> String?, clientVersion:)`, `init(connection:secretStore:clientVersion:)`, `inspectConnection`, `createSession`, `sendTurn`, `interrupt`, `respond`, `reconcile`, `loadSession`, `events`, `dispose`; pending requests keyed by interrupt id with `grant`, `allowAlways`, and generation; one streaming task per thread; reattach on transport loss.

- [ ] Tests over the fixture: inspect; create + streamed turn in order; tool turn; approve → request opened → `allow_once` resumes and completes; `deny`; decline (cancelled entry); hang → cancel → cancelled; fail → failed; drop → reattach completes with one user message; restart (kill fixture, start again on same port with same state file) → parked request answerable and reconcile reports parked; 401 → `auth_required`; unknown route → `incompatible_version`; reconcile of a missing ordinal → failed/not recorded; loadSession from state.
- [ ] Live test gated by `B4APP_LIVE_B4_URL`/`B4APP_LIVE_B4_ROUTE`.

### Task 5: Coordinator wiring

**Files:** Modify `Sources/Coordinator/SessionService.swift`, `Sources/Coordinator/Router.swift`, `Sources/Coordinator/Coordinator.swift`; Test `Tests/CoordinatorTests/SessionTests.swift` (new suite `B4SessionServiceTests`).

- [ ] `AdapterFactory` gains `any SecretStore`; `Context.secretStore`; `connectionAdd` handles `.b4` (validation, dedupe by url+route, `b4Mode`); `threadCreate` optional directory and B4 context/title; `credentialAdd`; router case.
- [ ] Tests: B4 thread beside Codex; permission answered via `request.respond`; `credential.add` returns a reference and the fixture accepts the bearer; a workflow route is `incompatible`.

### Task 6: CLI and UI

**Files:** Modify `Sources/AgentWorkspaceCLI/Main.swift`, `ConversationCommands.swift`, `Format.swift`; `Sources/WorkspaceUI/ConnectionsView.swift`, `NewThreadSheet.swift`, `WorkspaceModel.swift`, `TranscriptView.swift`, `ThreadsView.swift`.

- [ ] `credential add <label>` with `readpassphrase`; `connection add --url --route --auth-ref`; `thread new` sends no cwd for B4; formats show route.
- [ ] UI: attach-endpoint form, sheet without directory for B4, `toolCall` card, route in header. Build both apps.

### Task 7: Verification and docs

- [ ] `swift format lint --strict …`, `swift test`, both `xcodebuild` builds.
- [ ] Update `docs/decisions.md` (D-019–D-023), `docs/compatibility.md`, `docs/milestones.md`, `docs/verification.md`, `docs/research/2026-10-30-b4-runtime.md` (0.15.8 re-verification), `README.md`, `AGENTS.md`.
- [ ] Commit per task; open PR stacked on `feat/m2-claude-conversation`.
