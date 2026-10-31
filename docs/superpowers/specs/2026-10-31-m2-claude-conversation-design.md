# M2: Claude Code conversation (design)

Date: 2026-10-31. Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` sections 8, 10, and the M2 checklist. Builds on M1 (`docs/superpowers/specs/2026-10-30-m1-codex-conversation-design.md`): the same `SessionService`, protocol methods, CLI commands, and SwiftUI views, plus a second adapter.

## Intent

A Claude Code thread behaves like a Codex thread: create it in a directory, stream the reply, answer tool permissions and `AskUserQuestion`, stop, and continue the same native session after the app restarts. Codex and Claude threads sit side by side with separate native identities. Nothing is mocked: the adapter speaks the `claude` CLI's stream-json protocol that the TypeScript Agent SDK uses (decision D-002), and the live record states exactly what ran.

## Verified facts this design rests on (live, 2026-10-31, Claude Code 2.1.282, signed out)

- Launch: `claude --output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio --setting-sources user,project,local --permission-mode default --include-partial-messages --replay-user-messages --session-id <uuid>`; `--resume <id>` instead of `--session-id` continues a session. `--session-id` is honored: every frame of the run carried that id.
- Before the `initialize` response the CLI emits `system/hook_started` and `system/hook_response` for the user's `SessionStart` hooks (setting sources include `user`), then `control_response` for `initialize` with `commands`, `agents`, `models`, `account`, `current_permission_mode`, `session_state`.
- After a `user` message: `command_lifecycle { state: queued | started | cancelled }`, `system/init` (now with `claude_code_version`, `apiKeySource`, `capabilities` including `interrupt_receipt_v1` and `interrupt_cancel_queued_v1`), `system/status { status }`, the replayed `user` frame with `isReplay: true`, then `assistant`, `stream_event`, `user` (tool results), and one `result`.
- `assistant` frames carry `user_message_uuid` (our turn uuid), `message.id`, `message.content[]`, and for synthetic errors `error` (for example `authentication_failed`) with `is_api_error_message: true` and `message.model: "<synthetic>"`.
- `result` has `subtype` (`success` even when `is_error: true`), `is_error`, `terminal_reason` (`api_error` seen), `result` text, `user_message_uuid`, `num_turns`, `total_cost_usd`.
- `--resume` of an unknown id prints one `result { subtype: "error_during_execution", is_error: true }`, writes `No conversation found with session ID: …` to stderr, and exits 1.
- `claude auth login` options: `--claudeai` (default), `--console`, `--email`, `--sso`. It opens the browser itself; `claude auth status --json` reports `loggedIn`, `authMethod`, `email`, `subscriptionType`, `projectsDirectory`, `configDirectory`.
- Nothing requiring inference was verified: the Mac was signed out. The adapter's turn handling is fixture-tested against recorded shapes and must be re-run live after `claude auth login` (`B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`).

## Architecture

```
SessionService ──▶ ClaudeAdapter (actor, one per connection)
                     ├─ ClaudeSession (actor, one `claude` process per native session)
                     │     └─ StreamingProcess
                     └─ ClaudeTurnTracker (per session: frames → AdapterEvents)
```

### `ClaudeSession`

Spawns the CLI with `ClaudeStream.LaunchOptions` and `ClaudeStream.childEnvironment` (inherits, strips `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`, removes `NODE_OPTIONS`), with `cwd` as the working directory. Writes `control_request initialize` first and waits for its `control_response`. Routes `control_response` frames to pending control requests (`interrupt`, `set_permission_mode`); every other frame goes to one inbound stream with an exit marker at the end. Close = `closeInput`, two seconds, `terminate`.

### `ClaudeTurnTracker`

A value type that turns frames into events and holds the little state the protocol needs: the current assistant message id and content-block types from `stream_event`, tool uses awaiting results, the active turn uuid, and whether an interrupt was requested.

- `system/init` → `turn.state_changed running` (and the session id, model, `apiKeySource` for diagnostics; `apiKeySource != none` raises `adapter.error` with `auth_mode_conflict`).
- `stream_event content_block_start` → `message.started` (text, item id `<messageId>#<index>`), `tool.started` (tool_use, item id = tool use id, type `toolUse`), or `tool.started` type `thinking`.
- `stream_event content_block_delta text_delta` → `message.delta`.
- `assistant` → `message.completed` per text block, `tool.started` per tool_use (name and input recorded), `tool.completed` type `thinking` per thinking block. A frame with `error` set also yields `adapter.error` (`authentication_failed` → `auth_required`, `rate_limit` → `allowance_exceeded`).
- `user` with `tool_result` blocks → `tool.completed` with the recorded name, input, output text, `is_error`. Replays (`isReplay`) and our own echoes are ignored.
- `control_request can_use_tool` → `runtime_request.opened`, kind `tool_permission` (or `user_question` when `tool_name == "AskUserQuestion"`); `elicitation` → kind `elicitation` (auto-declined); `hook_callback`, `mcp_message`, `request_user_dialog` → kind `unknown` (auto-declined with an error response). `control_cancel_request` → `runtime_request.resolved`.
- `result` → `turn.finished`: `is_error` → `failed` (with `result` text and `terminal_reason`), interrupt requested or `terminal_reason` mentions interrupt/cancel → `cancelled`, else `completed`.
- `system/session_state_changed` → `turn.state_changed` (`requires_action` → `waiting_for_user`).
- `rate_limit_event`, `auth_status`, `system/api_retry` → `adapter.error` with `willRetry` where applicable.
- Process exit with an active turn → `turn.finished failed` ("claude exited") then `connection.changed` with `transport: disconnected` scoped to that thread (`nativeIds.threadId`).

### `ClaudeAdapter`

- `inspectConnection` = `ClaudeInspector.inspect` (executable, version, `claude auth status --json`, auth-mode conflict) plus the capability set (`streaming`, `nativeResume`, `explicitInterruption`, `permissionDecisions`, `userQuestions` supported; `historyRetrieval` supported through the transcript file; `reconnect`, `modelSelection` unverified).
- `createSession`: requires an authenticated status; generates the session uuid, spawns the process with `--session-id`, completes the handshake, returns `NativeSessionRef(uuid, scope: account email)`.
- `sendTurn`: reuses the live process or spawns one with `--resume`; a quick exit with "No conversation found" is `native_session_missing`. Writes one `user` message whose `uuid` is the native turn id, then waits up to 30 s for `system/init`, `assistant`, `stream_event`, or `result` → acknowledged; timeout → `submission_unknown`.
- `interrupt`: `control_request interrupt { cancel_queued: true }`; confirmed when the `control_response` arrives; the turn's outcome comes with the `result`.
- `respond`: `can_use_tool` → `permissionResponse` allow (with the original input) or deny; `AskUserQuestion` → `askUserQuestionAnswer` with answers keyed by question text (the app's answers are keyed by synthetic ids `q0`, `q1`, … in the safe payload); `.decline` → deny or `elicitationDecline`.
- `loadSession`: reads the native transcript `<projectsDirectory>/**/<sessionId>.jsonl` (the file Claude Code writes; path from `claude auth status --json`) into `SnapshotItem`s; missing file → `native_session_missing`.
- `reconcile`: a turn with no live process cannot still be running under this coordinator → `.known(.failed)` with the reason recorded; with a live process and an active turn → `.unknown`.
- `startLogin`: spawns `claude auth login --claudeai`, returns the first `https://` URL it prints within 15 s (the CLI also opens the browser itself); when the process exits the adapter re-reads auth status and emits `connection.changed`.

### Coordinator and UI

- `SessionService.defaultAdapterFactory` builds `ClaudeAdapter` for `.claude`; `connection.add --kind claude` locates `claude`; `connection.login` works for any adapter that conforms to `LoginCapable`.
- A `connection.changed` event carrying `nativeIds.threadId` is thread-scoped: only that thread's pending requests expire and the connection's status is left alone (a Claude process is per thread; a Codex process is per connection).
- The new-thread sheet lists ready Codex and Claude connections; the Connections screen gets "Add Claude Code connection" and "Sign in with Claude"; tool cards render `toolUse` items by tool name and command and `thinking` items as collapsed reasoning.

### Decisions

- **D-015** One `claude` process per native session, started on `createSession` (so the handshake and auth are validated before the thread row exists) and kept alive between turns; `--resume` after a coordinator restart.
- **D-016** For Claude, a process that exits mid-turn ends that turn as `failed` (the CLI process is the execution; nothing continues without it), unlike Codex where the app-server owns the thread and the outcome is reconciled.
- **D-017** History comes from the native transcript JSONL that Claude Code writes under `projectsDirectory`, read-only and best-effort; the app cache remains the display source.
- **D-018** `allow_always` on a Claude tool permission is sent as a plain allow; per-session rules are not written to the user's settings.

## Non-goals

Model selection, `set_permission_mode` from the UI, subagent (`parent_tool_use_id`) rendering beyond flat items, hook callbacks, MCP messages, elicitation forms, console (API) billing sign-in.

## Tests

- Fixture: `ClaudeTurnTracker` over recorded frames; `ClaudeSession` and `ClaudeAdapter` against `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (handshake, streamed turn, tool permission allowed and denied, question answered, elicitation auto-declined, hang + interrupt, crash, failed result, resume of a missing id); `SessionService` socket test with a Claude thread and a Codex thread side by side.
- Live, opt-in: `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` (needs `claude auth login`). Never in CI.
