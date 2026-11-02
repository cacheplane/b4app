# Repository instructions

This repository is the Personal Agent Workspace: a native Swift macOS app, an iOS companion, a coordinator service, and the `agent-workspace` CLI for Codex, Claude Code, and B4 conversations. The requirement source is `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md`. Read it and `docs/decisions.md` before changing architecture. The spec says Electron; decision D-001 replaced that with Swift at the owner's direction.

## Commands

- `swift build` and `swift test` for every library, the coordinator, and the CLI.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` before committing; `swift format format --in-place --recursive ...` fixes layout.
- `cd Hub && source <(./scripts/test-db.sh) && cargo test --workspace --locked` runs the hub's tests against a throwaway PostgreSQL (needs `./Scripts/fetch-postgres.sh` first); `./scripts/test-db.sh --stop` stops it. Also `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` from `Hub/`. CI's `hub` job runs the same.
- `docker compose up -d` in `Hub/` runs a local hub on `localhost:8080` (copy `.env.example` to `.env` and fill in both passwords first; the README's "Hub (optional)" has the seed and enroll steps). `agent-workspace hub join|status|leave` links a Mac to it.
- `./Scripts/generate-project.sh` regenerates `B4App.xcodeproj` (gitignored) from `project.yml`; needs `brew install xcodegen`.
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` and the same with `-scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`.
- Flavours (`prod`, `beta`, `local`; `Flavor` in `WorkspacePlatform`): `B4App-macOS` and `B4App-iOS` build local in Debug and prod in Release, and the `-Beta` schemes build beta. `Config/Flavor-*.xcconfig` holds each flavour's bundle id, site domain, and URL scheme. `B4APP_FLAVOR=beta ./Scripts/package.sh` and `./Scripts/upload-ios.sh` take the flavour (default `prod`); `B4APP_CHECK_PROFILES_ONLY=1 B4APP_TEAM_ID=<team>` on `package.sh` checks the profiles without building or signing.
- `.build/debug/agent-workspace doctor --json` runs the CLI; it spawns `.build/debug/b4app-coordinator` beside it when no coordinator is listening. Set `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` to keep experiments out of the real data directory; keep the runtime dir under `$TMPDIR`, since a Unix socket path is limited to 104 bytes.
- `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` and `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` run the opt-in live checks (real inference, need `codex login` / `claude auth login`). CI never sets them. Fixture tests use `Tests/CodexAdapterTests/Fixtures/fake-codex.py` and `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py`.

## Layout

- `Sources/WorkspaceProtocol` and `Sources/WorkspaceClient` are Foundation-only and link on iOS. Never import AppKit, NIO, GRDB, or Subprocess there.
- `Sources/WorkspaceUI` is SwiftUI shared by both apps; it talks only to `WorkspaceClient` and never imports `WorkspaceMirror`, `WorkspaceSync`, or `WorkspaceStorage`.
- `Sources/WorkspacePlatform` holds paths, executable lookup, process running, and the singleton lock; it re-exports `WorkspaceSecrets`.
- `Sources/WorkspaceSecrets` (secret references and the Keychain store; Foundation and Security, both platforms), `Sources/WorkspaceSync` (hub wire types and HTTP client; Foundation only), and `Sources/WorkspaceMirror` link on iOS.
- `Sources/WorkspaceStorage` is the only module that opens the coordinator's PostgreSQL store (it also reads a retired pre-0.2 SQLite file once, for the import), and only the coordinator uses it.
- `Sources/WorkspaceMirror` is the only module that keeps a SQLite store (the phone's mirror of the synced tables), and only the iOS app uses it.
- `Sources/Coordinator/HubSync/` is the only code that talks to the hub from the Mac.
- `Hub/` is the Rust hub (Cargo workspace: `b4hub-core`, `b4hub-db`, `b4hub`), its Dockerfile and Compose file, and `Hub/API.md`, the wire reference. `Tests/Fixtures/sync/changes.json` and `Tests/Fixtures/sync/auth.json` (the sign-in and account routes; `AuthWireTests` and the hub's `auth_fixture` test) are the contracts both languages decode; edit one only when both suites are updated.
- `Sources/Coordinator` is the service both the app and the CLI talk to over the Unix socket; `Sources/CoordinatorMain` is its executable.
- `Sources/CodexAdapter`, `ClaudeAdapter`, `B4Adapter`: one per native runtime. `Apps/` holds the two thin app targets.
- Fake runtimes for tests live under `Tests/<Adapter>Tests/Fixtures/` (`fake-codex.py`, `fake-claude.py`, `fake-b4.py`, plus `fake-b4-cli.py` and `fake-node.sh` for managed servers: `Tests/CoordinatorTests/FakeB4Project.swift` builds a scratch project whose `node_modules/@b4run/cli/dist/index.js` is the fake CLI and sets `B4APP_NODE_PATH` to the shim); the coordinator tests reuse them by path. Live tests are gated by `B4APP_LIVE_CODEX`, `B4APP_LIVE_CLAUDE`, and `B4APP_LIVE_B4_URL`.
- `Sources/Coordinator/SessionService.swift` is the only writer of turns, display items, and runtime requests; adapters emit `AdapterEvent`s with native ids and the session service maps them to app ids. `Sources/Coordinator/LocalServerService.swift` is the only owner of managed server processes (`ManagedProcess` in `WorkspacePlatform`); it never signals a process whose identity it has not verified.

## Rules

- Never represent a mocked response as a working integration. Unimplemented adapter behavior throws `WorkspaceError(.unsupportedCapability)` naming the milestone.
- The UI never touches processes, sockets, files, or secrets directly.
- Secrets never appear in arguments, JSON results, logs, or UI state. Use `SecretStore` references.
- Ordinary tests use fixtures and fake executables. Live provider tests are opt-in and never run in CI.
- Record material decisions in `docs/decisions.md`, versions in `docs/compatibility.md`, gate results in `docs/verification.md`, and keep `docs/milestones.md` current with implemented, fixture-tested, live-tested, or blocked.
- Do not reformat `docs/roadmaps/*.md`; it is the owner's document.
