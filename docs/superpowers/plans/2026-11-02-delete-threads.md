# Deleting threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete a thread from the Mac or the iPhone. It disappears everywhere, the runtime's copy is deleted where the runtime supports it, and the hub and Mac keep it marked deleted.

**Architecture:**
- **Marking.** A synced, phone-writable column `threads.userDeletedAt` marks a deleted thread. Every list and read on the Mac, the hub mirror and the phone skips it.
- **The runtime delete.** The Mac deletes the runtime's copy through a new `AgentAdapter.deleteSession`. A sweep finds marked threads whose runtime delete hasn't finished, whoever marked them, and retries those it couldn't reach.
- **Progress.** A local-only table `threadDeletes` records each runtime delete's progress.

**Tech Stack:** Swift 6 and SwiftUI (macOS 26 / iOS 26), swift-testing, PostgreSQL through `WorkspaceStorage`, SQLite through `WorkspaceMirror`, the Rust hub (sqlx), Python fixture runtimes.

**Spec:** `docs/superpowers/specs/2026-11-02-delete-threads-design.md`

## Global Constraints

- **Delete means hidden everywhere and never used for personal memory.** Thread rows, turns, items and drafts are kept on the Mac and the hub, and no SQL `DELETE` of thread data is added.
- **The confirmation, with no undo:**
  - Title: `Delete "<title>"?`
  - Message: `It's removed from this app and from <Codex | Claude Code | the B4 server>. You can't undo this.` When the connection is disabled, the message is `It's removed from this app. You can't undo this.`
  - While a turn runs, it adds `Its running turn will be stopped.`
  - Buttons: Cancel, and Delete (destructive).
- **Runtime outcomes:**
  - `deleted`, or `alreadyGone` (a B4 `404` counts) are done.
  - `unsupported` is final: Codex method-not-found, a B4 `405`, or the connection disabled.
  - A thrown error means unreachable, which is retried.
- **Claude:** delete only `<root>/<one folder>/<sessionId>.jsonl` and `<root>/<one folder>/<sessionId>/`, where `<root>` is `$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`. Refuse a session id that isn't `^[A-Za-z0-9_-]+$`.
- **No backwards compatibility** (owner, 2026-11-02): no gating for older hubs or builds.
- **Numbers:** Mac migration `0008_thread_delete`, hub migration `0011_thread_delete`, mirror schema version 5. They are stacked on `blove/phone-usage`, which holds Mac 0007, hub 0010 and mirror v4. Check every open branch for decision numbers before recording one.
- `swift format lint --strict` clean; hub `cargo fmt` and `clippy -D warnings` clean.

## Review Focus

1. **Deleting the thread open in the detail.** The detail closes, the draft isn't sent, and nothing crashes. Test in Task 7.
2. **Deleting while a turn runs.** The turn is interrupted before the runtime delete, and the thread doesn't come back when the turn's late `turn.finished` arrives. Tests in Task 4 and Task 7.
3. **A phone's delete while the Mac is offline.** When the Mac pulls it, the sweep deletes the runtime's copy. Test in Task 4 (the sweep finds a thread marked by the phone).
4. **A Claude session id with `/` or `..`.** Refused, and nothing outside the one session is removed. Test in Task 3.
5. **The runtime delete fails and later succeeds.** Retried with backoff, and the Diagnostics counts move from waiting to none. Test in Task 4.

---

### Task 1: Protocol

**Files:**
- Modify:
  - `Sources/WorkspaceProtocol/Domain.swift`: `ConversationThread.userDeletedAt: String?`, decoded as optional.
  - `Sources/WorkspaceProtocol/Commands.swift`: `case threadDelete = "thread.delete"`, a mutation.
  - `Sources/WorkspaceProtocol/Adapter.swift`: `SessionDeletion` and `AgentAdapter.deleteSession`.
  - `Sources/WorkspaceProtocol/HybridClock.swift`: `SyncColumns.phoneWritable["threads"]` adds `"userDeletedAt"`.
- Create: `Sources/WorkspaceProtocol/ThreadDelete.swift`, holding `enum ThreadDelete: WorkspaceCommand` and `struct ThreadDeleteSummary`.
- Test: `Tests/WorkspaceProtocolTests/ThreadDeleteTests.swift`, plus the mutation guard list in `ConversationCommandTests.swift` and the phone-writable guard.

**Interfaces (produces):**
- `enum ThreadDelete: WorkspaceCommand`: params `{ threadId: String }`, result `ThreadCreate.Result` (the thread, now with `userDeletedAt` set).
- `enum SessionDeletion: String, Codable, Sendable { case deleted, alreadyGone, unsupported }`.
- `func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion`, on `AgentAdapter`. A thrown error means unreachable. A protocol extension default returns `.unsupported`, so test adapters compile.
- `struct ThreadDeleteSummary: Codable, Sendable, Equatable { var kind: ConnectionKind; var waiting: Int; var unsupported: Int }`.
- `DiagnosticsReport.threadDeletes: [ThreadDeleteSummary]`, optional when decoding.

- [ ] **Step 1: Write the failing tests:**
  - `threadDeleteIsAMutationAndAllowlisted`;
  - `aThreadDecodesWithoutUserDeletedAt` (an old row decodes, and the field is nil);
  - `userDeletedAtIsPhoneWritable`;
  - update the mutation guard list (`ConversationCommandTests`), the phone-writable guard (`phoneWritableListIsExact`), and the hub parity comment.
- [ ] **Step 2: Run** `swift test --filter WorkspaceProtocolTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement the types above.** `Router` gets a placeholder `thread.delete` case until Task 4. `MirrorTransport.refusal` needs nothing.
- [ ] **Step 4: Run** `swift test --filter WorkspaceProtocolTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(protocol): thread.delete, userDeletedAt, adapter deleteSession`.

### Task 2: Mac storage

**Files:**
- Create:
  - `Sources/WorkspaceStorage/SQL/0008_thread_delete.sql`;
  - `Sources/WorkspaceStorage/ThreadDeletes.swift`.
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift`. `listThreads` always adds `t."userDeletedAt" IS NULL`; `thread(id:)` and the native lookup still return deleted rows (the coordinator needs them).
- Test:
  - `Tests/WorkspaceStorageTests/ThreadDeleteStoreTests.swift`;
  - the migration lists in `DatabaseTests` (add `0008_thread_delete`).

**SQL:**
- `ALTER TABLE "threads" ADD COLUMN "userDeletedAt" text;`
- `CREATE TABLE "threadDeletes" ("threadId" text PRIMARY KEY REFERENCES "threads"("id") ON DELETE CASCADE, "state" text NOT NULL CHECK ("state" IN ('waiting','done','unsupported')), "attempts" integer NOT NULL DEFAULT 0, "nextAttemptAt" text, "lastError" text, "updatedAt" text NOT NULL);`
- `threadDeletes` gets no trigger: it is local-only.

**Interfaces (produces, on `WorkspaceDatabase`):**
- `func markThreadDeleted(id: String, at: String) throws -> ConversationThread?`: sets `userDeletedAt` only when it is null, so a delete is never moved.
- `func threadsAwaitingRuntimeDelete(now: String) throws -> [ConversationThread]`: threads with `userDeletedAt` set and no `threadDeletes` row, or a `waiting` row whose `nextAttemptAt` is at or before `now`.
- `func recordThreadDelete(threadId: String, outcome: ThreadDeleteState, error: String?, nextAttemptAt: String?) throws`, where `ThreadDeleteState` is `waiting`, `done` or `unsupported`; it increments `attempts`.
- `func threadDeleteSummary() throws -> [ThreadDeleteSummary]`: counts by the thread's connection kind, plus deleted threads with no row yet, which count as waiting.

- [ ] **Step 1: Write the failing tests:**
  - `aDeletedThreadLeavesEveryList`: `listThreads` with and without archived omits it; `thread(id:)` still finds it.
  - `markingKeepsTheFirstTimeAndIsLogged`: the change log has a `threads` update for `userDeletedAt`; a second mark doesn't move the time.
  - `awaitingFollowsTheRecordAndItsBackoff`: a deleted thread is awaiting; after `waiting` with `nextAttemptAt` in the future it isn't, and after that time it is; after `done` or `unsupported` it never is.
  - `summaryCountsWaitingAndUnsupportedByKind`.
- [ ] **Step 2: Run** `swift test --filter ThreadDeleteStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter WorkspaceStorageTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(storage): userDeletedAt and local runtime-delete progress (0008)`.

### Task 3: Adapters

**Files:**
- Modify:
  - `Sources/CodexAdapter/CodexAdapter.swift`;
  - `Sources/ClaudeAdapter/ClaudeAdapter.swift`;
  - `Sources/B4Adapter/B4Adapter.swift` and `B4HTTPClient.swift` (a `DELETE` request);
  - the fixtures: `fake-codex.py` answers `thread/delete` (a known thread returns `{}`; an unknown one returns error code `-32602` with "not found"; `FAKE_CODEX_NO_DELETE=1` answers `-32601`), and `fake-b4.py` answers `DELETE /threads/:id` (`204` for a known thread, `404` for an unknown one, `405` when `FAKE_B4_NO_DELETE=1`).
- Test:
  - `Tests/CodexAdapterTests/CodexDeleteTests.swift`;
  - `Tests/ClaudeAdapterTests/ClaudeDeleteTests.swift`;
  - `Tests/B4AdapterTests/B4DeleteTests.swift`.

**Behaviour:**
- **Codex** calls `thread/delete { threadId }`:
  - success is `deleted`;
  - RPC error `-32601` is `unsupported`;
  - an error whose message says the thread isn't found (`-32602` or a message containing "not found") is `alreadyGone`;
  - anything else throws.
  - The thread is dropped from `loadedThreads`.
- **Claude** finds the root (`$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`, honouring the adapter's `environment`):
  - an id failing `^[A-Za-z0-9_-]+$` throws `protocolInvalid` and touches nothing;
  - it removes `<sessionId>.jsonl` and `<sessionId>/` in the one project folder that holds the transcript (reuse `transcript(sessionId:under:)`);
  - no transcript is `alreadyGone`;
  - success is `deleted`.
- **B4** sends `DELETE /threads/:id`: `204` or `200` is `deleted`, `404` is `alreadyGone`, `405` is `unsupported`, and anything else throws.

- [ ] **Step 1: Write the failing tests:**
  - Codex: `deletesAThread`, `aMissingThreadIsAlreadyGone`, `anOldCodexIsUnsupported`.
  - Claude:
    - `removesOnlyThatSession`: a temp root with `p1/s1.jsonl`, `p1/s1/sub.jsonl`, `p1/s2.jsonl`, `p2/other.txt`; after the delete only `s1` and its folder are gone.
    - `aMissingTranscriptIsAlreadyGone`.
    - `anUnsafeSessionIdIsRefused`: `../x` and `a/b` throw, and the files stay.
  - B4: `deletesAThread`, `aMissingThreadIsAlreadyGone`, `aServerWithoutTheRouteIsUnsupported`.
- [ ] **Step 2: Run** the three filters. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter "CodexAdapterTests|ClaudeAdapterTests|B4AdapterTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(adapters): delete a session in Codex, Claude Code, and B4`.

### Task 4: Coordinator

**Files:**
- Create: `Sources/Coordinator/ThreadDeleteService.swift`, an extension of `SessionService`.
- Modify:
  - `Router.swift`: `thread.delete`;
  - `SessionService.swift`: `start()` launches the sweep loop; `threadRead` answers `notFound` for a deleted thread; a late event for a deleted thread updates rows but publishes no `thread.updated` that clients would re-list;
  - `Diagnostics.swift`: `threadDeletes`;
  - `Coordinator.swift`: options `threadDeleteSweep: Duration`, default 60 s, zero in tests.
- Test: `Tests/CoordinatorTests/ThreadDeleteTests.swift`.

**Behaviour:**
- `threadDelete(_:)`:
  - interrupts an unresolved turn (best effort, waiting up to 10 s for it to settle);
  - `markThreadDeleted`;
  - publishes `thread.updated` with the thread, which now carries `userDeletedAt`;
  - then runs `sweepThreadDeletes()` for that thread at once.
- `sweepThreadDeletes()` handles each awaiting thread:
  - connection disabled or missing: `unsupported`;
  - otherwise `adapter.deleteSession(ref)` maps to `done` (`deleted`, `alreadyGone`) or `unsupported`;
  - a throw becomes `waiting`, with `nextAttemptAt = now + min(30 s × 2^(attempts), 1 h)` and the error message redacted.

- [ ] **Step 1: Write the failing tests:**
  - `deletingAThreadHidesItAndDeletesItInCodex`: `thread.list` omits it; `thread.read` is `notFound`; the fake Codex got `thread/delete`; Diagnostics shows no waiting.
  - `deletingStopsARunningTurnFirst`: a hanging B4 turn is interrupted, and the fake B4 then sees the `DELETE`.
  - `aPhonesDeleteIsSweptLater`: set `userDeletedAt` through `db.markThreadDeleted` directly, as a pull would, then run the sweep; the runtime delete happens.
  - `anUnreachableRuntimeIsRetried`: B4 stopped, so it is waiting with attempts 1; then B4 started and swept with the clock past `nextAttemptAt`, so it is done.
  - `anUnsupportedRuntimeIsFinal`: `FAKE_B4_NO_DELETE=1` gives unsupported, and a second sweep makes no request.
  - `aLateEventDoesNotBringTheThreadBack`.
- [ ] **Step 2: Run** `swift test --filter "CoordinatorTests.ThreadDeleteTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** The sweep takes an injectable `now` for the backoff test.
- [ ] **Step 4: Run** `swift test --filter CoordinatorTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(coordinator): thread.delete, the runtime-delete sweep, Diagnostics counts`.

### Task 5: Hub

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0011_thread_delete.sql`, containing `ALTER TABLE "threads" ADD COLUMN "userDeletedAt" text;`.
- Modify:
  - `b4hub-core/src/change.rs`: the threads columns add `"userDeletedAt"`;
  - `writable.rs`: `PHONE_WRITABLE` and `CLOCKED` add `("threads", "userDeletedAt")`;
  - `Hub/API.md`;
  - the migration guards in `tests/migrate.rs` (applied adds 11, count +1).
- Test: in `tests/changes.rs`, `a_phone_marks_a_thread_deleted_and_the_row_stays` (a phone update of `userDeletedAt` is applied by clock, and the row and its turns remain); `writable.rs` unit lists updated.

- [ ] **Step 1: Write the failing tests.**
- [ ] **Step 2: Run** `cd Hub && source <(./scripts/test-db.sh) && cargo test --workspace --locked`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** all three hub gates. Expected: PASS and clean.
- [ ] **Step 5: Commit** `feat(hub): threads carry userDeletedAt, phone-writable (0011)`.

### Task 6: Phone mirror

**Files:**
- Modify:
  - `MirrorSchema.swift`: version 5 adds `threads."userDeletedAt" TEXT`;
  - `MirrorStore.swift`: thread reads and lists exclude deleted threads, and `thread(id:)` still finds one for the event;
  - `MirrorWrites.swift`: `deleteThread(id:)` writes `userDeletedAt` and records an outbox update;
  - `MirrorTransport.swift`: serves `thread.delete` and publishes `thread.updated`;
  - the version guards in `MirrorMigrationTests` move up by one.
- Test: `Tests/WorkspaceMirrorTests/MirrorDeleteTests.swift`:
  - `thread.delete` on the phone hides the thread from `thread.list` and makes `thread.read` `notFound`;
  - the outbox holds one `threads` update for `userDeletedAt`;
  - a pulled `userDeletedAt` from the Mac hides it too.

- [ ] **Steps 1–5** as above. Run `swift test --filter "WorkspaceMirrorTests"`, then commit `feat(mirror): delete a thread from the phone`.

### Task 7: Apps

**Files:**
- Modify:
  - `WorkspaceModel.swift`: `thread.updated` with `userDeletedAt` removes the thread from `threads` and `activeTurns`, and closes `detail` if it was showing it;
  - `WorkspaceModel+Threads` (new file): `func deleteThread(id: String) async -> Bool` and `func deleteConfirmation(for thread: ConversationThread) -> (title: String, message: String)`;
  - `SidebarView.swift` (the row's context menu "Delete…");
  - `ThreadsView.swift` (the "…" menu "Delete…", and iOS `swipeActions` with a destructive Delete);
  - a shared `.confirmationAlert` modifier showing the spec's copy.
- Test: `Tests/WorkspaceUITests/ThreadDeleteModelTests.swift`:
  - `deletingTheOpenThreadClosesIt`;
  - `confirmationCopyNamesTheRuntime`: Codex reads `It's removed from this app and from Codex. You can't undo this.`; a disabled connection drops the runtime; a running turn appends `Its running turn will be stopped.`;
  - `aLateTurnEventForADeletedThreadKeepsItGone`.

- [ ] **Steps 1–5** as above.
- Then render the Mac snapshot of the alert, and check iOS in the Simulator (swipe, alert, and the row gone).
- Commit `feat(ui): delete a thread on the Mac and the iPhone`.

### Task 8: Records and PR

- [ ] **Decisions.** In `docs/decisions.md`, after checking every open branch for the highest number: the delete model, Claude transcript removal as in the desktop app, the runtime outcomes, no undo, and the `userDeletedAt` naming.
- [ ] **Compatibility.** In `docs/compatibility.md`: Codex `thread/delete` (0.166.0), B4 `DELETE /threads/:id` (0.15.8), Claude transcript removal (2.1.282, desktop app parity).
- [ ] **Milestones and verification.** Update `docs/milestones.md` and `docs/verification.md` with the gates, the tests, and the Simulator and Mac checks.
- [ ] **Gates.** `swift test`, lint, the hub's three gates, and both builds.
- [ ] **PR.** Push, open it with the base `main` (stacked on #46), and turn on auto-merge once #46 has merged.
