# Milestone checklist

States: `implemented` (code exists), `fixture-tested` (covered by tests with fixtures or fake executables), `live-tested` (exercised on the target Mac against the real runtime), `blocked` (needs an external action, named). Never mark a mocked path as live.

## M0: build and compatibility baseline

- [x] Inspect the repository; create the minimal workspace. `implemented` (this PR, Swift package plus XcodeGen apps).
- [x] Record target Mac/OS/architecture, Node, provider executables, Claude SDK, and B4 versions. `implemented` in `docs/compatibility.md`.
- [x] Check the selected Codex schema and official local sign-in path. `live-tested`: codex-cli 0.166.0 installed; schema generated from the binary; `account/read` and `account/login/start` verified (D-010).
- [x] Check Claude auth status and the executable pairing without reading credential contents. `live-tested`: `claude auth status --json` on 2.1.282; stream-json `initialize` handshake verified with no inference.
- [x] Identify a trusted local B4 project with one standard agent route. Chosen by the owner on 2026-10-31: `~/repos/b4app-live-check` (the M3 scratch project copied out of `/tmp`; `@b4run/cli` 0.15.8, one `/chat#agent` route on `gpt-5-mini`, `OPENAI_API_KEY` from this repository's gitignored `.env` via `--env-file`). Registered and `live-tested` as the M4 managed server `research`.
- [x] Establish a fixture-test runner, strict type check, and minimal coordinator entry point. `fixture-tested`: 87 tests in 19 suites; the coordinator integration test runs a real socket server on temporary directories.
- [x] Write `docs/compatibility.md`. `implemented`.

Exit gate status: closed. Codex baseline closed on 2026-10-30; the trusted B4 project was chosen on 2026-10-31.

## M1: one real Codex desktop conversation

- [x] Codex handshake, account status, sign-in, start/resume, stream, stop, history, runtime requests. Handshake, account, thread start/resume, streaming, stop, and history `live-tested` (CLI and the opt-in `CodexLive` test). Command approval `live-tested` on 2026-10-31 (a real `item/commandExecution/requestApproval` answered through the adapter under a stricter per-thread policy, since the owner's config is `never`); file-change approvals and user questions `fixture-tested` through the coordinator and UI, not yet triggered by the real runtime. Sign-in start `live-tested` (URL returned); completion from a signed-out state not exercised.
- [x] App, client, and coordinator boundaries over the shared socket. `live-tested` (macOS app hosts the coordinator; CLI shares it and streamed a real turn while the app was open).
- [x] Initial SQLite migration, connection registry, thread/native-ID mapping, turn record, cached display items. `fixture-tested`; JSON payload columns now round-trip as JSON.
- [x] Threads, conversation/composer, connection setup, runtime request UI. `implemented`; transcript rows, request cards, composer, and status badge rendered through `ImageRenderer` for a visual check; both apps build. Not driven interactively on screen (screen-recording permission declined).
- [x] Sign-in and reuse of an existing login. Existing ChatGPT login reused `live-tested`; "Sign in with ChatGPT" opens the URL returned by `account/login/start` (`implemented`, URL `live-tested`).
- [x] Persist and reopen a real thread. `live-tested`: `thread/resume` plus `thread/turns/list` returned the earlier user and assistant items after the first process was disposed.
- [x] Window close without duplicating or cancelling a turn. Window close keeps the coordinator alive (`implemented`); turn dedupe by `operationId` and refusal of a second active turn `fixture-tested`.

Exit gate status: open on two items. (1) A real runtime request has not been triggered live; the fixture and coordinator tests cover the path end to end. (2) The minimal packaged Finder launch is deferred to M6 with the rest of packaging.

## M2: Claude Code

- [x] Official auth status and login with consistent executable and environment selection. Status `live-tested` (`connection add --kind claude` → `ready / auth_required` on the signed-out Mac); login start `fixture-tested` (`claude auth login --claudeai` URL capture), not run live because it opens the owner's browser.
- [x] Session creation, streaming input, `session_id` persistence, native resume, final-result handling, stop. `fixture-tested` end to end (adapter and coordinator suites); handshake, `--session-id`, `system/init`, error `result`, and `--resume` of an unknown id `live-tested` without inference. `live-tested` on 2026-10-31 after the owner signed in: a real turn, an interrupt (the CLI reports a requested stop as an error result with reason `aborted_streaming`, now mapped to `cancelled`), and a native resume.
- [x] Tool permission and user-question bridges; explicit decline of unsupported elicitation. `fixture-tested` (allow, deny, answers keyed by synthetic question ids, elicitation auto-declined, hook/MCP requests answered with an error response).
- [x] Auth-mode conflict detection before execution. `fixture-tested`; `system/init.apiKeySource` is also checked per turn.
- [x] Drafts remain unsent while a turn runs and after interruption. The composer refuses a second turn (`protocol_invalid` / `turn_active`) and keeps the draft locally; `fixture-tested` through the coordinator for both runtimes.
- [x] Codex and Claude threads side by side with separate native identities. `fixture-tested` (both connections, both threads listed, a Claude crash leaves the Codex request pending and its connection `ready`).

Exit gate status: closed on 2026-10-31 (live inference turn passed; the window was driven on screen in M6).

## M3: B4 local and remote adapters

Design: `docs/superpowers/specs/2026-10-31-m3-b4-conversation-design.md`. Plan: `docs/superpowers/plans/2026-10-31-m3-b4-conversation.md`.

- [x] Endpoint reachability without inference, HTTPS enforcement for non-loopback. `fixture-tested` with a URLProtocol stub and the fixture server.
- [x] SSE parsing across chunk boundaries with parked, failed, cancelled, snapshot-only, and reattach outcomes. `fixture-tested`.
- [x] Endpoint profiles, exact route binding, endpoint secret references, capability checks, `credential add` with a hidden prompt. `implemented`, `fixture-tested` (coordinator suite), `live-tested` through the CLI against the fixture (keychain-backed secret store, piped stdin path; the TTY prompt path was not exercised).
- [x] Native thread creation, streaming input, state and turn reads, permission resolution (`once`, `always`, `deny`, cancel), explicit cancellation. `fixture-tested` end to end (adapter and coordinator suites).
- [x] Read-only reattachment with reconciliation and unknown-submission handling. `fixture-tested`: a dropped stream reattaches and finishes with one server-side turn; a parked prompt survives a server restart and a coordinator restart; a server restart mid-run fails the turn honestly; an unrecorded ordinal is reported as `submission_unknown` and never resubmitted.
- [x] Unsupported route kinds surface as a compatibility result. `fixture-tested` and `live-tested` via the CLI (`/dispatch#workflow` → `incompatible`, exit 2).
- [x] Test against an existing local standard-agent server. `live-tested` on 2026-10-31 against `b4 dev` 0.15.8 serving a `gpt-5-mini` `agent()` route (scratch project, `OPENAI_API_KEY` from the gitignored `.env`): streamed reply, real `runBash` permission prompt parked and approved through the CLI, tool card with the server's step label, cancel → `cancelled`, history and reconciliation. The live run found and fixed two shape differences (nested `turns.turns`, `usage`/`step`/`ToolMessage` events).
- [ ] Then a compatible remote HTTPS endpoint with its real endpoint credential. `blocked`: none deployed yet.
- [x] Standard-agent persistence across a real B4 server restart with its stores preserved. `live-tested` on 2026-10-31: a parked permission survived a `b4 dev` restart on the real `.b4/*.sqlite` stores and a coordinator restart, was re-opened from `pending_interrupts`, and completed on accept.

Exit gate status: local B4 threads coexist with harness threads live; stream loss and parked versus cancelled are live- and fixture-verified; open on a real remote HTTPS endpoint.

## M4: managed B4 execution and the shared CLI

Design: `docs/superpowers/specs/2026-10-31-m4-managed-b4-design.md`. Plan: `docs/superpowers/plans/2026-10-31-m4-managed-b4.md`.

- [x] One coordinator shared by GUI and CLI with a singleton lock. `fixture-tested` and `live-tested`.
- [x] `agent-workspace doctor --json` with stable exit codes. `live-tested`; managed servers appear as their own rows.
- [x] Local project registration, trusted route inspection (`b4 routes --json --cwd`), shared server and route records. `fixture-tested` (fake project CLI) and `live-tested` on 2026-10-31 against the M3 scratch project in place and then against its durable copy `~/repos/b4app-live-check` (the owner's chosen project, registered as `research`) with `@b4run/cli` 0.15.8: registration found `/chat#agent`, refused projects without the CLI, below 0.15.7, or without `b4.config.ts`.
- [x] Explicit Node and CLI paths, environment resolution (dotenv without shell evaluation), loopback binding, readiness via `/healthz`, redacted bounded logs, child ownership (`kinfo_proc` identity, own process group). `fixture-tested` and `live-tested` (Node v24.20.0 from `PATH`, the project-installed `dist/index.js`, the model key passed by env file and never read into app state).
- [x] Development (`b4 dev --port --env-file`) and source (`b4 start --host 127.0.0.1 --port`) launch profiles with their flag and environment differences. `live-tested` in both modes, including a `restart` that preserved `.b4/*.sqlite` (the thread recalled its earlier reply) and a `b4 dev` process group stop that took its runtime child.
- [x] GUI server controls and the CLI of section 11 (`server add|list|start|status|logs|restart|stop|inspect`, `connection add --server`). CLI `live-tested`; the Local servers view (`implemented`) builds on macOS and iOS and reacts to the same `server.changed` events, but its buttons were not clicked in this session (no screen control).
- [x] Concurrent GUI and CLI starts converge on one coordinator and one owned registration. `fixture-tested` (two simultaneous `server.start` requests share one launch) and `live-tested`: the macOS app hosted the coordinator (lock pid = app pid) while the CLI started, inspected, logged, and conversed through the same registration; the reverse order (CLI-spawned coordinator, then the app) also shared the row.
- [x] Attached local servers stay alive after disconnect, Quit, and coordinator restarts; owned-server controls never reach them. `live-tested`: a `b4 dev` started by hand on port 3102 and attached by URL survived a coordinator kill, the app's Quit, and a new coordinator; it never appeared in `server list`.
- [x] Port conflicts and stale ownership records never kill unrelated processes. `fixture-tested` (a foreign listener survives a refused start; a stale pid with a mismatched start time is left alone on coordinator start) and `live-tested` (a Python `http.server` on 3101 survived `server start` with `owned_process_conflict`).
- [x] Managed servers survive an app Quit and a coordinator restart and are re-adopted by the next coordinator. `fixture-tested` and `live-tested` (the server started under the app kept running after Quit, the CLI's coordinator adopted it by verified identity, ran a turn, and stopped it).

Exit gate status: closed for the CLI and the app-hosted coordinator on 2026-10-31. Open: clicking the Local servers view on screen; the M5 Quit dialog (keep running versus stop owned work, spec 10.3) is not built, so Quit always keeps managed servers running.

## M5: daily-use behavior and recovery

- [x] Complete rename, pin, archive/unarchive, title search, connection filtering, and local draft persistence. `fixture-tested`: rename, pin, archive, unarchive, query, and the draft survive a coordinator restart; the sidebar shows archived threads behind a toggle and a state dot per thread (running, waiting, stopping, outcome unknown, runtime offline, connection error) fed by the snapshot's active turns; drafts are saved 600 ms after typing stops and flushed at Quit; `agent-workspace thread update` covers the CLI. `live-tested` through the CLI on this Mac; the GUI controls build on macOS and iOS and were not clicked on screen.
- [x] Add safe account/endpoint identity changes, expired auth, allowance errors, and compatibility errors. `fixture-tested`: a Codex account change across restarts marks old threads `identity_changed` (readable, no new turns, new threads bind to the new identity, continuity returns with the original account); a missing native session marks the thread `missing`; an expired login during a turn flips the connection to `auth_required` with a `connection.changed` event; allowance and auth-mode failures are recorded under the connection label; `Remediation` maps every stable code to a sentence and one action. Not exercised live: a real expired login or allowance exhaustion (the spec forbids forcing one).
- [x] Implement all lifecycle outcomes from Section 10, including full Quit and wake reconciliation. `implemented` and `fixture-tested`: `workspace.activeWork` names local turns, remote turns, and owned servers; `workspace.stopLocalWork` cancels local turns, waits for the runtime's confirmation, force-stops owned servers, and detaches from attached and remote runs; `workspace.reconcile` settles a turn that finished while the coordinator was down; the coordinator's `SleepWatcher` and the app's wake observer both trigger it (D-034). The macOS Quit dialog (D-032) is `implemented` and was not clicked on screen; `applicationShouldTerminate` is exercised only by the build.
- [x] Test coordinator/runtime crash paths, ambiguous sends, stale decisions, and snapshot deduplication. `fixture-tested`: `swallow` (no acknowledgement) becomes `submission_unknown`, reconciles to still-unknown, blocks further sends until `turn.abandon`; `late ack` (response lost, notifications live) completes once with one native turn; a lost cache is rebuilt from `thread/turns/list` and a partial cache merges without duplicates (D-031); crash and stale-decision cases from M1 to M3 still pass.
- [x] Verify workspace write locks across local harness threads in the same directory. `fixture-tested`: two Codex threads and a Claude thread in one canonical directory (one through a `..`-containing path) are serialized across connections, a different directory runs, the lock holds through a crash (`reconciling`) and releases on `turn.abandon` (D-033).
- [x] Complete diagnostic redaction and bounded logs; inspect renderer IPC and credential boundaries. `fixture-tested`: a runtime failure carrying a bearer, an `sk-` key, and a callback URL with `code`, `state`, and `access_token` reaches the event, the thread read, and `doctor` masked; header lines and URL parameters are covered by unit tests; the CLI-spawned coordinator log is bounded. Boundary audit recorded in `docs/verification.md`.

Exit gate: critical recovery and ownership cases pass fixture tests (235 tests in 53 suites); the live Mac matrix rows that this Mac can run are recorded in `docs/verification.md`; every uncertain native outcome stays `reconciling` until a runtime answers or the owner abandons it.

### Open after M5

- The macOS Quit dialog, the continuity banner, the remediation button, and the rename alert were not clicked on screen (no screen control in this session).
- A real Mac sleep across a live turn has not been exercised; the wake path is fixture-tested through `workspace.reconcile` and the clock-gap watcher.
- Expired login and allowance exhaustion were fixture-tested only, as the spec requires.

## Visual system (LLA)

Design: `docs/superpowers/specs/2026-10-31-lla-visual-system-design.md`. Plan: `docs/superpowers/plans/2026-10-31-lla-design-and-m6.md`.

- [x] Tokens, type scale, bundled fonts, the mark, and the shared controls (`Sources/WorkspaceUI/Theme/`). `implemented`, `fixture-tested` (`ThemeTests`: SVG parsing and fit, font registration and fallback, palette contrast in both appearances).
- [x] Sidebar, thread detail, transcript, composer, approvals, continuity banner, connections, local servers, diagnostics, new-thread sheet, and empty states restyled; accessibility identifiers unchanged. `implemented`; both app targets build.
- [x] App icon from the brand tile for macOS and iOS. `implemented`.
- [x] Rendered offscreen in light and dark over a real coordinator (`SnapshotTests`, `docs/screenshots`); not clicked on screen (control declined). See `docs/verification.md`.

## M6: package and accept the personal v0

Design: `docs/superpowers/specs/2026-10-31-m6-package-and-accept-design.md`. Plan: `docs/superpowers/plans/2026-10-31-lla-design-and-m6.md`.

- [x] Produce a local `.app` bundle and package/locate the coordinator and companion CLI predictably. `implemented`: `Scripts/package.sh` builds `dist/Agent Workspace.app` with `Contents/Helpers/{b4app-coordinator,agent-workspace}` and the LaunchAgent plist, signs (ad hoc, or `B4APP_SIGN_IDENTITY`), verifies, and zips; `Scripts/install-cli.sh` links the bundled CLI onto PATH; the CLI finds the bundled coordinator (D-038, D-040). `live-tested` on this Mac: see `docs/verification.md`.
- [x] Verify Finder launch with executable paths outside the interactive shell PATH. `implemented` (D-040 fallback directories, `fixture-tested` with a fake nvm tree); `live-tested` by launching the packaged app through LaunchServices with no shell: see `docs/verification.md`.
- [x] LaunchAgent hosting per D-004. `implemented` as a per-user LaunchAgent plist the app writes and bootstraps (D-042; the `SMAppService` agent of D-038 broke on every ad hoc rebuild), with in-process fallback, restart and removal, `coordinator status|stop|restart|plist`; `live-tested`: spawn from the bundle, restart through launchd, survival across app Quit (`docs/verification.md`).
- [x] Document prerequisites, build/run/package commands, first sign-in, B4 environment setup, and CLI use. `README.md`.
- [ ] Run the release acceptance matrix on the target Mac. Rows and their status are in `docs/verification.md`; A10 (remote B4) and the on-screen rows A01/A17 are open or partial as recorded there; A03 passed live on 2026-10-31.
- [ ] Developer ID signing and notarisation. `blocked`: no signing identity on this Mac (D-039).
- [x] Record exact versions, performed checks, known limits, and blocked live checks. `docs/verification.md`, `docs/compatibility.md`.

Exit gate status: open. The implementation ships with the gate clearly open on the live rows that need the owner (Claude sign-in, a remote endpoint, a screen click-through) and on Developer ID signing; nothing is labelled fully validated.

## M7: PostgreSQL store (D-041)

Design: `docs/superpowers/specs/2026-10-31-storage-and-sync-design.md`. Plan: `docs/superpowers/plans/2026-10-31-storage-and-sync.md`.

- [x] Bundled, pinned PostgreSQL 17.11 (`Scripts/fetch-postgres.sh`, `Contents/SharedSupport/postgres`), a private cluster per Mac on a Unix socket, started and stopped by the coordinator. `implemented`, `fixture-tested` (`PostgresServerTests`: initdb, start, adopt, stop, stale pid), `live-tested` (the packaged app started its cluster from the bundle).
- [x] The store rewritten on libpq behind the existing API; one migrator with versioned SQL files; every existing test passes on Postgres. `implemented`, `fixture-tested` (261 tests).
- [x] The pre-0.2 SQLite store imported once and retired. `fixture-tested` (`SQLiteImportTests`), `live-tested` on a copy of the owner's real store.
- [x] `db status|migrate|backup|restore|import-sqlite` through the coordinator; JSON-lines export and restore. `fixture-tested` (`ChangeLogTests`), `live-tested` through the CLI.
- [x] Change log written by triggers, read and replayed by the store (`changes(after:)`, `replay`). `fixture-tested`: every write leaves rows and the log replays into an equal store.
- [ ] Hybrid logical clock and device identity (M8 sets them; the log carries the device id and wall clock now).
- [ ] Schema documentation (`docs/schema.md`).

Exit gate status: the store runs on Postgres end to end; sync (M8) has not started.

## M8a: read-only mirror (D-043 to D-046)

Design: `docs/superpowers/specs/2026-10-31-m8-hub-design.md`. Plan: `docs/superpowers/plans/2026-10-31-m8a-read-only-mirror.md`. Roadmap block: M8 in `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md`.

- [x] The hub: a Rust service in `Hub/` with `serve`, `migrate`, `seed`, `enroll`; one shared schema, `org_id` on every tenant table, RLS enabled and forced, the application role `b4hub_app` not the owner and without `BYPASSRLS` (D-043). `implemented`, `fixture-tested` (77 Rust tests against real PostgreSQL 17: `rls.rs` runs as `b4hub_app`: it sees only its own org's rows, sees nothing and cannot insert without a tenant context, and the owner role with row security off errors instead of filtering; plus change-log idempotency and ordering, long-poll, enrollment, and health tests). `live-tested` as a Compose service (below).
- [x] Device enrollment by a one-time code and device-token authentication; revocation keeps uploaded history (D-044). `implemented`, `fixture-tested` (enrollment, token authentication, and that revoking keeps uploaded history are all fixture-tested only). `live-tested`: a Mac and a Simulator device each enrolled against the Compose hub and authenticated with the token; the only revoke seen live was the Keychain-failure cleanup (`revoked_at` set, 0 tokens), not uploaded history surviving a revoke.
- [x] Change-log push and long-poll pull with a per-org sequence cursor; `GET /v1/changes` answers `resync_required` (410) for a negative cursor only; the retention horizon is 0 because M8a never prunes, so a stale cursor cannot occur yet. `implemented`, `fixture-tested` (including `resync_required`, which was never seen live). `live-tested`: push, long-poll pull, and the cursor, with 35 changes on the hub equal to the Mac's count and the phone's cursor.
- [x] The coordinator's `HubSync` and `agent-workspace hub join|status|leave`; `SyncFilter` keeps only the known `connections` columns, blanks `authReference`, `localServerId`, `target`, sends a `nativeScope` containing `/` as an opaque `scope:` hash, never uploads `localServers`, truncates a display-item or runtime-request payload over 1 MiB; `database.restore` refused while joined (D-046). `implemented`, `fixture-tested` against `FakeHubAPI` (`HubSyncTests`). `live-tested`: `hub join`, `hub status`, and the push, and after a real push the hub's `connections` row had `authReference` NULL, `target` empty, `localServerId` NULL, and no `localServers` table content; the non-loopback URL refusal on `hub join` was also seen live. `hub leave`, the `database.restore` refusal while joined, the 1 MiB payload truncation, and the 401 suspension are `fixture-tested` only.
- [x] The iOS SQLite mirror (`WorkspaceMirror`) behind the unchanged shell through an in-process transport, the Connect screen, and the Keychain-held device token (`WorkspaceSecrets`). `implemented`, `fixture-tested` (`WorkspaceMirrorTests`, `HubURLTests`, the shared `Tests/Fixtures/sync/changes.json` decoded by both languages), `live-tested` in the Simulator.
- [x] Compose for local use (`Hub/compose.yaml`, `Hub/.env.example`), a non-root image with `HEALTHCHECK`, and a CI `hub` job on Ubuntu with a `postgres:17` service. `implemented`; the image `live-tested` on `linux/arm64`; the CI `hub` job is recorded in the draft PR, cacheplane/b4app#17 (base `design/m8-hub`): the controller observed all three checks (the Swift package job, the apps job, which runs both app builds, and the new Ubuntu `hub` job) green at commit a6d9a2a (end of Task 6) and partially green on later heads; the heads after that, including the docs commit, were still pending when this was written, so the final head's result is in the PR, not here; `linux/amd64` not built.
- [x] Swift suite 324 tests (262 before M8a), Rust suite 77 tests; both app builds pass. `fixture-tested`.
- [ ] The owner's packaged Mac app joined to a hub. `open`: the live gate ran a scratch debug coordinator beside the running app and deliberately did not replace it.
- [ ] Real Codex or Claude threads through a hub. `open`: the agent in the live gate was the fixture `fake-codex.py`; the sync path (debug coordinator, Compose hub, iOS app) was real end to end, the inference was not. Only threads created in the app sync; nothing is read from `~/.codex`, `~/.claude`, or a B4 server's history.
- [ ] Hub deployed anywhere but the Mac's Compose, behind TLS, and from another architecture. `open`: no chart, no `linux/amd64` build, the hub speaks plain HTTP and the clients accept it only for `localhost`, `127.0.0.1`, and `::1`.

Live gate (2026-10-31, Task 9): scratch debug coordinator with the fixture Codex, the Compose hub, and the iOS app in the iPhone 17 Pro Simulator. A thread and its transcript appeared on the phone without a refresh; a second turn showed within 1.4 s and a new thread within 1.6 s; the hub's change count (35) equalled the Mac's and the phone's cursor; a non-loopback `http` URL was refused on both sides before any request. Evidence and commands: `docs/verification.md`.

Known limitations (none are fixed in M8a):

- Disconnecting the phone is deleting the app; that leaves its hub device unrevoked. There is no Disconnect control yet.
- The phone's thread header shows the Mac's working directory from `threads.context`. That is a project path crossing the wire; the design's list of what never syncs names secrets, executable paths, pids, ports, sockets, and log paths, not this. The owner decides whether `threads.context` should sync.
- The shell shows Mac wording on the phone ("Coordinator connected").
- Turns and runtime requests that arrive while a thread is open appear when it is reopened; only display items, threads, and connections are published live.
- No rate limit on `/v1/enroll`; `GET /v1/changes` pages have no byte limit; a value other than a display-item payload over 2 MiB would be refused with a permanent 413 that blocks the Mac's queue and shows only in `hub status`.
- The shared `WorkspaceRootView` now binds the compact column so a thread opens on iPhone; the Mac app's runtime behaviour after that change is covered by the test suite and by reading only, not by a click-through.
- ATS (`NSAllowsInsecureHTTPLoads` for `localhost`) is set in `project.yml`; the generated `Info.plist` is gitignored.

Exit gate status: the M8a exit as written in the roadmap holds for the Simulator with a fixture agent and a scratch Mac coordinator; it is not claimed for the owner's own app and real runtimes until a join is run there.

## M8b to M8e: phone writes, relay, accounts, deployable

- [ ] M8b The phone writes (pins, archive, titles, drafts; hybrid logical clocks, per-column last-writer-wins; the coordinator applies other devices' changes). `blocked` on M8a.
- [ ] M8c The relay (outbound WebSocket per coordinator; `turn.send`, `turn.interrupt`, `request.respond` routed to the owning Mac; a turn for an offline Mac is refused, D-045). `blocked` on M8a; the iOS composer stays unavailable until then (`unsupportedCapability` naming M8c).
- [ ] M8d Accounts (PKCE, device grant, refresh-token families, self-registration, organisations, OIDC brokering). `blocked` on M8a; extends D-044's tables.
- [ ] M8e Deployable (Helm chart with a migration hook and external Postgres, SAML, SCIM, tenant bundle export and import, a client compatibility window). `blocked` on M8a.
