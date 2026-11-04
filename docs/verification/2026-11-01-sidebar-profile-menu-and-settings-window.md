## 2026-11-01: Sidebar, profile menu, and Settings window (D-053, fixture gates)

Run from `blove/sidebar-profile-menu` at `42e329f` (on `main` after #25) on macOS 26.5.

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 556 tests in 94 suites pass |
| Mac app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Snapshots | `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` | 7 tests pass; sidebar, profile menu, search, notice, not signed in, Host disconnected, and the three Settings pages in light and dark compared by eye with the mockups. The first profile-menu capture showed the panel over the button; fixed in `42e329f` and captured again |

New tests: `ThemeTests` (`runtimeMarksLoad`, `parserHandlesArcsAndPackedNumbers`), `HubSyncTests` (`joinReportsTheDisplayName`, `leaveClearsTheDisplayName`, `restartFetchesTheDisplayName`), `AccountModelTests` (initials of odd names, log out and its failure, the phone's host-supplied account, the status line), `SettingsRequestTests`, `SearchPaletteTests`, `ThreadListTests.rowSpeaksItsReasonAndConnection`, `DevicePresenceTests` (an empty devices list is not a lost host), and `DetailMinimumSizeTests` (`sidebarFooterStaysBounded` at 240 pt with every notice at 3,000 characters; `settingsFitsItsMinimum` at 760 × 500 for each page).

Final review (a fresh reviewer over `a03a230..42e329f`) found no critical issues and six important ones, fixed in `088ba69`: iPhone search did not move to the thread it opened; the phone's Log out kept the outbox of unsent edits (now `MirrorLogOut` in `WorkspaceMirror`, with `MirrorLogOutTests`); the display name was never fetched again after a failed `/v1/me` (`aFailedNameFetchIsRetriedAfterTheNextSuccessfulPush`); the Mac's account did not refresh after a CLI join or leave (it now refreshes when the window becomes active); thread-row context was in the accessibility hint rather than the label; and two empty SVGs had shipped. After the fixes, at `088ba69`: lint clean, `swift test` 559 tests in 95 suites pass, both `xcodebuild` builds succeed.

Not run: the live checks (`B4APP_LIVE_*`), and the app on screen. Log out against a real hub, "Host disconnected" on a real phone, and ⌘, / ⌘K / ⌘N in the running app are still to be checked by hand.
