# b4app: Personal Agent Workspace

A native Swift app for running Codex, Claude Code, and B4 agent conversations side by side on one Mac, with an iOS companion built from the same code. Everything is local: no accounts, no cloud sync, no telemetry.

Status: M1. Real Codex conversations work from the macOS app and the CLI: create a thread in a directory, stream the reply, answer command and file-change approvals, stop a turn, and reopen the same native thread later. Claude Code and B4 conversations are M2 and M3. See `docs/milestones.md`.

## Prerequisites

- macOS 26 on Apple Silicon with Xcode 26.6 (Swift 6.3)
- XcodeGen for the app projects: `brew install xcodegen`

## Build and test

```bash
swift build
```

```bash
swift test
```

```bash
./Scripts/generate-project.sh
```

Then open `B4App.xcodeproj` and run the `B4App-macOS` or `B4App-iOS` scheme, or build from the command line:

```bash
xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'
```

```bash
xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'
```

## CLI

```bash
.build/debug/agent-workspace doctor --json
```

A Codex conversation from the terminal (Codex CLI 0.166.0 or newer, signed in with `codex login`):

```bash
.build/debug/agent-workspace connection add --kind codex
```

```bash
.build/debug/agent-workspace thread new --connection codex --cwd ~/project --title "Fix the tests"
```

```bash
.build/debug/agent-workspace turn send <thread-id> Run the test suite and summarize the failures.
```

`turn send` streams the reply, prints tool cards and any runtime request with the `request respond` command that answers it, and exits 0 when the turn completes, 1 when it fails, 130 when it was stopped. `turn interrupt <thread-id>` stops the active turn; `thread show <thread-id>` prints the cached transcript; every command takes `--json`.

The CLI connects to the running coordinator or starts `b4app-coordinator` next to itself. Set `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` to isolate an experiment from the real data under `~/Library/Application Support/b4app`. The runtime directory must be short enough for a Unix socket path (104 bytes); the default under `$TMPDIR` is.

Live provider tests are opt-in and never run in CI:

```bash
B4APP_LIVE_CODEX=1 swift test --filter CodexLive
```

## Layout

```
Package.swift            umbrella package: libraries, coordinator, CLI, tests
Sources/WorkspaceProtocol   commands, events, errors, domain (runtime-neutral)
Sources/WorkspaceClient     typed coordinator client (runtime-neutral)
Sources/WorkspaceUI         SwiftUI shared by macOS and iOS
Sources/WorkspacePlatform   paths, executables, processes, Keychain, lock
Sources/WorkspaceStorage    GRDB schema and repositories
Sources/Coordinator         event log, router, session service, socket server, launcher
Sources/CoordinatorMain     the b4app-coordinator executable
Sources/AgentWorkspaceCLI   the agent-workspace executable
Sources/NIOTransport        Unix socket transport
Sources/CodexAdapter, ClaudeAdapter, B4Adapter
Apps/macOS, Apps/iOS        thin app targets (project.yml, XcodeGen)
docs/                       spec, design, decisions, compatibility, verification, research
```

## Documents

- Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md`
- Design: `docs/superpowers/specs/2026-10-30-swift-monorepo-shell-design.md`, `docs/superpowers/specs/2026-10-30-m1-codex-conversation-design.md`
- Decisions: `docs/decisions.md`
- Compatibility: `docs/compatibility.md`
- Verification: `docs/verification.md`
- Research notes: `docs/research/`
