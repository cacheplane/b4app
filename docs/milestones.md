# Milestone checklist

States: `implemented` (code exists), `fixture-tested` (covered by tests with fixtures or fake executables), `live-tested` (exercised on the target Mac against the real runtime), `blocked` (needs an external action, named). Never mark a mocked path as live.

## M0: build and compatibility baseline

- [x] Inspect the repository; create the minimal workspace. `implemented` (this PR, Swift package plus XcodeGen apps).
- [x] Record target Mac/OS/architecture, Node, provider executables, Claude SDK, and B4 versions. `implemented` in `docs/compatibility.md`.
- [x] Check the selected Codex schema and official local sign-in path. `live-tested`: codex-cli 0.166.0 installed; schema generated from the binary; `account/read` and `account/login/start` verified (D-010).
- [x] Check Claude auth status and the executable pairing without reading credential contents. `live-tested`: `claude auth status --json` on 2.1.282; stream-json `initialize` handshake verified with no inference.
- [ ] Identify a trusted local B4 project with one standard agent route. `blocked`: none chosen yet.
- [x] Establish a fixture-test runner, strict type check, and minimal coordinator entry point. `fixture-tested`: 87 tests in 19 suites; the coordinator integration test runs a real socket server on temporary directories.
- [x] Write `docs/compatibility.md`. `implemented`.

Exit gate status: open only for B4 (no trusted project chosen). Codex baseline closed on 2026-10-30.

## M1: one real Codex desktop conversation

- [x] Codex handshake, account status, sign-in, start/resume, stream, stop, history, runtime requests. Handshake, account, thread start/resume, streaming, stop, and history `live-tested` (CLI and the opt-in `CodexLive` test). Command and file-change approvals and user questions `fixture-tested` through the coordinator and UI; not yet triggered by the real runtime. Sign-in start `live-tested` (URL returned); completion from a signed-out state not exercised.
- [x] App, client, and coordinator boundaries over the shared socket. `live-tested` (macOS app hosts the coordinator; CLI shares it and streamed a real turn while the app was open).
- [x] Initial SQLite migration, connection registry, thread/native-ID mapping, turn record, cached display items. `fixture-tested`; JSON payload columns now round-trip as JSON.
- [x] Threads, conversation/composer, connection setup, runtime request UI. `implemented`; transcript rows, request cards, composer, and status badge rendered through `ImageRenderer` for a visual check; both apps build. Not driven interactively on screen (screen-recording permission declined).
- [x] Sign-in and reuse of an existing login. Existing ChatGPT login reused `live-tested`; "Sign in with ChatGPT" opens the URL returned by `account/login/start` (`implemented`, URL `live-tested`).
- [x] Persist and reopen a real thread. `live-tested`: `thread/resume` plus `thread/turns/list` returned the earlier user and assistant items after the first process was disposed.
- [x] Window close without duplicating or cancelling a turn. Window close keeps the coordinator alive (`implemented`); turn dedupe by `operationId` and refusal of a second active turn `fixture-tested`.

Exit gate status: open on two items. (1) A real runtime request has not been triggered live; the fixture and coordinator tests cover the path end to end. (2) The minimal packaged Finder launch is deferred to M6 with the rest of packaging.

## M2: Claude Code

- [x] Official auth status and login with consistent executable and environment selection. Status `live-tested` (`connection add --kind claude` → `ready / auth_required` on the signed-out Mac); login start `fixture-tested` (`claude auth login --claudeai` URL capture), not run live because it opens the owner's browser.
- [x] Session creation, streaming input, `session_id` persistence, native resume, final-result handling, stop. `fixture-tested` end to end (adapter and coordinator suites); handshake, `--session-id`, `system/init`, error `result`, and `--resume` of an unknown id `live-tested` without inference. **Blocked for a live inference turn**: run `claude auth login`, then `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`.
- [x] Tool permission and user-question bridges; explicit decline of unsupported elicitation. `fixture-tested` (allow, deny, answers keyed by synthetic question ids, elicitation auto-declined, hook/MCP requests answered with an error response).
- [x] Auth-mode conflict detection before execution. `fixture-tested`; `system/init.apiKeySource` is also checked per turn.
- [x] Drafts remain unsent while a turn runs and after interruption. The composer refuses a second turn (`protocol_invalid` / `turn_active`) and keeps the draft locally; `fixture-tested` through the coordinator for both runtimes.
- [x] Codex and Claude threads side by side with separate native identities. `fixture-tested` (both connections, both threads listed, a Claude crash leaves the Codex request pending and its connection `ready`).

Exit gate status: open on the live inference turn (sign-in needed) and on interactive use of the window.

## M3: B4 local and remote adapters

Design: `docs/superpowers/specs/2026-10-31-m3-b4-conversation-design.md`. Plan: `docs/superpowers/plans/2026-10-31-m3-b4-conversation.md`.

- [x] Endpoint reachability without inference, HTTPS enforcement for non-loopback. `fixture-tested` with a URLProtocol stub and the fixture server.
- [x] SSE parsing across chunk boundaries with parked, failed, cancelled, snapshot-only, and reattach outcomes. `fixture-tested`.
- [x] Endpoint profiles, exact route binding, endpoint secret references, capability checks, `credential add` with a hidden prompt. `implemented`, `fixture-tested` (coordinator suite), `live-tested` through the CLI against the fixture (keychain-backed secret store, piped stdin path; the TTY prompt path was not exercised).
- [x] Native thread creation, streaming input, state and turn reads, permission resolution (`once`, `always`, `deny`, cancel), explicit cancellation. `fixture-tested` end to end (adapter and coordinator suites).
- [x] Read-only reattachment with reconciliation and unknown-submission handling. `fixture-tested`: a dropped stream reattaches and finishes with one server-side turn; a parked prompt survives a server restart and a coordinator restart; a server restart mid-run fails the turn honestly; an unrecorded ordinal is reported as `submission_unknown` and never resubmitted.
- [x] Unsupported route kinds surface as a compatibility result. `fixture-tested` and `live-tested` via the CLI (`/dispatch#workflow` → `incompatible`, exit 2).
- [ ] Test against an existing local standard-agent server, then a compatible remote HTTPS endpoint. **Blocked**: no local `agent()` project with model credentials on this Mac (hashbrown's B4 projects are `workflow` routes; `examples/chat` needs `OPENAI_API_KEY`). Opt-in test ready: `B4APP_LIVE_B4_URL`/`B4APP_LIVE_B4_ROUTE`.
- [ ] Standard-agent persistence across a real B4 server restart. `fixture-tested` only (fixture persists its stores to a JSON file).

Exit gate status: local and remote B4 threads coexist with harness threads, stream loss does not resubmit, parked is distinguishable from cancelled (all fixture-verified); open on live inference and on a real remote HTTPS endpoint with its real credential.

## M4: managed B4 execution and the shared CLI

- [x] One coordinator shared by GUI and CLI with a singleton lock. `fixture-tested` and `live-tested`.
- [x] `agent-workspace doctor --json` with stable exit codes. `live-tested` (0 ok, 3 not implemented).
- [ ] Project registration, route inspection, server lifecycle, logs, child ownership. Not started.

## M5 and M6

Not started. See the spec.
