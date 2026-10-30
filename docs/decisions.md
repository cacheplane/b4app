# Decision log

Material implementation decisions, newest first. The spec (`docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md`) is the requirement source; this log records deviations and choices the spec left open.

## 2026-10-30

- **D-001 Native Swift instead of Electron + React + TypeScript.** The spec chose Electron; the owner directed pure Swift with macOS and iOS targets. An Electron shell was built, verified, and discarded the same day. Consequences: no Node coordinator, no TypeScript adapters, and the Claude integration cannot use the TypeScript Agent SDK (D-002).
- **D-002 Claude Code is driven through the CLI's stream-json stdio protocol, not the TypeScript Agent SDK.** The SDK is a thin stdio client of the same CLI; its control protocol (`control_request` / `control_response`, `initialize`, `can_use_tool`, `interrupt`) was read from the SDK source and verified by a no-inference handshake against 2.1.282. The protocol is undocumented and version-coupled, so the tested CLI version is pinned and re-diffed on upgrade. See `docs/research/2026-10-30-claude-cli-stream-protocol.md`.
- **D-003 One umbrella Swift package plus XcodeGen for the app targets.** SwiftPM cannot build `.app` bundles; Tuist is heavier than needed; hand-edited `pbxproj` files are hostile to agents. The generated `.xcodeproj` is gitignored and produced by `Scripts/generate-project.sh`.
- **D-004 The macOS app hosts the coordinator in-process when none is running; the CLI spawns the standalone executable.** Both paths use the same library, lock, and socket, so GUI and CLI always share one coordinator. A LaunchAgent via `SMAppService` replaces in-process hosting in M6 when the bundle layout exists.
- **D-005 macOS 26 and iOS 26 minimum.** Personal app on current OS versions; removes availability shims for Liquid Glass APIs.
- **D-006 App Sandbox disabled.** A sandboxed app cannot spawn the user's `claude` or `codex` executables. Local builds are signed ad hoc; Developer ID and notarization are M6.
- **D-007 GRDB for SQLite, SwiftNIO for the socket, swift-subprocess for child processes, swift-argument-parser for the CLI.** See `docs/research/2026-10-30-swift-stack.md` for versions and rationale.
- **D-008 Keychain through the file-based keychain for ad-hoc builds.** The data-protection keychain needs a provisioning profile and access group; revisit at M6 with signing.
- **D-009 iOS ships the full shell with an unavailable transport.** The spec defers iOS; the owner wants both targets in the repo now. The iOS app builds and renders every screen but cannot reach a coordinator until the relay is designed.
- **D-010 Codex type generation deferred to M1.** `codex app-server generate-json-schema` output will be converted to Swift Codable types when the Codex adapter is implemented, from the pinned CLI version.
