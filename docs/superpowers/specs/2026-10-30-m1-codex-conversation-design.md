# M1: one real Codex conversation (design)

Date: 2026-10-30. Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` sections 3.3, 5, 6, 7, 10, 11, 13 (M1). Baseline: the M0 shell in PR #1.

## Intent

From the macOS app and the `agent-workspace` CLI, the owner can create a Codex thread bound to a working directory, send a message, watch the reply stream, answer a command or file-change approval, stop a turn, and reopen the same native thread later. Nothing in this slice is mocked: every byte on the wire goes to the pinned `codex app-server` (0.166.0), and the live checks in `docs/verification.md` record what was actually exercised.

## Verified facts this design rests on (live, 2026-10-30, codex-cli 0.166.0)

- `codex app-server` over stdio: JSON-RPC 2.0 without the `jsonrpc` field, one message per line. `initialize` then the `initialized` notification. The server also emits unsolicited `configWarning`, `remoteControl/status/changed`, and `account/updated` notifications right after startup; clients must ignore unknown methods.
- `account/read { refreshToken: false }` returns `{ account: { type: "chatgpt", email, planType, workspaceName } | { type: "apiKey" } | null, requiresOpenaiAuth }`. The owner's machine is signed in with ChatGPT (`promax`).
- `thread/start { cwd, serviceName }` returns `{ thread: { id, cwd, model, ... }, model, approvalPolicy, sandbox, ... }`. `thread/resume { threadId, cwd? }` returns the same shape plus history cursors. `thread/turns/list { threadId, itemsView: "full", sortDirection: "asc", limit }` returns `{ data: [Turn], nextCursor }`.
- `turn/start { threadId, input: [{ type: "text", text }], cwd? }` returns `{ turn: { id, status: "inProgress", items: [] } }`. `turn/interrupt { threadId, turnId }` returns `{}`.
- Streaming notifications: `turn/started { threadId, turn }`, `item/started { threadId, turnId, item, startedAtMs }`, `item/agentMessage/delta { threadId, turnId, itemId, delta }`, `item/commandExecution/outputDelta`, `item/reasoning/textDelta`, `item/completed { threadId, turnId, item, completedAtMs }`, `turn/completed { threadId, turn }` where `turn.status` is `completed | interrupted | failed | inProgress` and `turn.error` is `{ message, codexErrorInfo?, additionalDetails? }`, `error { threadId, turnId, error, willRetry }`, `thread/status/changed { threadId, status: { type: notLoaded | idle | systemError | active, activeFlags? } }`, `serverRequest/resolved { threadId, requestId }`.
- Server-to-client requests (answered by echoing the request id): `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` with response `{ decision: accept | acceptForSession | decline | cancel }`; `item/tool/requestUserInput` with `{ questions: [{ id, header, question, options?, isOther?, isSecret? }] }` and response `{ answers: { id: { answers: [String] } } }`; `item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, and legacy `execCommandApproval` / `applyPatchApproval`.
- Item types: `userMessage { content: [UserInput] }`, `agentMessage { text, phase? }`, `reasoning { summary?, content? }`, `plan { text }`, `commandExecution { command, cwd, status, exitCode?, aggregatedOutput? }`, `fileChange { changes: [{ path, kind, diff }], status }`, `mcpToolCall { server, tool, status, ... }`, `dynamicToolCall`, `webSearch`, `imageView`, `functionCallOutput`, `contextCompaction`, `hookPrompt`.
- Sign-in: `account/login/start { type: "chatgpt" }` returns `{ authUrl, loginId }`; `account/login/completed { loginId, success, error }` follows; `account/login/cancel { loginId }` exists.

## Architecture

```
WorkspaceUI / CLI  ──commands/events──▶  Coordinator
                                           ├─ Router (new methods)
                                           ├─ SessionService (actor)      ← new
                                           │    ├─ adapters per connection
                                           │    ├─ turn lifecycle + display projection
                                           │    └─ runtime request registry
                                           └─ WorkspaceDatabase (GRDB)
CodexAdapter ──▶ CodexAppServer (actor) ──▶ StreamingProcess ──▶ `codex app-server`
```

### WorkspacePlatform: `StreamingProcess`

A long-lived child with a writable stdin, a chunked stdout stream, bounded stderr capture, and an exit continuation. Foundation `Process` plus `Pipe`; the readability handler feeds an `AsyncStream<[UInt8]>`. Used by the Codex adapter now and the Claude adapter in M2. `CommandRunner` (one-shot, swift-subprocess) stays for `--version` style calls.

### CodexAdapter

- `CodexAppServer` (actor): owns one `StreamingProcess`, assigns request ids, matches responses to continuations, routes server requests and notifications to an `AsyncStream<RpcMessage>`. Handshake: `initialize` with `clientInfo { name: "agent_workspace", title: "Personal Agent Workspace", version }` and `capabilities { experimentalApi: false }`, then `initialized`. Generation counter increments per process start. Child environment: inherited minus `OPENAI_API_KEY` is **not** stripped (Codex handles its own auth); nothing is added. Nothing from stderr is logged beyond a bounded ring buffer exposed in diagnostics messages.
- `CodexProtocol` (enums and small structs): request builders and notification decoders for the methods above. Hand-written from the generated JSON schema (D-010 resolved below). Only the fields the app reads are typed; the rest stays `JSONValue`.
- `CodexEventTranslator`: pure function from `RpcMessage` to `[AdapterEvent]` with native ids in `nativeIds` (`threadId`, `turnId`, `itemId`, `requestId`). The adapter never knows app ids.
- `CodexAdapter` implements `AgentAdapter`: `createSession` (`thread/start`), `loadSession` (`thread/resume` + `thread/turns/list`), `sendTurn` (`turn/start`, ensures the thread is resumed in this process first), `interrupt`, `respond` (answers a pending server request by id; unknown kinds get an explicit decline), `reconcile` (`thread/read` for the active turn status), `events()`, `dispose()` (closes stdin, waits briefly, terminates). Extra, Codex-only: `accountStatus()` and `startLogin()`.
- Mapping to events: `turn/started` → `turn.acknowledged`; `item/started` → `message.started` (agentMessage) or `tool.started` (others); `item/agentMessage/delta` → `message.delta`; `item/completed` → `message.completed` or `tool.completed` with the final item as payload; `turn/completed` → `turn.finished` with `completed → completed`, `interrupted → cancelled`, `failed → failed`; `error` → `adapter.error`; server requests → `runtime_request.opened`; `serverRequest/resolved` → `runtime_request.resolved`; `account/updated` and `account/login/completed` → `connection.changed`; `thread/status/changed` → `turn.state_changed`; process exit → `connection.changed` with transport `disconnected`.

### Coordinator: `SessionService`

An actor that owns adapters keyed by connection id and consumes their event streams. It is the only writer of turns, display items, and runtime requests.

- `connectionAdd(kind: codex, label?, executablePath?)`: inspects, inserts the `Connection`, returns it. One Codex connection per executable path.
- `connectionInspect(id)`: `CodexInspector.inspect` plus `account/read` through the app server; updates status, auth status, capabilities (`streaming`, `nativeResume`, `historyRetrieval`, `explicitInterruption`, `permissionDecisions`, `userQuestions` supported; `reconnect`, `modelSelection` unverified), and `nativeScope` (account email or `"apikey"`). Publishes `connection.changed`.
- `loginStart(connectionId)`: returns `authUrl`; completion arrives as an event.
- `threadCreate(connectionId, workingDirectory, title?)`: `createSession`, inserts the thread with `nativeScope`, publishes `thread.updated` and `session.created`.
- `threadRead(threadId)`: thread, turns, display items, pending runtime requests from the database. No network.
- `threadUpdate(threadId, title?, pinned?, archived?)`: local only.
- `turnSend(threadId, text, operationId)`: rejects when an unresolved turn exists for the thread (`owned_process_conflict` is wrong here; use `protocol_invalid` with code detail `turn_active`); inserts the `Turn` row as `submitting/prepared`, inserts the user `DisplayItem`, calls `sendTurn`; on receipt marks `running/acknowledged` with `nativeTurnId`; on throw marks `terminal/failed` unless the error is a timeout after the request may have been written, which marks `reconciling/unknown`.
- `turnInterrupt(threadId)`: `interrupt` the active turn, mark `stopping`; outcome arrives via `turn.finished`.
- `requestRespond(requestId, decision | answers)`: single transition in the database, then adapter `respond`; a stale or unknown request fails with `stale_runtime_request`.
- Event projection: `message.delta` is re-published (not stored); `message.completed` and `tool.completed` upsert the display item by `nativeItemId`; `turn.finished` marks the turn terminal with the outcome and bumps the thread `updatedAt`; `runtime_request.opened` inserts a pending request; `runtime_request.resolved` transitions it; process exit expires pending requests of that connection's threads (`expireRuntimeRequests` by generation) and marks running turns `reconciling/unknown`.
- Every event published to the `EventLog` carries the app `threadId` and `turnId` resolved from the native ids.

### Protocol additions

Methods: `connection.add`*, `connection.inspect`*, `connection.login`*, `thread.create`*, `thread.read`, `thread.update`*, `turn.send`*, `turn.interrupt`*, `request.respond`*. Starred methods are mutations and require `operationId`. `turn.send` reuses the envelope `operationId` as the turn's operation id, so a retried send cannot dispatch twice (local dedupe only, spec 6.2).

### CLI

`connection add --kind codex [--label] [--path]`, `connection list`, `connection inspect <id>`, `connection login <id>` (prints the URL; `--open` opens it), `thread list [--connection]`, `thread new --connection <id> [--cwd DIR] [--title]`, `thread show <id>`, `turn send <threadId> <text> [--no-wait]` (subscribes to events before sending, prints deltas, exits 0 on `completed`, 1 on `failed`, 130 on `cancelled`, and prints pending runtime requests with the `request respond` command to answer them), `turn interrupt <threadId>`, `request respond <id> (--accept | --accept-session | --decline | --answer q=a ...)`. All support `--json`.

### UI

- Connections: the Codex card's button becomes "Add Codex connection" and calls `connection.add`; configured connections show auth state, a "Check" button, and a "Sign in with ChatGPT" button that opens the returned URL.
- Sidebar: a "New thread" button per Codex connection opens a sheet with a directory picker (defaults to the home directory) and an optional title.
- Thread detail: transcript list (user, assistant, tool cards with status and collapsed output), live assistant text from deltas, pending runtime request cards with Allow / Allow for session / Deny or question answers, a composer bound to the draft, Send and Stop. Turn state and outcome are shown from the turn rows.
- `WorkspaceModel` keeps per-thread `ThreadDetail` (turns, items, live text by item id, requests) loaded through `thread.read` and patched by events.

### Decisions

- **D-010 resolved**: protocol types are hand-written Swift from the schema generated by the pinned binary; the generator's output is not committed (4.5 MB, 677 definitions) and the exact `codex --version` plus `generate-json-schema` are recorded in `docs/compatibility.md`.
- **D-011**: the coordinator hosts one `codex app-server` process per Codex connection, started lazily and kept alive while the coordinator runs. Restarting it bumps the adapter generation and expires pending requests.
- **D-012**: approval policy and sandbox come from the user's Codex configuration; the app answers the resulting approval requests instead of overriding them to `never`.
- **D-013**: a Codex thread's `cwd` is fixed at creation and sent with every `turn/start`.

## Non-goals for this slice

Model selection UI, `turn/steer`, image input, Codex `thread/list` import of native history, the LaunchAgent, Claude or B4 conversation.

## Tests

- Fixture: `CodexEventTranslator` over recorded notification lines; `CodexAppServer` against a fake app-server shell script that replays canned responses (handshake, thread/start, turn/start with a streamed reply, an approval request); `SessionService` end to end over the socket with the fake script (turn lifecycle, display projection, request transition, dedupe by `operationId`, stale request).
- Live, opt-in: `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` performs a real handshake, `account/read`, `thread/start`, one short turn, `turn/interrupt` on a second turn. Never in CI.
