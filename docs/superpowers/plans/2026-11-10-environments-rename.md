# Environments Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the app's "project" (a set of folders threads work in) to "environment" in every store, wire contract, Swift symbol, CLI output and UI string, leaving "B4 project" untouched.

**Architecture:** A pure rename with no behaviour change. Three stores each get one new forward migration (hub PostgreSQL, coordinator PostgreSQL, the phone's SQLite mirror) that renames tables, columns, indexes and triggers and rewrites the table and column names stored as data in the change logs. The shared sync fixtures change once, with the hub; the Swift side follows in the same pull request.

**Tech Stack:** Swift 6 (SwiftPM, swift-testing/XCTest as each target already uses), Rust (sqlx, `#[sqlx::test]`), PostgreSQL, SQLite (GRDB, mirror only).

**Spec:** `docs/superpowers/specs/2026-11-10-thread-list-and-environments-design.md` ("Terms", and "The rename's mechanics" under "Builder's calls"). This is plan 1 of 6; the others (no-folder starts and temporary folders; marks and rows; arrangements and synced settings; composer palette; environment form) are written after this lands, because they use the names this plan creates.

## Global Constraints

- "B4 project" is a different feature and keeps its name everywhere: `B4ProjectsView`, `AttachB4ProjectSheet`, `B4ProjectSummary`, the "B4 projects" settings label, `Server.projectPath`, the CLI's `projectDir`, `Tests/CoordinatorTests/FakeB4Project.swift`.
- Also untouched: Claude Code's `projectsDirectory` (`Sources/ClaudeAdapter`), the Xcode project (`B4App.xcodeproj`, `project.yml`, `Scripts/generate-project.sh`), the word "projection", and every decision and verification file already on main.
- Never edit an applied migration (D-178). Existing `.sql` files and `MirrorSchema.version1`…`version6` (and any later existing version) stay byte-identical; renames happen only in new migrations.
- No backwards compatibility: old names are replaced, not aliased. No dual decoding, no old method names kept.
- `Tests/Fixtures/sync/*.json` are edited only in Task 1, and both suites must pass on them by the end of Task 4.
- The SwiftUI type `Environment` already exists, so the Swift model type is `WorkEnvironment`. Where a local `environment` (process environment variables) is already in scope, name the value `workEnvironment`.
- Before each commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift`; for hub tasks `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` from `Hub/`.
- One `cargo test` per checkout at a time; start the database with `cd Hub && source <(./scripts/test-db.sh)`.

### Name map (every task uses exactly these)

| Old | New |
|---|---|
| tables `projects`, `projectFolders` | `environments`, `environmentFolders` |
| columns `projectId` (on `projectFolders`, `threads`, `connections`) | `environmentId` |
| indexes `projectFoldersByProject`, `threadsByProject`, `connectionsByProject` | `environmentFoldersByEnvironment`, `threadsByEnvironment`, `connectionsByEnvironment` |
| hub indexes `projects_by_user`, `projectFolders_by_user` | `environments_by_user`, `environmentFolders_by_user` |
| triggers `projectsChanges`, `projectFoldersChanges` | `environmentsChanges`, `environmentFoldersChanges` |
| router methods `project.list/create/update/rename/delete`, event `project.changed` | `environment.list/create/update/rename/delete`, `environment.changed` |
| JSON keys `project`, `projects`, `projectId`, `projectFolders` | `environment`, `environments`, `environmentId`, `environmentFolders` |
| error code `project_missing` | `environment_missing` |
| Swift `Project`, `ProjectFolder` | `WorkEnvironment`, `EnvironmentFolder` |
| Swift `ProjectService`, `ProjectStore*`, `ProjectList/Create/Update/Rename/Delete`, `ProjectEditResult` | `EnvironmentService`, `EnvironmentStore*`, `EnvironmentList/Create/Update/Rename/Delete`, `EnvironmentEditResult` |
| Swift UI `ProjectSectionsView`, `ProjectSection`, `ProjectFilter`, `CollapsedProjects`, `NewProjectSheet`, `RenameProjectSheet`, `PhoneProjectSheet`, `PhoneProjectDraft`, `ProjectSheetRequest` | same names with `Environment` in place of `Project` |
| `NewThreadMemory.projectId`, `folderByProject`, `runtimeByProject` | `environmentId`, `folderByEnvironment`, `runtimeByEnvironment` |
| files named `*Project*.swift` (not `*B4Project*`) | same name with `Environment` |
| UI copy "Project", "project", "New Project…", "No project" | "Environment", "environment", "New Environment…", "No folder" |
| accessibility id `picker-project` | `picker-place` |

## Review Focus

1. A Mac that was offline with unpushed change-log rows naming `projects` or `projectId` upgrades: those rows must push under the new names, not be dropped or rejected. (Task 2 test.)
2. A phone with an unsent rename of a project in its outbox upgrades: the rename must still reach the Mac. (Task 3 test.)
3. The hub's per-column clocks for `projects.name` and `threads.projectId` must carry over, so an older write cannot win after the upgrade. (Task 1 test.)
4. An old app pushing a change for table `projects` to the new hub gets the hub's existing unknown-table refusal, not a 500. (Task 1 test.)
5. "B4 projects" still appears in Settings and its sheet still attaches a B4 project; `Server.projectPath` still round-trips. (Task 5 test.)

---

### Task 1: Hub schema, wire names, and the shared fixtures

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0018_environments.sql`
- Modify: `Hub/crates/b4hub-core/src/{change.rs,writable.rs,relay.rs}`, `Hub/crates/b4hub-db/src/{relay.rs,accounts.rs}`, `Hub/crates/b4hub/src/relay/{route.rs,link.rs}`, `Hub/API.md`
- Modify: `Tests/Fixtures/sync/{changes.json,relay.json,attention.json}` (name map only; no other edits)
- Test: `Hub/crates/b4hub-db/tests/{migrate.rs,changes.rs,rls.rs,accounts.rs}`, `Hub/crates/b4hub/tests/{relay.rs,accounts.rs,relay_support/mod.rs}`

**Interfaces:**
- Produces: the wire contract in the name map, as the three fixture files state it. Swift tasks decode these files unchanged.

- [ ] **Step 1: Write the failing migration test** in `Hub/crates/b4hub-db/tests/migrate.rs`:

```rust
#[sqlx::test(migrations = false)]
async fn environments_rename_carries_rows_changes_and_clocks(pool: PgPool) {
    // Apply migrations up to 0017, then as one org/user insert: a "projects" row (name "b4app"),
    // a "projectFolders" row pointing at it, a thread and a connection with that "projectId",
    // a `changes` row whose table is 'projects', one whose table is 'threads' and column is
    // 'projectId', and `column_clocks` rows for ('projects','name') and ('threads','projectId').
    // Apply 0018.
    assert_eq!(count(&pool, r#"SELECT count(*) FROM "environments" WHERE name = 'b4app'"#).await, 1);
    assert_eq!(count(&pool, r#"SELECT count(*) FROM "environmentFolders" WHERE "environmentId" IS NOT NULL"#).await, 1);
    assert_eq!(count(&pool, r#"SELECT count(*) FROM "threads" WHERE "environmentId" IS NOT NULL"#).await, 1);
    assert_eq!(count(&pool, r#"SELECT count(*) FROM "connections" WHERE "environmentId" IS NOT NULL"#).await, 1);
    // No stored name survives in data, in any table that stores table or column names.
    assert_eq!(count(&pool, old_names_in_changes_and_clocks_sql()).await, 0);
    assert!(!table_exists(&pool, "projects").await && !table_exists(&pool, "projectFolders").await);
}
```

Use the helper the file's `sqlx_applies_a_lower_numbered_migration_added_later` test already uses to apply a prefix of the migrations. `old_names_in_changes_and_clocks_sql` counts rows in `changes` and `column_clocks` whose table name is `projects`/`projectFolders` or whose column name is `projectId` (read `0002_sync.sql` and `0003_organisation.sql` for the exact column names of those two tables; a JSON `value` column that embeds `projectId` as a key counts too).

- [ ] **Step 2: Run it and see it fail**

Run: `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --locked --test migrate environments_rename`
Expected: FAIL, migration 0018 not found (or `environments` does not exist).

- [ ] **Step 3: Write `0018_environments.sql`**

`ALTER TABLE … RENAME` for both tables, `RENAME COLUMN` for the three `projectId` columns, `ALTER INDEX … RENAME` for the two hub indexes, then `UPDATE` statements rewriting stored names in `changes` and `column_clocks` (table names, column names, and `projectId` keys inside stored JSON values). Row-level-security policies and `FORCE ROW LEVEL SECURITY` follow a renamed table; assert that in Step 5 rather than recreating them. Open the file with a comment in the style of `0017_thread_runtime_choice.sql`.

- [ ] **Step 4: Rename in Rust and the fixtures**

Apply the name map to the listed Rust sources and tests and to the three fixture files and `Hub/API.md`. Add to `Hub/crates/b4hub-db/tests/changes.rs`:

```rust
#[sqlx::test]
async fn a_push_naming_the_old_projects_table_is_refused_like_any_unknown_table(pool: PgPool) {
    // Push one change with table "projects"; assert the same refusal (error variant and HTTP
    // status) that the existing malformed-change test near line 291 of this file asserts for an
    // unknown column. If no test covers an unknown table yet, assert it for "nonsense" here too.
}
```

- [ ] **Step 5: Run the hub suite**

Run: `cargo test --workspace --locked && cargo fmt --all -- --check && cargo clippy --workspace --all-targets --locked -- -D warnings`
Expected: PASS, including `tenant_tables_force_row_level_security` listing `environments` and `environmentFolders`. Then `./scripts/test-db.sh --stop`.

- [ ] **Step 6: Commit**

```bash
git add Hub Tests/Fixtures/sync
git commit -m "refactor(hub): rename projects to environments"
```

After this task the Swift suites that decode `Tests/Fixtures/sync/*.json` are red until Task 4. That is expected; do not edit the fixtures to appease them.

---

### Task 2: Coordinator store

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0011_environments.sql`
- Modify: every Swift file in `Sources/WorkspaceStorage` whose SQL names a renamed table, column or index (SQL strings only; Swift type names wait for Task 4)
- Test: `Tests/WorkspaceStorageTests/OrganisationSchemaTests.swift` (new test), existing `ProjectStoreTests.swift`, `ChangeLogTests.swift`, `RemoteApplyTests.swift`

**Interfaces:**
- Consumes: the name map.
- Produces: the coordinator database under the new names; the change log emits `environments`, `environmentFolders`, `environmentId`.

- [ ] **Step 1: Write the failing test** in `OrganisationSchemaTests.swift`:

```swift
@Test func environmentsMigrationCarriesRowsAndUnpushedChanges() async throws {
  // Migrate a scratch database to 0010. Insert a project "b4app" with one folder, a thread and a
  // connection pointing at it; leave the change-log rows those inserts produce unpushed.
  // Migrate to 0011.
  #expect(try await scalar(#"SELECT count(*) FROM "environments" WHERE "name" = 'b4app'"#) == 1)
  #expect(try await scalar(#"SELECT count(*) FROM "environmentFolders""#) == 1)
  #expect(try await scalar(#"SELECT count(*) FROM "threads" WHERE "environmentId" IS NOT NULL"#) == 1)
  #expect(try await scalar(#"SELECT count(*) FROM "connections" WHERE "environmentId" IS NOT NULL"#) == 1)
  #expect(try await scalar(#"SELECT count(*) FROM "changes" WHERE "table" IN ('projects','projectFolders') OR "column" = 'projectId'"#) == 0)
  #expect(try await scalar(#"SELECT count(*) FROM "changes" WHERE "table" = 'environments'"#) >= 1)
  // A rename after the migration is logged under the new table name.
  try await execute(#"UPDATE "environments" SET "name" = 'renamed'"#)
  #expect(try await scalar(#"SELECT count(*) FROM "changes" WHERE "table" = 'environments' AND "column" = 'name'"#) >= 1)
}
```

Use the migrate-to-a-version helper the file's existing tests use.

- [ ] **Step 2: Run it and see it fail**

Run: `swift test --filter OrganisationSchemaTests`
Expected: FAIL, relation "environments" does not exist.

- [ ] **Step 3: Write `0011_environments.sql`**

Rename both tables, the three columns, the three indexes and the two triggers; rewrite stored names in `"changes"` (`"table"`, `"column"`, and `projectId` keys inside `"value"`); and `CREATE OR REPLACE` the function from `0009_thread_runtime_choice.sql` that lists phone-writable columns per table, with `'environmentId'` and `WHEN 'environments'`. Check `0010_owned_rows.sql` for any other function body that names the old tables and replace it the same way.

- [ ] **Step 4: Update the SQL strings in `Sources/WorkspaceStorage`**, then run

Run: `swift test --filter WorkspaceStorageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WorkspaceStorage Tests/WorkspaceStorageTests
git commit -m "refactor(storage): rename projects to environments in the coordinator store"
```

---

### Task 3: The phone's mirror

**Files:**
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (add the next version after the last existing one; update `primaryKeys`-style tables, `ownedTables`, and the local-only column map to the new names), and the SQL strings in `MirrorStore.swift`, `MirrorApply.swift`, `MirrorWrites.swift`, `MirrorTransport.swift`, `MirrorGlance.swift`, `MirrorRelay.swift`
- Test: `Tests/WorkspaceMirrorTests` (new test beside the existing schema-migration tests)

**Interfaces:**
- Consumes: the name map.
- Produces: the mirror under the new names; outbox rows carry the new table and column names.

- [ ] **Step 1: Write the failing test**

```swift
@Test func mirrorUpgradeRenamesProjectsAndKeepsAnUnsentRename() throws {
  // Build a mirror at the last existing schema version with a project "b4app", one folder, a
  // thread in it, and an outbox row for an unsent rename of that project to "app".
  // Open it with the current schema.
  #expect(try count(#"SELECT count(*) FROM "environments" WHERE "name" = 'b4app'"#) == 1)
  #expect(try count(#"SELECT count(*) FROM "threads" WHERE "environmentId" IS NOT NULL"#) == 1)
  #expect(try tableExists("projects") == false)
  // The unsent rename is still queued, under the new table name, with its value intact.
  let pending = try outboxRows()
  #expect(pending.count == 1)
  #expect(pending[0].table == "environments" && pending[0].column == "name" && pending[0].value == "app")
}
```

Match the outbox's real column names from `MirrorSchema.version2`.

- [ ] **Step 2: Run it and see it fail**

Run: `swift test --filter WorkspaceMirrorTests`
Expected: FAIL, no such table: environments.

- [ ] **Step 3: Add the new schema version** with `ALTER TABLE … RENAME TO`, `RENAME COLUMN` (SQLite 3.25+ rewrites indexes that reference the column; drop and recreate the three named indexes under their new names), and `UPDATE`s on the outbox and any clock table that stores table or column names. Update the SQL strings in the listed files.

- [ ] **Step 4: Run** `swift test --filter WorkspaceMirrorTests` — Expected: PASS for schema and store tests. Tests that decode `Tests/Fixtures/sync/*.json` through Swift wire types may still fail until Task 4.

- [ ] **Step 5: Commit**

```bash
git add Sources/WorkspaceMirror Tests/WorkspaceMirrorTests
git commit -m "refactor(mirror): rename projects to environments in the phone's mirror"
```

---

### Task 4: Swift symbols and wire names

**Files:**
- Rename and modify: `Sources/WorkspaceProtocol/Projects.swift` → `Environments.swift`; every Swift file under `Sources`, `Apps` and `Tests` that the name map touches (about 118 files; `grep -rIl -i project Sources Apps Tests --include='*.swift'` lists them), including `Tests/WorkspaceStorageTests/ProjectStoreTests.swift` → `EnvironmentStoreTests.swift` and `Tests/Fixtures/ui/waiting-thread.json`
- Modify: `Sources/Coordinator/Router*.swift` so every `environment.*` method is in `Router.needsAccount`, as its `project.*` predecessor was

**Interfaces:**
- Consumes: Tasks 1–3 (fixtures, both stores).
- Produces: the Swift names in the name map. In particular `public struct WorkEnvironment: Codable, Sendable, Equatable, Identifiable` (same stored properties as `Project`, with `folders: [EnvironmentFolder]`), `ConversationThread.environmentId: String?`, `Connection.environmentId: String?`, `actor EnvironmentService` with `ensure(folder:)` unchanged in behaviour, and `WorkspaceModel.environments: [WorkEnvironment]`.

- [ ] **Step 1: Write the failing wire test** in `Tests/WorkspaceProtocolTests` (beside the existing project wire tests, which are renamed with it):

```swift
@Test func environmentWireNamesAreTheNewOnes() throws {
  #expect(EnvironmentRename.method.rawValue == "environment.rename")
  let thread = ConversationThread(/* minimal */ environmentId: "e1")
  let json = String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)
  #expect(json.contains(#""environmentId":"e1""#) && !json.contains("projectId"))
  #expect(EnvironmentList.method.rawValue == "environment.list")
}
```

Commands expose `static let method = Method.projectList` today; the cases become `Method.environmentList` and so on. `project_missing` is a string code, not an enum case: `grep -rn project_missing Sources Hub/crates` finds its two definitions and every site that matches on it; rename them all to `environment_missing` and extend the nearest existing test that asserts the old code.

- [ ] **Step 2: Run it and see it fail** — `swift build --build-tests` fails to compile on `EnvironmentList`.

- [ ] **Step 3: Apply the name map**, module by module in dependency order (`WorkspaceProtocol`, `WorkspaceSync`, `WorkspaceClient`, `WorkspaceStorage`, `WorkspaceMirror`, `Coordinator`, `WorkspaceUI`, `AgentWorkspaceCLI`, `Apps`, then `Tests`), letting the compiler find each next site. Leave everything under "Global Constraints" untouched. UI copy changes only as the name map's last two rows say.

- [ ] **Step 4: Run everything**

Run: `swift build && swift test && swift format lint --strict --recursive Sources Tests Apps Package.swift`
Expected: PASS, including `AuthWireTests` and every suite that decodes `Tests/Fixtures/sync/*.json`.

- [ ] **Step 5: Build both apps**

Run: `./Scripts/generate-project.sh && xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS' && xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Apps Tests
git commit -m "refactor: rename Project to WorkEnvironment across the Swift targets"
```

---

### Task 5: The gate, the B4-project pin, and the records

**Files:**
- Create: `docs/decisions/D-NNN-environments.md` (number from `Scripts/docs-index.sh --next` when the pull request opens; first line `## 2026-11-10 (environments)`; amends D-048 and D-084; records the `WorkEnvironment` name and why)
- Create: `docs/verification/2026-11-10-environments-rename.md`
- Modify: `AGENTS.md` (the Layout paragraphs that say "projects" for this feature), `README.md` where it describes projects, `docs/milestones.md`
- Test: `Tests/WorkspaceUITests` (new test)

- [ ] **Step 1: Write the test that pins B4 projects**

```swift
@Test func b4ProjectsKeepTheirName() {
  #expect(SettingsPane.servers.title == "B4 projects")
  #expect(B4ProjectSummary.self == B4ProjectSummary.self)  // the type still exists under this name
  let server = try JSONDecoder().decode(ManagedServer.self, from: Data(#"{"projectPath":"/tmp/app", …}"#.utf8))
  #expect(server.projectPath == "/tmp/app")
}
```

Match the real enum (`WorkspaceModel.swift:48` returns "B4 projects" for `.servers`) and the real server type and its required keys.

- [ ] **Step 2: Run it** — `swift test --filter b4ProjectsKeepTheirName`. Expected: PASS (it guards against over-renaming; if it fails, Task 4 renamed too much and must be corrected).

- [ ] **Step 3: Run the leftover gate**

```bash
grep -rInE -i '\bproject' Sources Apps Tests Hub/crates Hub/API.md --include='*.swift' --include='*.rs' --include='*.json' --include='*.md' \
  | grep -viE 'b4 ?project|B4Project|FakeB4Project|projectPath|projectDir|projectsDirectory|projectsRoot|xcodeproj|generate-project|project\.yml|projection|\.b4app/projects|claude.*project|project (directory|folder)s? .*(claude|transcript)'
```

Expected: no output outside applied migrations (`Sources/WorkspaceStorage/SQL/0001`–`0010`, `Hub/crates/b4hub-db/migrations/0001`–`0017`, `MirrorSchema` versions before the new one) and the three new migrations' own `RENAME` statements. Read every remaining line; fix it or, if it is a legitimate other meaning, leave it and list it in the verification record.

- [ ] **Step 4: Upgrade check on real data shapes**

Run a coordinator against a scratch data directory created by the build before this branch (`B4APP_RUNTIME_DIR` under `$TMPDIR`, `B4APP_DATA_DIR` scratch): start the old build, create a thread in a folder, stop it, start the new build, and run `.build/debug/agent-workspace doctor --json`.
Expected: doctor reports no store error and the thread lists with a non-null `environmentId`.

- [ ] **Step 5: Write the records and run the docs check**

The verification record states the suites run, the gate's remaining lines, the upgrade check's result, and the rollout order: deploy the hub (migration 0018) and install the Mac and phone builds together; between the hub deploy and the app installs, the old apps' pushes of environment rows are refused and retried after the upgrade (Review Focus 4), and on two hub tasks the old task errors on renamed tables until it is replaced, so deploy in a quiet moment.

Run: `Scripts/docs-index.sh --check`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add docs AGENTS.md README.md Tests/WorkspaceUITests
git commit -m "docs: record the environments rename"
```
