# M2 Claude Code Conversation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code threads with the same behavior as Codex threads: stream, permissions, questions, stop, resume after restart.

**Architecture:** `ClaudeSession` wraps one `claude` stream-json process per native session; `ClaudeTurnTracker` translates frames to `AdapterEvent`s; `ClaudeAdapter` manages sessions and pending control requests; `SessionService` gains a Claude factory, thread-scoped disconnects, and a generic login hook; the UI and CLI already speak the shared methods.

**Tech Stack:** Swift 6.2 tools, Foundation `Process` via `StreamingProcess`, Swift Testing, Python fixture.

**Spec:** `docs/superpowers/specs/2026-10-31-m2-claude-conversation-design.md`

## Global Constraints

- Claude Code minimum `2.1.200`; never pass `--bare`; strip `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from the child environment.
- No mocked behavior presented as working; live checks only behind `B4APP_LIVE_CLAUDE=1`, never in CI.
- Secrets never in arguments, JSON results, logs, or UI state. `claude auth status` output is reduced to the fields `ClaudeAuthStatus` declares.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; `docs/roadmaps/*.md` untouched.

## Review Focus

1. A `can_use_tool` answered twice must send exactly one `control_response` (Task 3 test).
2. A `result` with `subtype: success` and `is_error: true` is a failed turn, never completed (Task 2 test).
3. A Claude process exiting mid-turn must not expire Codex requests or mark the Codex connection offline (Task 4 test).
4. `--resume` of a deleted session surfaces `native_session_missing` and keeps the cached transcript (Task 3 test).
5. Interrupting a turn that then reports `result` must end as `cancelled`, not `completed` (Task 2 and Task 3 tests).

---

### Task 1: Tracker and fixture

**Files:** Create `Sources/ClaudeAdapter/ClaudeEvents.swift`, `Tests/ClaudeAdapterTests/ClaudeEventsTests.swift`, `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py`; Modify `Package.swift` (exclude `Fixtures`).

**Produces:** `struct ClaudeTurnTracker { init(connectionId:sessionId:generation:); mutating func beginTurn(uuid:); mutating func markInterruptRequested(); mutating func translate(_ frame: ClaudeStream.Frame) -> [AdapterEvent]; var activeTurnUuid: String?; mutating func processExited(status:) -> [AdapterEvent] }`; `enum ClaudeRequestKind { static func kind(subtype:toolName:) -> (RuntimeRequestKind, answerable: Bool) }`; `static func safePayload(_ request: ControlRequestFrame) -> JSONValue` (synthetic question ids); `static func snapshotItems(transcriptLines:) -> [SnapshotItem]`.

- [ ] Tests from the design's mapping list, including `is_error` success, interrupt → cancelled, tool_use + tool_result pairing, AskUserQuestion payload with `q0` ids, hook frames ignored, process exit with an active turn.
- [ ] Fixture script behaviors: `--version`, `auth status --json`, `auth login`, `--resume missing`, text triggers `tool`, `deny`, `question`, `elicitation`, `hang`, `crash`, `fail`.
- [ ] Commit `feat(claude): frame translation and fake CLI fixture`.

### Task 2: `ClaudeSession` and `ClaudeAdapter`

**Files:** Create `Sources/ClaudeAdapter/ClaudeSession.swift`; Rewrite `Sources/ClaudeAdapter/ClaudeAdapter.swift`; Create `Sources/WorkspaceProtocol/Login.swift` (`protocol LoginCapable`); Modify `Sources/CodexAdapter/CodexAdapter.swift` to conform; Test `Tests/ClaudeAdapterTests/ClaudeAdapterTests.swift` (new suite `ClaudeSessionTests`) and `Tests/ClaudeAdapterTests/ClaudeLiveTests.swift`.

- [ ] Tests: inspect through the fixture (ready, authenticated, scope email); create + stream a turn; tool permission allowed then stale; denied permission shows `is_error` result; question answers; elicitation auto-declined; hang + interrupt → cancelled; crash → `turn.finished failed` + thread-scoped disconnect; `--resume missing` → `native_session_missing`; `loadSession` from a transcript file the fixture writes.
- [ ] Commit `feat(claude): drive the claude CLI stream-json session`.

### Task 3: Coordinator, UI, CLI wiring

**Files:** Modify `Sources/Coordinator/SessionService.swift`, `Sources/WorkspaceUI/WorkspaceModel.swift`, `ConnectionsView.swift`, `TranscriptView.swift`, `NewThreadSheet.swift`; Test `Tests/CoordinatorTests/SessionTests.swift`.

- [ ] Test: Claude thread conversation over the socket; Codex and Claude threads listed together; a Claude crash leaves the Codex connection `ready` and its requests pending.
- [ ] Commit `feat(coordinator,ui): Claude Code connections and threads`.

### Task 4: Verification and docs

- [ ] `swift test`, lint, both `xcodebuild` targets; live test if signed in (record the signed-out result otherwise); update `docs/decisions.md` (D-015..D-018), `docs/compatibility.md`, `docs/milestones.md`, `docs/verification.md`, research note, README; push; open the PR.
