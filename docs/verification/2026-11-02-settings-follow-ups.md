## 2026-11-02: Settings follow-ups (the deferred review minors of D-081 to D-084)

Branch `blove/settings-connections-minors`. Gates: `swift format lint --strict` clean; `swift test` 862 tests in 125 suites passed; both `xcodebuild` builds succeeded. Each fix has a test that failed first:

- **Claude windows.** The top-level figures now fill whichever window `unifiedWindows` lacks, and the per-model weekly buckets are no longer shown as "Weekly" (`fillsTheMissingWindowFromTheTopLevel`, `perModelWeeklyWindowsAreNotTheWeek`).
- **Codex windows.** Windows are ordered by length and named by it, so a daily window reads "Daily" and two short windows are both kept (`windowsAreOrderedByLengthAndKeepTheirLength`, `windowsAreNamedByTheirLength`, `aDailyWindowIsCalledDaily`).
- **Token counts** round once in the unit shown, so they never read "1000k" (`tokensNeverReadAThousandK`).
- **Renames** reach every client: `connection.changed` carries the whole connection (`aRenameCarriesTheConnection`, `aConnectionChangeWithTheConnectionUpdatesTheList`).
- **Orphaned keys.** The new `credential.remove` deletes a key that no connection uses, and the form takes back a key whose add or edit failed (`credentialRemoveKeepsASecretInUse`, `aFailedAddLeavesNoKeyBehind`).
- **Saved edits.** Deleting a replaced key is best effort once the edit is saved (`aSavedKeyChangeIsNotReportedFailedWhenTheOldKeyStays`).

Not covered by a test: B4 token counts are now recorded last in `turn.finished`, and a failure there is ignored. Observing that needs a fault injected into the database.
