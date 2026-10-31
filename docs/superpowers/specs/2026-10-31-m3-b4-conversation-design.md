# M3: B4 local and remote conversation (design)

Date: 2026-10-31. Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` sections 3.2, 5.3, 6, 9, and the M3 checklist. Builds on M1 and M2: the same `SessionService`, protocol methods, CLI commands, and SwiftUI views, plus a third adapter that speaks HTTP and SSE instead of a child process.

## Intent

A B4 thread behaves like a Codex or Claude thread: create it on a connection, stream the reply, answer permission prompts, stop, and continue the same native thread after the app restarts. The connection is an endpoint (base URL) plus one exact route key such as `/chat#agent`; local HTTP is allowed for loopback and remote endpoints use HTTPS with an endpoint secret held in the credential store. Managed local servers (starting `b4 dev` from the app) are M4; in M3 the app attaches to a server the owner already runs.

## Verified facts this design rests on

Read from `github.com/cacheplane/b4run` at `origin/main` (`844cf3bf`, 2026-10-30, `@b4run/cli` 0.15.8, the npm `latest`). The Agent Protocol files under `packages/cli/src/lib/dev/` are byte-identical to the reviewed commit `547c4ecb` named in the spec; only two SDK display files changed.

- `POST /threads` with an optional `{ metadata }` body returns a `Thread { thread_id, created_at, updated_at, metadata, status }`. `GET /threads/:id` returns the same row, 404 `Thread not found` otherwise. Neither runs the app's middleware.
- `POST /threads/:id/runs/stream` body `{ route: "<id>#<kind>", input: { messages: [{ role: "user", content: "<text>" }] } }`. Order of checks: body shape (400), route lookup (404 `Unknown route: …`), middleware (its status and body verbatim, 401 for the bearer middleware pattern), thread row (created when missing), run slot (409 `run_in_flight`). The agent adapter accepts `messages` whose `content` is a string or an array of parts and keeps only `role: "user"` entries.
- The run streams `event: <type>\ndata: <json>\n\n` frames with a `: ping` comment on an interval: `chunk` (JSON string delta), `tool_call { id?, name, input, messageId? }`, `tool_call_args`, `tool_result { id?, name, output }`, `reasoning`, `message_end { messageId }`, `interrupt`, capability events (`plan_update`), and exactly one terminal `done`. `done` is `{ output: <final state> }` on success, `{ output: { error } }` on failure, `{ output: { cancelled: true } }` after `POST /cancel`.
- A permission prompt is an `interrupt` event whose data is `{ interruptId: "perm-…", type: "permission-request", kind: command | path | tool | memory | subagent, detail: {…}, toolCallId?, callId?, step?, allowAlways?: false, grant? }`. The turn then ends with `done` and the thread status becomes `interrupted`; the prompt is durable in `GET /threads/:id/pending_interrupts` → `{ interrupts: [{ interruptId, resumeKey, value, grant? }] }` where `value` is the same envelope. The same `interrupted` status follows a cancel, so an empty `interrupts` list means cancelled and a non-empty one means parked.
- `POST /threads/:id/resume` body is exactly `{ resume: [{ interruptId, status: "resolved", payload: "once" | "always" | "deny", grant? }], route }` or `{ interruptId, status: "cancelled", grant? }`; any extra key is a 400. Entries must match the pending set exactly (409 `interrupt_set_mismatch`, `stale_interrupt`, `resume_required`, `malformed_checkpoint`, `resume_in_progress`, `run_in_flight`, `route_not_found`, `client_tool_pending`). The response is a second SSE stream that continues the same turn and ends with its own `done`.
- `POST /threads/:id/cancel` returns 200 `{ status: "interrupted", thread_id }` when a run was aborted and 409 `no_run_in_flight` otherwise; the running stream then emits `done { output: { cancelled: true } }`.
- `GET /threads/:id/runs/stream` reattaches: a live run yields `state { status, live: true, anchor, input, resume, run_started_at, turn, values }` followed by the remaining frames and the terminal `done`; a thread with no live run yields `state { live: false, interrupts, values }`, a `retry:` line, and `done { output: null }`. 409 `thread_route_unknown` when the server cannot establish the route; `detached { reason: capacity | overflow }` when the viewer cap is hit.
- `GET /threads/:id/turns` returns `{ threadId, status, turns: TurnView[], warnings, truncated }` where each `TurnView` has `runId`, `status` (`working | awaiting | done | failed | stopped`), `text` (assistant text), `steps`, `approvals`, `error`. It carries no user text. `GET /threads/:id/state` returns the checkpoint `{ values: { messages: [...] } }` with LangChain-serialized messages (`{ lc: 1, type: "constructor", id: [..., "HumanMessage" | "AIMessage" | "ToolMessage"], kwargs: { content, tool_calls?, tool_call_id? } }`); 404 before the first checkpoint. Both run the middleware.
- Error bodies are `{ error: { kind, message, details?: { code } , code?, docsUrl? } }`.
- There is no thread list endpoint, no run id, and no built-in endpoint authentication; a project may add `src/middleware.ts` (runs on `runs/*`, `resume`, `pending_interrupts`, `turns`, `events`) and `src/thread-access.ts`. `healthz`, `readyz`, `POST /threads`, `GET /threads/:id`, `state`, and `cancel` are not covered by middleware.
- The run registry is process-local: after a server restart a thread can read `busy` with no run; threads, checkpoints, and pending interrupts persist in `.b4/*.sqlite`.
- On this Mac: no `b4` on PATH; `~/repos/hashbrown/tools/{lifecycle,marketing}` are B4 projects but their only routes are `workflow`s behind a service bearer with Postgres, so they are not standard-agent candidates; `~/repos/b4run/examples/chat` is a standard `agent()` project that needs `OPENAI_API_KEY`, which is not set in this environment. No live inference has run.

## Architecture

```
SessionService ──▶ B4Adapter (actor, one per connection)
                     ├─ B4HTTPClient (JSON + SSE over URLSession, redirects refused)
                     ├─ B4TurnTranslator (per thread: SSE events → AdapterEvents)
                     └─ one streaming Task per active turn (run, resume, or reattach)
```

### Connection profile

`Connection.target` is the base URL, `routeKey` the exact route, `authReference` an optional `secret:<uuid>`, `b4Mode` `attached_local` for loopback or `remote` for HTTPS (`managed_local` is M4). `connection.add` for kind `b4` takes `url`, `route`, `label?`, `authReference?`; it rejects a non-loopback `http` URL and a route that is not `/<path>#<kind>`. A route whose kind is not `agent` is stored and inspected as `incompatible` with `unsupported_capability` ("only standard agent routes carry the message input shape"), a compatibility result rather than a silent downgrade. Inspection is `GET /healthz` and `GET /readyz` only; it never issues inference and reports `authStatus: unknown` when a secret is configured, because no non-inference path exercises the app middleware.

### Credentials

`agent-workspace credential add <label>` reads the secret with a hidden terminal prompt (`readpassphrase`), sends `credential.add { label, value }` over the local socket, and prints the returned reference. The coordinator writes the value to `SecretStore` and returns `secret:<uuid>`; the value never appears in arguments, results, events, or logs. `B4Adapter` resolves the reference lazily through the coordinator's secret store and sends `Authorization: Bearer <value>` (or the value verbatim when it already names a scheme) only to requests whose origin equals the connection's origin; the URLSession delegate refuses redirects so a credential never follows one.

### Thread identity and turn identity

`createSession` is `POST /threads` with `metadata.route` and `metadata.client`; the native thread id is `thread_id`, the native scope the endpoint origin. B4 has no run id, so a turn's native id is its ordinal: `sendTurn` reads `GET /threads/:id/turns`, counts `turns`, and names the new turn `turn-<count + 1>` (falling back to `run-<uuid>` when the read fails). `reconcile` reads the thread status and the turn list again: `busy` → reattach; `interrupted` → pending interrupts decide parked versus cancelled; `idle` with a turn at that ordinal → completed or failed from its `status`; `idle` without it → the prompt never reached the server, so the turn is `failed` with `submission_unknown` resolved as "not recorded", never resubmitted.

### Streaming and translation

`sendTurn` issues the `runs/stream` request and resolves the receipt when the response headers arrive (200 → acknowledged with the ordinal id; 401/403 → `auth_required`; 404 route → `incompatible_version`; 409 `run_in_flight` → `protocol_invalid` with `reason: turn_active`; transport failure → `endpoint_unavailable`; no headers within 30 s → `submission_unknown`). A streaming task then feeds the SSE parser and `B4TurnTranslator`:

- `chunk` → `message.started` on first text, then `message.delta`; `message_end` or the terminal event → `message.completed` (item type `agentMessage`, native id `<turn>:m<n>`).
- `reasoning` → one `reasoning` item per message, completed on `message_end` or `done`.
- `tool_call` → `tool.started` type `toolCall` with `name` and `input`; `tool_call_args` appends to the input preview; `tool_result` → `tool.completed` with `output` and `status: completed`.
- `interrupt` → `runtime_request.opened` with kind `command_approval` (`command`), `file_change_approval` (`path`), or `tool_permission` (`tool`, `memory`, `subagent`), payload `{ request: { interruptId, kind, detail, allowAlways } }`, `answerable: true`. The turn becomes `waiting_for_user`.
- `done`: failed → `turn.finished failed`; cancelled → `cancelled`; completed after an `interrupt` → the turn stays open, parked; completed otherwise → `completed`, with the final assistant message from `output.messages` emitted when nothing streamed.
- Capability events (`plan_update`, `subagent.*`) → `tool.completed` items of their own type so they are visible rather than dropped.
- A transport error mid-stream with the turn still open → reattach with `GET /runs/stream` (three attempts with backoff); a `state` frame with `live: false` ends the attempt and the outcome comes from `reconcile`. The prompt is never resent.

`interrupt` is `POST /cancel`; 200 confirms and the outcome arrives through the stream's `done`; 409 `no_run_in_flight` is confirmed with no outcome (the stream already decided or the turn is parked, which cancel cannot change). `respond` sends `POST /resume` with the pending entry: `allow_once` → `once`, `allow_always` → `always` (or `once` when the prompt said `allowAlways: false`), `deny` → `deny`, decline → `status: cancelled`, each echoing `grant` when present; the response stream continues the same turn.

`loadSession` reads `GET /threads/:id/state` and maps LangChain messages to snapshot items (user text, assistant text and tool calls, tool results); 404 before the first checkpoint is an empty history, a connection failure is `endpoint_unavailable`, a 404 thread is `native_session_missing`.

### Coordinator, CLI, UI

- `SessionService.Context` gains the secret store; the adapter factory receives it. `connection.add` accepts the B4 parameters; `thread.create` no longer requires a working directory (B4 threads record the route as their context and default their title to the route id).
- CLI: `credential add <label>`, `connection add --kind b4 --url … --route … [--auth-ref secret:…] [--name …]`, `thread new --connection <b4>` without `--cwd`; `turn send` and `request respond` are unchanged.
- UI: the Connections screen gets an "Attach B4 endpoint" form (URL, route, label, credential reference) and the new-thread sheet hides the directory picker for B4 connections; the transcript renders `toolCall` cards by tool name and `reasoning` collapsed; the thread header shows the route.

### Decisions

- **D-019** A B4 turn's native id is its ordinal in `GET /threads/:id/turns`; the protocol has no run id, and the ordinal lets reconciliation tell "the server ran it" from "the prompt never arrived" without resubmitting.
- **D-020** Parked versus cancelled is decided by `GET /threads/:id/pending_interrupts`, never by the `interrupted` status alone; a parked turn stays `waiting_for_user` across stream loss and coordinator restart and its requests are re-opened from the durable `value`.
- **D-021** Permission answers go through `POST /threads/:id/resume` with B4's own decisions (`once`, `always`, `deny`, or `cancelled`); `allow_always` maps to `always` because B4 persists it itself, unlike Claude (D-018).
- **D-022** Endpoint secrets enter through the CLI's hidden prompt and the local socket into the coordinator's credential store; the adapter sends them as a bearer header to the configured origin only and refuses redirects. The GUI collects the reference, never the value.
- **D-023** Route kinds other than `agent` are stored as `incompatible` connections with an explanation; no attempt is made to run them.

## Non-goals

Managed servers and `b4 routes` inspection (M4), client tool calls, `thread-access` stamps, AG-UI, image input, deleting threads, model selection, custom header names for endpoint auth.

## Tests

- Fixture: `B4TurnTranslator` over recorded frames; `B4Adapter` and `SessionService` against `Tests/B4AdapterTests/Fixtures/fake-b4.py`, an HTTP server that implements the endpoints above with scripted behavior (streamed turn, tool turn, permission park and resume with `once`/`always`/`deny`/cancel, hang + cancel, failure, stream drop with background continuation and reattach, server restart with state preserved, bearer middleware returning 401, unknown route 404).
- Live, opt-in: `B4APP_LIVE_B4_URL=http://127.0.0.1:<port> B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` against a server the owner runs (`examples/chat` needs `OPENAI_API_KEY`). Never in CI.
