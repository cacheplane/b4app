# New-Thread Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the new-thread sheets with a blank, focused composer (Mac empty pane, iPhone pushed screen) whose picker row chooses project · folder, permissions, and runtime · model; Send creates the thread and its first turn; model and permissions stay changeable inside a thread; every project folder is attached to a thread; the directory lock goes.

**Architecture:** Three layers, landed bottom-up so every merged step leaves both apps working. (1) Protocol, storage, and sync: a runtime-options catalog, new synced columns (`threads.model`, `threads.permission`, `connections.models`), `thread.update` carrying them. (2) Coordinator and adapters: each turn carries model, permission, and extra directories into Codex (`turn/start` overrides) and Claude (launch flags plus `set_model` / `set_permission_mode` control requests); `thread.start` becomes callable locally and owns the start validation; the directory lock is deleted. (3) UI: one `NewThreadDraft` model for both platforms, an extracted composer field, a picker row, the Mac empty pane, and the iPhone list cleanup.

**Tech Stack:** Swift 6 / SwiftUI (macOS 26, iOS 26), Swift Testing, PostgreSQL (coordinator), SQLite via the mirror (phone), Rust hub (sqlx, PostgreSQL), Python fake runtimes.

**Spec:** `docs/superpowers/specs/2026-11-03-new-thread-composer-design.md`

**Suggested pull requests:** Tasks 1–9 (runtime plumbing, no visible UI change beyond the lock's remediation copy going away); Tasks 10–13 (Mac); Tasks 14–15 (iPhone and docs/gate). Each PR takes its decision numbers with `Scripts/docs-index.sh --next` when it opens.

## Global Constraints

- `swift format lint --strict --recursive Sources Tests Apps Package.swift` passes; `swift build`, `swift test`, and both `xcodebuild` schemes (`B4App-macOS` on `platform=macOS`, `B4App-iOS` on `generic/platform=iOS Simulator`) build.
- Hub: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, and `cargo test --workspace --locked` (via `source <(./scripts/test-db.sh)`) pass from `Hub/`.
- `WorkspaceProtocol`, `WorkspaceClient` stay Foundation-only; `WorkspaceUI` talks only to `WorkspaceClient` (and never imports `WorkspaceMirror`, `WorkspaceSync`, `WorkspaceStorage`).
- `SessionService` stays the only writer of threads and turns.
- A fixture in `Tests/Fixtures/sync/` changes only in a commit that updates both the Swift and the Rust suite.
- Never show a capability as working when it is not: no + (attach) or mic button is drawn; a picker the runtime cannot honour is disabled with its reason, or the adapter throws `WorkspaceError(.unsupportedCapability)`.
- LLA visual rules (`docs/superpowers/specs/2026-10-31-lla-visual-system-design.md`): picker labels are 13 pt (`LLAFont.small` on the Mac) muted text with a chevron, no chips, icons, or colour; the accent only for focus and caret; runtime marks via `RuntimeMark`.
- Copy, exactly: "As configured" (no override); Claude permissions "Ask permissions" (`default`), "Accept edits" (`acceptEdits`), "Plan mode" (`plan`), "Bypass permissions" (`bypassPermissions`); Codex permissions "Read only" (`read-only`), "Auto" (`auto`), "Full access" (`full-access`); model "Default" (no override); the menu group "Remote B4"; the project item "Choose folder…"; the project placeholder "No project"; the iPhone field "New thread"; the screen title "New thread".
- Decisions are files `docs/decisions/D-NNN-<slug>.md` (first line `## YYYY-MM-DD (topic)`, then one `- **D-NNN Title.** …` bullet); never edit an earlier decision or `docs/roadmaps/*.md`; `Scripts/docs-index.sh --check` passes.
- Secrets never in arguments, results, logs, or UI state (nothing here touches secrets).

## Review Focus

- **The runtime refuses between picking and Send** (Mac goes offline, connection not ready, project deleted): the composer keeps the text, shows the refusal, creates no thread. → Task 12 test `startRefusedKeepsTheText`.
- **Send pressed twice** (double click, Return then click, a relay resend): exactly one thread and one turn. → Task 8 test `localThreadStartIsIdempotentPerOperation`; Task 12 test `secondSendWhileStartingIsIgnored`.
- **Model or permission changed while a turn runs**: the running turn is unaffected; the next turn carries the change. → Task 7 test `aChangeDuringATurnAppliesToTheNextTurn`.
- **Project folders change between turns of a Claude thread**: the conversation continues (resume), and the next turn has the new `--add-dir` set. → Task 6 test `changedDirectoriesRestartWithResume`.
- **The remembered project or folder no longer exists** (deleted, folder removed, connection removed): the draft falls back to the next valid choice instead of offering a dead one. → Task 11 test `staleMemoryFallsBackToAValidChoice`.

---

## Phase 1 — Protocol, storage, sync

### Task 1: Runtime options catalog

**Files:**
- Create: `Sources/WorkspaceProtocol/RuntimeOptions.swift`
- Test: `Tests/WorkspaceProtocolTests/RuntimeOptionsTests.swift`

**Interfaces:**
- Produces:
  - `public struct RuntimeModel: Codable, Sendable, Equatable, Identifiable { public var id: String; public var label: String }`
  - `public struct PermissionOption: Sendable, Equatable, Identifiable { public var id: String; public var label: String }`
  - `public enum RuntimeOptions` with `static let asConfiguredLabel = "As configured"`, `static let defaultModelLabel = "Default"`, `static let claudeModels: [RuntimeModel]` (`opus`/"Opus", `sonnet`/"Sonnet", `haiku`/"Haiku"), `static func permissions(for kind: ConnectionKind) -> [PermissionOption]` (Claude four, Codex three, B4 empty, in the Global Constraints order), `static func permissionLabel(_ id: String?, kind: ConnectionKind) -> String` (nil → "As configured", unknown id → the id).
  - `public enum CodexPermission: String { case readOnly = "read-only", auto, fullAccess = "full-access" }` with `var approvalPolicy: String` (`on-request`, `on-request`, `never`) and `func sandboxPolicy(writableRoots: [String]) -> JSONValue` (`{"type":"readOnly"}`, `{"type":"workspaceWrite","writableRoots":[…]}`, `{"type":"dangerFullAccess"}`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func eachRuntimeOffersItsOwnPermissions() {
  #expect(RuntimeOptions.permissions(for: .claude).map(\.id) == ["default", "acceptEdits", "plan", "bypassPermissions"])
  #expect(RuntimeOptions.permissions(for: .claude).map(\.label) == ["Ask permissions", "Accept edits", "Plan mode", "Bypass permissions"])
  #expect(RuntimeOptions.permissions(for: .codex).map(\.id) == ["read-only", "auto", "full-access"])
  #expect(RuntimeOptions.permissions(for: .codex).map(\.label) == ["Read only", "Auto", "Full access"])
  #expect(RuntimeOptions.permissions(for: .b4).isEmpty)
  #expect(RuntimeOptions.permissionLabel(nil, kind: .codex) == "As configured")
}

@Test func codexPresetsMapToPolicyAndSandbox() {
  #expect(CodexPermission.auto.approvalPolicy == "on-request")
  #expect(CodexPermission.fullAccess.approvalPolicy == "never")
  #expect(CodexPermission.auto.sandboxPolicy(writableRoots: ["/a"]) == ["type": "workspaceWrite", "writableRoots": ["/a"]])
  #expect(CodexPermission.readOnly.sandboxPolicy(writableRoots: ["/a"]) == ["type": "readOnly"])
  #expect(CodexPermission.fullAccess.sandboxPolicy(writableRoots: []) == ["type": "dangerFullAccess"])
}
```

- [ ] **Step 2: Run** `swift test --filter RuntimeOptionsTests` — Expected: FAIL (types not defined).
- [ ] **Step 3: Implement `RuntimeOptions.swift`** with the interfaces above. Comment that Codex's three presets are its `/approvals` menu and that the shapes are from `codex app-server generate-json-schema` for 0.166.0 (`TurnStartParams.sandboxPolicy`, `AskForApproval`).
- [ ] **Step 4: Run** `swift test --filter RuntimeOptionsTests` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(protocol): runtime model and permission catalog`.

### Task 2: Synced columns for a thread's model and permission and a connection's models

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0009_thread_runtime_choice.sql`
- Create: `Hub/crates/b4hub-db/migrations/0017_thread_runtime_choice.sql`
- Modify: `Sources/WorkspaceProtocol/Domain.swift` (`ConversationThread`, `Connection`)
- Modify: `Sources/WorkspaceProtocol/HybridClock.swift` (`SyncColumns.phoneWritable`, `clocked`)
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (add `(6, version6)`; JSON-column map gains `connections.models`)
- Modify: `Hub/crates/b4hub-core/src/change.rs` (`TableSpec` columns for `threads` and `connections`)
- Modify: `Hub/crates/b4hub-core/src/writable.rs` (`PHONE_WRITABLE`, `CLOCKED`; the length test 9 → 11)
- Modify: `Tests/Fixtures/sync/changes.json` (thread insert gains `"model": null, "permission": null`; add one thread `update` change with `column: "permission"`, value `"plan"`)
- Test: `Tests/WorkspaceStorageTests/ChangeLogTests.swift`, `Tests/WorkspaceStorageTests/RemoteApplyTests.swift`, `Tests/WorkspaceMirrorTests/MirrorMigrationTests.swift`, the hub's existing fixture tests

**Interfaces:**
- Produces: `ConversationThread.model: String?`, `ConversationThread.permission: String?` (nil = never overridden; a value is a `RuntimeModel.id` / `PermissionOption.id`); `Connection.models: [RuntimeModel]?` (nil for B4 and until inspected). `SyncColumns.phoneWritable["threads"]` gains `"model"`, `"permission"`.

- [ ] **Step 1: Write the failing tests**
  - `ChangeLogTests.threadModelAndPermissionAreClocked`: update a thread's `permission` to `"plan"`; assert one `update` change with `column == "permission"` and a clock, and that the SQL clocked list equals `SyncColumns.clocked["threads"]` (extend the existing equality test if it enumerates tables).
  - `RemoteApplyTests.aPhonePermissionChangeIsApplied`: apply a remote `threads` update `permission = "acceptEdits"` from a phone device; assert `thread(id:).permission == "acceptEdits"`.
  - `MirrorMigrationTests.version6AddsRuntimeChoiceColumns`: open a version-5 mirror, migrate; assert `PRAGMA table_info(threads)` has `model`, `permission` and `connections` has `models`, and a decoded `Connection` round-trips `models`.
- [ ] **Step 2: Run** `swift test --filter "ChangeLogTests|RemoteApplyTests|MirrorMigrationTests"` — Expected: FAIL.
- [ ] **Step 3: Write `0009_thread_runtime_choice.sql`:** `ALTER TABLE threads ADD COLUMN "model" text, ADD COLUMN "permission" text; ALTER TABLE connections ADD COLUMN "models" <same type as "capabilities">;` then `CREATE OR REPLACE FUNCTION b4app_record_change()` copied from `0008_thread_delete.sql:8-60` with the threads clocked array extended by `'model','permission'`.
- [ ] **Step 4: Update `Domain.swift`, `HybridClock.swift`, `MirrorSchema.swift`** to the interfaces above (`version6`: `ALTER TABLE threads ADD COLUMN model TEXT; … permission TEXT; ALTER TABLE connections ADD COLUMN models TEXT;`).
- [ ] **Step 5: Hub:** `0017_thread_runtime_choice.sql` adds the same three nullable columns (`models` typed as the hub's `capabilities` column); add the names to `change.rs`'s `threads` and `connections` specs and to `writable.rs` (`("threads","model")`, `("threads","permission")` in both `PHONE_WRITABLE` and `CLOCKED`; length assertion 11).
- [ ] **Step 6: Update `changes.json`** as listed under Files.
- [ ] **Step 7: Run** `swift test` and, from `Hub/`, `cargo test --workspace --locked` — Expected: PASS (including `every_fixture_row_uses_only_known_columns` and the Swift fixture decoders).
- [ ] **Step 8: Commit** `feat(sync): a thread's model and permission and a connection's models sync`.

### Task 3: `thread.update` carries model and permission on both devices

**Files:**
- Modify: `Sources/WorkspaceProtocol/Commands.swift` (`ThreadUpdate.Params`)
- Modify: `Sources/Coordinator/SessionService.swift:530` (`threadUpdate`)
- Modify: `Sources/WorkspaceMirror/MirrorWrites.swift:26` (`updateThread`), `Sources/WorkspaceMirror/MirrorTransport.swift:472`
- Test: `Tests/CoordinatorTests/SessionTests.swift`, `Tests/WorkspaceMirrorTests/MirrorWritesTests.swift`

**Interfaces:**
- Consumes: Task 1 `RuntimeOptions`, Task 2 columns.
- Produces: `ThreadUpdate.Params` gains `model: String?`, `permission: String?` (nil = unchanged). The coordinator refuses `protocol_invalid` with `reason: "unknown_permission"` when `permission` is not in `RuntimeOptions.permissions(for:)` of the thread's connection kind, and `reason: "not_supported_for_b4"` for either field on a B4 thread. `MirrorStore.updateThread(id:title:pinned:archived:model:permission:)` queues one outbox `update` per given field.

- [ ] **Step 1: Write the failing tests** — `SessionTests.threadUpdateStoresModelAndPermission` (Claude thread, update `permission: "plan", model: "opus"`, reread, assert both), `SessionTests.threadUpdateRefusesAnotherRuntimesPermission` (Claude thread, `permission: "full-access"` → `protocolInvalid`, reason `unknown_permission`), `MirrorWritesTests.permissionChangeQueuesAnUpdate` (assert one outbox row `table "threads", column "permission", value "plan"`).
- [ ] **Step 2: Run** `swift test --filter "SessionTests.threadUpdate|MirrorWritesTests"` — Expected: FAIL.
- [ ] **Step 3: Implement** the param fields, the validation in `SessionService.threadUpdate`, and the mirror write.
- [ ] **Step 4: Run** the same filter — Expected: PASS.
- [ ] **Step 5: Commit** `feat: thread.update sets a thread's model and permission`.

## Phase 2 — Adapters

### Task 4: Turn and session inputs carry the runtime choice

**Files:**
- Modify: `Sources/WorkspaceProtocol/Adapter.swift:32-41,101-110`
- Modify: `Sources/WorkspaceProtocol/Adapter.swift:1-30` (`ConnectionInspection` gains `models`)
- Modify: `Sources/Coordinator/SessionService.swift:312` (store `inspection.models` on the connection)
- Test: `Tests/CoordinatorTests/SessionTests.swift`

**Interfaces:**
- Produces:
  - `NewSessionInput` gains `permission: String?`, `additionalDirectories: [String]` (default `[]`); its existing `model` is now read.
  - `TurnInput` gains `model: String?`, `permission: String?`, `additionalDirectories: [String]` (defaults nil/nil/`[]`, so existing call sites compile).
  - `ConnectionInspection.models: [RuntimeModel]?` (default nil); `SessionService` copies it to `Connection.models` wherever it copies `capabilities`.

- [ ] **Step 1: Implement** the fields and the copy (no behaviour yet; Tasks 5–6 fill them and test them, including `SessionTests.inspectionModelsReachTheConnection` in Task 6).
- [ ] **Step 2: Run** `swift build && swift test` — Expected: builds; existing tests PASS.
- [ ] **Step 3: Commit** `feat(protocol): turns and sessions carry model, permission, and extra directories`.

### Task 5: Codex takes model, permission, and writable roots per turn

**Files:**
- Modify: `Sources/CodexAdapter/CodexProtocol.swift:40-73` (`threadStartParams`, `turnStartParams`, new `modelListParams`)
- Modify: `Sources/CodexAdapter/CodexAdapter.swift` (`createSession` :236, `sendTurn` :298, `inspectConnection`, remove nothing from `threadPolicy`)
- Modify: `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (record params; implement `model/list`)
- Test: `Tests/CodexAdapterTests/CodexAppServerTests.swift`

**Interfaces:**
- Consumes: Task 1 `CodexPermission`, Task 4 inputs.
- Produces:
  - `CodexProtocol.turnStartParams(threadId:text:cwd:model:permission:writableRoots:)`: adds `"model"` when non-nil; when `permission` is a `CodexPermission`, adds `"approvalPolicy"` and `"sandboxPolicy"` (writable roots only for `auto`); nil permission adds neither ("As configured", D-012).
  - `CodexProtocol.threadStartParams(cwd:policy:model:)` adds `"model"` when non-nil (permissions go on the first `turn/start`, which applies "to this turn and subsequent turns").
  - `inspectConnection` calls `model/list` (`{"includeHidden": false}`), maps each `data[]` entry to `RuntimeModel(id: model, label: displayName)` in order; a `-32601` or any error leaves `models` nil and is not a connection failure.
  - fake-codex: when `FAKE_CODEX_PARAMS` is set, appends each request as one JSON line `{"method":…, "params":…}` to that file; `model/list` answers `{"data":[{"id":"gpt-fake","model":"gpt-fake","displayName":"GPT Fake","description":"","hidden":false,"isDefault":true,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[]}]}`.

- [ ] **Step 1: Failing tests** — `turnCarriesModelAndAutoWithWritableRoots` (send a turn with `model: "gpt-fake", permission: "auto", additionalDirectories: ["/x"]`; read the params file; assert the `turn/start` params contain `"model":"gpt-fake"`, `"approvalPolicy":"on-request"`, `"sandboxPolicy":{"type":"workspaceWrite","writableRoots":["/x"]}`), `asConfiguredSendsNoPolicy` (permission nil → `turn/start` has no `approvalPolicy` and no `sandboxPolicy` keys), `inspectionListsModels` (`inspection.models == [RuntimeModel(id: "gpt-fake", label: "GPT Fake")]`).
- [ ] **Step 2: Run** `swift test --filter CodexAppServerTests` — Expected: FAIL.
- [ ] **Step 3: Implement** per Interfaces. Keep `threadPolicy` (the live approval test uses it).
- [ ] **Step 4: Run** `swift test --filter CodexAppServerTests` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(codex): per-turn model, permission preset, and writable roots`.

### Task 6: Claude takes model, permission, and extra directories

**Files:**
- Modify: `Sources/ClaudeAdapter/ClaudeStream.swift:8-38` (`permissionMode: String?`, nil omits the flag; add `setModelRequest(requestId:model:)`)
- Modify: `Sources/ClaudeAdapter/ClaudeSession.swift:9-56` (`Options` gains `model`, `permissionMode`, `addDirectories`; `start()` passes them; public `setModel(_:)`, `setPermissionMode(_:)` via `control(...)`)
- Modify: `Sources/ClaudeAdapter/ClaudeAdapter.swift` (`createSession` :208, `sendTurn` :216, `startSession` :108, `inspectConnection` capabilities/models)
- Modify: `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (record argv and control requests)
- Test: `Tests/ClaudeAdapterTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 `RuntimeOptions.claudeModels`, Task 4 inputs.
- Produces:
  - Launch: `--model <id>` when set; `--permission-mode <id>` only when set (nil = "As configured", so Claude's own settings apply; amends D-012); one `--add-dir` per directory.
  - The adapter keeps, per live session, the applied `(model, permission, directories)`. On `sendTurn` with a live session: a changed directory set disposes the process and starts it again with `resume: true` and the new flags; otherwise a changed `model` sends control `set_model {"model": id}` and a changed `permission` sends `set_permission_mode {"mode": id}`, each before the user frame, and a control error fails the turn with `WorkspaceError(.unsupportedCapability)` naming the control.
  - `inspectConnection` reports `models: RuntimeOptions.claudeModels`.
  - fake-claude: when `FAKE_CLAUDE_LOG` is set, appends `{"argv": [...]}` at start and `{"control": subtype, "request": {...}}` per control request, one JSON line each.

- [ ] **Step 1: Failing tests** — `SessionTests.inspectionModelsReachTheConnection` (refresh a fake-Claude connection; `connection.models?.map(\.id) == ["opus", "sonnet", "haiku"]`), `launchPassesModelPermissionAndDirectories` (argv contains `--model opus`, `--permission-mode plan`, `--add-dir /x`), `asConfiguredOmitsPermissionMode` (no `--permission-mode` in argv), `aChangedPermissionIsSentAsAControlRequest` (second turn with `permission: "acceptEdits"` → log has `set_permission_mode` with `mode == "acceptEdits"` and only one `argv` line), `changedDirectoriesRestartWithResume` (second turn with `additionalDirectories: ["/y"]` → a second `argv` line containing `--resume <id>` and `--add-dir /y`, and the turn completes).
- [ ] **Step 2: Run** `swift test --filter ClaudeSessionTests` — Expected: FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `swift test --filter "ClaudeSessionTests|SessionTests.inspectionModelsReachTheConnection"` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(claude): model, permission mode, and extra directories, changeable between turns`.

## Phase 3 — Coordinator

### Task 7: Turns carry the thread's choice and the project's other folders

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift:549-580` (`turnSend`), `:340-368` (`threadCreate` passes `NewSessionInput.model`/`permission`/`additionalDirectories`)
- Test: `Tests/CoordinatorTests/SessionTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4–6.
- Produces: `SessionService.additionalDirectories(for thread: ConversationThread) throws -> [String]` — the canonical paths of `db.project(id: thread.projectId)?.folders`, oldest first, minus `canonicalDirectory(thread.context)`; `[]` for B4 or no project. `turnSend` builds `TurnInput(operationId:text:workingDirectory:model: thread.model, permission: thread.permission, additionalDirectories:)`.

- [ ] **Step 1: Failing tests** — `turnsAttachTheProjectsOtherFolders` (project with folders A and B, Claude thread in A; send; fake log argv has `--add-dir B` and not `--add-dir A`), `aFolderAddedLaterReachesTheNextTurn` (add C to the project via `project.update`, send again; the restart argv has `--add-dir B` and `--add-dir C`), `aChangeDuringATurnAppliesToTheNextTurn` (start a turn that the fake holds open, `thread.update permission: "plan"`, let it finish; no control request was sent during it; the next turn's log shows `set_permission_mode plan` before its user frame).
- [ ] **Step 2: Run** `swift test --filter SessionTests` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `swift test --filter SessionTests` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(coordinator): turns carry the thread's model, permission, and the project's other folders`.

### Task 8: Remove the directory lock

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift:556,686-713` (delete `assertDirectoryFree`, `assertFolderFree`; `assertCanStart` keeps its other checks or goes if empty)
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift:766-781` (delete `activeHarnessTurns()` if unused)
- Modify: `Sources/Coordinator/HubSync/RelayExecutor.swift:140-152,218-219,286-289` (`blockingReasons = ["turn_active"]`; drop lock comments)
- Modify: `Sources/WorkspaceUI/Remediation.swift:96-100` (delete the `directory_locked` case)
- Modify tests: `Tests/CoordinatorTests/SessionTests.swift:1020` (replace `directoryLockSerializesHarnessTurnsAcrossConnections` with `twoThreadsMayRunInOneFolder`), `:568` (drop the second-directory workaround), `Tests/CoordinatorTests/RelayExecutorTests.swift:704-727,775-797` (drop the `directory_locked` cases; `threadStartInALockedFolderCreatesNothing` becomes `threadStartBesideARunningThreadInTheSameFolderStarts`), `Tests/WorkspaceUITests/RemediationTests.swift:36`
- Create: `docs/decisions/D-NNN-the-directory-lock-is-removed.md` (amends D-033, records the departure from spec 10.1.5; number from `Scripts/docs-index.sh --next` when the PR opens)

The opaque `"directory_locked"` strings in `Tests/WorkspaceMirrorTests/MirrorTransportTests.swift:773` and `Hub/crates/b4hub/tests/relay.rs:2122,2158` are sample refusal codes; change them to `"turn_active"` so nothing references the retired reason.

- [ ] **Step 1: Write** `twoThreadsMayRunInOneFolder`: two Claude threads in one folder, hold the first turn open, send on the second; assert the second turn is accepted and both complete.
- [ ] **Step 2: Run** `swift test --filter twoThreadsMayRunInOneFolder` — Expected: FAIL with `directory_locked`.
- [ ] **Step 3: Delete** the lock code and adjust the tests listed above.
- [ ] **Step 4: Run** `swift test` and, from `Hub/`, `cargo test --workspace --locked` — Expected: PASS; `grep -rn directory_locked Sources Tests Hub/crates` prints nothing.
- [ ] **Step 5: Write the decision file**, run `Scripts/docs-index.sh --check` — Expected: PASS.
- [ ] **Step 6: Commit** `feat(coordinator)!: remove the per-directory turn lock`.

### Task 9: `thread.start` runs locally and owns start validation

**Files:**
- Modify: `Sources/WorkspaceProtocol/Relay.swift:7-33` (`ThreadStart.Params`)
- Modify: `Sources/Coordinator/SessionService.swift` (new `threadStart`)
- Create: `Sources/WorkspaceProtocol/ThreadTitle.swift`, `Tests/WorkspaceProtocolTests/ThreadTitleTests.swift`
- Modify: `Sources/Coordinator/HubSync/RelayExecutor.swift:220-308` (delegate to `SessionService.threadStart`)
- Modify: `Sources/Coordinator/Router.swift:85-103,136-137` (`.threadStart` moves to the account group and dispatches with the envelope's `operationId`)
- Modify: `Tests/Fixtures/sync/relay.json` (the `thread.start` example gains `"model": "sonnet", "permission": "plan"`) and the Rust relay fixture test if it asserts the params' keys
- Test: `Tests/CoordinatorTests/SessionTests.swift`, `Tests/CoordinatorTests/RelayExecutorTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 7, 8.
- Produces:
  - `ThreadStart.Params`: `projectId` becomes `String?`; adds `model: String?`, `permission: String?`. Wire-compatible with phones that always send `projectId`.
  - `SessionService.threadStart(_ params: ThreadStart.Params, operationId: String, requireProject: Bool) async throws -> ThreadStart.Result` — the checks now in `RelayExecutor.threadStart` (:225-300, same reasons and order, minus the lock), plus: `projectId == nil` is refused `project_missing` when `requireProject`; otherwise a Codex/Claude folder resolves its project through `ProjectService.ensureProject(folder:)` when the thread is inserted (D-048, unchanged); a remote B4 connection is allowed only when `!requireProject`. It validates `permission` as Task 3 does, stores `model`/`permission` on the new thread, titles it `ThreadTitle.fromFirstMessage(text)`, then calls `turnSend`.
  - `public enum ThreadTitle { public static func fromFirstMessage(_ text: String) -> String }`: the first non-empty line, whitespace-trimmed, cut at 60 characters on a word boundary with "…" appended when cut.
  - `RelayExecutor` calls it with `requireProject: true`; `Router` with `requireProject: false`.

- [ ] **Step 1: Failing tests** — `SessionTests.localThreadStartCreatesThreadAndTurn` (Mac-side `thread.start` over the router with project, folder, Claude, `model: "sonnet"`, `permission: "plan"`; assert thread exists with those fields and title, a turn exists, fake argv has `--model sonnet --permission-mode plan`), `localThreadStartIsIdempotentPerOperation` (same operation id twice → one thread, one turn), `aChosenFolderWithoutAProjectGetsAnAutomaticProject` (`projectId: nil`, a fresh folder → thread's `projectId` is a new automatic project of that folder), `localThreadStartMayUseRemoteB4` (no project, remote B4 connection → starts), `RelayExecutorTests.relayedStartStillRequiresAProject` (`projectId` absent → `project_missing`), `ThreadTitleTests.cutsOnAWordBoundary` (`"Why does the relay drop after the Mac sleeps for more than an hour at night"` → `"Why does the relay drop after the Mac sleeps for more…"`, and `"\n\n  hi  \nthere"` → `"hi"`).
- [ ] **Step 2: Run** `swift test --filter "SessionTests|RelayExecutorTests|ThreadTitleTests"` — Expected: new tests FAIL.
- [ ] **Step 3: Implement** per Interfaces; move, do not copy, the validation.
- [ ] **Step 4: Run** `swift test` and the hub suite — Expected: PASS.
- [ ] **Step 5: Write the decision file** `D-NNN-a-thread-starts-with-its-first-message-and-runtime-choice.md` (amends D-012: the app passes a model/permission only when the user picks one; amends D-048: a thread's project's other folders are attached each turn, membership still derived from the starting folder; `thread.start` is local too). Record the Codex limit: extra folders reach Codex only as `writableRoots` under "Auto"; under "As configured", "Read only", and "Full access" Codex sees them only as far as its sandbox already allows. Run `Scripts/docs-index.sh --check`.
- [ ] **Step 6: Update** `docs/compatibility.md` (Codex `turn/start` `model`/`approvalPolicy`/`sandboxPolicy` and `model/list` used, 0.166.0; Claude `--model`, `--add-dir`, `set_model`, `set_permission_mode`) and `docs/milestones.md` (model selection fixture-tested).
- [ ] **Step 7: Commit** `feat: thread.start is local, carries model and permission, and titles the thread`.

## Phase 4 — Shared UI

### Task 10: Composer field extracted, and local preferences

**Files:**
- Create: `Sources/WorkspaceUI/ComposerField.swift`
- Modify: `Sources/WorkspaceUI/ComposerView.swift` (uses `ComposerField`)
- Create: `Sources/WorkspaceUI/LocalPreferences.swift`
- Test: `Tests/WorkspaceUITests/ThemeTests.swift` (existing `ComposerView.shape` tests move to `ComposerField.shape`)

**Interfaces:**
- Produces:
  - `struct ComposerField<Trailing: View>: View` with `init(text: Binding<String>, placeholder: String, focused: FocusState<Bool>.Binding, onSubmit: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing)` — the D-061 line/box field (editor, capsule, `surface` fill, `rule` stroke, the trailing control at the tool row's end); `static func shape(...)` moves here unchanged. `ComposerView` keeps its banners, relay lines, turn row, and supplies send/stop as `trailing`.
  - `public protocol LocalPreferences: AnyObject, Sendable { func data(forKey key: String) -> Data?; func set(_ data: Data?, forKey key: String) }`; `extension UserDefaults: LocalPreferences` (Foundation's per-app defaults; per device, never synced); `final class InMemoryPreferences: LocalPreferences` for tests. `WorkspaceModel` gains `public var preferences: LocalPreferences` (default `UserDefaults.standard`).

- [ ] **Step 1: Move** the `shape` tests to target `ComposerField.shape`; run `swift test --filter ThemeTests` — Expected: FAIL (no `ComposerField`).
- [ ] **Step 2: Extract** `ComposerField`; `ComposerView` renders identically (the `composer`, `send`, `stop` ids stay on the same elements).
- [ ] **Step 3: Run** `swift test --filter "ThemeTests|IdealSizeTests|DetailMinimumSizeTests"` — Expected: PASS. With `B4APP_SNAPSHOT_DIR` set, the thread composer snapshot is unchanged by eye.
- [ ] **Step 4: Commit** `refactor(ui): extract the composer field; add local preferences`.

### Task 11: `NewThreadDraft` for both platforms

**Files:**
- Create: `Sources/WorkspaceUI/NewThread/NewThreadDraft.swift` (replaces `PhoneNewThreadDraft`)
- Create: `Sources/WorkspaceUI/NewThread/NewThreadMemory.swift`
- Move: the `WorkspaceModel` extension at `Sources/WorkspaceUI/PhoneNewThreadSheet.swift:7-83` to `Sources/WorkspaceUI/NewThread/StartOptions.swift`
- Modify: `Sources/WorkspaceUI/SendState.swift:281-318` (`startThread`)
- Test: `Tests/WorkspaceUITests/NewThreadDraftTests.swift` (port `PhoneNewThreadTests.swift`, then delete it in Task 14)

**Interfaces:**
- Consumes: Task 1 catalog, Task 9 `ThreadStart.Params`, Task 10 `LocalPreferences`.
- Produces:
  - `struct RuntimeChoice: Codable, Equatable { var connectionId: String; var model: String?; var permission: String? }`
  - `struct NewThreadMemory: Codable, Equatable { var projectId: String?; var folderByProject: [String: String]; var runtimeByProject: [String: RuntimeChoice]; var lastRuntime: RuntimeChoice?; var text: String }` with `static func load(from: LocalPreferences) -> Self` / `func save(to:)` under the key `"newThread.memory"`.
  - `@MainActor @Observable final class NewThreadDraft` with `projectId: String?`, `folder: String?`, `chosenFolder: String?` (a "Choose folder…" path outside any project, Mac only), `connectionId: String?`, `model: String?`, `permission: String?`, `text: String`; `init(model: WorkspaceModel, projectId: String?)` applying the spec's Defaults order and falling back past any remembered id that no longer exists; `selectFolder(_ folder: String, in projectId: String)`, `chooseFolder(_ path: String)`, `selectRuntime(connectionId: String, model: String?)` (resets `permission` to nil when the kind changes), `selectPermission(_ id: String?)`, `send() async`; derived `blockedReason: String?`, `canSend: Bool`, `status: String?`, `finished: Bool`, `startedThreadId: String?` (as `PhoneNewThreadDraft` has them).
  - `WorkspaceModel.newThreadDraft: NewThreadDraft` (created once, text persisted to memory on change, cleared on success); `startConnections(for:)` and `startProjects` gain a Mac branch (`!relaysThroughHub`: every project; ready Codex/Claude connections and this project's local B4); `remoteB4Connections: [Connection]` (Mac only, ready, `b4Mode == .remote`).
  - `startThread(projectId: String?, connectionId: String, folder: String?, model: String?, permission: String?, text: String) async -> PendingSend?` — Mac and phone both send `ThreadStart` through `client`; on the Mac the result is stored and the thread opened, as on the phone.

- [ ] **Step 1: Port** the existing `PhoneNewThreadTests` to `NewThreadDraftTests` against `NewThreadDraft` and run them — Expected: FAIL (type missing).
- [ ] **Step 2: Add failing tests** — `defaultsComeFromTheLastChoiceInThatProject`, `aProjectIdOverridesOnlyTheProject`, `switchingRuntimeResetsPermissionToAsConfigured`, `staleMemoryFallsBackToAValidChoice` (memory names a deleted project and a removed folder → draft picks the newest project and its first folder), `macOffersRemoteB4WithNoProject` (selecting a remote B4 connection sets `projectId` nil), `theDraftTextSurvivesARelaunch` (set text, build a new model on the same `InMemoryPreferences`, text restored).
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `swift test --filter "NewThreadDraftTests|SendStateTests"` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(ui): one new-thread draft for the Mac and the phone`.

### Task 12: Picker row, new-thread view, and in-thread pickers

**Files:**
- Create: `Sources/WorkspaceUI/NewThread/ComposerPickerRow.swift`
- Create: `Sources/WorkspaceUI/NewThread/NewThreadView.swift`
- Modify: `Sources/WorkspaceUI/ThreadsView.swift:109-120` (`bottom(detail)` adds the in-thread row under `ComposerView`)
- Modify: `Sources/WorkspaceUI/WorkspaceModel+Threads.swift` (`setThreadRuntime`)
- Test: `Tests/WorkspaceUITests/NewThreadDraftTests.swift`, `Tests/WorkspaceUITests/SnapshotTests.swift`

**Interfaces:**
- Consumes: Tasks 10, 11.
- Produces:
  - `struct ComposerPickerRow: View` with `enum Source { case draft(NewThreadDraft); case thread(ConversationThread) }`. Leading: the project · folder menu (`picker-project`): one section per project (header = display name; items = folders by last path component; a one-folder project is one item), then "Choose folder…" on the Mac (`fileImporter`, folders only). Trailing: the permissions menu (`picker-permission`: "As configured" first only while the draft or thread has `permission == nil`, then `RuntimeOptions.permissions(for:)`; hidden for B4) and the runtime · model menu (`picker-runtime`: one section per connection, header = `RuntimeMark` + label, items = "Default" first only while `model == nil`, then `connection.models`; local B4 agents of the project as single items; on the Mac a last "Remote B4" section). Label text: `"<runtime> · <model>"` on the Mac, the mark plus model name on compact width. For `.thread`, the project menu is a muted label without a chevron, the runtime menu lists only the thread's connection's models, and a B4 thread shows neither the permissions nor the runtime menu. "As configured" and "Default" disappear once a thread has an override because Codex keeps a `turn/start` override "for this turn and subsequent turns" and offers no way to clear it; Claude follows the same rule for consistency.
  - `WorkspaceModel.setThreadRuntime(threadId: String, model: String?, permission: String?) async` → `ThreadUpdate`.
  - `struct NewThreadView: View` — the headline (`llaDisplay`, text "What should we work on?", replaceable), `HostNotice` when `startNotice` applies, `ComposerField` (placeholder `"Message <connection label>"`, trailing send circle `ComposerCircleStyle`, `send` id), `ComposerPickerRow(.draft)`, the draft's `status` line (`new-thread-status`); focuses the field on appear and on `model.newThreadFocusRequest` change; Mac: centred in `LLA.Metrics.column`; compact: field and row pinned to the bottom with `navigationTitle("New thread")`. Screen id `new-thread`.

- [ ] **Step 1: Failing tests** — `startRefusedKeepsTheText` (script a `thread.start` refusal; `draft.text` unchanged, `draft.status` is the refusal copy, `model.threads` unchanged), `secondSendWhileStartingIsIgnored` (two `send()` calls before the reply → one `ThreadStart` request), `aThreadsRuntimeChangeIsSent` (`setThreadRuntime(permission: "plan")` → one `ThreadUpdate` with `permission == "plan"`).
- [ ] **Step 2: Run** `swift test --filter NewThreadDraftTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the views and `setThreadRuntime`.
- [ ] **Step 4: Run** `swift test --filter "NewThreadDraftTests|IdealSizeTests|DetailMinimumSizeTests"` — Expected: PASS (a thread with the picker row still fits `LLA.Metrics.minimumWindow`).
- [ ] **Step 5: Commit** `feat(ui): composer picker row, new-thread view, in-thread model and permission`.

## Phase 5 — Mac

### Task 13: The empty pane is the new thread

**Files:**
- Modify: `Sources/WorkspaceUI/ThreadsView.swift:4-31` (no selection and a ready connection → `NewThreadView`; otherwise today's "Add connection" state)
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (`showNewThread` → `openNewThread(projectId:)`, `newThreadFocusRequest: Int`; `Remediation.Action.newThread` calls it)
- Modify: `Sources/WorkspaceUI/SidebarView.swift:40-57` ("New thread" row calls `openNewThread()`, shows selected while `selectedThreadId == nil`)
- Modify: `Sources/WorkspaceUI/ThreadsView.swift:231` (continuity banner)
- Modify: `Sources/WorkspaceUI/WorkspaceRootView.swift:95-105` (drop the sheet; see below)
- Modify: `Apps/macOS/B4App/B4AppMac.swift:44-48` (⌘N calls `openNewThread()`, disabled by `newThreadEntryReason != nil`)
- Delete: `Sources/WorkspaceUI/NewThreadSheet.swift`, `NewThreadProject` and its test (`Tests/WorkspaceUITests/ThreadListTests.swift:81-90`) if nothing else uses it
- Test: `Tests/WorkspaceUITests/WorkspaceModelTests.swift`, `Tests/WorkspaceUITests/SnapshotTests.swift`

**Interfaces:**
- Consumes: Tasks 11, 12.
- Produces: `public func openNewThread(projectId: String? = nil) async` — saves the open thread's draft, sets `selectedThreadId = nil`, applies `projectId` to `newThreadDraft`, increments `newThreadFocusRequest` and `detailRequest`. `WorkspaceRootView` no longer moves the compact column to the sidebar when the selection becomes nil; the delete and account-clear paths that nil the selection request the sidebar explicitly through a new `sidebarRequest: Int`.

- [ ] **Step 1: Failing tests** — `openNewThreadClearsTheSelectionAndFocuses` (open a thread, `openNewThread()`; `selectedThreadId == nil`, `newThreadFocusRequest` incremented, the old thread's draft saved), `openNewThreadWithAProjectPreselectsIt`, `remediationNewThreadOpensTheComposer`.
- [ ] **Step 2: Run** `swift test --filter WorkspaceModelTests` — Expected: FAIL.
- [ ] **Step 3: Implement**; replace every `showNewThread = true` (listed in `WorkspaceModel.swift:1243`, `ThreadsView.swift:22,231`, `SidebarView.swift:45`, `B4AppMac.swift:45`) and remove the property.
- [ ] **Step 4: Snapshots:** in `SnapshotTests`, rename the `threads-empty` capture to `new-thread` (light and dark; open menus are not capturable headless). Run `B4APP_SNAPSHOT_DIR=$TMPDIR/snaps swift test --filter SnapshotTests` and look at `new-thread-light.png` / `-dark.png` against the approved mockup (empty pane, focused field, project left, permissions and runtime · model right).
- [ ] **Step 5: Run** `swift test`, `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` — Expected: PASS / BUILD SUCCEEDED.
- [ ] **Step 6: Commit** `feat(mac): the empty pane is a blank new-thread composer`.

## Phase 6 — iPhone

### Task 14: The list's header and bottom field; the pushed new-thread screen

**Files:**
- Modify: `Sources/WorkspaceUI/SidebarView.swift:96-118` (iOS toolbar and insets)
- Modify: `Sources/WorkspaceUI/ProfileMenu.swift` (iOS: `ProfileToolbarMenu`; `SidebarFooter` becomes Mac-only; its notices move to the iOS bottom dock)
- Create: `Sources/WorkspaceUI/NewThread/NewThreadDock.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceRootView.swift` (iOS: no sheet; iPad regular width shows `NewThreadView` as the detail with no selection)
- Modify: `Apps/iOS/B4App/B4AppiOS.swift:114-116` (`workspaceSheetUp` drops `showNewThread`)
- Delete: `Sources/WorkspaceUI/PhoneNewThreadSheet.swift`, `Tests/WorkspaceUITests/PhoneNewThreadTests.swift`
- Test: `Tests/WorkspaceUITests/SnapshotTests.swift` (`ListSnapshotTests`), `Tests/WorkspaceUITests/ListSearchTests.swift`

**Interfaces:**
- Consumes: Tasks 11–13.
- Produces:
  - iOS toolbar: `.topBarLeading` `ProfileToolbarMenu` (the avatar, `profile-button`; a native `Menu` with ProfileMenuPanel's items: Settings, GitHub, Log out with the phone's existing alert); `.topBarTrailing` `MoreMenu(inToolbar: true)` and a search button (`list-search`) that sets `model.listSearchPresented = true` (a new `public var listSearchPresented = false` on `WorkspaceModel`, beside `listSearch`). The compose button is removed.
  - `.searchable(text: $model.listSearch, isPresented: $model.listSearchPresented, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search threads")`.
  - `struct NewThreadDock: View` in `.safeAreaInset(edge: .bottom)`: the footer's notices (`link-note`, `host-note`, `logout-failure`, `version-note`) above a capsule button styled as the composer line (`surface`, `rule`, placeholder "New thread", the disabled `ComposerCircleStyle` circle), id `new-thread-dock`; tap → `openNewThread()`; disabled with `newThreadEntryReason` as its accessibility hint.
  - `Connect your Mac` still replaces the list (and the dock) while the account has no Mac.

- [ ] **Step 1: Failing tests** — `ListSnapshotTests.iosListHeaderAndDock` (renders the iOS list at 390×844 with the dock; layout check passes; with the snapshot env var, writes `ios-list-dock-light/dark.png`), `ListSearchTests.searchPresentationResetsWithTheAccount` (set `listSearchPresented` and `listSearch`; clearing the account resets both, as it does `showSearch`).
- [ ] **Step 2: Run** `swift test --filter "ListSnapshotTests|ListSearchTests"` — Expected: FAIL.
- [ ] **Step 3: Implement**; delete the phone sheet and its tests (their behaviours are ported in Task 11).
- [ ] **Step 4: Run** `swift test` and `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` — Expected: PASS / BUILD SUCCEEDED.
- [ ] **Step 5: Commit** `feat(ios): header profile and search, a new-thread field, and the pushed composer`.

### Task 15: On-screen verification and the gate record

**Files:**
- Create: `docs/verification/YYYY-MM-DD-new-thread-composer.md`
- Modify: `docs/milestones.md`

- [ ] **Step 1: Mac, local flavour:** run the app against a dev coordinator; with no thread open, type and Send on Claude and on Codex in a two-folder project; confirm the thread opens titled from the message, `ps` shows `--add-dir` for the other folder, and switching permissions mid-thread takes effect on the next turn (Claude: Plan mode refuses an edit; Codex: Read only refuses a write).
- [ ] **Step 2: iPhone Simulator** paired to that Mac: tap the dock, pick project, runtime, permission, send; the thread opens on the phone and runs on the Mac; turn the Mac's coordinator off and confirm the screen's offline notice and disabled Send.
- [ ] **Step 3: Live checks (opt-in):** `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` and `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` with a new case in each that sends one turn with a model and a permission (Claude: `set_permission_mode` mid-session accepted; Codex: `turn/start` with `sandboxPolicy` accepted). Record versions in `docs/compatibility.md`; flip `.modelSelection` to `.supported` for an adapter only after its live case passes.
- [ ] **Step 4: Write the gate record** with what passed, screenshots' paths, and anything left; mark the milestone line. Run `Scripts/docs-index.sh --check`.
- [ ] **Step 5: Commit** `docs: new-thread composer gate`.
