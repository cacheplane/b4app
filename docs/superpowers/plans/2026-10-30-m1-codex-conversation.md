# M1 Codex Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A real streamed Codex conversation from the macOS app and the CLI, with approvals, stop, and reopen of the same native thread.

**Architecture:** A `StreamingProcess` wraps the long-lived `codex app-server` child; `CodexAppServer` speaks JSON-RPC over it; `CodexAdapter` translates to `AdapterEvent`s; a new coordinator `SessionService` owns adapters, turn lifecycle, display projection, and runtime requests; the router gains nine methods; the CLI and SwiftUI call them.

**Tech Stack:** Swift 6.2 tools, Foundation `Process`, GRDB 7, SwiftNIO, swift-argument-parser, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-30-m1-codex-conversation-design.md`

## Global Constraints

- Codex minimum `0.166.0`; `clientInfo.name` is `agent_workspace`; `experimentalApi: false`.
- No mocked provider behavior is presented as working; unimplemented paths throw `unsupported_capability`.
- Secrets never appear in arguments, JSON results, logs, or UI state. `account/read` responses are reduced to `type`, `email`, `planType` before leaving the adapter.
- Live tests run only when `B4APP_LIVE_CODEX=1`; CI never sets it.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; `docs/roadmaps/*.md` untouched.

## Review Focus

1. A `turn.send` retried with the same `operationId` after a socket drop must not start a second native turn (Task 5 dedupe test).
2. `codex app-server` exiting mid-turn must leave the turn `reconciling/unknown` and expire its pending requests, never mark it completed (Task 5 exit test).
3. A server request of a kind the app does not implement (`item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`) must receive an explicit decline so Codex never hangs (Task 3 test).
4. Reopening a thread after a coordinator restart must `thread/resume` before `turn/start`; a missing native thread surfaces `native_session_missing` and the cached transcript stays (Task 3 and Task 5 tests).
5. A user message is stored before dispatch; a failed dispatch marks the turn failed and keeps the message visible (Task 5 test).

---

### Task 1: `StreamingProcess` in WorkspacePlatform

**Files:** Create `Sources/WorkspacePlatform/StreamingProcess.swift`; Test `Tests/WorkspacePlatformTests/StreamingProcessTests.swift`.

**Produces:** `public final class StreamingProcess: Sendable` with `static func start(executable: String, arguments: [String], environment: [String: String]?, workingDirectory: String?) throws -> StreamingProcess`, `var stdout: AsyncStream<[UInt8]>` (single consumer), `func write(_ data: Data) throws`, `func closeInput()`, `func terminate()`, `var processIdentifier: Int32`, `func waitForExit() async -> Int32?`, `func recentStderr() -> String` (last 16 KiB).

- [ ] Test: a `/bin/cat` child echoes two written lines across the stream; `closeInput()` ends the stream; exit code 0.
- [ ] Test: `terminate()` on `/bin/sleep 30` ends `waitForExit()` with a non-zero or signal result within 2 s.
- [ ] Test: stderr ring buffer keeps the tail when a `sh -c` child writes 40 KiB to stderr.
- [ ] Implement, run `swift test --filter StreamingProcess`, commit `feat(platform): add StreamingProcess for long-lived stdio children`.

### Task 2: Codex protocol types and event translation

**Files:** Create `Sources/CodexAdapter/CodexProtocol.swift`, `Sources/CodexAdapter/CodexEvents.swift`; Test `Tests/CodexAdapterTests/CodexEventsTests.swift`; fixture lines inline.

**Produces:** `enum CodexProtocol` with `initializeParams(version:)`, `threadStartParams(cwd:)`, `threadResumeParams(threadId:cwd:)`, `turnStartParams(threadId:text:cwd:)`, `turnInterruptParams(threadId:turnId:)`, `turnsListParams(threadId:)`, `approvalResponse(_ decision: RuntimeDecision) -> JSONValue`, `userInputResponse(_ answers: [String: [String]]) -> JSONValue`, `declineResponse(method:) -> JSONValue?`; `struct CodexAccount { type, email?, planType? }` with `init?(_ json: JSONValue)`; `enum CodexEventTranslator { static func translate(_ message: RpcMessage, connectionId: String, generation: Int) -> [AdapterEvent] }`; `static func requestKind(method:) -> RuntimeRequestKind`; `static func snapshotItems(turns: JSONValue) -> [SnapshotItem]`.

- [ ] Test: the recorded turn stream (turn/started, item/started, two deltas, item/completed, turn/completed) translates to `turn.acknowledged, message.started, message.delta ×2, message.completed, turn.finished(completed)` with `nativeIds["turnId"] == "turn_1"`.
- [ ] Test: `turn/completed` with `interrupted` → `cancelled`; with `failed` and `error.codexErrorInfo == "usageLimitExceeded"` → `failed` with `payload.errorCode == "allowance_exceeded"`.
- [ ] Test: `item/commandExecution/requestApproval` → `runtime_request.opened` with kind `command_approval`, `nativeIds["requestId"] == "7"`, payload containing `command` and `cwd` but no `environmentId`.
- [ ] Test: `item/tool/requestUserInput` → kind `user_question`; `item/permissions/requestApproval` → kind `unknown`; `declineResponse` returns a valid body for each known-unsupported method and nil for `item/commandExecution/requestApproval`.
- [ ] Test: `snapshotItems` turns a `thread/turns/list` page into user and assistant `SnapshotItem`s in order.
- [ ] Implement, commit `feat(codex): add protocol builders and event translation`.

### Task 3: `CodexAppServer` and the real `CodexAdapter`

**Files:** Create `Sources/CodexAdapter/CodexAppServer.swift`; Modify `Sources/CodexAdapter/CodexAdapter.swift`, `Sources/CodexAdapter/CodexInspector.swift` (expose `locate`); Test `Tests/CodexAdapterTests/CodexAppServerTests.swift` with `Tests/CodexAdapterTests/Fixtures/fake-codex.sh`.

**Produces:** `actor CodexAppServer { init(executablePath:environment:clientVersion:); func start() async throws; func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue; func notify(_ method:_ params:) async throws; func respond(id: RpcId, result: JSONValue) async throws; var inbound: AsyncStream<RpcMessage>; var generation: Int; func close() async }`. `CodexAdapter(connectionId:executablePath:environment:clientVersion:)` with the `AgentAdapter` methods plus `accountStatus() async throws -> CodexAccount?` and `startLogin() async throws -> (authUrl: String, loginId: String)`.

- [ ] Fixture script: reads stdin lines; answers `initialize`, `account/read`, `thread/start` (`thr_1`), `thread/resume`, `thread/turns/list`, `turn/start` (then streams the canned turn, and when the text contains `approve` first emits a command approval request and waits for the response), `turn/interrupt` (emits `turn/completed interrupted`).
- [ ] Test: handshake sends `initialize` then `initialized`; `accountStatus()` returns `chatgpt` + email from the fixture.
- [ ] Test: `createSession` returns `thr_1` with `nativeScope` equal to the account email; `sendTurn` yields acknowledged receipt and the adapter event stream carries the six events.
- [ ] Test: approval flow: `runtime_request.opened` arrives, `respond(.decision(.allowOnce))` writes `{"id":7,"result":{"decision":"accept"}}` (the fixture echoes it to stderr; assert through the emitted `item/completed`).
- [ ] Test: `respond` for an unknown request id throws `stale_runtime_request`; unsupported request kinds are auto-declined by the adapter when `autoDeclineUnsupported` is on (default), producing `runtime_request.opened` followed by `runtime_request.resolved` with `payload.autoDeclined == true`.
- [ ] Test: `sendTurn` on a thread the process has not loaded issues `thread/resume` first; a fixture `thread/resume` error (`-32600`, "not found") maps to `native_session_missing`.
- [ ] Test: process exit mid-turn finishes the event stream after a `connection.changed(transport: disconnected)`.
- [ ] Implement, commit `feat(codex): drive codex app-server over stdio`.

### Task 4: Protocol methods and storage helpers

**Files:** Modify `Sources/WorkspaceProtocol/Commands.swift`, `Sources/WorkspaceStorage/WorkspaceDatabase.swift`; Tests `Tests/WorkspaceProtocolTests/CommandTests.swift`, `Tests/WorkspaceStorageTests/DatabaseTests.swift`.

**Produces:** `Method` cases `connectionAdd, connectionInspect, connectionLogin, threadCreate, threadRead, threadUpdate, turnSend, turnInterrupt, requestRespond` (mutations all but `threadRead`); command enums `ConnectionAdd { Params(kind, label?, executablePath?) Result(connection) }`, `ConnectionInspect { Params(connectionId) Result(connection) }`, `ConnectionLogin { Params(connectionId) Result(authUrl, loginId) }`, `ThreadCreate { Params(connectionId, workingDirectory, title?) Result(thread) }`, `ThreadRead { Params(threadId) Result(thread, turns, items, requests) }`, `ThreadUpdate { Params(threadId, title?, pinned?, archived?) Result(thread) }`, `TurnSend { Params(threadId, text) Result(turn) }`, `TurnInterrupt { Params(threadId) Result(turn) }`, `RequestRespond { Params(requestId, decision?: RuntimeDecision, answers?: [String: [String]]) Result(request) }`. Storage: `turns(threadId:)`, `activeTurn(threadId:)`, `upsertDisplayItem(_:)` keyed by `(threadId, nativeItemId)`, `runtimeRequest(id:)`, `updateConnection(id:_:)`, `connections(kind:)`, `displayItems(threadId:)` exists.

- [ ] Test: `turn.send` without `operationId` is rejected; `thread.read` without one is accepted.
- [ ] Test: `upsertDisplayItem` replaces the payload of an existing native item without changing its sequence; a new native item gets the next sequence.
- [ ] Test: `activeTurn` returns the non-terminal turn and nil after it is marked terminal.
- [ ] Implement, commit `feat(protocol,storage): add thread, turn, request, and connection methods`.

### Task 5: `SessionService` and router wiring

**Files:** Create `Sources/Coordinator/SessionService.swift`; Modify `Sources/Coordinator/Router.swift`, `Sources/Coordinator/Coordinator.swift`; Test `Tests/CoordinatorTests/SessionTests.swift` (uses the Task 3 fixture script through an explicit executable path).

**Produces:** `actor SessionService { init(database:eventLog:diagnostics:environment:clientVersion:adapterFactory:); func connectionAdd(...); connectionInspect; loginStart; threadCreate; threadRead; threadUpdate; turnSend(threadId:text:operationId:); turnInterrupt; requestRespond; func shutdown() }`. `adapterFactory: @Sendable (Connection) throws -> any AgentAdapter` so tests can inject the fixture path. `RunningCoordinator.sessions`.

- [ ] Test (socket, fixture): add connection → inspect reports `ready/authenticated`, `nativeScope` set → create thread → `turn.send` streams `message.delta` events with the app `threadId` → `thread.read` shows user and assistant items and a terminal turn with outcome `completed`.
- [ ] Test: a second `turn.send` while one is active fails with `protocol_invalid` and detail `turn_active`; a repeat of the first with the same `operationId` returns the cached response and the fixture saw one `turn/start`.
- [ ] Test: approval round trip: `turn.send "please approve"` → `runtime_request.opened` → `request.respond accept` → turn completes; a second `request.respond` fails `stale_runtime_request`.
- [ ] Test: fixture killed mid-turn (`kill -9` the pid printed by the fixture) → turn `reconciling/unknown`, pending request expired, `connection.changed` disconnected; the next `turn.send` restarts the process and resumes the thread.
- [ ] Test: `turn.interrupt` marks the turn `stopping` and the fixture's `turn/completed interrupted` yields outcome `cancelled`.
- [ ] Implement, commit `feat(coordinator): session service for Codex threads, turns, and runtime requests`.

### Task 6: CLI commands

**Files:** Modify `Sources/AgentWorkspaceCLI/Main.swift`, `Sources/AgentWorkspaceCLI/Format.swift`; Create `Sources/AgentWorkspaceCLI/ThreadCommands.swift`, `Sources/AgentWorkspaceCLI/EventPrinter.swift`.

- [ ] Implement `connection add|list|inspect|login`, `thread list|new|show`, `turn send|interrupt`, `request respond` as designed, with `--json` and exit codes (`turn send`: 0 completed, 1 failed, 130 cancelled, 2 unavailable).
- [ ] Manual check against the fixture through `B4APP_RUNTIME_DIR`/`B4APP_DATA_DIR` scratch dirs; commit `feat(cli): thread, turn, request, and connection commands`.

### Task 7: UI

**Files:** Modify `Sources/WorkspaceUI/WorkspaceModel.swift`, `ThreadsView.swift`, `ConnectionsView.swift`, `WorkspaceRootView.swift`; Create `Sources/WorkspaceUI/ThreadDetail.swift` (state), `TranscriptView.swift`, `ComposerView.swift`, `RuntimeRequestView.swift`, `NewThreadSheet.swift`.

- [ ] `WorkspaceModel`: `addConnection(kind:)`, `inspectConnection(id:)`, `login(connectionId:) -> URL`, `createThread(connectionId:directory:title:)`, `openThread(id:)` loads `ThreadDetail`, `send(text:)`, `stop()`, `respond(requestId:decision:)`, `answer(requestId:answers:)`; event patches for `message.*`, `tool.*`, `turn.*`, `runtime_request.*`.
- [ ] Views as designed; both apps build with `xcodebuild`; commit `feat(ui): conversation transcript, composer, approvals, and Codex connection setup`.

### Task 8: Live verification and docs

- [ ] `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` on the owner's Mac; `agent-workspace` end to end against the real coordinator in scratch dirs; macOS app end to end.
- [ ] Update `docs/decisions.md` (D-010 resolved, D-011..D-013), `docs/compatibility.md`, `docs/milestones.md`, `docs/verification.md`, `docs/research/2026-10-30-codex-app-server.md` (live-verified shapes), `README.md` usage.
- [ ] Commit `docs: record M1 verification and decisions`, push, open the PR.
