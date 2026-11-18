# Approval Choices (step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A request card offers only the allow choices its runtime applies, an unsupported wider allow is refused, and a `multiSelect` question takes several answers.

**Architecture:** Each adapter writes `allowScope` (`session` or `always`) into the request payload it already builds. One Foundation-only type in `WorkspaceProtocol` reads it, so the coordinator (refusal), the card (buttons) and the CLI (hint) agree. The card's choices are decided by a pure type in `WorkspaceUI`.

**Tech Stack:** Swift 6, Swift Testing, the fake runtimes under `Tests/*/Fixtures`.

**Spec:** `docs/superpowers/specs/2026-11-17-approval-choices-design.md` (step 1 only; step 2 has its own plan after its live recording).

## Global Constraints

- `WorkspaceProtocol` stays Foundation-only; `WorkspaceUI` talks only to `WorkspaceClient`.
- The wire decision stays `allow_always` for both wider buttons. No migration, no wire change.
- Labels, exactly: "Allow once", "Allow for session", "Always allow", "Deny".
- An adapter never narrows `allow_always`; it refuses with `unsupportedCapability`.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean; decision numbered at PR time.

## Review Focus

- A request stored before this change (no `allowScope`) on Codex: the card offers once and deny only. Acceptable; pending requests do not outlive a turn.
- A phone on an older build sending `allow_always` to a Claude Code request: refused with a message, the request stays pending.
- A `multiSelect` question with `isOther`: chosen labels in option order, then the typed text.
- A question with no options and `multiSelect: true`: a text field, as now.
- The refusal must not claim the request (`answering`) for good: a second, valid answer still goes through.

---

### Task 1: `AllowScope` in `WorkspaceProtocol`

**Files:** Create `Sources/WorkspaceProtocol/AllowScope.swift`; test `Tests/WorkspaceProtocolTests/AllowScopeTests.swift`.

**Interfaces — Produces:** `public enum AllowScope: String, Sendable, Equatable { case session, always }`, `public static let payloadKey = "allowScope"`, `public init?(requestPayload: JSONValue)` reading `payload["request"]["allowScope"]`.

- [ ] Test: `session`, `always`, absent and an unknown string (nil). Run, fail. Implement. Run, pass. Commit.

### Task 2: adapters set the scope and refuse what they cannot apply

**Files:** `Sources/CodexAdapter/CodexProtocol.swift`, `Sources/B4Adapter/{B4TurnTranslator,B4Protocol,B4Adapter}.swift`, `Sources/ClaudeAdapter/ClaudeAdapter.swift`; their tests.

- [ ] Codex: `safeRequestPayload` adds `allowScope: "session"` for `commandApproval`, `fileChangeApproval`, `legacyExecApproval`, `legacyPatchApproval`, and for no other method. Test in `CodexEventsTests`.
- [ ] B4: the interrupt's request carries `allowScope: "always"` when `allowAlways` is true and no `allowScope` when false. `B4Protocol.resumeDecision(_:allowAlways:)` throws `unsupportedCapability` for `.allowAlways` with `allowAlways: false`. Tests in `B4TranslatorTests` (replace the `== .once` expectation).
- [ ] Claude Code: `.decision(.allowAlways)` on a tool permission throws `unsupportedCapability`; no `allowScope` is set. Test in `ClaudeSessionTests` with the fake's permission prompt; the request stays answerable with `.allowOnce` afterwards.
- [ ] Run each adapter's suite. Commit.

### Task 3: the coordinator refuses an unsupported wider allow

**Files:** `Sources/Coordinator/SessionService.swift` (`requestRespond`), `Tests/CoordinatorTests/SessionTests.swift`.

- [ ] Test: a Claude permission request answered `allow_always` throws `unsupportedCapability`, the request is still `pending`, and `allow_once` then resolves it. The existing Codex `allow_always` test still passes.
- [ ] Implement: after the `pending` guard and before `answering.insert`, `if params.decision == .allowAlways, AllowScope(requestPayload: request.payload) == nil { throw … }`.
- [ ] Run `CoordinatorTests`. Commit.

### Task 4: the card's choices, multi-select, and the CLI hint

**Files:** Create `Sources/WorkspaceUI/RequestChoices.swift`; modify `Sources/WorkspaceUI/RuntimeRequestView.swift`, `Sources/AgentWorkspaceCLI/{Format,ConversationCommands}.swift`; test `Tests/WorkspaceUITests/RequestChoicesTests.swift`.

**Interfaces — Produces:**
- `struct RequestChoices { struct Choice: Equatable { let decision: RuntimeDecision; let label: String; let identifier: String }; init(request: RuntimeRequest); let choices: [Choice] }` — once, the wider one when a scope exists, deny, in that order; identifiers `allow-once`, `allow-wider`, `deny`.
- `static func answer(options: [String], chosen: Set<String>, other: String) -> [String]` — chosen labels in option order, then trimmed `other` when not empty.
- `static func isMultiSelect(_ question: JSONValue) -> Bool` — `multiSelect` true and at least one option.

- [ ] Tests for the three button sets, the answer order, and `isMultiSelect`. Run, fail. Implement. Run, pass.
- [ ] Card: buttons from `RequestChoices`; a multi-select question draws a `Toggle` per option; "Submit answers" sends `[String: [String]]`.
- [ ] CLI: the answer hint lists `--accept-session` only when the request has a scope; the flag's help says "where the request offers it".
- [ ] Build both apps' shared target (`swift build`). Commit.

### Task 5: docs

- [ ] Decision (number at PR time; amends D-018, D-021), verification record, `docs/milestones.md`, `docs/compatibility.md` line 322's D-018 clause.
- [ ] Lint, both test shards, `Scripts/docs-index.sh --check`.
