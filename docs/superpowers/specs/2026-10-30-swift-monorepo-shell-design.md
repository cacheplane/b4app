# Design: b4app Swift monorepo and application shell

Date: 2026-10-30. Status: adopted for the initial PR. Requirement source: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` (revision 1.0), "the spec". This design replaces the spec's Electron direction with native Swift at the owner's instruction (decision D-001).

## Intent

Land the repository, toolchain, module boundaries, and a running application shell for the Personal Agent Workspace as native Swift: a SwiftUI macOS app, a SwiftUI iOS app from the same feature code, a coordinator that owns SQLite and serves GUI and CLI over a Unix socket, the `agent-workspace` CLI, and adapter modules for Codex, Claude Code, and B4. Milestone M1 (a real Codex conversation) starts from this base.

## Goals

- One Swift package that builds and tests with `swift build` and `swift test`, plus an XcodeGen project that builds the macOS and iOS apps.
- The spec's process topology with real plumbing and no provider conversations: SwiftUI renderer, typed client, coordinator over NDJSON on a Unix socket, CLI reaching the same coordinator, SQLite owned by the coordinator alone.
- Shared, versioned command, event, and error types in `WorkspaceProtocol`, free of macOS-only dependencies so iOS uses them unchanged.
- Adapter modules that implement real inspection (executable discovery, version, auth status, endpoint health) and throw `unsupportedCapability` for everything else.
- Tests for the parts the spec calls out: envelope validation, event cursor and replay, NDJSON and JSON-RPC framing, SSE parsing across chunk boundaries, Claude auth-mode conflicts, singleton locking.
- M0 documents: compatibility manifest, decision log, verification record, milestone checklist.

## Non-goals for this PR

- Any provider turn, sign-in flow, or stream. M1 to M3.
- The iOS relay to the Mac. The iOS app shows the same shell with an explicit "not connected" state.
- LaunchAgent registration, packaging, signing, notarization. M6.
- Windows. Swift on Windows has no SwiftUI; the protocol and adapters are portable but nothing targets it.

## Anti-goals

- Representing mocked provider behavior as working. Every unimplemented adapter path throws `WorkspaceError.unsupportedCapability` with the planned milestone.
- Secrets in command arguments, logs, or UI state.
- Hidden deviations from the spec. Each is in `docs/decisions.md`.

## Constraints

- Xcode 26.6, Swift 6.3, Swift 6 language mode, approachable concurrency features on every target.
- macOS 26 and iOS 26 minimum.
- App Sandbox disabled on macOS (the app must spawn the user's `claude` and `codex` executables).
- The coordinator and adapters use only Apple frameworks plus GRDB, SwiftNIO, swift-subprocess, and swift-argument-parser.

## Layout

```
Package.swift                 umbrella package, tools-version 6.2
Sources/
  WorkspaceProtocol/          envelopes, commands, events, domain, errors, JSONValue, NDJSON (Foundation only)
  WorkspaceClient/            transport protocol, event cursor, typed client actor (Foundation only)
  WorkspacePlatform/          paths, private dirs, executable lookup, command runner, SecretStore, singleton lock
  WorkspaceStorage/           GRDB database, migrations, repositories
  CodexAdapter/               JSON-RPC NDJSON codec, executable inspection, adapter
  ClaudeAdapter/              stream-json control protocol types, auth assessment, inspection, adapter
  B4Adapter/                  SSE parser, event mapping, HTTP client, endpoint inspection, adapter
  Coordinator/                event log, router, diagnostics, NIO socket server, start/ensure, launcher
  CoordinatorMain/            executable `b4app-coordinator`
  AgentWorkspaceCLI/          executable `agent-workspace`
  NIOTransport/               Unix socket client transport for the app and CLI
  WorkspaceUI/                SwiftUI views and the observable workspace model (macOS and iOS)
Tests/                        one test target per module (Swift Testing)
Apps/
  macOS/B4App/                app entry, Info.plist, entitlements
  iOS/B4App/                  app entry, Info.plist
project.yml                   XcodeGen definition of the two app targets
Scripts/                      bootstrap and project generation
docs/
```

## Process boundaries

- Renderer: SwiftUI in `WorkspaceUI` drives an `@Observable` `WorkspaceModel` that only talks to a `WorkspaceClient`. No process, file, or socket code lives in UI.
- macOS app: injects a `UnixSocketTransport`. On launch it connects to an existing coordinator; if none answers, it starts the coordinator in-process through the `Coordinator` library (same lock, same socket) and connects to it. The CLI then shares that coordinator. Quitting the app releases the lock and socket; a LaunchAgent replaces in-process hosting in M6 (D-004).
- iOS app: injects an `UnavailableTransport` that reports `endpointUnavailable` with a message naming the future relay. All screens render.
- CLI: connects, or spawns `b4app-coordinator` detached (found through `B4APP_COORDINATOR_PATH`, next to the CLI binary, or on PATH), waits for the socket, then issues commands.
- Coordinator: `flock` on `coordinator.lock` in a private runtime directory, GRDB `DatabasePool` under Application Support with mode 0600, a new event epoch per start with a bounded replay buffer, NIO `ServerBootstrap` on the socket, hello on connect, validated commands.

## Protocol

`CommandEnvelope`, `ResponseEnvelope`, and `EventEnvelope` as the spec defines, `protocolVersion: 1`, plus a `hello` envelope the coordinator sends first. Methods: `system.ping`, `diagnostics.read`, `connection.list`, `thread.list`, `draft.read`, `draft.save` (mutation, requires `operationId`), `events.snapshot`, `events.replay`. Each method has typed `Params` and `Result` structs; `parseCommand` validates version, method allowlist, operationId requirement, and params decoding. Unknown JSON goes through `JSONValue`. Error codes are the spec's list plus `protocolInvalid`, `methodUnknown`, `snapshotRequired`, `notImplemented`, `notFound`, `internal`. `AdapterEvent` is an enum discriminated by `kind` carrying the spec's identity fields.

## Storage

One migration `v1` creating `connections`, `localServers`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts` with foreign keys and the unique `(connectionId, nativeScope, nativeThreadId)` constraint. Columns are camelCase to match the protocol structs, which conform to GRDB records inside the storage module only.

## Adapters

`AgentAdapter` is the spec's protocol in Swift. Implemented now: Codex executable lookup and `codex --version` with a minimum of 0.166.0; Claude executable lookup, `claude --version`, `claude auth status --json`, and inherited API-key conflict detection; B4 `GET /healthz` and `/readyz` with HTTPS enforcement for non-loopback. Claude's stream protocol types (control requests and responses, user frame, system init, result) are defined and unit-tested so M2 builds on verified shapes.

## Platform

`PlatformPaths` with `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` overrides; runtime dir under `$TMPDIR/b4app` (socket path limit), data under `~/Library/Application Support/b4app`. `SecretStore` protocol with a Keychain implementation (generic password, service `b4app`, references `secret:<uuid>`) and a memory implementation for tests. `CommandRunner` uses swift-subprocess with argument arrays, bounded output, and timeouts.

## Testing

Swift Testing in every module. Coordinator integration test starts a real coordinator on temporary directories and talks to it over the socket. Adapter inspection tests use fake executables written to a temp dir and a `URLProtocol` stub for HTTP. No live provider calls.

## CI

GitHub Actions on `macos-26`: `swift build`, `swift test`, `swift format lint --strict`, `xcodegen generate`, `xcodebuild build` for the macOS app and for the iOS app against `generic/platform=iOS Simulator`.

## Left to the builder

Visual polish beyond standard SwiftUI controls, exact log categories, and the order of sidebar sections.
