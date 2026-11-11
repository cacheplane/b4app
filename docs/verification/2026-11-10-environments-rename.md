## 2026-11-10: Environments rename

The rename of "project" to "environment" (D-201) across the hub, the coordinator store, the phone's mirror, the Swift targets, the CLI, and the interface. "B4 project" is unchanged.

### Suites

- `swift test`: 1481 passing after the Swift rename (commit 70dd882); `B4ProjectNameTests.b4ProjectsKeepTheirName` was added in this task and passed on its own (`Test run with 1 test in 1 suite passed`). It asserts the Settings page title "B4 projects", `B4ProjectSummary`, and that `LocalServer.projectPath` encodes under the key `projectPath` (not `environmentPath`) and decodes back.
- `B4App-macOS` and `B4App-iOS` built after the Swift rename.
- The hub's migration, change-log, relay and row-level-security tests ran with the hub commits (c2c9ae5); the store migration tests (`OrganisationSchemaTests`) and the mirror migration tests (`MirrorMigrationTests`) cover the other two stores.

### Leftover gate

The gate command from the plan (a case-insensitive `\bproject` over `Sources`, `Apps`, `Tests`, `Hub/crates`, `Hub/API.md`, with the B4-project, Xcode and `projection` exclusions) printed 223 lines. Every one was read; none is the environment concept:

- Upgrade tests that deliberately use the old names: `Hub/crates/b4hub-db/tests/migrate.rs` (the 0018 test), `Hub/crates/b4hub-db/tests/changes.rs` (an app from before the rename pushing `projects`), `Tests/WorkspaceStorageTests/OrganisationSchemaTests.swift` (a store at 0010), `Tests/WorkspaceMirrorTests/MirrorMigrationTests.swift`, and the applied-version statements in `Sources/WorkspaceMirror/MirrorSchema.swift` (versions 1 to 6 and the version 7 renames).
- B4 project meaning: `Sources/Coordinator/LocalServerService.swift` (the registered B4 app root and its messages), `Sources/AgentWorkspaceCLI/{ServerCommands,Format}.swift` (the `server add` help and hints), `Tests/CoordinatorTests/LocalServerTests.swift`, `RelayExecutorTests.swift`, `AccountCommandTests.swift` and `EnvironmentServiceTests.swift` (the `h.project(...)` fake B4 project helper), `Tests/macOSSmoke` and `Tests/B4Runtime/README.md` (the smoke's B4 project), `Tests/CoordinatorTests/HubSyncTests.swift` (a `/tmp/b4-project` path for a local server).
- Other meanings of the word: `LogRedactor.swift` and `RuntimeOptions.swift` comments (the agent's working project), `B4TranslatorTests` (`projectsLangChainStateIntoSnapshotItems`, a projection), `Tests/iOSLayout/README.md` and `Tests/macOSSmoke/README.md` (the Xcode project and project generation).
- Opaque fixture values and sample paths, left as they are: the ids `project-1`, `their-project`, `new-project`, `no-such-project` (hub and sync fixtures, relay and RLS tests, `LayoutApp.swift`), and the paths `/Users/brian/project`, `/Users/me/project`, `/tmp/project` (`attention.json`, `changes.json`, `Hub/API.md`, storage and mirror tests, `RecordingOutputTests`).

### Upgrade check

Run on 2026-11-10 with a scratch data directory and runtime directory under `/tmp` (not the real ones), the flavour `local`, and `codex` on `PATH` replaced by a shim to `Tests/CodexAdapterTests/Fixtures/fake-codex.py`.

1. Built the commit before this branch (920e0ec) in a throwaway worktree (`git worktree add`, `swift build`).
2. Started the old coordinator through its CLI (`doctor --json`) so it created the cluster. A signed-out coordinator answers `signed_out` to store commands and signing in needs a hub, so I registered a local test account the way the coordinator tests do (`TestAccount.register`, from a throwaway test in the old worktree) and restarted it.
3. With the old build: `connection add --kind codex --name Codex`, then `thread new --connection Codex --cwd <scratch folder> --title Upgrade`. The thread came back with `"projectId" : "c31b7864-02aa-450c-9ecd-37ab9e1b8834"` (the automatic project for the folder).
4. Stopped the old coordinator, built this branch (`swift build`), and ran `.build/debug/agent-workspace doctor --json` from it against the same directories. The coordinator started on the existing store; `doctor` reported `"ok" : true` and `recentErrors` empty.
5. `thread list --json` returned the same thread (`bd9b74bb-...`) with `"environmentId" : "c31b7864-02aa-450c-9ecd-37ab9e1b8834"`, the id the old build gave as `projectId`, and no `projectId` key.
6. Stopped the coordinator and removed the worktree and scratch directories.

Not exercised: the environment list itself (there is no CLI command for it), a hub, or a phone.

### Rollout

Deploy the hub (migration 0018) and install the Mac and phone builds together, in a quiet moment. The hub does not refuse a change that names an old table: it records it and skips it (the `a_push_naming_the_old_projects_table_is_skipped_like_any_unknown_table` test in `Hub/crates/b4hub-db/tests/changes.rs`). An environment edit pushed by a not-yet-upgraded app after the hub is deployed is lost, not retried. With two hub tasks, the old task errors on the renamed tables until it is replaced.

### Accepted resets

The per-device new-thread memory (`newThread.memory` in `LocalPreferences`: last place, folder, runtime, and any unsent first-message draft) and the Mac's collapsed-sections state (`@SceneStorage` key `collapsedEnvironments`) start fresh after the upgrade. Export archives made before the rename no longer restore.

### Follow-ups

- The hub migrate test applies 0018 as a superuser, so it does not exercise the NO FORCE/FORCE row-level-security bracket.
- `migrate.rs` copies the scratch-directory guard instead of sharing a helper.
- Primary-key constraint names (`projects_pkey`, `projectFolders_pkey`) keep their old names in both PostgreSQL stores.
- The mirror migration test has no unsent insert with a null `projectId`.
- `Router.swift`'s case list around lines 99 to 101 wraps oddly.
