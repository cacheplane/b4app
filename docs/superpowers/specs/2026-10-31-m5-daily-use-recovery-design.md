# M5: daily-use behavior and recovery (design)

Date: 2026-10-31. Spec: `docs/roadmaps/Personal_Agent_Workspace_Technical_Spec_and_Roadmap.md` sections 3.1, 3.3, 5.1, 5.2, 10, 12, 14.2 (A05, A11, A12, A13, A15, A16, A17, A18) and the M5 checklist. Builds on M0 to M4, all merged into `main` on 2026-10-31. No new runtime; M5 completes the workspace behavior around the three adapters and hardens recovery.

## Intent

The owner can live in the app: organize threads (rename, pin, archive, search, filter) with drafts that survive a restart; see per-thread state in the sidebar; get a specific next action when sign-in expires, an allowance runs out, a runtime is incompatible, or a native session is gone; quit the app with a clear choice about local work; wake the Mac and have the app reconcile instead of pretending; and never have two writable harness turns run in one directory through this app. Everything uncertain stays visibly uncertain, and the user gets a deliberate way out of it.

## What already exists (read from `main` at 477ccdf)

- `thread.update` sets title, pinned, archived; `thread.list` filters by connection, archived, and a title query; drafts are read on open and saved when the selection changes. The sidebar searches titles and filters by connection. Missing: rename in the UI, any way to see or unarchive archived threads, a CLI for organization, draft saves while typing and at quit, and per-thread status in the sidebar (spec 3.1).
- Startup expires every pending request and marks unresolved turns `reconciling` with an unknown submission; `thread.read` reconciles one active turn through the adapter; a runtime exit expires that connection's (or that thread's) requests. Missing: any action for a turn that stays `reconciling` (spec 10.1.4 "deliberate recovery"), the directory lock (10.1.5), wake handling (10.3), the Quit choice (10.3), and the snapshot merge: `AgentAdapter.loadSession` is implemented by all three adapters and called by nobody, so missing native history is never detected after a restart and a reopened thread never deduplicates a snapshot against the cache (A11, A13).
- Adapters already map `unauthorized` → `auth_required`, usage and rate limits → `allowance_exceeded`, an inherited API key → `auth_mode_conflict`, a missing thread or transcript → `native_session_missing`. The coordinator records the code on the failed turn and nothing else: the connection still says `authenticated` after Codex reported it signed out, and the UI shows the message with no action (A15).
- `LogRedactor` masks bearers, `sk-` keys, and key/value pairs in server logs only. Adapter error messages, stderr tails in `connection.changed`, `recentErrors` in diagnostics, and the CLI-spawned coordinator's stdout log are not redacted or bounded.

## Design

### 1. Thread organization (A05)

- `EventsSnapshot.Result` gains `activeTurns: [Turn]` (every non-terminal turn). `WorkspaceModel` keeps `activeTurns[threadId]` from the snapshot and from `turn.acknowledged`, `turn.state_changed`, and `turn.finished` events, so each sidebar row shows a state dot: running, waiting for you, stopping, outcome unknown, or nothing when idle; the connection's `offline`/`error` status overrides it. No schema change: `ConversationThread` stays a plain row.
- UI: a thread's context menu and toolbar offer Rename (an alert with a text field), Pin/Unpin, Archive/Unarchive. The sidebar gets a "Show archived" toggle; archived rows appear in their own section and can be reopened and unarchived. An archived thread opens normally; archiving never stops a turn (spec 3.3).
- Drafts: the model saves the draft 600 ms after the last keystroke, on selection change (already), and when the app is about to quit (`persistDraftNow()`), so the text is there after a restart. `turn.send` still deletes the draft on dispatch and the composer restores it when the send is refused.
- CLI: `thread update <id> [--title T] [--pin|--unpin] [--archive|--unarchive]` prints the row; `thread list --archived` already exists.

### 2. Native continuity: missing history and identity changes (A13, spec 3.3, 5.1)

- `connections` gain `nativeScope` (migration `v3`), written from `ConnectionInspection.nativeScope` on every inspect. `threads` gain `continuity` (`available`, `missing`, `identity_changed`), default `available`.
- A new mutation `thread.reconcile { threadId }` does, in order: refuse nothing; if the thread's `nativeScope` is non-empty and the connection's known scope differs → `continuity = identity_changed`, publish `thread.updated`, return. Otherwise reconcile the active turn (as `thread.read` does), then call `adapter.loadSession` and merge the snapshot: an item whose native id is already cached is updated in place; an item without a native id whose role and text equal a cached item of the same role is skipped; the rest replace the previous snapshot-provenance items, placed before the cached live items when the cache held no history for them (sequences are renumbered in one transaction). Live items are never deleted or duplicated (D-031). `native_session_missing` from `loadSession` → `continuity = missing`; a successful load → `available`. `thread.read` calls the same reconcile when the thread has an unresolved turn or when the cache is empty, and leaves the stored continuity alone otherwise, so a plain read stays cheap and offline-safe.
- `turn.send` on a thread whose continuity is `missing` or `identity_changed` is refused with `native_session_missing` (reason `missing`) or the new code `identity_changed`; the UI shows a banner ("Continuation is unavailable: …. The cached transcript stays.") with "Start a new thread" and disables the composer. Identity: Codex scope is the account email, Claude the signed-in email, B4 the endpoint origin; a changed scope means another account or server, and old threads are never retargeted (spec 5.1).

### 3. Deliberate recovery and the directory lock (A12, A18)

- `turn.abandon { threadId }` (mutation): only a `reconciling` turn can be abandoned; it becomes `terminal/failed`, a `system` display item `turnAbandoned` records that the native outcome was never established, and `turn.finished` is published with `source: "abandoned"`. `thread.reconcile` is the "Check again" action; nothing is ever re-sent. The composer offers both while a turn is `reconciling`.
- Directory lock: before dispatch on a `codex` or `claude` connection, the coordinator canonicalizes the working directory (symlinks resolved, trailing slashes removed) and refuses with `protocol_invalid` (reason `directory_locked`, details `threadId`, `turnId`, `status`) while any other harness thread, on any connection, has a non-terminal turn in the same canonical directory. `reconciling` and `waiting_for_user` hold the lock (10.1.5). B4 routes are not directories and are not locked.
- Ambiguous sends: the fake Codex gains `swallow` (never answers `turn/start`, starts nothing) and `late ack` (starts the turn and streams, but never answers the RPC). The adapter's 30 s request timeout is configurable per adapter (`CodexAppServer.Options.requestTimeout`) and the coordinator passes `B4APP_CODEX_REQUEST_TIMEOUT` seconds when set, so the fixture tests run in a second. Expected: `swallow` → `submission_unknown`, turn `reconciling`, `thread.reconcile` leaves it unknown, a second send is refused until `turn.abandon`; `late ack` → the `turn/started` notification acknowledges the turn and it completes normally, exactly one native turn.

### 4. Actionable auth, allowance, and compatibility failures (A15)

- When a turn fails with `auth_required`, the coordinator sets the connection's `authStatus = required` and publishes `connection.changed`; `incompatible_version` sets `status = incompatible`; `allowance_exceeded` and `auth_mode_conflict` are recorded in diagnostics with the connection label. Nothing retries, nothing switches billing mode (Claude's environment is already stripped of `ANTHROPIC_API_KEY`).
- `WorkspaceModel.lastFailure: WorkspaceError?` replaces string-only errors; `Remediation.for(error, connection:)` in `WorkspaceUI` maps codes to a sentence and an action: `auth_required` → Sign in (Codex, Claude) or "Update the credential with `agent-workspace credential add`" (B4); `allowance_exceeded` → "Wait for the allowance to reset or change the plan; nothing was re-sent"; `auth_mode_conflict` → "Remove `ANTHROPIC_API_KEY` from the environment"; `incompatible_version` → Open Connections; `endpoint_unavailable` with `server_stopped` → Start the server; `native_session_missing`/`identity_changed` → New thread; `submission_unknown` → Check again / Abandon; `directory_locked` → Open the other thread. The composer banner shows the sentence and the button.

### 5. Lifecycle: Quit, wake, reconnect (A17, spec 10.3)

- `workspace.activeWork` (read): `{ turns: [{ threadId, turnId, status, connectionId, kind, b4Mode, local }], servers: [LocalServer] }` where `local` is true for Codex, Claude, and managed B4 (work this coordinator's process tree owns) and false for attached and remote B4 (runs continue on their server when the app quits; the app detaches, it does not cancel).
- `workspace.stopLocalWork` (mutation): interrupts every local active turn (parked local prompts are declined by the existing B4 stop path), waits up to 5 s for each to leave `running`, force-stops owned servers, and returns what it did and what it could not confirm. Remote work is left alone.
- `workspace.reconcile { reason }` (mutation): reconciles every unresolved turn through its adapter and re-inspects connections that are `offline`. Published events are the usual turn and connection events; the result counts what changed and what stayed unknown.
- macOS Quit: `applicationShouldTerminate` persists the draft, and when this process hosts the coordinator asks `workspace.activeWork`. With nothing local it quits. Otherwise an alert offers "Quit" (local turns stop with the app and become outcome-unknown on next launch; owned servers keep running; remote runs continue and are reconciled next launch), "Stop local work and quit" (`workspace.stopLocalWork`, then quit), and "Cancel". "Keep running in the background" is not offered: the coordinator lives inside the app until the M6 LaunchAgent (D-004), and saying otherwise would be a lie (D-032). When another process hosts the coordinator, Quit is immediate: the app owns nothing.
- Wake: the app observes `NSWorkspace.didWakeNotification` and calls `refreshSnapshot()` then `workspace.reconcile(reason: "wake")`. The coordinator also runs a `SleepWatcher` that compares a monotonic clock with the wall clock every 5 s and treats a gap over 20 s as a wake, so a CLI-spawned coordinator reconciles too. Reconnect after a desync already re-snapshots; it now also reconciles.

### 6. Redaction and bounded logs; boundaries (A16)

- `LogRedactor.redact` also masks sensitive URL query parameters (`token`, `access_token`, `refresh_token`, `id_token`, `code`, `state`, `key`, `api_key`, `secret`, `password`, `session`, `sig`) and `Authorization:` header lines. It is applied to every `adapter.error` message, every `connection.changed` message, every `turn.finished` error message, and every `recentErrors` entry before they leave the coordinator; adapters keep sending what they have, the coordinator is the boundary.
- The CLI-spawned coordinator's `coordinator.stdout.log` is bounded by the same copy-truncate as server logs (4 MiB, keep 1 MiB) before each spawn.
- Boundary audit (recorded in `docs/verification.md`): `WorkspaceUI` depends only on `WorkspaceProtocol` and `WorkspaceClient` (Package.swift); the credential value exists in `CredentialAdd.Params` on the socket and in `SecretStore.put` only; the router's operation cache holds responses, never params; no `print`/`os_log` of params anywhere in `Sources`.

## Decisions

- D-031 Snapshot merge rule (section 2).
- D-032 Quit offers stop-or-detach, not background; identity-changed and missing threads stay readable and never resume (sections 2, 5).
- D-033 Directory lock is derived from stored turns, not a separate lock table, so it survives restarts and holds through `reconciling` (section 3).
- D-034 Wake detection by clock gap in the coordinator plus `didWakeNotification` in the app (section 5).
- D-035 The coordinator redacts at its boundary; adapters do not (section 6).

## Not in M5

Removing registrations and changing ports (listed open after M4), model selection, the LaunchAgent, iOS transport, auto-titles, and any provider-side history rewrite.

## Tests

Fixture and integration tests through the real coordinator over the socket (`Tests/CoordinatorTests`): organization survives a restart (rename, pin, archive, unarchive, query, draft); snapshot merge after a restart with an empty cache and with a partial cache (no duplicates, order kept); missing Codex thread (`thr_missing`) → `continuity = missing` and `turn.send` refused; scope change (`FAKE_CODEX_EMAIL`) → `identity_changed`; directory lock across two Codex threads and one Claude thread, held through a crash; `swallow` and `late ack`; `turn.abandon` only from `reconciling`; auth expiry flips the connection; `workspace.activeWork`, `stopLocalWork` leaving an attached B4 run alone, `reconcile` finishing a B4 turn that completed while the coordinator was down; `SleepWatcher` with an injected clock; redaction of URL parameters, header lines, and an error path through diagnostics. Model-level tests (`WorkspaceUITests`, macOS) cover the sidebar state projection, archived visibility, draft debounce, and the remediation mapping. Live on this Mac: the CLI organization commands and a Quit of the macOS app while a Codex turn hangs, recorded in `docs/verification.md`; the dialog itself cannot be clicked without screen control and is recorded as such.
