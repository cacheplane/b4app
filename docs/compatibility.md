# Compatibility manifest

Recorded on 2026-10-30 (M0 baseline). Update whenever a pinned version, a verified behavior, or a known limit changes. "Verified" means exercised on the target Mac or against the real published artifact; "reviewed" means read in source or docs only.

## Target machine

| Item | Value |
| --- | --- |
| Hardware | Apple Silicon (arm64) |
| macOS | 26.5 (Darwin 25.5.0) |
| Xcode | 26.6 (17F113), Swift 6.3.3 |
| XcodeGen | 2.46.0 |
| Node (for B4 servers only) | v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node` |

Xcode 27 (Swift 6.4) requires macOS 26.6; the package uses `swift-tools-version: 6.2` so either toolchain builds it.

## Pinned dependencies

| Package | Version | Used for |
| --- | --- | --- |
| GRDB.swift | 7.11.1 | SQLite with WAL, migrations, Codable records |
| swift-nio | 2.104.0 | Unix socket server and client |
| swift-nio-extras | 1.35.x | `LineBasedFrameDecoder` for NDJSON |
| swift-subprocess | 1.0.2 | Running `codex`, `claude`, and `node` with bounded output and timeouts |
| swift-argument-parser | 1.8.2 | `agent-workspace` CLI |

Exact resolved versions are in `Package.resolved`.

## Provider runtimes

| Runtime | Installed on target Mac | Published | Verified behavior | Limits and gates |
| --- | --- | --- | --- | --- |
| Codex CLI (`@openai/codex`) | Not installed | 0.166.0 (2026-10-29) | None live. App-server protocol, `generate-json-schema`, and auth docs reviewed (`docs/research/2026-10-30-codex-app-server.md`). | Blocked: install the CLI and sign in before M1 live checks. Adapter minimum: 0.166.0. |
| Claude Code | 2.1.282 at `~/.local/bin/claude` | Agent SDK 0.3.314 (bundles 2.1.314) | `claude auth status --json` parsed live; the stream-json `initialize` handshake verified live with no inference. The adapter reported `authenticated` while the Mac was signed in and `auth_required` after the session signed out later the same day. | The control protocol is undocumented (D-002); re-diff on CLI upgrades. Adapter minimum: 2.1.200. `interrupt` does not clear queued input. |
| B4 (`@b4run/cli`) | Not installed; no trusted project chosen | 0.15.7 (2026-10-28), Node `>=24` | None live. Routes, SSE frames, resume body, and launch flags reviewed at commit `547c4ecbf3f7f7bf5662ed78522fbe8f6fe0b522` (equals `main` on 2026-10-30). | Blocked: choose a trusted local project with one `agent()` route. `b4 start` binds `0.0.0.0` and loads no `.env`; the supervisor must pass `--host 127.0.0.1` and an explicit environment. |

## Protocol observations captured for adapters

- Codex app-server: newline-delimited JSON-RPC without the `jsonrpc` field; `initialize` then `initialized`; `account/read` distinguishes `chatgpt` from `apiKey`; `item/tool/requestUserInput` is experimental. Docs and generated schema disagree on policy string casing; generate from the pinned binary.
- Claude Code: write `control_request initialize` before any user message and wait for its `control_response`; `system/init` arrives per turn; strip `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`; never pass `--bare`; `AskUserQuestion` arrives through `can_use_tool`; end a session by closing stdin after `interrupt`.
- B4: no thread-list endpoint; `done` carries several outcomes; `interrupted` means cancelled or parked (check `pending_interrupts`); no built-in endpoint auth middleware.

## Known limits of the shell

- No provider conversation exists yet. Every adapter method except `inspectConnection()` throws `unsupported_capability`.
- The macOS app hosts the coordinator in-process; a LaunchAgent replaces that in M6. The coordinator has no idle shutdown.
- iOS renders the shell with an unavailable transport; the relay is a follow-on design.
- Keychain uses the file-based login keychain; the data-protection keychain needs signing (M6).
- Packaging, Finder launch, signing, and notarization are untested.
