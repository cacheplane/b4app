# Swift Monorepo and Application Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land an all-Swift monorepo with a running SwiftUI shell for macOS and iOS, a coordinator over a Unix socket, the `agent-workspace` CLI, protocol, storage, platform, and three adapter modules with honest inspection, plus tests and M0 documents.

**Architecture:** SwiftUI views drive a `WorkspaceModel` that talks to a typed `WorkspaceClient` over a transport. On macOS the transport is a NIO Unix socket to a coordinator hosted in-process or spawned by the CLI. The coordinator alone opens SQLite through GRDB. Adapters wrap native CLIs and HTTP.

**Tech Stack:** Swift 6.3 (tools 6.2), Swift Testing, GRDB 7.11, SwiftNIO 2.104, swift-nio-extras, swift-subprocess 1.0, swift-argument-parser 1.8, XcodeGen 2.46, `swift format`.

**Spec:** `docs/superpowers/specs/2026-10-30-swift-monorepo-shell-design.md`.

## Global Constraints

- Swift 6 language mode and approachable concurrency on every target; `MainActor` default isolation only in `WorkspaceUI` and the apps.
- `WorkspaceProtocol`, `WorkspaceClient`, `WorkspaceUI` import only Foundation and SwiftUI so iOS links them.
- Every envelope carries `protocolVersion: 1`; mutations require `operationId`; events carry `epoch` and `sequence`.
- Unimplemented adapter methods throw `WorkspaceError(code: .unsupportedCapability)`.
- Error codes: `missing_executable, incompatible_version, auth_required, auth_mode_conflict, allowance_exceeded, endpoint_unavailable, unsupported_capability, native_session_missing, stale_runtime_request, submission_unknown, owned_process_conflict, cancellation_unconfirmed, protocol_invalid, method_unknown, snapshot_required, not_implemented, not_found, internal`.

## Review Focus

1. A second coordinator starting while one holds the lock must report `alreadyRunning` and leave the lock alone. Test in Task 6.
2. A client replaying from a position older than the buffer must get `snapshot_required`. Test in Task 6.
3. An SSE frame split inside `data:` across chunks must yield one event. Test in Task 5.
4. A Claude environment with `ANTHROPIC_API_KEY` must report `auth_mode_conflict`, not `authenticated`. Test in Task 5.
5. A malformed envelope or unknown method must be rejected by `parseCommand` before any handler runs. Test in Task 2.

---

### Task 1: Package and tooling
Files: `Package.swift`, `.swift-format`, `.gitignore`, `project.yml`, `Scripts/generate-project.sh`, `README.md`, `AGENTS.md`, `CLAUDE.md`, `.github/workflows/ci.yml`.
- [ ] Declare all targets and products; `swift package resolve` succeeds.

### Task 2: WorkspaceProtocol
Produces: `ErrorCode`, `WorkspaceError`, `JSONValue`, domain structs and enums, `CommandEnvelope`/`ResponseEnvelope`/`EventEnvelope`/`HelloEnvelope`/`ServerEnvelope`, `Method`, per-method `Params`/`Result`, `parseCommand(_:) throws -> ParsedCommand`, `AdapterEvent`, `LineDecoder`, `AgentAdapter`.
- [ ] Tests: mutation without operationId fails; unknown method fails with `methodUnknown`; version 2 fails; NDJSON decoder reassembles split lines.

### Task 3: WorkspaceClient and NIOTransport
Produces: `WorkspaceTransport` protocol, `EventCursor`, `WorkspaceClient` actor with `request`, `events`, `desync`, `UnixSocketTransport.connect(path:)`.
- [ ] Tests: cursor gap and epoch change; client resolves typed results and surfaces error codes with a fake transport.

### Task 4: WorkspacePlatform and WorkspaceStorage
Produces: `PlatformPaths`, `ensurePrivateDirectory`, `ExecutableLocator`, `CommandRunner`, `SecretStore` + `KeychainSecretStore` + `MemorySecretStore`, `SingletonLock`; `WorkspaceDatabase` with repositories.
- [ ] Tests: socket path short and inside runtime dir; missing executable nil; command output captured; schema created with WAL and foreign keys; native-id uniqueness per connection and scope; draft round trip; runtime request single transition.

### Task 5: Adapters
Produces: `CodexAdapter.inspect`, `JSONRPCFraming`; `ClaudeAdapter.inspect`, `ClaudeAuthAssessment`, `ClaudeStream` types; `B4Adapter.inspect`, `SSEParser`, `B4StreamEvent`, `B4HTTPClient`.
- [ ] Tests listed in Review Focus plus framing across chunk boundaries, done-outcome classification, fake executables for version and auth.

### Task 6: Coordinator, CoordinatorMain, CLI
Produces: `EventLog`, `Router`, `DiagnosticsService`, `SocketServer`, `Coordinator.start(options:) -> StartOutcome`, `CoordinatorLauncher.ensure(...)`, `b4app-coordinator`, `agent-workspace doctor [--json]` and not-implemented groups with exit codes 0/2/3/4.
- [ ] Integration test over a temporary socket: ping, diagnostics, draft mutation dedupe, replay and snapshot_required, lock behavior.

### Task 7: WorkspaceUI and apps
Produces: `WorkspaceModel`, `WorkspaceRootView` (NavigationSplitView), Threads, Connections, Local servers, Diagnostics views; macOS app hosting the coordinator; iOS app with `UnavailableTransport`.
- [ ] `xcodegen generate`; `xcodebuild build` for both; macOS app launches, shows the empty Threads screen with Add connection, Diagnostics shows live data; iOS simulator renders the shell.

### Task 8: Docs, verification, PR
- [ ] `docs/compatibility.md`, `docs/milestones.md`, `docs/verification.md`; commit; push; open PR.
