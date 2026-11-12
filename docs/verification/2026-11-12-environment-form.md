## 2026-11-12: The environment form

D-212: the "environment form" step of the thread list and environments design. The Mac edits an environment in a form in the main view; any environment takes another's folder or is deleted, its threads moving to "No folder" for good; the phone no longer makes one. Branch `blove/environment-form`, from `main` c442426.

### Gates

- `swift test --filter "EnvironmentStoreTests|EnvironmentServiceTests|ConnectionEnvironmentTests|RelaySchemaTests|RelayExecutorTests"`: pass. New or changed: deleting any environment leaves its threads with none (storage and coordinator), and after a restart the backfill leaves them under "No folder"; taking a manual environment's last folder deletes it; adding another environment's folder moves it with its threads; removing an environment's last folder is refused; the phone's relayed delete of an automatic environment goes through.
- `EnvironmentFormTests` (the name a save sends, the thread count), `AttentionModelTests` (the shared edit and delete calls, the form closing for a thread, the composer, Done, and its environment leaving the list), `PhoneEnvironmentTests` (edit only; the name starts as shown; the last folder keeps no Remove; any environment can be deleted; every other environment's folders offered), `SignInTests`: pass.
- `swift test`: 1698 tests, one failing, `PostgresServerTests.locatorFindsTheFetchedTreeAndRejectsIncompleteDirectories`, which expects no PostgreSQL to be found with `HOME=/nonexistent` and finds the one bundled in the installed `/Applications/Agent Workspace.app` (prod was reinstalled there earlier the same day). It depends on what is installed on this Mac, and this change does not touch the locator.
- Rendered (`B4APP_SNAPSHOT_DIR=… swift test --filter ListSnapshotTests/environmentForm`): the form for b4app with a second folder, light and dark, looked over by eye against `grouped-v13` card 4. The first render clipped the "Threads start here" tag and left a gap above Done; both fixed and rendered again.
- `swift format lint --strict`, `Scripts/docs-index.sh --check`, `xcodebuild` of `B4App-macOS` (Debug) and of `B4App-iOS` for the Simulator.
- `./Scripts/test-ios-layout.sh` on this checkout's Simulator (iPhone 17 Pro, iOS 26.5): 15/16. `testConnectionNoticeJourney` failed with the Simulator's "Timed out while acquiring background assertion" for the app; run alone (`-only-testing:…/testConnectionNoticeJourney`) it passed. The tests were not extended: the phone change removes a menu item and none of them touched it.

### Not checked

- The form in the running Mac app: not opened from a heading, not typed into, no folder added through the panel, no delete confirmed. The delete confirmation, the failure line, and the hover buttons were not rendered.
- The phone's sheet on a device or the Simulator; the layout tests do not open it.
- Between two devices through a hub: a delete on the Mac reaching the phone as threads under "No folder".
