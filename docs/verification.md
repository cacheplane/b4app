# Verification record

Gate results and unresolved checks, newest first. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

## 2026-10-31: M4 managed B4 execution and the shared CLI

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Node v24.20.0 on `PATH` from nvm, no `b4` on `PATH`. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4-cli.py` (a `b4` stand-in serving the M3 fixture protocol) behind `fake-node.sh`, in scratch projects built by `Tests/CoordinatorTests/FakeB4Project.swift`. Live runs first registered the M3 scratch project in place under `/tmp` (`@b4run/cli` 0.15.8, one `gpt-5-mini` `agent()` route, `.b4` stores from M3) with `--env-file` pointing at this repository's gitignored `.env`, under scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`; the built macOS app was launched from the command line with the same scratch directories. After the owner chose it, the project was copied to `~/repos/b4app-live-check` (node_modules and `.b4` included) and the registration, both launch modes, restart continuity, and stop were repeated there as the server `research` (last table row).

### Live against the real project and `@b4run/cli` 0.15.8

| Scenario | How | Result |
| --- | --- | --- |
| Register and inspect | `server add <project> --name live --env-file <b4app>/.env --port 3101` | Pass in 1.1 s: Node v24.20.0 (`path`), CLI 0.15.8 from the project's `package.json`, `b4 routes --json` found `/chat#agent`; the registration printed the trust line first. |
| Source mode start and a real turn | `server start live`; `connection add --kind b4 --server live --route /chat#agent`; `thread new`; `turn send … pong` | Pass: `b4 start --host 127.0.0.1 --port 3101` was ready in 1.1 s (pid owned, log shows `b4 start listening on http://127.0.0.1:3101` after B4's anonymous-auth notices); the connection stored `managed_local` with target `http://127.0.0.1:3101`; gpt-5-mini answered `pong` in 2.4 s. |
| Development mode and continuity across restart | `server stop`; `server add … --mode development`; `server start`; `server restart`; `turn send` on the same thread | Pass: the profile updated in place (same id, same port); `b4 dev` was ready in 1.9 s (`Loaded 1 variable(s)`, `B4.run dev ready at …`); `restart` took 2.6 s to generation 2 with a new pid; the next turn on the same thread recalled its earlier `pong`, so `.b4/{threads,checkpoints}.sqlite` survived the restart. |
| Coordinator restart with the server running | SIGTERM to the coordinator; `server status live` from a fresh coordinator | Pass: the `b4 dev` process stayed alive; the new coordinator reported `ready … (adopted)` with the same pid and `owned`; a turn completed; `server stop` ended the `b4 dev` parent and its runtime child (pid gone, port free). |
| Port conflict | `python3 -m http.server 3101`, then `server start live` | Refused `owned_process_conflict` "Port 3101 is in use by another process; nothing was stopped"; the Python server was still alive afterwards. Exit 1. |
| Attached server survives everything | `node node_modules/@b4run/cli/dist/index.js dev --port 3102` by hand; `connection add --url http://127.0.0.1:3102 …`; a turn; coordinator kill; app Quit; new coordinator | Pass: the hand-started server answered `pong`, never appeared in `server list`, and was still alive after the coordinator was killed, after the app quit, and under the next coordinator; only my own `kill` ended it. |
| GUI start, CLI inspect and stop (app-hosted coordinator) | Launch `Agent Workspace.app` with the scratch directories (lock pid = app pid 53028); `server start live`, `server list`, `server logs`, `turn send`, `server status --json`, then `tell application "Agent Workspace" to quit` | Pass: the CLI started the server through the app's in-process coordinator (pid 53317 owned, `b4 dev` ready), listed and tailed it, and ran a turn (`pong`); after Quit the app was gone, the lock released, and the managed server still alive. |
| CLI adopts after Quit, then the reverse order | `server status live` (CLI spawns a coordinator), a turn, `server stop`; relaunch the app, `server start`, `server stop`, Quit | Pass: adopted by verified identity (same pid), `pong`, stopped (pid gone); the relaunched app's coordinator started generation 5 as owned and stopped it; Quit left nothing behind. |
| Doctor | `agent-workspace doctor` | Managed servers appear as `b4` rows with the CLI path, version, health, port, mode, and project; attached endpoints keep their reachability rows. |
| The owner's chosen project | `server add ~/repos/b4app-live-check --name research --env-file <b4app>/.env --port 3101`; source start and a turn; `server add … --mode development`; start; a turn; `restart`; a turn; `server logs`; `server stop` | Pass: route `/chat#agent` found; `pong` in source mode; after the switch to development mode the same thread answered `pong` to "which word did you answer last time" and again after `restart` (`.b4` preserved across the mode change and the restart); the log tail showed `B4.run dev ready at http://127.0.0.1:3101`; stop left no process behind. |

Not exercised live: clicking Start / Stop / Restart / Connect / Logs in the Local servers view (built for macOS and iOS; no screen control in this session), a project whose `b4.config.ts` sets `env`, two different projects at once, a `b4 dev` file change mid-turn.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 218 tests in 44 suites (38 new) in 21 s; no fixture server left running afterwards |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

New fixture coverage: `WorkspaceProtocol` (server methods and their mutation flags, params round trips, `LocalServerRoute` keys, `server.changed`); `WorkspaceStorage` (migration `v2`, server rows with routes, update, unique names, connections by server); `WorkspacePlatform` (dotenv quoting, comments, escapes, no expansion; process identity of self and a child; spawn with output to a 0600 file and an exit status; group terminate reaching a grandchild; missing executable; redaction of bearers, `sk-` keys, and key/value pairs; log tail with offsets and copy-truncate bounding; port allocate and in-use detection); `LocalServerService` over the socket (registration with route discovery, refusals for a missing CLI, an old CLI, no config, a missing env file; profile matching and updates; env-file values reaching the child but never a result; source and development starts to ready; idempotent start; concurrent starts joining one launch; port conflict without a kill; restart generations; monitor detecting an exit; stop reaching a `b4 dev` grandchild whose parent ignores SIGTERM; re-adoption after a coordinator restart; a stale pid left alone; an unready start failing with the log tail; a start over a live owned instance marked `unhealthy` refused by pid with the instance still stoppable; a stop racing a start serialized so the new generation is owned and the old process gone; `b4 routes` stderr redacted before it reaches a result; logs tailed, redacted, and followable by offset; doctor rows); managed route connections (`offline` with the start hint while stopped and no thread created; a conversation through the managed server and `offline` after stop; stop refused with `turn_active` then forced, after which the turn is not `completed`, a stopped server stops again without force, and a reconciling turn does not block restart; a server exit marking the connection `offline`, its running turn `reconciling`, and the next turn refused `endpoint_unavailable` with `server_stopped`; a `workflow` route `incompatible` and an unknown route `not_found`). The platform port probe also sees a listener that set `SO_REUSEADDR` (as Node does) through a non-blocking connect and answers within 200 ms against a saturated backlog.

A fresh-context review of the whole branch found no critical issue and five important ones, all fixed with a failing test first: a start on an unhealthy owned server discarded its monitor and blamed another process; a stop racing a start could orphan an owned process behind a `stopped` row; `b4 routes` stderr reached the client unredacted; the CLI sent relative paths unresolved (`server add .` now resolves against the shell's directory, checked by a CLI smoke); and the server-exit test accepted a turn still `running`. Deferred minors are listed in the PR.

### Open after M4

- The Local servers view has not been driven on screen.
- Removing a registration, changing a port that route connections use, and the Quit choice dialog (spec 10.3) are not built; Quit keeps managed servers running.
- Built artifacts (`b4 build` + `node .b4/build/server.mjs`) and `b4 typegen` before `b4 start` are not run by the app.

## 2026-10-31: M3 B4 local and remote conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3). No `b4` on PATH. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4.py`, a stdlib Python server that implements the Agent Protocol subset the adapter uses with the shapes read from `@b4run/cli` 0.15.8 source and corrected from the live run. Live runs use a scratch project with `@b4run/cli` 0.15.8 project-installed, one `gpt-5-mini` `agent()` route, a `workspace/` directory, and `OPENAI_API_KEY` loaded by `b4 dev --env-file` from this repo's gitignored `.env` (the key was copied from the b4run checkout and checked against `GET /v1/models`, HTTP 200).

### Live against a real B4 server (`b4 dev` 0.15.8 on 127.0.0.1:3101)

| Scenario | How | Result |
| --- | --- | --- |
| Opt-in adapter test | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s: inspection `ready`, thread `t-…`, reply "pong" `completed`, cancel of a counting turn confirmed and finished `cancelled`, history `[userMessage, agentMessage, userMessage]`, reconcile of the first turn `completed`. |
| CLI attach and turns | `connection add --kind b4 --url http://127.0.0.1:3101 --route /chat#agent`, `thread new`, `turn send` | Pass: `ready / not_required`; "pong" streamed in 2.0 s; a second turn answered "pong" from the same native thread (continuity). |
| Real permission prompt | `turn send --no-wait <id> "Use your runBash tool to run exactly: ls -la …"`, `thread show`, `request respond <rid> --accept` | Pass: the turn parked `waiting_for_user` with a `command_approval` request carrying the server's `interrupt` envelope (`perm-…`, `kind: command`, `detail.command: "ls -la"`, `toolCallId`); `--accept` resumed it; the transcript ended with the tool card, then "AGENTS.md\nnotes.txt"; the turn was `completed`. |
| Tool card from live `step` frames | `turn send <id> "Use your runBash tool to run exactly: pwd …"` | Pass: `[toolCall started]`, `[toolCall completed] pwd`, one card labelled "Ran pwd" with the output, then the answer. No `step` or `usage` items in the transcript. |
| Parked prompt across a real server restart and a coordinator restart | park on `ls -la`; stop `b4 dev` and the coordinator; start `b4 dev` again on the same `.b4/{threads,checkpoints}.sqlite`; fresh coordinator `thread show`; `request respond --accept` | Pass: after the restart `GET /threads/:id` still read `interrupted` with `metadata.parked_route` and `GET /pending_interrupts` listed the same `perm-…` prompt; `thread show` on the fresh coordinator reconciled the turn to `waiting_for_user` with the request re-opened at adapter generation 2; `--accept` resumed the run, the tool card showed `ls -la`, the answer listed the files, and the turn ended `completed`. The server's turn list showed one `done` turn per prompt sent. |
| Raw protocol capture | `curl -N` of `runs/stream`, `GET /turns`, `GET /state`, `GET /pending_interrupts` | Recorded in `docs/research/2026-10-30-b4-runtime.md`. Two differences from the source reading were found and fixed before merging: `GET /turns` nests the list under `turns.turns` (the ordinal reconcile had silently fallen back to status-only and reported the wrong outcome), and `usage`/`step` events plus serialized `ToolMessage` outputs needed folding instead of rendering as items. |

Not exercised live: a remote HTTPS endpoint with a real endpoint credential, approval grants, `detached capacity`, the macOS forms (built, not clicked).

### Live Codex approval (M1 gate closed from this branch)

| Scenario | How | Result |
| --- | --- | --- |
| Approval under the owner's configuration | CLI thread, "create `/tmp/…` with a shell command" | No request: `~/.codex/config.toml` sets `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`, so Codex ran `printf hello > /tmp/…` directly. Honest result for daily use on this Mac. |
| Real `item/commandExecution/requestApproval` round trip | `B4APP_LIVE_CODEX=1 B4APP_LIVE_CODEX_APPROVALS=1 swift test --filter CodexLiveTests/commandApprovalRoundTrip` (the test alone asks `thread/start` for `on-request` + `workspace-write`) | Pass in 6.4 s: the request arrived as `command_approval` with `command: /bin/zsh -lc 'curl -sI https://example.com'`, `cwd`, and `reason: "Allow curl to access https://example.com outside the network-blocked sandbox?"`; `allow_once` → `{ decision: accept }`; the turn completed and the reply was `HTTP/2 200`. A first attempt that wrote under `/tmp` needed no approval because `workspace-write` keeps `/tmp` writable. |

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 180 tests in 35 suites (35 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live B4 (opt-in) | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s against `b4 dev` 0.15.8 with gpt-5-mini (see the live table) |

New fixture coverage: `B4TurnTranslator` (ordered streamed turn, tool calls paired with results and messages split around them, park keeps the turn open and the resume stream continues item numbering, failed and cancelled outcomes, final message from `done.output` when nothing streamed including LangChain envelopes, capability events and reasoning visible, reattach `state live:false` ends without an outcome, durable prompt re-open, transport-loss event); `B4Protocol` (route keys, HTTP error mapping, exact resume bodies, decision mapping, LangChain state projection); `B4Adapter` against the fixture (inspect, create, two consecutive turns with ordinals `turn-1`/`turn-2`, tool turn and `loadSession` history, park then `once` with a stale second answer refused, `always`/`deny`/decline all reaching the server, stop on a parked turn declining the prompt, hang then cancel with a later stop returning the known outcome, failed run, **dropped stream reattached with one server-side turn**, **parked prompt answerable after a server restart** under a new generation, **server restart mid-run fails the turn and the thread accepts the next one**, reconcile distinguishing recorded from unrecorded ordinals with a `submission_unknown` error event, bearer middleware 401 as `auth_required` then success with the credential, unknown route 404 and `workflow` route as compatibility results, malformed route as an error); `SessionService` over the socket (a B4 conversation beside Codex with both threads listed and re-adding the same endpoint returning the same connection, a permission answered through `request.respond` with the turn `waiting_for_user` in between, `credential.add` producing a reference the endpoint accepts while an unknown reference is refused and an anonymous turn fails `auth_required`, route and URL problems rejected with codes, **a parked B4 turn answerable after a coordinator restart** via `thread.read` reconciliation to `waiting_for_user`).

### Live on the target Mac (coordinator and CLI against the fixture server)

| Scenario | How | Result |
| --- | --- | --- |
| Credential path | `echo s3cret \| agent-workspace credential add fake-endpoint` with scratch `B4APP_RUNTIME_DIR`/`B4APP_DATA_DIR` | Pass: printed `Stored "fake-endpoint" as secret:<uuid>` and the `connection add` hint; the value appeared nowhere else. The item was written to the login keychain (service `b4app`) by the real `KeychainSecretStore` and removed afterwards. The TTY `readpassphrase` path was not exercised (no terminal in this session). |
| Attach an endpoint with the credential | `connection add --kind b4 --url http://127.0.0.1:<port> --route /chat#agent --auth-ref secret:<uuid> --name fake-b4` | Pass: `ready / auth=unknown`, `route /chat#agent (attached_local)`, message "Server reachable (readyz: ready). Model credentials are not verified by this check." Exit 0. |
| Workflow route | `connection add --kind b4 … --route /dispatch#workflow` | Stored as `incompatible` with "Route /dispatch#workflow is a workflow route. Conversations support standard agent routes only (D-023)." Exit 2. |
| Remote plain HTTP | `connection add --kind b4 --url http://agent.example.com …` | Refused `protocol_invalid` "Remote B4 endpoints must use HTTPS". Exit 4. |
| Thread and streamed turn | `thread new --connection fake-b4 --title smoke`, `turn send <id> hello there` | Pass: thread `native thr_1 route /chat#agent`; streamed "Hello from fake B4." then `[turn completed]`, exit 0. |
| Permission through the CLI | `turn send --no-wait <id> please approve`, `thread show`, `request respond <rid> --accept` | Pass: `thread show` listed the `command_approval` request with `command: rm -rf tmp` and the `request respond` hint; after `--accept` the transcript ended with "Approved (once). Command ran." and the turn was `completed`. |
| Stop a running turn | `turn send --no-wait <id> hang around`, `turn interrupt <id>` | Pass: `stopping`, then `turn-4 terminal cancelled`. |
| Reopen after a coordinator restart | `thread show` from a fresh coordinator process | Pass: three terminal turns and seven cached items; no reconciliation needed. |
| Missing credential | keychain item deleted, then `turn send <id> hello` | Failed honestly with `auth_required` "Credential secret:<uuid> is not in the credential store. Run `agent-workspace credential add` and update the connection." Exit 1. |
| No resubmission | `GET /threads/thr_1/turns` on the fixture after the session | `idle`, exactly one server-side turn per `turn send` (`run_2`, `run_6`, `run_13` all `done`). |
| Doctor | `agent-workspace doctor` | Lists each B4 connection as a runtime row with its reachability message. |

### Open after M3

- A compatible remote HTTPS endpoint with its real endpoint credential has not been attached; the local live run used no middleware.
- Approval grants (`approvals.grants`) are reviewed from source and fixture-tested only.
- The macOS Connections form and new-thread sheet for B4 build but were not clicked through in this session.
- Mac sleep/wake across a long SSE stream and the reattach cap (`detached capacity`) are untested.

## 2026-10-31: M2 Claude Code conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Claude Code 2.1.282 at `~/.local/bin/claude`, **signed out** (`claude auth status --json` → `loggedIn: false`) for the whole session.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 145 tests in 30 suites (21 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Claude (opt-in) | `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` | **Not run**: requires `claude auth login` first |

New fixture coverage: `ClaudeTurnTracker` (streamed turn in order, `result success` with `is_error` → failed with `auth_required`, interrupt → cancelled by flag and by `terminal_reason`, tool_use paired with its tool_result, permission and question requests with safe payloads and synthetic question ids, elicitation marked unanswerable, `control_cancel_request`, session state, `apiKeySource` conflict, process exit ending the turn and scoping the disconnect, transcript snapshots); `ClaudeSession` and `ClaudeAdapter` against `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (inspect and login URL capture, session + streamed turn, permission allowed then stale, permission denied with a failed tool result, question answers passed through by question text, elicitation auto-declined, hang + interrupt → cancelled, crash → failed turn + thread-scoped disconnect + resume on the next send with a new generation, failed result error code, `--resume` of a known session and `native_session_missing` for an unknown one, `loadSession` from the transcript file); `SessionService` over the socket (a Claude conversation beside a Codex thread with both connections listed, a Claude tool permission answered exactly once through `request.respond`, a Claude crash leaving the Codex request pending and both connections `ready`).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Protocol shapes while signed out | Raw `claude` launch with the adapter's argv, `initialize` + one `user` message on stdin | Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`: hooks before the handshake, `command_lifecycle`, `system/init` with `apiKeySource: none`, replayed user frame, synthetic `assistant` error, `result success` with `is_error: true`. `--resume` of an unknown id → `result error_during_execution`, exit 1. |
| Claude connection registration | `agent-workspace connection add --kind claude` (scratch directories) | Pass, honest: `ready / auth_required`, version 2.1.282, message "Not signed in. Run `claude auth login` or use Sign in from the Connections screen." Exit 0. |
| Thread creation while signed out | `agent-workspace thread new --connection claude --cwd <dir>` | Refused with `auth_required`, exit 1. No process was left behind. |
| Codex unaffected | `connection add --kind codex` in the same coordinator | `ready / authenticated` beside the Claude row. |

### Not exercised (open gates)

- Any Claude inference: streaming, a real `can_use_tool`, `AskUserQuestion`, the `result` after `interrupt`, and resume with `--resume`. Sign in with `claude auth login`, then run the live test; it prints the reply, the interrupt outcome, and the resume answer.
- `claude auth login` through the app or CLI (it opens the owner's browser; not triggered unattended).
- Interactive use of the macOS window (screen-recording permission declined).

## 2026-10-30: M1 Codex conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), codex-cli 0.166.0 from the Homebrew cask, signed in with ChatGPT.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 124 tests in 26 suites (37 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Codex (opt-in) | `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` | Pass in 9.7 s: handshake, account, thread, "pong" turn, interrupt → cancelled, reopen with history |

New fixture coverage: `StreamingProcess` (echo, terminate, stderr tail, write after exit, missing executable); Codex event translation for a streamed turn, interrupted and failed turns with mapped error codes, approval requests with a safe payload, every server request method's kind and decline body, account notifications, thread status, history snapshots; `CodexAppServer` and `CodexAdapter` against `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (handshake and account, streamed turn, approval answered with the user's decision then stale on a second answer, unsupported permissions request declined automatically, user question answers passed through, `thread/resume` before `turn/start` and `native_session_missing`, interrupt → cancelled, process exit mid-turn then restart on the next send, failed turn error code); storage upsert by native item id with stable sequence, active-turn lookup, request expiry per connection, snapshot replacement keeping live items; protocol mutation flags for the nine new methods; `SessionService` over the real socket (whole conversation with user and assistant items persisted, second turn refused while one is active, retry with the same `operationId` returning the same turn, approval answered exactly once, runtime exit leaving the turn `reconciling` with submission `unknown` and refusing dispatch, failed dispatch keeping the user message, pending requests expiring and turns reconciling across a coordinator restart).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Codex connection registration | `agent-workspace connection add --kind codex` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` | Pass. Found `/opt/homebrew/bin/codex` 0.166.0, `account/read` reported the ChatGPT account (`promax`), connection stored `ready / authenticated`, capabilities recorded. Exit 0. |
| New thread in a directory | `agent-workspace thread new --connection codex --cwd <dir> --title "Live check"` | Pass. `thread/start` returned native id `01a18f32-…`; the thread row carries the account email as `nativeScope`. |
| Real streamed turn | `agent-workspace turn send <id> Reply with exactly the single word: pong` | Pass in 3.5 s. Deltas streamed to the terminal, `[turn completed]`, exit 0. |
| Tool turn | `turn send <id> Read README.txt …` | Pass in 4.9 s. Codex ran `/bin/zsh -lc 'cat README.txt'` (shown as a tool card with its output), then answered with the file contents. No approval was requested under the user's Codex configuration, so the approval path was not exercised live. |
| Stop | `turn send … Count slowly from 1 to 3000 …` in the background, `turn interrupt <id>` after 6 s | Pass. The in-flight numbers drained, `[turn cancelled]`, exit 130; `thread show` lists the turn with a `reasoning` item and no assistant text. |
| Reopen the same native thread | `CodexLive` test: dispose the adapter, create a new one, `loadSession` | Pass. `thread/resume` + `thread/turns/list` returned the earlier user message and the "pong" reply. |
| macOS app hosts the coordinator during a live turn | Built `Agent Workspace.app` launched from the command line with the scratch directories; `agent-workspace doctor`, `thread list`, `turn send <id> … pong2` | Pass. The lock carried the app's pid (4700), the CLI reused it, the second turn completed through the app-hosted coordinator, and `thread show` listed both turns. |
| Conversation UI rendering | `ImageRenderer` of `TranscriptRow`, `RuntimeRequestList`, `ComposerView`, and `TurnStatusBadge` with representative items (throwaway test, not committed) | Pass. User bubble, Markdown assistant text, collapsed command card with status, live streaming text, "Turn stopped." note, "Waiting for you" badge, approval card with Allow once / Allow for session / Deny, question card, composer with Stop and a disabled Send while a turn is active. `ScrollView`, `TextEditor`, and `Picker` do not render through `ImageRenderer` and were checked by build only. |

### Not exercised (open gates)

- A real approval or user-question request from Codex. The coordinator, adapter, CLI, and UI paths are fixture-tested end to end; trigger one live by asking Codex to run a command outside its sandbox policy.
- Interactive use of the macOS window (screen-recording permission declined). The window was not clicked through; the shared SwiftUI code built for both platforms and rendered in isolation.
- `account/login/completed` from a signed-out state (the Mac stayed signed in).
- Mac sleep/wake with an app-server running; the minimal packaged Finder launch (M6).

## 2026-10-30: M0 baseline and Swift application shell (initial PR)

Target: MacBook Pro (Apple Silicon), macOS 26.5, Xcode 26.6, Swift 6.3.3, iPhone 17 Pro simulator (iOS 26.5).

### Automated (run locally; CI runs the same on `macos-26`)

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass (11 targets) |
| Tests | `swift test` | Pass: 87 tests in 19 suites |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

Fixture coverage the spec calls out as easy to break: envelope and method validation (mutations require `operationId`, unknown methods, wrong version, non-object params), event cursor gaps and epoch changes, bounded replay returning `snapshot_required`, singleton lock (held lock reported without removal, release and reacquire), NDJSON and JSON-RPC framing across arbitrary chunk boundaries, SSE parsing across every chunk size with parked, failed, cancelled, snapshot-only, and reattach outcomes, CRLF split across chunks, Claude auth-mode conflict detection, Claude stream-json frame encoding and decoding (initialize, user, can_use_tool allow and deny, AskUserQuestion answer, system init, result), B4 HTTPS enforcement and offline mapping through a `URLProtocol` stub, native-id uniqueness per connection and scope, runtime request single transition, command runner timeout and missing executable.

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| CLI starts the coordinator and reports diagnostics | `.build/debug/agent-workspace doctor --json` with `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` pointed at scratch directories | Pass. The CLI spawned `b4app-coordinator` from beside itself, the lock and socket were created with mode 0600 in a 0700 directory, the database opened in WAL mode. Exit 0. A second `doctor` reused the same coordinator pid. |
| CLI not-implemented commands | `agent-workspace server start research --json` | Pass. JSON error `not_implemented` with the milestone, exit 3. |
| Claude Code inspection | Through coordinator diagnostics | Found `~/.local/bin/claude` 2.1.282 through PATH. Earlier in the day the adapter reported `ready / authenticated` (claude.ai pro); by the time of the final run `claude auth status --json` itself reported logged out and the adapter reported `auth_required`, which is the honest result. No credential files were read. |
| Claude stream-json handshake | `claude` launched with the SDK's argv, one `initialize` control request on stdin, then EOF | Pass with no inference: one `control_response` frame, exit 0. Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`. |
| Codex inspection | Through coordinator diagnostics | `missing_executable` with install guidance (the CLI is not installed). Expected; not a pass of the Codex integration. |
| macOS app hosts the coordinator and shares it with the CLI | Built app launched from the command line with no coordinator running | Pass. The lock file carried the app's pid; `agent-workspace doctor` returned the same pid and `ready` runtime rows while the app was running. |
| Stale lock and socket files after an unclean exit | App killed with SIGTERM, then `doctor` | Pass. The next coordinator took the freed `flock`, replaced the socket file, and served the CLI. |
| iOS app renders the shell | Installed and launched on the iPhone 17 Pro simulator with `simctl`; screenshot captured with `simctl io` | Pass. Sidebar with Threads, Connections, Local servers, Diagnostics, the thread list, search, and the status "Coordinator unavailable: iOS cannot reach the Mac coordinator yet". A first build was letterboxed because XcodeGen overwrote the Info.plist; fixed by moving the keys into `project.yml`. |

### Not exercised (open gates)

- A screenshot of the macOS window could not be captured (screen-recording permission declined), so the macOS layout was verified only through the socket and the shared SwiftUI code that rendered on iOS.
- Packaging, Finder launch, LaunchAgent registration, signing, notarization. M6.
- Codex app-server handshake, sign-in, any turn. Blocked on installing the Codex CLI.
- Claude sessions beyond the handshake, permission bridge, interrupt. M2.
- B4 thread operations and managed server supervision. Blocked on selecting a trusted local project. M3 and M4.
- Keychain writes through `KeychainSecretStore`. The memory store was used in tests; the Keychain store is wired but untested live.
