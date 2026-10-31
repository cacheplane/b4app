# b4app: Personal Agent Workspace

A native Swift app for running Codex, Claude Code, and B4 agent conversations side by side on one Mac, with an iOS companion built from the same code. Everything is local: no accounts, no cloud sync, no telemetry.

Status: M3. Codex and B4 conversations are live-verified from the CLI (Codex also from the macOS app); Claude Code conversations use the same transcript, approvals, stop, and resume through the CLI's stream-json protocol and are fixture-verified end to end, awaiting a signed-in Mac for the live inference check. B4 attaches a running local server or a remote HTTPS endpoint at one `agent()` route; managed B4 servers are M4. See `docs/milestones.md`.

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

A conversation from the terminal (Codex CLI 0.166.0 or newer signed in with `codex login`, or Claude Code 2.1.200 or newer signed in with `claude auth login`; use `--kind claude` and `--connection claude` for Claude):

```bash
.build/debug/agent-workspace connection add --kind codex
```

```bash
.build/debug/agent-workspace thread new --connection codex --cwd ~/project --title "Fix the tests"
```

```bash
.build/debug/agent-workspace turn send <thread-id> Run the test suite and summarize the failures.
```

`turn send` streams the reply, prints tool cards and any runtime request with the `request respond` command that answers it, and exits 0 when the turn completes, 1 when it fails, 130 when it was stopped. Flags go before the message text. `turn interrupt <thread-id>` stops the active turn; `thread show <thread-id>` prints the cached transcript; every command takes `--json`.

A B4 agent route on a server you already run (`b4 dev` in the project; remote endpoints must be HTTPS):

```bash
.build/debug/agent-workspace credential add research-endpoint
```

```bash
.build/debug/agent-workspace connection add --kind b4 --url http://127.0.0.1:3001 --route /chat#agent --auth-ref secret:<id>
```

```bash
.build/debug/agent-workspace thread new --connection b4 --title "Research"
```

`credential add` reads the secret with a hidden prompt (or one line from a piped stdin), stores it in the coordinator's credential store, and prints a `secret:` reference; `--auth-ref` is optional for servers without middleware. The connection check confirms the server is reachable, not that its model credentials or your endpoint secret work; those are verified on the first turn. B4 threads bind to the route, so `thread new` takes no `--cwd`.

The CLI connects to the running coordinator or starts `b4app-coordinator` next to itself. Set `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` to isolate an experiment from the real data under `~/Library/Application Support/b4app`. The runtime directory must be short enough for a Unix socket path (104 bytes); the default under `$TMPDIR` is.

Live provider tests are opt-in and never run in CI:

```bash
B4APP_LIVE_CODEX=1 swift test --filter CodexLive
```

```bash
B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive
```

```bash
B4APP_LIVE_B4_URL=http://127.0.0.1:3001 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live
```

The B4 live check needs a server you run yourself: a B4 project with one `agent()` route, started with `b4 dev --port 3001 --env-file .env` where that `.env` holds the model provider key. This repo's `.env` is gitignored for exactly that; B4 keeps the provider key, the app never sees it.

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
- Design: `docs/superpowers/specs/2026-10-30-swift-monorepo-shell-design.md`, `docs/superpowers/specs/2026-10-30-m1-codex-conversation-design.md`, `docs/superpowers/specs/2026-10-31-m2-claude-conversation-design.md`, `docs/superpowers/specs/2026-10-31-m3-b4-conversation-design.md`
- Decisions: `docs/decisions.md`
- Compatibility: `docs/compatibility.md`
- Verification: `docs/verification.md`
- Research notes: `docs/research/`
