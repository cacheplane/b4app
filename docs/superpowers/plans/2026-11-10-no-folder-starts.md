# No-folder starts and temporary folders: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Codex or Claude thread can be started with no folder, from the Mac, the CLI, and the phone; the coordinator makes a folder for it, records it, and the thread has no environment.

**Architecture:** The coordinator owns everything on disk. `thread.create` with no working directory makes a folder under a per-flavour root, records it in a new local-only table `appFolders`, and inserts the thread without an environment; app folders are never adopted into an environment. The hub routes a relayed `thread.start` with no `environmentId` by a new `deviceId` param, as it already routes `environment.create`. The composer gains a "No folder" choice in the existing place menu; the palette is a later plan.

**Tech stack:** Swift (coordinator, storage, UI, CLI), PostgreSQL migration in `WorkspaceStorage`, Rust hub (`b4hub` relay routing), the shared fixture `Tests/Fixtures/sync/relay.json`.

**Spec:** `docs/superpowers/specs/2026-11-10-thread-list-and-environments-design.md` ("Starting a thread", "Temporary folders"). This is plan 2 of 6; plan 1 (the rename, D-202) is merged.

## Global constraints

- No backwards compatibility: replace old behaviour outright; no aliases.
- `WorkspaceUI` talks only to `WorkspaceClient`; the UI never touches files. Only the coordinator creates folders.
- Never edit an applied migration (D-178). The store gets one new migration, `0012_app_folders.sql`. The hub and the phone's mirror get none.
- `appFolders` is local to the Mac: not in `ChangeLog.syncedTables`, no change-log trigger, never sent to the hub.
- The user-visible words are exactly "No folder". "B4 project" wording is untouched.
- Nothing in this plan deletes a folder the user could have files in. The only removal is of a folder this code created moments earlier, and only while it is still empty.
- `Tests/Fixtures/sync/relay.json` changes only together with both suites that decode it.
- Secrets never in arguments, results, or logs; ordinary tests use fixtures and fake runtimes.
- Before each commit: `swift build`, the task's tests, `swift format lint --strict --recursive Sources Tests Apps Package.swift`. Hub tasks also: `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` from `Hub/`.
- Decision and verification files follow AGENTS.md ("Decisions and gate records"); take the decision number with `Scripts/docs-index.sh --next` when the pull request opens (D-203 at the time of writing).

## Planner's decisions

These settle what the spec leaves open. Change one only with a reason, and record it in the decision file.

1. **Root.** `PlatformPaths.threadFoldersDir`: `~/.b4app/projects` for prod, `~/.b4app/projects-beta`, `~/.b4app/projects-local`. When `B4APP_DATA_DIR` is set it is `<dataDir>/projects`, so tests and experiments stay out of the home directory.
2. **Folder name.** `<yyyy-MM-dd in UTC>-<first 8 characters of the thread id>`, for example `2026-11-10-3f9a2c1e`. If that path already exists, `<date>-<whole thread id>`. Mode 0700 (`PrivateFiles.ensurePrivateDirectory`).
3. **Where it lives in the code.** In `SessionService.threadCreate`: a Codex or Claude `thread.create` with no `workingDirectory` used to be refused; it now makes the folder. `thread.start` passes no folder through. The CLI gets it for free.
4. **No environment, ever.** A folder is an app folder when it has an `appFolders` row or sits under `threadFoldersDir`. `EnvironmentService.folder(forThread:connection:)` returns nil for one, so neither the insert nor the start-up `backfill()` gives its thread an environment.
5. **Relay routing.** `ThreadStart.Params` gains `deviceId: String?`. The hub routes by `environmentId` when it is present and by `deviceId` otherwise. The Mac ignores `deviceId`.
6. **Which Mac, from the phone.** "No folder" on the phone offers the ready Codex and Claude connections of the primary Mac (`primaryHostId`). Choosing among several Macs waits for the palette plan.
7. **Default place.** The remembered environment if it still exists, else "No folder" (the spec's fresh-install default). The newest environment is no longer a fallback. A Codex or Claude start with no environment clears the remembered environment; a remote B4 start still leaves it alone.
8. **A thread with no environment reads "No folder"** in the composer row, whatever its folder is called.
9. **Folder gone.** `turn.send` on a Codex or Claude thread whose folder is not a directory is refused before a turn is inserted, with `reason: "folder_gone"`. This covers every thread, not only app folders.

## Review focus

Inputs the spec implies and that are most likely to bite, each pinned by a test in the task named:

1. A retried `thread.start` (same thread id, same operation id, or a new operation id after a refusal) must not make a second folder or a second record. Task 2.
2. The coordinator restarts: `backfill()` must leave app-folder threads without an environment. Task 2.
3. The user deletes the folder in Finder: the thread still opens with its cached transcript, and Send says the folder is gone. Task 2.
4. `db backup` then `db restore`: the `appFolders` rows survive, so restored threads are not adopted into environments. Task 1.
5. The phone starts with no folder while its Mac is offline, or on a hub that predates this change: Send is blocked with the Mac's notice, or the refusal is shown, and no thread row is left on the phone. Tasks 3 and 4.

---

### Task 1: The folder root and the `appFolders` table

**Files:**
- Modify: `Sources/WorkspacePlatform/Paths.swift`
- Create: `Sources/WorkspaceStorage/SQL/0012_app_folders.sql`
- Create: `Sources/WorkspaceStorage/AppFolders.swift`
- Modify: `Sources/WorkspaceStorage/Export.swift` (the table list at line 17)
- Test: `Tests/WorkspacePlatformTests/` (the existing paths test file), create `Tests/WorkspaceStorageTests/AppFolderStoreTests.swift`

**Interfaces:**
- Produces:
  - `PlatformPaths.threadFoldersDir: String` (stored; `init(runtimeDir:dataDir:)` sets `<dataDir>/projects`; `resolve(environment:)` replaces it with `defaultThreadFoldersDir(flavor:)` when `B4APP_DATA_DIR` is absent).
  - `static func PlatformPaths.defaultThreadFoldersDir(flavor: Flavor, home: String = NSHomeDirectory()) -> String`
  - `public struct AppFolder: Sendable, Equatable, Codable { public var path: String; public var threadId: String; public var createdAt: String }`
  - On `WorkspaceDatabase`: `insertAppFolder(_ folder: AppFolder) throws`, `appFolder(path: String) throws -> AppFolder?`, `appFolder(threadId: String) throws -> AppFolder?`, `deleteAppFolder(path: String) throws`, `listAppFolders() throws -> [AppFolder]`.

- [ ] **Step 1: Write the failing path tests**

```swift
@Test func threadFoldersFollowTheFlavour() {
  #expect(PlatformPaths.defaultThreadFoldersDir(flavor: .prod, home: "/Users/a") == "/Users/a/.b4app/projects")
  #expect(PlatformPaths.defaultThreadFoldersDir(flavor: .beta, home: "/Users/a") == "/Users/a/.b4app/projects-beta")
  #expect(PlatformPaths.defaultThreadFoldersDir(flavor: .local, home: "/Users/a") == "/Users/a/.b4app/projects-local")
}

@Test func aDataDirOverrideKeepsThreadFoldersInsideIt() {
  let paths = PlatformPaths.resolve(environment: ["B4APP_DATA_DIR": "/tmp/x", "B4APP_RUNTIME_DIR": "/tmp/r"])
  #expect(paths.threadFoldersDir == "/tmp/x/projects")
}
```

- [ ] **Step 2: Run them; expect a compile failure** (`swift test --filter threadFolders`).
- [ ] **Step 3: Implement the two path members.**
- [ ] **Step 4: Write the failing store tests** in `AppFolderStoreTests.swift`, using the suite's existing database helper:

```swift
@Test func anAppFolderIsFoundByPathAndByThread()        // insert, then both lookups return it
@Test func aSecondFolderForTheSameThreadIsRefused()     // unique threadId: second insert throws
@Test func insertingAnAppFolderWritesNoChange()         // changes count is the same before and after
@Test func appFoldersSurviveBackupAndRestore()          // export, restore into an empty store, listAppFolders() equal
```

- [ ] **Step 5: Add the migration**

```sql
-- Folders the app made for threads started with no folder. Local to this Mac: never synced, no
-- change-log trigger. The cleanup service (a later design) reads it.
CREATE TABLE "appFolders" (
  "path" TEXT PRIMARY KEY,
  "threadId" TEXT NOT NULL UNIQUE,
  "createdAt" TEXT NOT NULL
);
```

No foreign key to `threads`: the record is written before the thread row and outlives a deleted thread.

- [ ] **Step 6: Implement `AppFolders.swift` and add `"appFolders"` to the export's table list** (after `"threads"`).
- [ ] **Step 7: Run** `swift test --filter "AppFolderStoreTests|threadFolders|aDataDirOverride|StorageResourcesTests"`; expect all pass. `StorageResourcesTests` checks the migration list; update its expectation if it names the last migration.
- [ ] **Step 8: Commit** `feat(storage): record folders the app makes for threads`.

### Task 2: The coordinator makes the folder

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift` (`threadCreate` near line 355, `threadStart` at 617, `turnSend` near 747)
- Modify: `Sources/Coordinator/EnvironmentService.swift` (`folder(forThread:connection:)` at line 27)
- Modify: `Sources/Coordinator/Router.swift:289`, `Sources/Coordinator/HubSync/RelayExecutor.swift:186` (the renamed argument)
- Modify: `Sources/WorkspaceProtocol/Commands.swift` (the `ThreadCreate.Params.workingDirectory` doc comment), the CLI's `thread new` command file
- Test: `Tests/CoordinatorTests/SessionTests.swift`, the environment service's test file, the CLI's test file

**Interfaces:**
- Consumes: Task 1's `threadFoldersDir`, `AppFolder`, and store functions. `SessionService` needs the coordinator's `PlatformPaths`; pass `threadFoldersDir` into its context if it is not already reachable.
- Produces:
  - `func SessionService.appFolder(forThread threadId: String) throws -> String`: the canonical path of the thread's app folder, made and recorded on first call, the same path on every later call.
  - `threadStart(_:operationId:fromAnotherDevice:)`: `requireEnvironment` is renamed.
  - `func EnvironmentService.isAppFolder(_ canonical: String) throws -> Bool`
  - Refusal `reason: "folder_gone"` with `details["folder"]`.

**What `threadStart` accepts, Codex and Claude:**

| `environmentId` | `folder` | From this Mac | From another device |
|---|---|---|---|
| given | given | as today | as today |
| given | none | `folder_missing`, as today | `folder_missing`, as today |
| none | given | as today: joins or makes the folder's environment | refused, `environment_missing` |
| none | none | **app folder, no environment** | **app folder, no environment** |

B4 is unchanged: from another device a remote connection is `remote_b4` and a local one with no environment is `environment_missing`.

- [ ] **Step 1: Write the failing tests** in `SessionTests.swift`, with the fake Codex runtime the file already uses:

```swift
@Test func aStartWithNoFolderMakesOneAndHasNoEnvironment()
// thread.context is a directory under threadFoldersDir named <date>-<8 chars of id>, mode 0700;
// thread.environmentId == nil; db.appFolder(threadId:) names the same path; no environment was created.

@Test func aRelayedStartWithNoEnvironmentIsAccepted()      // fromAnotherDevice: true, no folder: same result
@Test func aRelayedStartWithAFolderAndNoEnvironmentIsRefused()   // reason environment_missing
@Test func retryingANoFolderStartMakesNoSecondFolder()
// same threadId twice (same operationId, then a new one after the first was refused by an offline
// connection): one directory under the root, one appFolders row.

@Test func aStartRefusedBeforeTheThreadLeavesNoFolder()    // connection not ready: the root holds no entry
@Test func backfillLeavesAppFolderThreadsWithoutAnEnvironment()
@Test func sendingToAThreadWhoseFolderIsGoneSaysSo()
// remove the directory; turn.send throws protocolInvalid, reason folder_gone, details.folder == path;
// db.turns(threadId:) is unchanged.

@Test func aThreadWhoseFolderIsGoneStillReads()            // thread.read returns the cached display items
@Test func threadCreateWithNoWorkingDirectoryMakesAnAppFolder()
```

- [ ] **Step 2: Run them; expect failures** (`swift test --filter SessionTests`).
- [ ] **Step 3: Implement `appFolder(forThread:)`.** Return the recorded path when the row exists and the directory is still there. Otherwise create the root and the folder (decision 2), canonicalise with `canonicalDirectory`, insert the row. If the row exists but the directory is gone, recreate the same path.
- [ ] **Step 4: `threadCreate`.** A Codex or Claude create with a nil or empty `workingDirectory` calls `appFolder(forThread:)` with the id the thread will have (mint it first when `params.threadId` is nil). Call it after every check that can refuse, immediately before the insert. If the insert throws, remove the directory when it is empty and delete the row.
- [ ] **Step 5: `threadStart`.** Rename the argument and apply the table above. The existing-thread branch already treats a nil folder as "same folder"; keep it, so a retry never reaches `threadCreate`.
- [ ] **Step 6: `EnvironmentService`.** `isAppFolder` is true when `db.appFolder(path:)` finds a row or the path starts with `threadFoldersDir + "/"`. `folder(forThread:connection:)` returns nil for a Codex or Claude thread whose canonical context is an app folder.
- [ ] **Step 7: `turnSend`.** After `threadContext`, before `assertContinuable`: for a Codex or Claude thread with a non-empty context that is not a directory, throw `Self.refusal("This thread's folder is gone (\(path)). Start a new thread to continue.", reason: "folder_gone")` with `details["folder"]`.
- [ ] **Step 8: CLI.** `agent-workspace thread new --no-folder` sends `thread.create` with no working directory. With `--cwd` as well it fails validation: "Use --cwd or --no-folder, not both." Test: the command's params have no `workingDirectory`.
- [ ] **Step 9: Run** `swift test --filter "SessionTests|EnvironmentService|RelayExecutorTests"` and the CLI's tests; expect all pass.
- [ ] **Step 10: Commit** `feat(coordinator): start a thread with no folder in one the app makes`.

### Task 3: The hub routes a start with no environment

**Files:**
- Modify: `Sources/WorkspaceProtocol/Relay.swift` (`ThreadStart.Params`)
- Modify: `Hub/crates/b4hub/src/relay/route.rs:539-547`
- Modify: `Tests/Fixtures/sync/relay.json`, `Hub/API.md` (the routing table near line 1459 and the lookup rule), `docs/compatibility.md`
- Test: `Hub/crates/b4hub/tests/relay.rs`, `Tests/WorkspaceSyncTests/RelayWireTests.swift`

**Interfaces:**
- Produces: `ThreadStart.Params.deviceId: String?` (last in the initialiser, default nil; omitted from the JSON when nil). Doc comment: "The Mac to start on when no environment names one. The hub routes by it; the Mac ignores it."

- [ ] **Step 1: Write the failing hub tests** in `relay.rs`, beside the existing `thread.start` tests:

```rust
async fn thread_start_without_environment_routes_by_device(pool: PgPool)   // forwarded to the caller's own Mac
async fn thread_start_with_neither_environment_nor_device_is_not_found(pool: PgPool)
async fn thread_start_to_another_users_device_is_not_found(pool: PgPool)
async fn thread_start_with_an_environment_ignores_device(pool: PgPool)     // routed by the environment's owner
```

- [ ] **Step 2: Run them; expect failures** (`cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub --test relay --locked thread_start`).
- [ ] **Step 3: Route.** Split `ThreadStart` from the two environment edits. A present, non-null `environmentId` routes as today. Otherwise `deviceId` routes exactly as `EnvironmentCreate` does (`owner_device`, a non-UUID is `not_found`).
- [ ] **Step 4: Fixture.** Add one `thread.start` command to `relay.json` with `deviceId` and no `environmentId`, `folder`, `model`, or `permission`. Extend `RelayWireTests` to decode it (`environmentId == nil`, `deviceId` set) and to check that encoding params with a nil `deviceId` writes no `deviceId` key. Extend the hub test that reads the fixture the same way.
- [ ] **Step 5: `API.md`.** The table row becomes: `thread.start` | `params.environmentId`, or `params.deviceId` when there is none | the environment, or that device itself. Say in the lookup rule that a start with neither is `not_found`.
- [ ] **Step 6: `docs/compatibility.md`.** A phone start with no folder needs a hub with this change; an older hub answers `not_found`.
- [ ] **Step 7: Run** the whole hub suite, `cargo fmt`, `cargo clippy`, and `swift test --filter RelayWireTests`; expect all pass.
- [ ] **Step 8: Commit** `feat(hub): route thread.start by device when it names no environment`.

### Task 4: "No folder" in the composer

**Files:**
- Modify: `Sources/WorkspaceUI/NewThread/NewThreadDraft.swift`, `NewThreadMemory.swift`, `StartOptions.swift`, `ComposerPickerRow.swift`
- Modify: `Sources/WorkspaceUI/SendState.swift` (`startThread` at line 304, `SendRules.reason`)
- Modify: `Sources/WorkspaceUI/EnvironmentSections.swift`, `Sources/WorkspaceUI/SidebarView.swift` (the "Other" heading and filter label)
- Test: `Tests/WorkspaceUITests/NewThreadDraftTests.swift`, the tests that cover `startThread` and `SendRules`

**Interfaces:**
- Consumes: Task 3's `ThreadStart.Params.deviceId`; the coordinator's `folder_gone` reason.
- Produces:
  - `func NewThreadDraft.selectNoFolder()`; `var NewThreadDraft.isNoFolder: Bool` (no environment, no chosen folder, and the connection is not a remote B4).
  - `mutating func NewThreadMemory.remember(_ start: ThreadStart.Params, thread: ConversationThread?, remoteB4: Bool)`
  - `func WorkspaceModel.startBlockedReason(forDevice deviceId: String?) -> String?`; the environment variant calls it.

- [ ] **Step 1: Write the failing tests** in `NewThreadDraftTests.swift`:

```swift
@Test func aFreshInstallOpensOnNoFolder()             // empty memory, environments exist: isNoFolder, canSend with text
@Test func theRememberedEnvironmentStillWins()
@Test func aRememberedEnvironmentThatIsGoneFallsBackToNoFolder()
@Test func selectNoFolderClearsEnvironmentAndChosenFolder()
@Test func noFolderOffersCodexAndClaudeButNoLocalB4()
@Test func sendingNoFolderFromTheMacSendsNoEnvironmentFolderOrDevice()
@Test func sendingNoFolderFromThePhoneNamesThePrimaryMac()   // params.deviceId == primaryHostId
@Test func noFolderOnThePhoneIsBlockedWhileItsMacIsOffline()  // blockedReason is the Mac's offline notice
@Test func aNoFolderStartClearsTheRememberedEnvironment()
@Test func aRemoteB4StartLeavesTheRememberedEnvironment()
@Test func aRefusedPhoneStartLeavesNoThread()                // hub answers not_found: status shows the refusal
@Test func aThreadWithNoEnvironmentReadsNoFolder()           // ComposerPickerRow's place text for a thread
@Test func folderGoneHasItsOwnWords()
// SendRules.reason for reason folder_gone ==
// "This thread's folder is no longer on your Mac. Start a new thread to continue."
```

- [ ] **Step 2: Run them; expect failures** (`swift test --filter NewThreadDraftTests`).
- [ ] **Step 3: `StartOptions`.** `startConnectionsWithoutEnvironment` on the phone becomes the ready Codex and Claude connections whose `ownerDeviceId == primaryHostId` (none when there is no primary Mac). Add `startBlockedReason(forDevice:)`. `newThreadEntryReason` on the phone no longer needs an environment: it is nil when no-folder connections exist and their Mac is reachable.
- [ ] **Step 4: Draft.** `defaultEnvironment` follows decision 7. `blockedReason` no longer says "Choose a folder to start in." for a no-folder Codex or Claude draft; on the phone it returns `startBlockedReason(forDevice: primaryHostId)`. `selectRuntime` leaving a remote B4 lands on the default place, which may now be "No folder". `send()` passes no environment and no folder.
- [ ] **Step 5: `startThread`.** A Codex or Claude start with no environment and no folder is sent, not dropped; on the phone its params carry `deviceId: connection.ownerDeviceId`. Everything else is unchanged.
- [ ] **Step 6: Memory.** `remember` per decision 7; update its one caller in `NewThreadDraft.swift:349`.
- [ ] **Step 7: The menu.** In `environmentItems`, after the environments and a divider: a "No folder" choice (checked when `isNoFolder`, accessibility identifier `no-folder`) on both platforms, then "Choose folder…" on the Mac as today. `placeText(_ thread:)` returns "No folder" whenever the thread has no environment.
- [ ] **Step 8: The list.** Threads with no environment are grouped under "Other" today (`EnvironmentSections.swift:42-45`, the filter label at `SidebarView.swift:254`). Rename that heading and filter label to "No folder" and update the tests that name "Other". Add `@Test func aNoFolderThreadIsListedUnderNoFolder()` to the sections' test file: a thread with a context and no environment lands in the section titled "No folder".
- [ ] **Step 9: Run** `swift test --filter "NewThreadDraftTests|WorkspaceUITests"`; expect all pass. Build both apps (`xcodebuild build` for `B4App-macOS` and `B4App-iOS`, as in AGENTS.md).
- [ ] **Step 10: Commit** `feat(ui): start a thread with no folder from the Mac and the phone`.

### Task 5: Records and gates

**Files:**
- Create: `docs/decisions/D-NNN-no-folder-starts.md`, `docs/verification/YYYY-MM-DD-no-folder-starts.md`
- Modify: `docs/milestones.md`, `README.md` (the data section: where thread folders live), `AGENTS.md` (Layout: `appFolders` is local, `SessionService` makes thread folders)

- [ ] **Step 1: Write the decision.** One bullet in the log's style covering the nine planner's decisions, and that it amends D-048 (a Codex or Claude thread always joined its folder's environment; an app-folder thread does not). List what is left for later plans: the palette, picking among several Macs from the phone, the cleanup service.
- [ ] **Step 2: Run every gate** and record the results in the verification file: `swift build`, `swift test`, the format lint, the hub's tests, `cargo fmt`, `cargo clippy`, both `xcodebuild` builds, `Scripts/docs-index.sh --check`.
- [ ] **Step 3: Check it by hand** with a scratch data directory and the fake or real Codex (`B4APP_RUNTIME_DIR`, `B4APP_DATA_DIR`): start with "No folder" in the Mac app, confirm the folder under `<dataDir>/projects`, the thread reading "No folder", a restart leaving it without an environment, and Send after deleting the folder showing the folder-gone words. Record what was and was not checked; say plainly if the phone path was only fixture-tested.
- [ ] **Step 4: Update `docs/milestones.md`** with implemented, fixture-tested, and live-tested states.
- [ ] **Step 5: Commit** `docs: record no-folder starts`.
