# Milestone checklist

States: `implemented` (code exists), `fixture-tested` (covered by tests with fixtures or fake executables), `live-tested` (exercised on the target Mac against the real runtime), `blocked` (needs an external action, named). Never mark a mocked path as live.

## M0: build and compatibility baseline

- [x] Inspect the repository; create the minimal workspace. `implemented` (this PR, Swift package plus XcodeGen apps).
- [x] Record target Mac/OS/architecture, Node, provider executables, Claude SDK, and B4 versions. `implemented` in `docs/compatibility.md`.
- [ ] Check the selected Codex schema and official local sign-in path. `blocked`: Codex CLI is not installed. Docs reviewed; schema generation deferred to M1 (D-010).
- [x] Check Claude auth status and the executable pairing without reading credential contents. `live-tested`: `claude auth status --json` on 2.1.282; stream-json `initialize` handshake verified with no inference.
- [ ] Identify a trusted local B4 project with one standard agent route. `blocked`: none chosen yet.
- [x] Establish a fixture-test runner, strict type check, and minimal coordinator entry point. `fixture-tested`: 87 tests in 19 suites; the coordinator integration test runs a real socket server on temporary directories.
- [x] Write `docs/compatibility.md`. `implemented`.

Exit gate status: open. Codex and B4 live checks are blocked on installs; everything else is in place.

## M1: one real Codex desktop conversation

- [ ] Codex handshake, account status, sign-in, start/resume, stream, stop, history, runtime requests. JSON-RPC NDJSON framing `fixture-tested`; the rest not started.
- [x] App, client, and coordinator boundaries over the shared socket. `implemented` and `live-tested` (macOS app hosts the coordinator; CLI shares it).
- [x] Initial SQLite migration, connection registry, thread/native-ID mapping, turn record, cached display items. `fixture-tested`.
- [ ] Threads, conversation/composer, connection setup, runtime request UI. Threads list and empty state `implemented`; composer and requests not started.
- [ ] Sign-in and reuse of an existing login. Not started.
- [ ] Persist and reopen a real thread. Not started.
- [ ] Window close without duplicating or cancelling a turn. Window close keeps the coordinator alive (`implemented`).

## M2: Claude Code

- [x] Auth status with consistent executable and environment selection. `live-tested` through `agent-workspace doctor`.
- [x] Stream-json control protocol types: initialize, user message, can_use_tool allow/deny, AskUserQuestion answer, interrupt, system init, result. `fixture-tested` against shapes read from the SDK and a live handshake.
- [ ] Session lifecycle, streaming, `session_id` persistence, resume, stop. Not started.
- [x] Auth-mode conflict detection. `fixture-tested`.
- [ ] Drafts remain unsent while a turn runs. Draft persistence `fixture-tested`; turns not started.

## M3: B4 local and remote adapters

- [x] Endpoint reachability without inference, HTTPS enforcement for non-loopback. `fixture-tested` with a URLProtocol stub.
- [x] SSE parsing across chunk boundaries with parked, failed, cancelled, snapshot-only, and reattach outcomes. `fixture-tested`.
- [ ] Endpoint profiles, route binding, secret references, `credential add`. SecretStore `implemented`; CLI command exits 3 `not_implemented`.
- [ ] Thread operations and live tests. `blocked`: no project or endpoint selected.

## M4: managed B4 execution and the shared CLI

- [x] One coordinator shared by GUI and CLI with a singleton lock. `fixture-tested` and `live-tested`.
- [x] `agent-workspace doctor --json` with stable exit codes. `live-tested` (0 ok, 3 not implemented).
- [ ] Project registration, route inspection, server lifecycle, logs, child ownership. Not started.

## M5 and M6

Not started. See the spec.
