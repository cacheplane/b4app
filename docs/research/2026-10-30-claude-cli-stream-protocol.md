# Research: Claude Code CLI stream-json wire protocol (verified 2026-10-30)

Why this exists: the app is pure Swift, so it cannot use the TypeScript Agent SDK. The SDK itself only spawns the `claude` CLI and exchanges JSON lines over stdio, so the Swift adapter reproduces that protocol. Sources: `sdk.mjs` and `sdk.d.ts` from `@anthropic-ai/claude-agent-sdk@0.3.314` (types target CLI 2.1.314), the headless, cli-reference, streaming, user-input and sessions docs, and a live no-inference `initialize` handshake against the installed 2.1.282 (one control request on stdin, then EOF; exit 0).

## Launch

Argument order the SDK uses: `claude --output-format stream-json --verbose --input-format stream-json`, then optional flags, then `--permission-prompt-tool=stdio` (one token) when the client answers permissions, then `--include-partial-messages`, `--setting-sources user,project,local`, `--permission-mode <mode>`, `--resume <id>`, `--fork-session`, `--session-id <uuid>`, `--model`, `--max-turns`, `--add-dir`. The SDK never passes `-p`; 2.1.282 answers `initialize` identically with and without it. `cwd` is the spawn working directory. System prompt and agents go in the `initialize` request, not argv. `--permission-prompt-tool=stdio` and `--max-turns` are accepted by 2.1.282 but hidden from `--help`.

Environment set on the child: `CLAUDE_CODE_ENTRYPOINT=sdk-ts`, `CLAUDE_AGENT_SDK_VERSION`, `CLAUDE_CODE_SDK_READS_SESSION_STATE=1`; `NODE_OPTIONS` removed. For plan auth also remove `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`. Never pass `--bare` (disables OAuth).

## Framing and handshake

One JSON object per newline-terminated line in both directions. Sequence: spawn; write `control_request initialize` first; wait for its `control_response`; then write `user` messages; read `system/init` (per turn, after the first user message, not at startup), `assistant`, `user` (tool results), `stream_event`, `control_request`s from the CLI, and exactly one `result` per turn. End the session by closing stdin; there is no end frame. For a clean stop send `interrupt` first; SIGTERM leaves the turn unfinished (exit 143).

```json
{"type":"control_request","request_id":"r1","request":{"subtype":"initialize","hooks":{}}}
{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"commands":[],"agents":[],"models":[],"account":{"email":"","organization":"","subscriptionType":"","apiProvider":""},"current_permission_mode":"default","session_state":"idle","pid":0}}}
```

`claude_code_version` is absent from the initialize response on 2.1.282; treat every field as optional and feature-detect through `system/init.capabilities` (`interrupt_receipt_v1`, `interrupt_cancel_queued_v1`, `queued_notifications`, `ask_user_question_unanswered_v1`).

## Control envelope

```json
{"type":"control_request","request_id":"id","request":{"subtype":"..."}}
{"type":"control_response","response":{"subtype":"success","request_id":"id","response":{}}}
{"type":"control_response","response":{"subtype":"error","request_id":"id","error":"message"}}
{"type":"control_cancel_request","request_id":"id"}
```

Client to CLI: `interrupt` (optionally `"cancel_queued": true`; response `{still_queued, cancelled}`), `set_permission_mode {mode}`, `set_model {model}`, `rename_session {title, source}`, `mcp_status`, `get_context_usage`. Ignore inbound `keep_alive` and `transcript_mirror`.

CLI to client that must be answered: `can_use_tool`, `hook_callback`, `mcp_message`, `elicitation` (answer `{"action":"decline"}` for v0), `request_user_dialog`.

## Permission flow

```json
{"type":"control_request","request_id":"abc","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1","permission_suggestions":[],"decision_reason":null}}
{"type":"control_response","response":{"subtype":"success","request_id":"abc","response":{"behavior":"allow","updatedInput":{"command":"ls"},"toolUseID":"toolu_1"}}}
{"type":"control_response","response":{"subtype":"success","request_id":"abc","response":{"behavior":"deny","message":"User declined","interrupt":false,"toolUseID":"toolu_1"}}}
```

AskUserQuestion arrives as `can_use_tool` with `tool_name: "AskUserQuestion"` and `input.questions[{question, header, options[{label, description}], multiSelect}]`; answer with `{"behavior":"allow","updatedInput":{"questions":<original>,"answers":{"<question text>":"<label>"}}}`. An interrupted turn may produce `control_cancel_request` for a pending ask.

## User input

```json
{"type":"user","session_id":"","message":{"role":"user","content":[{"type":"text","text":"Hello"}]},"parent_tool_use_id":null,"uuid":"<client uuid>"}
```

`uuid` is echoed as `user_message_uuid` on the turn's first assistant, stream_event and result frames. `--replay-user-messages` echoes stdin messages back as an acknowledgement.

## Output frames

- `system/init`: `session_id`, `cwd`, `model`, `tools`, `mcp_servers`, `permissionMode`, `apiKeySource` (`ANTHROPIC_API_KEY`, `apiKeyHelper`, `/login managed key`, `none`), `capabilities`. Emitted per turn.
- `system/status`, `system/api_retry`, `system/permission_denied`, `system/session_state_changed {state: idle|running|requires_action}`, `rate_limit_event`, `auth_status`.
- `assistant`: `message` is a Messages API message; `parent_tool_use_id`, `uuid`, `session_id`.
- `user`: tool results; replays carry `isReplay`.
- `stream_event` (with `--include-partial-messages`): raw `message_start`, `content_block_delta`, `message_stop` and friends.
- `result`: `subtype` in `success | error_during_execution | error_max_turns | error_max_budget_usd | error_max_structured_output_retries`; `session_id`, `is_error`, `duration_ms`, `num_turns`, `total_cost_usd`, `usage`, `permission_denials`, `result`, `errors`, `stop_reason`. Cost totals are cumulative.

## Risks

1. The control protocol is not publicly documented; shapes live in `sdk.d.ts`. Pin the tested CLI version and re-diff on upgrades. This is the material deviation from the spec's "use the TypeScript SDK" (decision D-002).
2. Type and binary skew: fields marked "absent on older CLIs" must be optional.
3. Version gates: `--permission-prompts` needs 2.1.259+, allow without `updatedInput` needs 2.1.207+.
4. `system/init` is not a startup event; block on the initialize response instead.
5. After stdin EOF the CLI may linger up to ten minutes for background work; use `interrupt` then graceful teardown.
