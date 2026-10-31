# Compatibility manifest

Recorded on 2026-10-30 (M0 baseline, updated for M1 the same day, M2 and M3 on 2026-10-31). Update whenever a pinned version, a verified behavior, or a known limit changes. "Verified" means exercised on the target Mac or against the real published artifact; "reviewed" means read in source or docs only.

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
| Codex CLI (`@openai/codex`) | 0.166.0 at `/opt/homebrew/bin/codex` (Homebrew cask, upgraded from a broken 0.128.0 install on 2026-10-30) | 0.166.0 (2026-10-29) | Live: `codex app-server` handshake, `account/read` (ChatGPT, `promax`), `account/login/start`, `thread/start`, `thread/resume`, `thread/turns/list`, `turn/start` with streamed `item/*` notifications, a tool turn (`commandExecution`), `turn/interrupt` ending as `interrupted`, reopen with history. Schema generated with `codex app-server generate-json-schema --out <dir>` from this binary and hand-typed (D-010). | Adapter minimum: 0.166.0. App-server is labelled experimental; regenerate the schema and re-run `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` after every upgrade. Not exercised live: a real approval request (the user's config did not ask for one during `cat README.txt`), `item/tool/requestUserInput`, sign-in completion from a signed-out state. |
| Claude Code | 2.1.282 at `~/.local/bin/claude` | Agent SDK 0.3.314 (bundles 2.1.314) | `claude auth status --json` parsed live; the stream-json `initialize` handshake, `--session-id`, `system/init` (with `claude_code_version`, `apiKeySource`, `capabilities`), the replayed `user` frame, a synthetic `assistant` error frame, a `result` with `subtype: success` and `is_error: true`, and `--resume` of an unknown id were all recorded live on 2026-10-31 while the Mac was signed out. Through the coordinator, `connection add --kind claude` reports `ready / auth_required` and `thread new` refuses with `auth_required`. | Adapter minimum: 2.1.200. The control protocol is undocumented (D-002); re-diff on CLI upgrades. **No inference turn has run live yet**: the Mac was signed out all day. Run `claude auth login`, then `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`. Fixture coverage mirrors the Codex suite. |
| B4 (`@b4run/cli`) | Not on PATH; `~/repos/hashbrown` has 0.14.0 project-installed (workflow routes only); no standard-agent project chosen | 0.15.8 (2026-10-30), Node `>=24` | Agent Protocol source re-read at `origin/main` 844cf3bf (0.15.8): identical to the reviewed commit `547c4ecb` for every protocol file. The adapter (`Sources/B4Adapter`) implements threads, `runs/stream`, cancel, `pending_interrupts`, `resume`, attach, `turns`, and `state` and is fixture-verified end to end against `Tests/B4AdapterTests/Fixtures/fake-b4.py` (streaming, tool calls, park and resume with `once`/`always`/`deny`/cancel, cancel, failure, stream drop with reattach, server restart with stores preserved, bearer middleware 401, unknown route 404). Through the coordinator and CLI: `credential add`, `connection add --kind b4`, `thread new`, `turn send`, `request respond`, `turn interrupt`. | Adapter minimum: 0.15.7 (`turns`, `pending_interrupts`, `resume` with grants). Only `agent` routes converse (D-023). **No live inference has run**: no local standard-agent server with model credentials exists on this Mac (`examples/chat` needs `OPENAI_API_KEY`). Run one, then `B4APP_LIVE_B4_URL=… B4APP_LIVE_B4_ROUTE=… swift test --filter B4Live`. Managed servers (`b4 dev` from the app) are M4. |

## Protocol observations captured for adapters

- Codex app-server (verified live on 0.166.0): newline-delimited JSON-RPC without the `jsonrpc` field; `initialize` then `initialized`; the server emits `configWarning`, `remoteControl/status/changed`, and `account/updated` right after the handshake and clients must ignore unknown methods. `account/read` distinguishes `chatgpt` from `apiKey`. A turn echoes the user message as an `item/started` + `item/completed` `userMessage` pair before the agent items; reasoning arrives as a `reasoning` item. `turn/completed.turn.status` is `completed | interrupted | failed`. Notification params for `thread/status/changed` use `{ type, activeFlags }`. Generated schema policy strings are `untrusted | on-request | never` and `read-only | workspace-write | danger-full-access`.
- Claude Code (recorded live on 2.1.282, 2026-10-31): write `control_request initialize` before any user message and wait for its `control_response`; the user's `SessionStart` hooks run first and emit `system/hook_started` / `system/hook_response`; `command_lifecycle` frames bracket each turn; `system/init` arrives per turn with `apiKeySource` (`none` for plan login) and `capabilities`; `--replay-user-messages` echoes the input as a `user` frame with `isReplay: true`; a synthetic `assistant` frame carries `error` (for example `authentication_failed`) and `is_api_error_message`; `result` may be `subtype: success` with `is_error: true` and `terminal_reason: api_error`; `--resume` of an unknown id emits one `result error_during_execution` and exits 1. Strip `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`; never pass `--bare`; `AskUserQuestion` arrives through `can_use_tool`; end a session by closing stdin after `interrupt`.
- B4 (source-verified on 0.15.8, 2026-10-31; see `docs/research/2026-10-30-b4-runtime.md`): no thread-list endpoint and no run id, so the app names turns by their ordinal in `GET /threads/:id/turns` (D-019); `done` carries several outcomes; `interrupted` means cancelled or parked and `GET /pending_interrupts` tells them apart (D-020); a permission prompt is `interrupt { interruptId, type: "permission-request", kind, detail, grant? }` answered with `POST /resume { resume: [{ interruptId, status, payload?, grant? }], route }` whose response is a second SSE stream (D-021); `GET /runs/stream` reattaches and sends only frames after the attach; `runs/stream` checks route before middleware, so an unknown route is a 404 and a rejected credential a 401 on the first turn, never on the health check; no built-in endpoint auth, so the health check cannot verify a secret.

## Known limits of the shell

- Codex, Claude Code, and attached B4 endpoints have conversation adapters. Managed B4 servers (`b4 dev` started by the app, `b4 routes` inspection) are M4. Model selection, `turn/steer`, image input, importing native threads, Claude hook callbacks, MCP messages, elicitation forms, console (API) billing sign-in, B4 client tool calls, non-agent B4 routes, custom header names for B4 endpoint auth, and persisted credential labels are not implemented.
- A B4 endpoint secret is one bearer value per connection; `credential add` returns a `secret:` reference and nothing lists stored credentials yet. Stop on a parked B4 turn declines its prompt (D-021). A B4 server that restarts mid-run loses the run; the app marks that turn `failed` and the thread is usable again.
- Claude `allow_always` is sent as a plain allow (D-018); Claude history comes from the transcript file (D-017); a Claude process exit ends its turn as failed (D-016).
- Runtime request kinds the app cannot present (`item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`, token refresh, attestation) are declined automatically with a valid response and shown as resolved.
- A turn whose `codex app-server` process exits stays `reconciling` until the thread is reopened and Codex reports the turn's final status; the composer refuses a new turn until then.
- The macOS app hosts the coordinator in-process; a LaunchAgent replaces that in M6. The coordinator has no idle shutdown.
- iOS renders the shell with an unavailable transport; the relay is a follow-on design.
- Keychain uses the file-based login keychain; the data-protection keychain needs signing (M6).
- Packaging, Finder launch, signing, and notarization are untested.
