## 2026-11-12: Thread list follow-ups

D-211, on `blove/list-followups` from `main` c442426.

### Gates

- `swift test`, the whole suite, before the review's fixes: 1697 tests in 203 suites, 8 issues, all of the two kinds this Mac always has: `PostgresServerTests.locatorFindsTheFetchedTreeAndRejectsIncompleteDirectories` (it finds the PostgreSQL inside the production app in `/Applications`) and seven `MirrorSyncTests` timeouts (a reviewer and the suite were running together). `AppleSignInTests.appleSheetSaysItHasNoWindow`, which failed in the full suite on `main`, passed.
- After the review's fixes: `swift test --filter "ViewSettingsModelTests|PlacePaletteTests|SnapshotTests|AppleSignInTests|RecoveryCompressionTests|NewThreadDraftTests|MirrorSyncTests"`: 134 tests in 8 suites passed, `MirrorSyncTests` among them. The full suite was not run again.
- `swift test --filter "RecoveryCompressionTests|AppleSignInTests"` three times after the window change: 23 of 23 each time. On `main` the same pair failed four times out of four (found while gating D-209's parallel build).
- New tests: `theHighlightFollowsItsRow`, `folderRowsNameTheirEnvironment`, `aReadOvertakenByASetIsReadAgain`, `aReadThatAnswersDuringASetWaitsForIt`, `aSetLeftOutByAnEndedAccountDoesNotHoldTheNextRead`; `aSlowReadDoesNotUndoNewerValues` now expects the second read's row. The two palette tests failed to build before their code existed. The three settings tests were written with the change and were not seen failing first.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `xcodebuild` of `B4App-macOS` and of `B4App-iOS` for the Simulator, `Scripts/docs-index.sh --check`.
- A read-only review of the first diff found two bugs, both fixed here with the test above: a held-back read was lost when the account changed while a set was out, and the remembered row went stale when its row had gone.

### Not seen

Nothing here was run in an app. The Local app on this Mac holds a store with migration 0014 from another session's build, which a build of this branch (through 0013) refuses, so it was not installed. The highlight following its row, the hints under VoiceOver, the phone's sheet closing, and the settings reads against a real coordinator and hub are covered by tests only. `./Scripts/test-ios-layout.sh` was not run; CI runs it.
