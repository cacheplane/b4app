# M5 Daily-Use Behavior and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Threads can be organized and keep their drafts, the sidebar shows per-thread state, every auth/allowance/compatibility/continuity failure names a next action, unknown outcomes have a deliberate way out, two harness turns never overlap in one directory, and Quit and wake behave as spec section 10.3 requires.

**Architecture:** Three new coordinator methods (`thread.reconcile`, `turn.abandon`, `workspace.activeWork`/`stopLocalWork`/`reconcile`) on the existing `SessionService`; two migrations (`connections.nativeScope`, `threads.continuity`); a snapshot merge in `WorkspaceStorage`; a `SleepWatcher` in the coordinator; redaction at the coordinator boundary; UI and CLI surfaces on top. No adapter protocol changes beyond a configurable Codex request timeout.

**Tech Stack:** Swift 6.3, GRDB, SwiftUI, Swift Testing, the three Python fixtures.

**Spec:** `docs/superpowers/specs/2026-10-31-m5-daily-use-recovery-design.md`

## Global Constraints

- Nothing is ever re-sent to a runtime by reconciliation, reconnection, wake, or Quit.
- Secrets never appear in arguments, results, events, logs, or UI state; the coordinator redacts messages before publishing.
- Uncertain outcomes stay `reconciling` until a runtime answers or the user abandons the turn.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; `docs/decisions.md`, `docs/milestones.md`, `docs/verification.md`, `README.md` updated.

## Review Focus

1. A draft typed and then the app quit within 600 ms: `persistDraftNow()` at termination must flush it (Task 1 test saves through the model path).
2. Reopening a thread whose cache already holds live items: the snapshot merge must not duplicate the user message or reorder live items (Task 2 partial-cache test).
3. A Codex account change between launches: old threads read fine, refuse to send, and the UI says why (Task 2 scope test).
4. Two threads in the same directory where the first turn crashed: the lock must hold while that turn is `reconciling` and release on abandon (Task 3 test).
5. Quit while an attached B4 run is in flight: `stopLocalWork` must leave it running and the dialog must say so (Task 5 test and wording).

---

### Task 1: Thread organization, sidebar state, drafts, CLI

**Files:** Modify `Sources/WorkspaceProtocol/Commands.swift` (`EventsSnapshot.Result.activeTurns: [Turn]`), `Sources/Coordinator/Router.swift`, `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`unresolvedTurns()` already exists), `Sources/WorkspaceUI/WorkspaceModel.swift`, `ThreadsView.swift`, `WorkspaceRootView.swift`, `ComposerView.swift`, `Sources/AgentWorkspaceCLI/ConversationCommands.swift`, `Format.swift`; Test `Tests/CoordinatorTests/SessionTests.swift` (`ThreadOrganizationTests`), new `Tests/WorkspaceUITests/WorkspaceModelTests.swift` (+ `Package.swift` test target, macOS only).

**Produces:** `EventsSnapshot.Result(epoch:sequence:connections:threads:activeTurns:)`; `WorkspaceModel.activeTurns: [String: Turn]`, `showArchived: Bool`, `archivedThreads`, `threadState(_:) -> ThreadRowState`, `persistDraftNow()`, `scheduleDraftSave()`; CLI `thread update`.

- [ ] Test (coordinator): rename, pin, archive, query, draft, restart the coordinator, read back; `thread.list` excludes archived by default and includes with `includeArchived`; unarchive; snapshot carries a hanging turn in `activeTurns`.
- [ ] Test (model, fake transport that answers snapshot/replay): rows reflect `turn.state_changed` and `turn.finished`; archived threads hidden until `showArchived`; draft debounce saves once.
- [ ] Implement; `swift test --filter "ThreadOrganizationTests|WorkspaceModelTests"`; commit `feat(workspace): thread organization, sidebar state, drafts, thread update CLI`.

### Task 2: Continuity: migrations, snapshot merge, `thread.reconcile`

**Files:** Modify `Sources/WorkspaceStorage/Migrations.swift` (`v3`), `Records.swift`, `WorkspaceDatabase.swift` (`mergeSnapshotItems(threadId:items:)`, `updateThreadContinuity`), `Sources/WorkspaceProtocol/Domain.swift` (`Connection.nativeScope: String?`, `ConversationThread.continuity: ThreadContinuity`), `Errors.swift` (`identityChanged`), `Commands.swift` (`ThreadReconcile`), `Sources/Coordinator/SessionService.swift`, `Router.swift`, `Sources/WorkspaceUI/*` (banner, composer disabled), `Sources/AgentWorkspaceCLI/*` (`thread show --reconcile`); fixture `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (`FAKE_CODEX_EMAIL`); Tests `Tests/WorkspaceStorageTests/ConversationStorageTests.swift`, `Tests/CoordinatorTests/SessionTests.swift` (`ContinuityTests`).

**Produces:** `enum ThreadContinuity: String { available, missing, identityChanged = "identity_changed" }`; `WorkspaceDatabase.mergeSnapshotItems(threadId: String, items: [SnapshotItem]) -> (inserted: Int, updated: Int, skipped: Int)`; `SessionService.threadReconcile(_:) -> ThreadRead.Result`.

- [ ] Storage test: merge with empty cache inserts in order; merge with a live user item (no native id) and a live assistant item (native id) updates/skips and keeps sequences; a second merge is a no-op.
- [ ] Coordinator tests: after a restart with the display cache wiped, `thread.reconcile` rebuilds history from `thread/turns/list` without duplicating the live user message; `thr_missing` → `missing`, `turn.send` refused `native_session_missing`; `FAKE_CODEX_EMAIL` change across restart → `identity_changed`, send refused `identity_changed`, read still returns the cache.
- [ ] Implement; `swift test --filter "ConversationStorageTests|ContinuityTests"`; commit `feat(coordinator): native continuity, snapshot merge, thread.reconcile`.

### Task 3: Deliberate recovery, directory lock, ambiguous sends

**Files:** Modify `Sources/WorkspaceProtocol/Commands.swift` (`TurnAbandon`), `Sources/Coordinator/SessionService.swift` (`turnAbandon`, `assertDirectoryFree`), `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`activeHarnessTurns() -> [(Turn, ConversationThread)]`), `Sources/CodexAdapter/CodexAdapter.swift` (request timeout from `B4APP_CODEX_REQUEST_TIMEOUT`), fixture `fake-codex.py` (`swallow`, `late ack`), `Sources/WorkspaceUI/ComposerView.swift` (Check again / Abandon), `Sources/AgentWorkspaceCLI/ConversationCommands.swift` (`turn abandon`); Test `Tests/CoordinatorTests/SessionTests.swift` (`RecoveryTests`).

- [ ] Tests: lock across two Codex threads in one directory (second refused `directory_locked` naming the first), a Claude thread in the same directory also refused, another directory allowed, held after `crash`, released by `turn.abandon`; `turn.abandon` refused for a running turn; `swallow` → `submission_unknown`, reconcile stays unknown, resend refused, abandon then send works with exactly one fixture turn per send; `late ack` → completed with one native turn.
- [ ] Implement; `swift test --filter RecoveryTests`; commit `feat(coordinator): turn.abandon, directory lock, ambiguous-send handling`.

### Task 4: Actionable failures

**Files:** Modify `Sources/Coordinator/SessionService.swift` (`noteFailure(code:connection:)`), new `Sources/WorkspaceUI/Remediation.swift`, `WorkspaceModel.swift` (`lastFailure`), `ComposerView.swift`, `ConnectionsView.swift`; fixture `fake-codex.py` (`signout` → failed turn with `codexErrorInfo: unauthorized`); Tests `Tests/CoordinatorTests/SessionTests.swift` (`FailureTests`), `Tests/WorkspaceUITests/RemediationTests.swift`.

- [ ] Tests: a `signout` turn flips the connection to `auth_required` with a `connection.changed` event and `doctor` lists the error; `Remediation.for` returns the expected action per code.
- [ ] Implement; commit `feat(workspace): actionable auth, allowance, and compatibility failures`.

### Task 5: Lifecycle: activeWork, stopLocalWork, reconcile, SleepWatcher, Quit, wake

**Files:** Modify `Sources/WorkspaceProtocol/Commands.swift` (`WorkspaceActiveWork`, `WorkspaceStopLocalWork`, `WorkspaceReconcile`), `Sources/Coordinator/SessionService.swift`, `Router.swift`, `Coordinator.swift`, new `Sources/Coordinator/SleepWatcher.swift`, `Apps/macOS/B4App/B4AppMac.swift` (Quit alert, wake observer), `Sources/WorkspaceUI/WorkspaceModel.swift` (`handleWake()`, `activeWork()`, `stopLocalWork()`); Tests `Tests/CoordinatorTests/SessionTests.swift` (`LifecycleTests`), `Tests/CoordinatorTests/SleepWatcherTests.swift`.

- [ ] Tests: `activeWork` lists a hanging Codex turn as local and a hanging attached B4 turn as remote; `stopLocalWork` cancels the Codex turn and leaves the B4 run active (then the test cancels it); a B4 `slow` turn finished while the coordinator was down → `workspace.reconcile` reports it `completed`; `SleepWatcher.tick` fires once for a 25 s gap and not for 5 s.
- [ ] Implement; commit `feat(lifecycle): active work, stop-or-detach Quit, wake reconciliation`.

### Task 6: Redaction at the boundary, bounded coordinator log, audit

**Files:** Modify `Sources/WorkspacePlatform/LogRedactor.swift`, `Sources/Coordinator/SessionService.swift`, `Diagnostics.swift`, `Launcher.swift`; fixture `fake-codex.py` (`leak` → failed turn whose message holds a bearer, an `sk-` key, and a URL with `access_token`); Tests `Tests/WorkspacePlatformTests/LogRedactorTests.swift`, `Tests/CoordinatorTests/SessionTests.swift` (`RedactionTests`).

- [ ] Tests: URL parameters and header lines masked; a `leak` turn's `turn.finished` payload and `doctor` `recentErrors` contain `[redacted]` and not the values.
- [ ] Implement; grep audit for `print(`/params logging; commit `fix(coordinator): redact at the boundary and bound the coordinator log`.

### Task 7: Docs, lint, app builds, live checks, PR

- [ ] `docs/decisions.md` D-031 to D-035; `docs/milestones.md` M5 section; `docs/verification.md` M5 section (automated table, CLI live table, Quit noted as not clicked); `README.md` status M5 and CLI additions; `AGENTS.md` unchanged unless a command changed.
- [ ] `swift format lint --strict …`, `swift build`, `swift test`, both `xcodebuild` builds, `./Scripts/generate-project.sh` if `project.yml` changed.
- [ ] Push `feat/m5-daily-use-recovery`, open the PR against `main`.
