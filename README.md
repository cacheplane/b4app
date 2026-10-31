# b4app: Personal Agent Workspace

A native Swift app for running Codex, Claude Code, and B4 agent conversations side by side on one Mac, with an iOS companion built from the same code. Everything is local: no accounts, no cloud sync, no telemetry.

Status: M4. Codex and B4 conversations are live-verified from the CLI (Codex also from the macOS app); Claude Code conversations use the same transcript, approvals, stop, and resume through the CLI's stream-json protocol and are fixture-verified end to end, awaiting a signed-in Mac for the live inference check. B4 attaches a running local server or a remote HTTPS endpoint at one `agent()` route, or registers a local project and runs its server itself (`b4 start` or `b4 dev` on loopback) with the GUI and the CLI sharing one owned registration. See `docs/milestones.md`.

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

A local B4 project the app runs for you (registering it runs its `b4.config` and route modules with Node, so register only projects you trust):

```bash
.build/debug/agent-workspace server add ~/code/my-agent --name research --env-file ~/code/my-agent/.env
```

```bash
.build/debug/agent-workspace server start research
```

```bash
.build/debug/agent-workspace connection add --kind b4 --server research --route /chat#agent
```

`server add` resolves Node 24+ and the project-installed `@b4run/cli` (never `.bin/b4`, never downloaded), allocates a loopback port once, and inspects the routes with `b4 routes --json`. `server start` runs `b4 start --host 127.0.0.1 --port <n>` (source mode, the default) or `b4 dev --port <n> --env-file <p>` (`--mode development`, hot reload) from the project directory with an environment the coordinator builds from the env file, waits for `/healthz`, and is idempotent. `server status`, `server logs [--follow]`, `server restart`, `server stop`, `server inspect`, and `server list` work the same from the Local servers screen; `stop` and `restart` refuse while a route connection has a running turn unless `--force`. Servers keep running when the app quits or the coordinator restarts; the next coordinator re-adopts one whose pid, start time, and arguments still match, and never signals anything else. Logs live under the data directory and are redacted when read.

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

The B4 live check needs a server you run yourself: a B4 project with one `agent()` route, started with `b4 dev --port 3001 --env-file .env` where that `.env` holds the model provider key, or the same project registered with `server add` and started by the app. This repo's `.env` is gitignored for exactly that; B4 keeps the provider key, the app never sees it. On the owner's Mac the trusted project is `~/repos/b4app-live-check`.

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
