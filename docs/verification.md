# Verification record

Gate results and unresolved checks, newest first. Each entry names what was exercised, how, and what remains open. Live checks are only those run on the target Mac against real runtimes.

## 2026-11-01: iPhone follow-ups (D-060, fixture gates and Simulator)

Run from `blove/iphone-hig-followups` (on `main` at `4552bdb`) on macOS 26.5 with Xcode 26.6, iPhone 17 Pro Simulator (iOS 26.5).

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 573 tests in 99 suites pass |
| Mac app | `xcodebuild build … -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Read-only Settings | Simulator: Settings › Connections and › Local servers | Connections shows its two cards with status and account only, and the sentence about the Mac; no Add section, Check, Sign in, or Re-check runtimes. Local servers shows the sentence and "No projects registered on your Mac."; no Add a project or server controls |
| Titles follow the text size | `xcrun simctl ui <udid> content_size accessibility-extra-large`, then `large`, with the screen open | The open Connections large title grew in place; a thread's inline title measured 140.7 pt wide at Large, 166.0 pt at AX3, and 140.7 pt again after switching back, without leaving the screen |

`docs/screenshots/ios-hig-followups.png`. The Mac's pages are unchanged (`WorkspaceDevice.managesWorkspace` is true there; the server controls moved into a property, same views).

## 2026-11-01: Composer (D-061, fixture gates, Simulator, and Mac snapshots)

Run from `blove/ios-mobile-fit` after the merge of `main` (#31) on macOS 26.5 with Xcode 26.6, iPhone 17 Pro Simulator (iOS 26.5).

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 573 tests in 99 suites pass, including `ThemeTests.composerChoosesLineOrBox`. The first run failed `DetailMinimumSizeTests` (the Mac detail's minimum height 1317 pt against 548): the turn caption above the field wrapped a character per line at zero width; it is two lines at most on the Mac now |
| Mac app | `xcodebuild build … -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build … -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Phone geometry | 3x screenshots scanned pixel by pixel | Box with one line 74.3 pt tall; send 32 pt, 6.0 pt from the trailing and bottom edges; text 16 pt in, its cap-height centre 21.5 pt from the top (22 is the centre of a 44 pt line); three lines 116 pt, the fourth scrolls |
| Mac geometry | `B4APP_SNAPSHOT_DIR=… swift test --filter SnapshotTests`, 2x | One-line capsule 44 pt; stop 32 pt, 6 pt from the top, trailing, and bottom edges; text 16 pt in, cap centre at 21.3. The first capture showed flattened capsule ends (continuous corners); circular corners fixed it |
| Behaviour | Simulator | Typing grows the field a line at a time to three, then scrolls; Return adds a line; the field rides 8 pt above the on-screen keyboard; the caret is cobalt; the transcript scrolls under the field behind the soft edge; at AX3 the button grows to 48 pt and stays concentric; dark mode reads on the theme's surface and rule |

`docs/screenshots/composer.png` shows the phone empty, at three lines, with the keyboard, and at AX3 in dark, and the Mac's line. Open: the iPad's one-line shape was checked through the Mac (the same code path); no iPad Simulator is enrolled with the hub. Test drafts typed on the phone were cleared afterwards.

## 2026-11-01: iPhone sizes, targets, and accessibility text sizes (D-060, fixture gates and Simulator)

Run from `blove/ios-mobile-fit` (on `main` at `2e05bad`) on macOS 26.5 with Xcode 26.6; the iPhone 17 Pro Simulator (iOS 26.5) showed the mirror of the Mac's threads through the local Compose hub.

| Check | Command | Result |
| --- | --- | --- |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Clean |
| Tests | `swift test` | 572 tests in 99 suites pass |
| Mac app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iPhone app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Mac unchanged | `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` | The sidebar, profile menu, and Settings pages draw at the desktop scale as before (by eye) |
| Phone, default size | Simulator build with team `GJJKL34HCT`, `xcrun simctl ui <udid> content_size large`, screenshots before (`main`) and after | `docs/screenshots/ios-hig-default.png`. Sidebar and thread rows measured 28 pt tall on a 52 pt pitch before and 44 pt on a 44 pt pitch after (selection highlight, 3x screenshot); profile-menu items 28 to 44 pt; body text 15 to 17 pt; one title on the thread instead of two |
| Phone, AX3 | `content_size accessibility-extra-large` | `docs/screenshots/ios-hig-ax3.png`. Before: symbols ran into labels, the avatar and marks stayed small, "completed" broke inside its badge, the command title truncated to "/b…md'". After: titles wrap, the card and header stack, Diagnostics and Connections read label above value, Send drops below the editor |
| Hit regions | Taps 3 pt inside a thread row's top edge on its empty right side, and on a transcript card's padding | The row opened its thread; the card toggled Show/Hide |

Design review (same branch, after the first gates): New thread, Search, the More menu, Settings, and Connections were added to the pass, in light and dark (`xcrun simctl ui <udid> appearance dark`) and at AX3. The fixes are listed under D-060; `docs/screenshots/ios-hig-review.png` shows New thread before and after and the dark Settings and Connections pages. Gates rerun after the fixes: lint clean, `swift test` 572 tests in 99 suites pass, both app builds succeed, the 7 Mac `SnapshotTests` pass. The Hanken navigation titles are computed when the app starts, so a text-size change while it runs takes effect at the next launch (system inline titles barely scale either).

Open: the Connect screen was checked in code only (the phone is joined, and leaving would need a new enrollment code); its fields and button were already 44 pt and now share the 16 pt margin and the phone scale. No `performAccessibilityAudit` UI test exists yet (no XCUITest target).

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

## 2026-11-01: Coordinator robustness (D-052)

- `HubSyncTests.aKeychainPromptIsReportedAndTheTokenIsReadOncePerRun`: with the secret store's read held open (an unanswered prompt), `hub status` answers and names the Keychain wait; after release the push drains and later pushes and the pull reuse the one read.
- `KeychainCallTests`: a Keychain call made from the main actor runs off it, and its error reaches the caller.
- `PostgresServerTests.replacesAPostmasterFromAnotherInstall` and `aPostmasterRunningAnotherBinaryIsNotThisInstalls`: a server whose binary was written after it started, or that runs another file, is stopped and replaced; this install's own server is still adopted.
- `ReasonLineTimeTests`: a reply up to a minute old, or a few seconds in the future, reads "Replied just now".
- Manual, scratch coordinator with the fake Codex: `turn send <id> please hang around --no-wait` returned in 0.05 s and the stored message was "please hang around".

## 2026-11-01: distribution, provisioning, and the Mac keychain (D-051)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, XcodeGen 2.46.0). Research: `docs/research/reports/App Store and TestFlight signing.md`. The owner's running app and coordinator were left alone; the package checks ran in the worktree's own `dist/` and a scratch runtime and data directory.

| Check | How | Result |
| --- | --- | --- |
| File-based keychain across rebuilds | A throwaway tool (`com.cacheplane.b4app.kcprobe`) with `SecKeychainSetUserInteractionAllowed(false)` added an item, then was rebuilt to a new CDHash and read it | Developer ID rebuilds: read OK with no prompt. Ad hoc rebuild: `-25293` (it would have prompted). Probe item deleted |
| Data-protection keychain without a profile | The same probe, Developer ID, `kSecUseDataProtectionKeychain` | `-34018` "A required entitlement isn't present", as TN3137 says |
| iOS, as CI builds it | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` | Pass |
| iOS Release bundle | The same, `-configuration Release`, signing to run locally | `ITSAppUsesNonExemptEncryption = false`, the local-network string, versions from build settings (0.1.0, 1), `PrivacyInfo.xcprivacy` in the bundle, no `NSAppTransportSecurity`; the Debug build keeps the localhost exception |
| macOS, as CI builds it | `xcodebuild build -scheme B4App-macOS CODE_SIGNING_ALLOWED=NO` | Pass |
| Coordinator bundle | `B4APP_SKIP_PROFILES=1 B4APP_SKIP_NOTARIZE=1 B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` | `Contents/Helpers/{B4AppCoordinator.app,agent-workspace}`; identifiers `com.cacheplane.b4app.coordinator` and `com.cacheplane.b4app.agent-workspace`, hardened runtime, team GJJKL34HCT; the bundle's LaunchAgent plist names `Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator` |
| Wrapped coordinator runs | The package's CLI `doctor` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`, then `coordinator stop` | Spawned the wrapper's executable, which found `SharedSupport/postgres` and served; `secrets: login keychain (file-based)` (no profile) |
| Suite, lint | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass: 334 tests in 76 suites; lint clean. A first incremental run crashed (SIGSEGV decoding `DiagnosticsReport`) because the test bundle was linked against the old `CoordinatorInfo` layout; clearing `.build/arm64-apple-macosx/debug` fixed it |

### Live, with the owner's profiles and API key

Both Developer ID profiles (App IDs `com.cacheplane.b4app` and `com.cacheplane.b4app.coordinator`, Keychain Sharing group `GJJKL34HCT.com.cacheplane.b4app.shared`, expiring 2044-10-27) are tied to the Developer ID certificate under the Previous Sub-CA, which expires 2027-02-01; the profiles must be regenerated with its successor.

| Check | How | Result |
| --- | --- | --- |
| Notarized package with profiles | `B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` at `3cff73e` (this branch merged with M8b) | Submission `63e2dc2a-7047-4372-acf2-9ed722f13cfd` Accepted, stapled; `spctl`: `source=Notarized Developer ID`; `syspolicy_check distribution` passed. An earlier package before the merge: `c541ae47-b369-4aed-8773-34bf4c56b98e`, same results |
| Installed on the owner's Mac | Old `dist/` moved aside, the zip unpacked, `Agent Workspace --register-agent` | The LaunchAgent names `Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator`; launchd started it; `doctor`: `secrets data-protection keychain (GJJKL34HCT.com.cacheplane.b4app.shared)` |
| Moving the existing items | First read of the hub token by the new coordinator | **Failed, and lost the token.** The read prompted once (the item's ACL named the old ad hoc coordinator), was allowed, and the value was written to the group; then the delete of the login-keychain copy, which set no `kSecUseDataProtectionKeychain`, also deleted the new copy: an entitled process with no flag deletes from both keychains. The next read found nothing, so the hub answered 401. Found from the coordinator's unified log (`SecItemAdd_ios`, then `SecItemDelete_ios`). The coordinator was stopped before it read the one other item (`secret:0bfa…`), which is still in the login keychain |
| The fix | `3062544`: every query sets `kSecUseDataProtectionKeychain` explicitly; `everyQueryNamesItsKeychain` | An entitled probe (`com.cacheplane.b4app.coordinator`, the coordinator profile and entitlements) compiled from `Secrets.swift` on a throwaway service: the old file loses the item on the second read, and even after `put`; the fixed file migrates it, keeps it, updates and removes it. With an explicit `false`, a delete leaves the group's copy alone |
| Fixed build installed | The same package at `82569b2`, swapped in the same way | Submission `cf6cb03e-7468-4733-819f-0e5d3245bfd4` Accepted; `spctl`: `source=Notarized Developer ID`; the coordinator started from the wrapper on the data-protection keychain; `secret:0bfa…` still in the login keychain; the hub still 401 (no token) |
| Re-joined, on the fixed build | `hub leave` (local only; the hub refused the revoke without a token), a code from `docker compose run --rm migrate enroll --user blove` on stdin to `hub join http://localhost:8080`, then `coordinator restart` and the app opened | New device "Brian’s MacBook Pro (2)" (`01a1988c-…`, the Mac's current name); 188 changes pushed, `unsynced 0`; the token went straight into the group (the login keychain still holds only `secret:0bfa…`); after the restart every hub request read it and got 200, with no `last error`; the app attached to the running coordinator over its socket. The old device `01a194cf-…` stays at the hub, unrevoked, with no usable token |
| iOS archive and export | `B4APP_ASC_KEY_ID=… B4APP_ASC_ISSUER_ID=… ./Scripts/upload-ios.sh` | The archive is unsigned (an automatically signed archive needs a registered device, and the team has none); the export registered the App ID and signed with a cloud-managed Apple Distribution certificate and "iOS Team Store Provisioning Profile: com.cacheplane.b4app.ios" |
| iOS upload | The same script | Xcode 26.6's `destination: upload` failed ("Cannot verify client's JWT headers") with the same key that had just provisioned the export; `altool --validate-app` then `--upload-app` with that key passed. Build 0.1.0 (2611011615), delivery `f960f188-4368-4338-a1e2-1da8fab89c11` |

Open: the move of the remaining login-keychain item (`secret:0bfa…`, created before the hub join) on its first read by the fixed build; revoking the old Mac device at the hub, which has no operator command yet; adding the TestFlight build to an internal group and installing it on a phone.

## 2026-11-01: M8b live gate

Run on the owner's MacBook Pro (macOS 26.5) from `feat/m8b-organisation` at `2c5ccef`, plus `87a494e` (the phone's project rename, found missing below). Backups first: `agent-workspace db backup` (152 rows) and `pg_dump` of the hub (13 tables), both in `~/Library/Application Support/b4app/backups/`. The Compose stack moved to the branch's `Hub/` on the same `hub_b4hub-db` volume: migration `0003_organisation` applied, `/readyz` `{"migrations":"current"}`. The packaged app was rebuilt with `./Scripts/package.sh` and swapped into `~/repos/b4app/dist` (main's bundle parked in `dist-main/` for the restore). The store migrated to `0004_organisation` and backfilled 2 projects. Then `agent-workspace hub status` showed `unsynced 0` and the coordinator a pid started at 14:40:00Z. The phone is the iPhone 17 Pro Simulator against `http://localhost:8080`. Real runtimes: Codex 0.166.0 and Claude Code.

| Exit item | Result |
| --- | --- |
| 1. Attention order on both devices | Pass. The phone list opened with both threads quiet (the `0004` backfill). A Codex reply moved its thread to the top as unread. A Claude Code turn asking to run `touch` opened a `tool_permission` request at 14:50:39.9; the phone showed the thread first with the cobalt dot and "Waiting for your input". Declined on the Mac at 14:53:50.9 (`request respond --decline`): the phone showed "Working" (ring) below the unread thread within seconds, then unread when the reply finished. Opened on the phone at 14:54:03.8: the Mac's `readTurnId` matched the latest turn 0.15 s later. The Mac sidebar showed "Pinned" and a collapsible "B4 Run (Mac)" section, with the b4app section hidden while its only thread was pinned |
| 2. Phone and Mac edits show on the other | Pass, each within about 1 s of the tap: pin (14:54:11), thread rename (14:54:23 at the hub, on the Mac by 14:54:25.2), draft (14:54:28; `draft.read` on the Mac returned it), archive (on the Mac 0.14 s after the tap), and project rename (on the Mac 0.2 s after). Reverse, from the CLI and the socket: title, unpin, unarchive, pin, project rename, and draft all showed on the phone within a few seconds. The project rename needed `87a494e`: the phone had no rename control, although the spec gives the phone that edit and the mirror already answered `project.rename` |
| 3. Live convergence | Pass. `docker compose stop hub` at 14:58:32 (the phone showed "Not synced"). The phone renamed the thread "Offline phone title" and drafted "Offline phone draft"; then the Mac set "Offline Mac title" and "offline Mac draft" (4 unsynced). `docker compose start hub` at 14:58:57. The phone's edits reached the hub at 14:59:03 and the Mac's at 14:59:13, with greater clocks (`…1979ecbc9` over `…1979ea41b`). By 14:59:14 the Mac showed `unsynced 0`, and both devices showed the Mac's title and draft. The reversed-clock order is fixture-tested only |
| 5. The real hub's rows | 198 change rows over `connections`, `displayItems`, `drafts`, `projectFolders`, `projects`, `runtimeRequests`, `threads`, `turns`: none holds a `secret:` reference, an executable path, a `pid`, or a socket path |

Found during the run, outside the exit items:

- **Keychain prompt blocks the hub actor.** Each ad-hoc `package.sh` rebuild changes the coordinator's signature, so its first read of the hub token raises a Keychain access prompt. Until someone answers, `HubSync` is suspended inside `SecItemCopyMatching`: nothing pushes, and `hub status` times out after 15 s. The coordinator that main's 2026-10-31 rebuild started sat there for 8 hours. Answering the prompt cleared it.
- **A stale cluster survives a coordinator swap.** That stuck coordinator did not exit within `coordinator stop`'s 10 s, and when it did go it left its PostgreSQL server (started from the old bundle) running. The new coordinator reused that server, and `0004` failed: the server could not `dlopen` the new bundle's `plpgsql.dylib`, whose ad-hoc signature differs. The migration rolled back. After `pg_ctl stop` with the old bundle's binaries, the new coordinator started its own server and migrated.
- **Simulator team prefix.** With the Developer ID certificate now installed, Xcode signs Simulator builds as `GJJKL34HCT.com.cacheplane.b4app.ios` instead of `FAKETEAMID…`, so the reinstalled app could not read the token the earlier build had stored, and every request got a 401. The Simulator was enrolled again (the old phone device revoked at the hub).
- `agent-workspace turn send --no-wait` did not return after the turn opened a request; the request itself was recorded correctly.
- A just-finished reply reads "Replied in 0 sec." on the phone when its time is a moment ahead of the phone's clock.
- The Codex connection runs with its sandbox off, so a Codex turn never opens a command approval; the approval check used Claude Code.

## 2026-11-01: M8b final-review fix wave (fixture gates)

Run from `feat/m8b-organisation` at `446c8c0` (six commits over `6baea96`: read marks wait for the thread to be on screen; `0004` backfills `readTurnId` and indexes `runtimeRequests("threadId", "state")`; the phone's push is capped at 8 MiB and unsent edits of one column collapse; an advisory lock orders local writes against pulled batches; a router test waits for its events; README and D-048/D-049). `Hub/` was not touched, so the Rust gates were not rerun. The live gate below is still pending.

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 526 tests in 89 suites in 37.7 s, no issues on the first run |
| Project | `./Scripts/generate-project.sh` | Regenerated |
| macOS app | `xcodebuild build ... -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app | `xcodebuild build ... -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |

## 2026-11-01: M8b organisation (fixture gates; live gate pending)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6), run from the worktree `feat/m8b-organisation` at `2cedd55` (the head of Tasks 1 to 12) before this documentation commit. **Only the fixture gates are recorded here. The live gate (the owner's packaged app, the Compose hub, and the Simulator) has not been run, and nothing below is a live result.** The owner's running Agent Workspace app, its LaunchAgent, `~/Library/Application Support/b4app`, and the Compose stack were not touched.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 517 tests in 89 suites in 36.4 s (324 tests at the end of M8a). The first full run reported 1 issue in 517 tests: `MirrorSyncTests.offlineEditsWaitAndDrainWhenTheHubReturns` (`MirrorSyncTests.swift:185`, `lastError == nil`), a timing flake under load (the PR #19 class, a 10 s wait). `swift test --filter MirrorSyncTests` alone passed (13 tests), and a second full run passed with no issues |
| Project | `./Scripts/generate-project.sh` | `B4App.xcodeproj` regenerated from `project.yml` |
| macOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| iOS app | `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` |
| Rust format | `cd Hub && eval "$(./scripts/test-db.sh)" && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked`, then `./scripts/test-db.sh --stop` | Pass: 117 tests against a real PostgreSQL 17.11 (77 at the end of M8a): `b4hub` 51 (unit 22, `changes` 14, `enroll` 10, `health` 5), `b4hub-core` 19, `b4hub-db` 47 (unit 3, `changes` 34, `migrate` 7, `rls` 3) |
| CI | the Swift package job, the apps job, and the Ubuntu `hub` job | Recorded in the PR for `feat/m8b-organisation`, not here |

### Exit items the fixtures cover

| M8b exit item (design) | Fixture evidence | Not covered by fixtures |
| --- | --- | --- |
| 1. Sidebar and phone list in attention order; an approval moves its thread to the top within one poll; answering it moves it to unread; opening it on the phone makes it quiet on both | `Tests/Fixtures/sync/attention.json` run against the coordinator's store (`ActivityQueryTests`), the mirror's store (`MirrorActivityTests`), `Attention` (`AttentionTests`), and the model (`AttentionModelTests`, `ThreadListTests`); `markRead` and its guard in `ProjectServiceTests` | The timing within one poll, and both screens, against the real stack |
| 2. A phone rename, pin, archive, project rename, and draft show on the Mac, and the reverse | Hub: `phone_title_edit_applies_and_later_mac_edit_wins`, `a_phone_may_insert_a_draft_and_clear_it`; Mac: `HubPullTests`, `RemoteApplyTests`; phone: `MirrorWritesTests`, `outboxIsPushedThenPulledBack` | The same through the Compose hub with the owner's joined app |
| 3. Convergence: both devices rename one thread and edit one draft while the hub is down, the Mac later; both converge on the Mac's values, and on the phone's with the clocks reversed | The shared `conflicts.json` (`conflictFixtureMergesToTheExpectedValues`, both orders, in the Swift suites; the Rust suite decodes the same file), `stale_phone_edit_loses`, `offlineEditsWaitAndDrainWhenTheHubReturns` | The live run with `docker compose stop hub` |
| 4. A cursor below a pruned horizon resyncs from `/v1/snapshot` without losing an outbox row | `stale_cursor_gets_resync_and_snapshot_restores`, `a_pruned_cursor_resyncs_through_the_snapshot_over_http`, `staleCursorResyncsFromSnapshotWithoutLosingLocalRows`, `resyncUsesTheSnapshot`, `snapshotKeepsTheOutbox`, `aSnapshotClockNewerThanAnUnsentEditWins` | A prune of the real hub |
| 5. A phone change to a Mac-only column is refused; no hub row holds a secret, path, or pid | `phone_cannot_write_mac_only_columns`, `connection_secrets_are_scrubbed_even_if_sent` | A look at the real hub's tables after the live run |
| 6. `cargo test`, `swift test`, and both app builds pass | Above, locally | CI |

### Live gate: run 2026-11-01 (see "M8b live gate" above; the table below is the procedure as planned)

To be run only after the owner's go-ahead, because it rebuilds the owner's packaged app and migrates the owner's real local store (to `0004`) and the Compose hub's volume (to `0003`); both migrations are hard to reverse. First: `agent-workspace db backup` and a `pg_dump` of the hub volume. Then rebuild the hub image and bring the stack up from the branch's `Hub/` (`/readyz` must show `"migrations":"current"`), `./Scripts/package.sh`, quit the app, `agent-workspace coordinator restart`, reopen, and run the three items below in the iPhone 17 Pro Simulator with a fixture approval (or a real Codex command approval), recording each with timings. Fill this table in; leave a row `not run` until it is.

| Exit item | Procedure | Result |
| --- | --- | --- |
| 1. Attention order on both devices | Open the Mac sidebar (Pinned and per-project sections) and the phone's list with the project filter. Start a fixture turn that opens an approval: the thread must move to the top on both within one poll interval. Answer it on the Mac: it moves to unread. Open it on the phone: it becomes quiet on both | not run |
| 2. Phone and Mac edits show on the other | Rename a thread on the phone, pin one, archive one, rename a project, and type a draft: each shows on the Mac within one poll interval. Then do the reverse | not run |
| 3. Live convergence | `docker compose stop hub`; rename the same thread and edit the same draft on both devices, the Mac's edit later; `docker compose start hub`; both must show the Mac's values (and, with the phone's edit later, the phone's) | not run |

Also record for the live run: `agent-workspace hub status` shows `unsynced 0`; `agent-workspace coordinator status` shows a pid started after the restart; a screenshot of the Simulator list and the Mac sidebar; and that the owner's app, once restored from `main`, is rebuilt with the same dev loop.
## 2026-10-31: Developer ID signing and notarization (D-039 gate)

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, notarytool 1.1.2). The owner created the certificate and the `b4app` notarytool profile; neither password passed through the script or this session. The owner's running app was quit, `~/repos/b4app/dist` was moved aside and replaced from the stapled zip, `agent-workspace coordinator restart` ran, and the app was reopened.

| Check | How | Result |
| --- | --- | --- |
| Identity found | `security find-identity -v -p codesigning` | 1 valid identity: `Developer ID Application: Brian Love (GJJKL34HCT)` |
| Notary profile | `xcrun notarytool history --keychain-profile b4app` | Succeeds ("No submission history.") |
| Signing | `B4APP_SIGN_IDENTITY="Developer ID Application: Brian Love (GJJKL34HCT)" ./Scripts/package.sh` | Every PostgreSQL Mach-O, both helpers, and the bundle signed with `flags=0x10000(runtime)` and a secure timestamp; `codesign --verify --deep --strict`: valid on disk, satisfies its Designated Requirement; `TeamIdentifier=GJJKL34HCT`; entitlements an empty dictionary |
| Before notarization | `spctl -a -vv --type exec` | `rejected`, `source=Unnotarized Developer ID` (expected; the script shows it and goes on) |
| Notarization | `xcrun notarytool submit … --keychain-profile b4app --wait` | Submission `7f19144e-ec91-40b3-95ab-928ac1221b32`: **Accepted** on the first submission, no entitlement changes |
| Stapling | `xcrun stapler staple`, `stapler validate`, then re-zip | "The staple and validate action worked!"; the shipped `dist/Agent-Workspace-0.1.0.zip` (39 MB; app 122 MB) holds the stapled app |
| Gatekeeper | `spctl -a -vv --type exec "dist/Agent Workspace.app"` | `accepted`, `source=Notarized Developer ID`, `origin=Developer ID Application: Brian Love (GJJKL34HCT)` |
| As downloaded | The zip copied with a `com.apple.quarantine` attribute, unpacked with `ditto -x -k`, then `spctl -a -vv`, `syspolicy_check distribution`, `stapler validate` | Quarantine propagated to the app; `accepted`, `source=Notarized Developer ID`; "App passed all pre-distribution checks and is ready for distribution."; ticket valid |
| Coordinator | `agent-workspace coordinator restart`, `doctor --json`, `thread list` | Launch agent loaded and running, last exit 0, from the new bundle; the bundled `postgres` serves the store; the coordinator mapped the bundled `libpq.5.dylib` under the hardened runtime; both stored threads listed |
| First launch | `open "dist/Agent Workspace.app"` | Launched; the app's Unix socket is connected to `coordinator.sock` in the LaunchAgent coordinator, and it hosts nothing itself (no child processes). The installed copy came from a local unzip, so it carries no quarantine and Gatekeeper's first-launch check has nothing to show; the downloaded case is the row above. Screen access was declined, so nobody watched the window on screen |
| `SMAppService` after a rebuild (D-042) | A throwaway bundle (`com.cacheplane.b4app.smprobe`) with `Contents/Library/LaunchAgents` and a `BundleProgram` helper, registered with `SMAppService.agent(plistName:)`; the helper rebuilt to a new CDHash and re-signed, then `launchctl kickstart -k`, without re-registering | Developer ID: the job (`has LWCR`) respawned the rebuilt helper at once (`state = running`, the new build's log line). Ad hoc control under a fresh label: the first build ran, and the rebuild went to `spawn scheduled`/`spawn failed`, the D-042 failure. After a Developer ID registration, an ad hoc build under the same label could not spawn even after unregister and register. Both probes unregistered afterwards |
| Ad hoc path | `./Scripts/package.sh` with no identity, in the worktree's own `dist/` | `Signature=adhoc`, `flags=0x2(adhoc)`, verify passes, no notary step; the bundle is now re-signed with its (empty) entitlements file |
| Suite, lint | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass: 332 tests in 75 suites; lint clean (no Swift source changed) |

So the managed agent's requirement is stable across rebuilds once the build is team-signed; the per-user plist of D-042 stays in place unless the owner asks to switch. Still open: Developer ID builds on another Mac, and an on-screen first launch of a downloaded copy (macOS still asks once to confirm opening an app downloaded from the internet; it no longer refuses it).

## 2026-10-31: blank window on a pending Claude request

Found in the owner's running app: a new Claude thread asked to run Bash, and when the thread opened the window went blank, sidebar and detail, with the toolbar still working; relaunching restored it until the thread was opened again. Root cause and rule in D-047.

| Check | How | Result |
| --- | --- | --- |
| Reproduce | The stored thread exported to `Tests/Fixtures/ui/waiting-thread.json`; the packaged app quit and a Debug build of the same tree launched against the running coordinator; env switches hid one part of the thread detail per round | Blank with the request card; rendered without it; rendered with the command text plain or selectable; blank again with only `fixedSize(horizontal: false, vertical: true)` on the command |
| Measure | `NSHostingController(rootView: ThreadsView(model:)).sizeThatFits(in: .zero)` on the mirrored thread | 184 points without the request, 4,749 with it; 822 with the `fixedSize` removed; 485 with the bounded list (then 240-point cap) |
| Near the limit | The rendering variant with the window dragged to 900 by 652 points | Not blank, but the sidebar's top was pushed out and the composer off the bottom |
| Regression test | `swift test --filter DetailMinimumSizeTests` against the unfixed views (`RuntimeRequestView`, `ThreadsView`, `ComposerView` stashed) | Fails: 4,749; 100,969; 201,733; 103,418 points at zero width, 650 at 610 wide for the banner variant |
| With the fix | The same | Pass, five variants (the long-draft case is folded into each) |
| Live | The Debug build with the fix, thread "test" opened, then the window dragged to its minimum | Renders: transcript, the whole command, Allow once / Allow for session / Deny, the composer with Stop and Send; the pending permission was left unanswered for the owner |
| Suite, lint, apps | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift`, both `xcodebuild` schemes | Pass: 328 tests in 75 suites (324 before; the new test runs four variants); lint clean; macOS and iOS build |

## 2026-10-31: `db restore` of a store with updates (jsonb scalars)

Found while bringing up the M8a hub: `agent-workspace db restore` failed with `invalid input syntax for type json` on any archive from a store whose change log held an update. An update row in `changes` stores the changed column's value as jsonb, which for most columns is a scalar (`"ready"`, `true`, `7`, `null`). The version 1 exporter parsed every jsonb cell into a value, so a scalar string landed in the archive bare, and the restore bound it back to the jsonb column as raw text. Objects (inserts, display-item payloads, capabilities, routes) were unaffected, which is why `exportAndRestoreRoundTrip`, seeded with inserts only, passed.

| Check | How | Result |
| --- | --- | --- |
| Reproduce | New `exportAndRestoreRoundTripKeepsScalarChangeValues` seeds a store, then updates a string, a boolean, a number, a JSON null (optional column set to nil), and a nested payload, and restores the archive | Failed on the old code with the reported error on the first scalar (an `updatedAt` string) |
| Fix | Archive version 2: every `json`/`jsonb` cell travels as its JSON text in a string; restore looks the table's JSON columns up in the catalog and binds that text as jsonb. Version 1 archives are still read, each jsonb value re-encoded as JSON, so an old archive with bare scalar strings now restores too (`restoreReadsAVersionOneArchive`). An archive newer than this build is refused | Both new tests pass; the restored change log, threads, connections, and display items equal the source's, and the JSON null is a jsonb null in both stores |
| Suite | `swift test` after clearing `.build/debug` | Pass: 264 tests in 62 suites in 35 s. A first incremental run on a `.build` left by an older worktree build reported 8 error-code mismatches in the adapter suites; the test modules had been linked against a stale `WorkspaceProtocol`, and a clean build cleared them |
| Lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Live | `agent-workspace connection add --kind codex` on scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`, then `db backup`, `db restore --replace` into the same store, `coordinator stop`, and `db restore` into a second, empty scratch store | Pass. The archive (version 2, 9 rows) held 7 update rows with scalar values (`"ready"`, `"authenticated"`, timestamps, the account scope) and one object (`capabilities`); both restores returned 9 rows, `db status` on the fresh store showed 1 connection and 8 changes, and `connection list` returned the connection as `ready / authenticated` with its capabilities. Before the fix, the first scalar update row made the same restore fail |

Still SQL NULL after restoring a version 1 archive: a jsonb null, which the old exporter could not tell from an absent cell. No row the app writes carries one outside the change log, where `ChangeRecord` reads both as a missing value.

## 2026-10-31: M8a read-only mirror

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6), Docker 27.4.0 for the hub image and Compose, the iPhone 17 Pro Simulator (iOS 26.5) for the phone. The owner's running Agent Workspace app, its LaunchAgent, and `~/Library/Application Support/b4app` were left alone; the live gate ran a scratch debug coordinator on scratch `B4APP_DATA_DIR` and `B4APP_RUNTIME_DIR`. **The agent in the live gate was the fixture `fake-codex.py`. The sync path (coordinator, hub, PostgreSQL, iOS mirror) was real end to end; the inference was not, and, at the time of this gate, the owner's packaged app had not joined a hub; the evening entry below covers the join with a real Codex turn.**

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Rust format | `cd Hub && source <(./scripts/test-db.sh) && cargo fmt --all -- --check` | Pass |
| Rust lint | `cargo clippy --workspace --all-targets --locked -- -D warnings` | Pass |
| Rust tests | `cargo test --workspace --locked` (then `./scripts/test-db.sh --stop`) | Pass: 77 tests against a real PostgreSQL 17.11: `b4hub` 43 (unit 20, `changes` 8, `enroll` 10, `health` 5), `b4hub-core` 12, `b4hub-db` 22 (unit 3, `changes` 10, `migrate` 6, `rls` 3) |
| Swift format | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 324 tests in 74 suites (262 before M8a; 319 before the final-review fixes) |
| macOS app | `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | Pass |
| iOS app | the same with `-scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| CI | the `hub` job (Ubuntu, `postgres:17` service) | Recorded in the draft PR cacheplane/b4app#17 (base `design/m8-hub`), not here: the controller observed all three checks (the Swift package job, the apps job, which runs both app builds, and the Ubuntu `hub` job) green at commit a6d9a2a (end of Task 6) and partially green on later heads; later heads, including the docs commit, were still pending when this was written. The final head's result is in the PR |
| Image | `docker build` of `Hub/Dockerfile` on the build Mac, `linux/arm64` | Builds; runs as uid 10001; `docker compose ps` showed `hub` healthy after about 11 s (Task 5) |

### Live on this Mac (Task 9 gate)

| Step | How | Result |
| --- | --- | --- |
| Hub up | `docker compose build` and `up -d` in `Hub/` with a `Hub/.env` holding two random passwords; `curl localhost:8080/readyz` | db healthy, `migrate` exited 0, hub serving: `{"migrations":"current","minClientProtocol":1,"ok":true}` |
| Seed and codes | `docker compose run --rm migrate seed --org cacheplane … --user blove …`, then `migrate enroll --user blove` once per device | Org and user seeded; each code printed once and spent once |
| Scratch coordinator | `agent-workspace doctor --json` with scratch directories spawned `.build/debug/b4app-coordinator`; `connection add --kind codex --path Tests/CodexAdapterTests/Fixtures/fake-codex.py` | `ready`, `authenticated`, 0.166.0 (the fixture's version string) |
| Mac join | the code piped on stdin to `agent-workspace hub join http://localhost:8080` | Joined as `blove@cacheplane`; it never appeared as an argument; `hub status` then showed 0 unsynced |
| Thread and turn on the Mac | `thread new --connection "Fixture Codex" --title "First Codex thread"`; `turn send` | `[turn completed]`, reply "Hello from fake Codex."; `hub status` back to 0 unsynced |
| Phone enrolls | Simulator build signed ad hoc by Xcode; Connect screen with `http://localhost:8080`, an eight-character code, device name "iPhone 17 Pro" | Switched to the shell; the list showed "First Codex thread" without a refresh (`docs/screenshots/ios-mirror-list.png`) |
| Transcript | opened the thread; then quit and relaunched the app | The user message and the reply showed; after relaunch the stored link resumed the pull loop and the list showed at once |
| Live turn | `turn send` on the Mac while the thread was open on the phone | The second user message and its reply were on screen 1.4 s after the Mac's turn completed (`docs/screenshots/ios-mirror-thread.png`); the first screenshot taken already showed them |
| Live new thread | `thread new --title "Second Codex thread"` while the list was open | On the phone within 1.6 s |
| What the hub holds | `psql` in the Compose database | `connections`: `authReference` NULL, `target` empty, `localServerId` NULL, and the hub has no `localServers` table; `changes` count 35, all from the `macos` device; the Mac's `db status` also 35 and the phone's `syncState` cursor 35 |
| URL refusal, Mac | `agent-workspace hub join http://192.168.1.10:8080` | `protocol_invalid`, "The hub URL must use https (http is allowed only for localhost)."; exit 4; the existing link untouched |
| URL refusal, phone | the same URL typed on the Connect screen | The same message inline, the code kept, no request made, nothing from 192.168.x in the hub log |
| Secret boundary | the Simulator's unified log for the app (5,797 lines) and `docker compose logs hub` searched for each code and for `Bearer` | 0 matches; the Mac's code was only ever on stdin; the store holds a `secret:` reference, never the token |
| Teardown | `coordinator stop`, `docker compose down -v`, scratch directories, `Hub/.env`, and code files removed, app uninstalled from the Simulator | The owner's coordinator (pid 11944) was never touched |

Three things the gate found and Task 9 fixed in the same commit: an unsigned Simulator build cannot use the data-protection Keychain (`Keychain error -34018`), and a failure after enrollment (the Keychain put or the link save) had spent the code and left an unrevoked device, so `MirrorHost.connect` now removes the secret and revokes the new device with the token it still holds. The same cleanup was confirmed against an unsigned build (the device row showed `revoked_at` and no tokens). Tapping a thread on an iPhone did nothing in the shared shell (the collapsed split view's sidebar was buttons, not navigation links); `WorkspaceRootView` now binds the compact column.

### Review Focus items that only the live gate exercises

- **URL refusal on the Connect screen.** `HubURLTests` covers the rule; the Simulator run showed the screen refusing before any request (no screenshot of that step was kept).
- **The Simulator end to end** (hub, enrollment, push, mirror, live update): there is no other way to exercise it; it passed with the fixture agent as recorded above.

### Live on this Mac: the packaged app joined, with a real Codex turn (2026-10-31, evening)

| Step | How | Result |
| --- | --- | --- |
| Packaged app on this branch | `./Scripts/package.sh`, the running app quit, `dist/Agent Workspace.app` replaced, `agent-workspace coordinator restart` | Coordinator pid 76419 on the new bundle; `db status` shows `0001_init, 0002_changes, 0003_hub`, so the live store migrated in place (18 change rows kept) |
| Hub | Compose stack from `Hub/` with a local `.env`; `seed` and two `enroll` codes through the `migrate` service | `/readyz` current; org `cacheplane`, user `blove` |
| Mac join | `agent-workspace hub join http://localhost:8080 --name "Brian's MacBook Pro"` with the code on stdin | `hub status`: device enrolled, `unsynced 0`, first push 2026-11-01T01:52:39Z |
| Phone enrol | The iOS build on the booted iPhone 17 Pro Simulator, Connect screen, URL default and the second code | List showed the real `First Codex thread` (connection `Codex`) within one poll of the Mac's push; before the Mac joined the list was honestly empty |
| Real Codex turn | In the Mac app, opened the thread and sent `Reply with exactly one word: synced` (clicked Send; a plain Return in the composer inserts a newline through accessibility) | Codex answered `synced`; the Mac transcript, the phone's transcript, and `hub status` (`unsynced 0`, 39 changes on the hub) agreed within seconds |
| Hub rows | `psql` in the Compose database | `connections`: `authReference` NULL, `target` empty, `localServerId` NULL, `nativeScope` the account email (no `/`, so not hashed); `devices`: two active; `threads.context` is the thread's working directory `/Users/blove/repos/b4app` (owner's call pending) |
| Mac click-through | Threads, Connections (both runtimes `ready`, signed in), Local servers (`research` registered, stopped), Diagnostics (coordinator, runtimes, database path) | All four surfaces render and respond; the shared-shell change for iPhone has no visible effect on the Mac |
| Phone Send | Typed into the composer and tapped Send | Refused inline with `Writing from this device arrives in M8b; sending turns through the hub in M8c.` (`unsupported_capability`) |
| Phone Diagnostics | Diagnostics row | Sync section: hub URL, device `iPhone 17 Pro`, cursor 39, last sync time, unreadable rows 0 |

Found and fixed during this run: the iOS app died with `SIGTRAP` about two seconds after a relaunch and once during use. The crash reports show `LLA.Dynamic.color`'s dynamic colour provider being resolved by UIKit off the main thread (scene snapshot) while the closure was main-actor isolated by the module's default isolation. `LLA.Dynamic`, `LLA.Palette`, and the hex colour initialisers are now `nonisolated`; `ThemeTests.dynamicColorsResolveOffTheMainActor` resolves every palette colour from a detached task, and the nonisolated `Palette` makes a main-actor `Dynamic` a compile error. The rebuilt app survived relaunch and the Diagnostics screen.

### Not exercised (open gates)

- Real Claude or B4 threads through a hub (only the real Codex thread above); a second Mac.
- `hub leave`, the `database.restore` refusal while joined, uploaded history surviving a device revoke, the 1 MiB payload truncation, and the 401 suspension: `fixture-tested` only, never run live. The one revoke seen live was the Keychain-failure cleanup.
- A hub behind TLS, a `linux/amd64` image, any deployment other than the Mac's Compose, and a restore of a hub from a PostgreSQL backup.
- Rate limiting, byte-limited pull pages, and pruning (`resync_required` for a real stale cursor; M8a answers it for a negative cursor only, fixture-tested and never seen live): not built.

### Known limitations

- Disconnecting the phone is deleting the app; the hub device stays unrevoked (there is no Disconnect control to call the hub's revoke).
- The phone's thread header shows the Mac's working directory from `threads.context`. It is a project path, not an executable path, and it crosses the wire; the owner decides whether `threads.context` should sync.
- The shell shows Mac wording on the phone ("Coordinator connected"). When the last pull failed (hub down, token revoked, hub wiped) a one-line banner above the shell says "Not synced since <time>: <error>" and hides after the next successful pull (`MirrorSyncTests` covers the status callback; the banner was built for both app targets but not seen in the Simulator). A healthy phone still cannot tell that the Mac is asleep or offline: its pulls succeed and simply bring nothing, until M8c adds presence.
- New turns and runtime requests mirrored while a thread is open appear when it is reopened; only display items, threads, and connections are published live.
- No rate limit on `/v1/enroll`; `/v1/changes` pages have no byte limit; a value over 2 MiB in any column other than `displayItems.payload` and `runtimeRequests.payload` (both truncated over 1 MiB) would block the Mac's queue with a permanent 413, visible only in `hub status`.
- `linux/amd64` is unverified.

### Found during M8a, fixed separately

`database.restore` (M7) failed with `invalid input syntax for type json` on any archive whose change log held an `update` with a scalar jsonb value, because `Export.swift` wrote a jsonb scalar string bare and the restore reinserted it as raw text; `exportAndRestoreRoundTrip` missed it because its seed had no updates. Fixed on `main` by PR #18 (archive version 2, see the entry above).

## 2026-10-31: switching the running app to the M7 build

| Step | Result |
| --- | --- |
| First switch (package built from the M7 branch) | Quit, `coordinator restart` through launchd, the new coordinator imported the real store (2 connections, 1 thread, 1 server, 5 items, 1 draft) and retired the SQLite files; the app relaunched against it. |
| Second switch (after #13) | `coordinator restart` timed out at its 10 s limit; `launchctl kickstart -k` by hand returned after 16 s but the old coordinator kept its pid, and `launchctl print` showed `spawn scheduled`, `last exit code = 78: EX_CONFIG`, 193 runs, and `needs LWCR update`. The helper ran fine by hand under launchd's environment, so launchd was refusing to spawn it: the rebuilt, re-signed ad hoc binary no longer matched the pinned code requirement. Unregistering and relaunching did not clear it either, because the app skipped `register` for an already-enabled agent. |
| Re-registering the managed agent | Registering again from the rebuilt app changed nothing (`needs LWCR update`, 47 runs, still EX_CONFIG), and neither did unregister-and-register. The same helper bootstrapped under a throwaway label with `launchctl bootstrap` ran at once, so launchd could exec the file; the managed registration was refusing it. |
| Fix (D-042) | The app now writes and bootstraps a per-user LaunchAgent plist with the coordinator's absolute path, rewriting it when the path changes or launchd reports a spawn failure, and unregisters the old managed agent once. `coordinator status` prints launchd's state and last exit; `coordinator restart` allows 90 s. |
| Outcome | `Agent Workspace --register-agent` from the rebuilt bundle: launchd `running`, 1 run, pid 11713 from `Contents/Helpers`; the store intact (2 connections, 1 thread, 18 change-log rows); `coordinator restart` replaced it with pid 11944 in about ten seconds; the relaunched app connected to it. |

## 2026-10-31: Claude Code live gate (A03) closed

Target: the same MacBook Pro, after the owner signed in to Claude Code 2.1.282 (claude.ai, Max plan). `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`, real inference, run twice.

| Step | Result |
| --- | --- |
| Inspection | `ready`, `authenticated`, 2.1.282, "Signed in as brian@brianflove.com (max) via claude.ai"; the native scope is the account. |
| First turn | "Reply with exactly the single word: pong" streamed and finished `completed`; the reply was `pong`. |
| Interrupt | A long counting turn was interrupted after its first delta; the CLI confirmed, and the result frame came back with `is_error` set and terminal reason `aborted_streaming`. The first run recorded that turn as `failed`; the translator now treats a stop it asked for (or a reason naming interrupt, cancel, or abort) as `cancelled` before it looks at the error flag, and the second run recorded `cancelled`. The fixture now emits the same shape. |
| Native resume | A new adapter on the same native session id asked what word it had been told to reply with: `pong`, `completed`. |
| Transcript | Rebuilt from the session file: four user and assistant pairs in order. |

Open on Claude: a tool-permission prompt and an `AskUserQuestion` live (fixture-tested since M2); hook callbacks and MCP messages are out of scope.

## 2026-10-31: M7 PostgreSQL store

Target: the same MacBook Pro. PostgreSQL 17.11 from the pinned zonky build (`Scripts/fetch-postgres.sh`, SHA-256 verified against Maven Central's published checksum before extraction). The owner's running app was left alone; every live row below ran on scratch directories, including an import of a copy of the real `workspace.sqlite` with its `-wal` and `-shm` files.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 261 tests in 62 suites in 31 s, every suite now on a shared ephemeral cluster with a fresh database per test (`PostgresServerTests` 3, `SQLiteImportTests` 5, `ChangeLogTests` 2 new); one run saw a timing flake in `WorkspaceModelTests` that did not repeat |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass (the store and the server manager are macOS-only modules; the window background modifier is now platform-aware) |
| Package | `./Scripts/package.sh` | Pass: 119 MB app, 39 MB zip; the PostgreSQL tree under `Contents/SharedSupport/postgres` with every Mach-O signed; `codesign --verify --deep --strict` clean |

### Live on this Mac

| Scenario | How | Result |
| --- | --- | --- |
| Bundled cluster from the packaged app | `open -n dist/Agent Workspace.app` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` (the registered agent serves the real directories, so this instance hosted in-process) | `coordinator status` running 0.1.0; `doctor` reported `postgresql:///workspace?host=<runtime dir>&port=5432`; `postgres -D <data dir>/pg` ran from `Contents/SharedSupport/postgres/bin`; the socket and its lock sat in the runtime directory; `PG_VERSION` and the cluster tree under the data directory. |
| Cluster lifetime | SIGTERM to that app instance, then `pg_ctl stop` by hand | A SIGTERM is not an orderly quit, so the owned cluster stayed up (adopt-on-next-start, by design); a CLI-spawned coordinator stopped with `coordinator stop` took its cluster down with it. |
| Import of the real store | Copy of `~/Library/Application Support/b4app/workspace.sqlite{,-wal,-shm}` into a scratch data directory; `db status` through a CLI-spawned coordinator | Imported in one transaction: 2 connections (Codex authenticated, Claude mid-login as on the real store), 1 thread, 1 turn, 5 display items, 1 draft, 1 server registration; `connection list`, `thread list`, `server list` showed them; the three files renamed `.imported`; `db import-sqlite` on the retired file: "nothing imported (the store already holds data)". The first attempt, without the `-wal` and `-shm` copies, found two defects now fixed: a read-only open of a WAL-mode file fails, and an import error trapped the coordinator at top level and left the freshly started cluster running. |
| Backup and restore | `db backup`; `db restore <archive>`; `db restore --replace <archive>`; `db status` | 21 rows written (mode 0600, header with format, time, and applied migrations); restore refused on a non-empty store with the `--replace` hint; replace restored 21 rows and left the change log at the archive's 10 entries (the first run doubled it because the log was silenced after the clearing, now before). |
| Schema and status | `db status`, `db migrate` | `0001_init, 0002_changes`; row counts per table; unsynced change count; backups folder. |

### Open after M7

- Device identity, the hybrid logical clock, and sync itself (M8); the hub schema's tenant and user columns.
- Developer ID signing: executables under `SharedSupport` are sealed as resources, which an ad hoc build accepts and notarisation would not; the tree moves to a nested-code layout when a certificate exists.
- A major-version move (export, new cluster, import) has not been exercised; the bundled version is pinned.
- `docs/schema.md`.

## 2026-10-31: M6 package and accept

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0), no code-signing identity installed. Screen control for the app was declined in this session, so rows that need a person at the window are marked as such; everything else ran from the terminal against the packaged app or the fixtures.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 251 tests in 58 suites (new: `FallbackDirectoryTests` nvm ordering and lock peek, `LauncherTests` bundled-coordinator discovery through a symlinked CLI and the LaunchAgent plist) |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass (LaunchAgent hosting, Coordinator menu, `--remove-agent`) |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Package | `./Scripts/package.sh` | Pass: `dist/Agent Workspace.app` 0.1.0 with `Contents/Helpers/{b4app-coordinator,agent-workspace}` and the LaunchAgent plist; `plutil -lint` OK; `codesign --verify --deep --strict` "valid on disk, satisfies its Designated Requirement" (ad hoc); zip written |

### Live on this Mac (packaged app and bundled CLI)

All against the owner's real data directory (`~/Library/Application Support/b4app`), which the 0.1.0 coordinator opened and migrated to schema v3; no connection, thread, or turn was created. The Mac was left as found: agent unregistered, coordinator stopped.

| Scenario | How | Result |
| --- | --- | --- |
| Finder launch (A01) | `open dist/Agent Workspace.app` (LaunchServices, no shell environment) with no coordinator running | The app registered `com.cacheplane.b4app.coordinator` through `SMAppService` and launchd started `Contents/Helpers/b4app-coordinator` (parent pid 1, `launchctl print` state running, "submitted by smd"); `coordinator status` 10 s later: running, version 0.1.0, launch agent loaded. The coordinator's environment held `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `TMPDIR` and nothing from a shell. |
| Runtime lookup without a shell (A01) | `agent-workspace doctor` (the bundled CLI) against that coordinator | node `ready` v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node` (source `fallback`, D-040); codex `ready` 0.166.0 at `/opt/homebrew/bin/codex`; claude `ready`, `auth=required`, 2.1.282 at `~/.local/bin/claude`. |
| Quit with the agent hosting (A17, part) | `tell application id "com.cacheplane.b4app" to quit` | The app exited at once (it owned nothing); the coordinator kept the same pid. |
| Relaunch | `open` again | Connected to the same coordinator (same pid and start time); no second registration. |
| CLI finds the bundled coordinator | `coordinator status` from the bundled CLI before anything ran | `executable: …/dist/Agent Workspace.app/Contents/Helpers/b4app-coordinator` (resolved beside the CLI). |
| Lifecycle commands | `coordinator status`, `doctor` (spawns), `status`, `restart`, `stop`, `status --json` on scratch directories with the debug CLI | A CLI-spawned coordinator reported, restarted to a new pid, stopped by SIGTERM; `status` exits 0 and reports `running: false` afterwards. |
| Removal | `Agent Workspace --remove-agent`, then `launchctl print`, `coordinator stop`, `coordinator status` | "removed com.cacheplane.b4app.coordinator"; launchd no longer knows the label; unregistering ended the coordinator (nothing left to stop); no bundled coordinator process remained. |

Not exercised: an upgrade (a 0.0.0 coordinator was not running when the test started, so the version note and the launchd restart path were not seen live; `coordinator restart` was exercised only against a CLI-spawned coordinator); the Login Items approval prompt (registration from `dist/` was accepted without one on this Mac); the Quit dialog for in-process hosting (needs a window).

### Acceptance matrix (spec 14.2)

| ID | Scenario | Status | Evidence |
| --- | --- | --- | --- |
| A01 | Finder launch | Pass (live) | This section, "Finder launch" |
| A02 | Codex login and use | Pass (live, M1 and M4) | `connection login` browser flow and real turns under the owner's account; the same native thread continued across restarts (M1, M4 records) |
| A03 | Claude login and use | Pass (live, 2026-10-31 after the owner signed in) | Real turn, interrupt as `cancelled`, native resume, transcript rebuild; see "Claude Code live gate" |
| A04 | Shared thread list | Pass (fixtures; live for Codex and both B4 modes; a Codex thread created from the window on screen) | Codex, Claude, managed and attached B4 threads listed with distinct connections and labels (M2, M3, M4 records; `SnapshotTests` render) |
| A05 | Thread organization | Pass (integration) | Rename, pin, title search, archive and unarchive, drafts across a coordinator restart (`ThreadOrganizationTests`, `WorkspaceModelTests`, M5 CLI smoke) |
| A06 | Runtime decisions | Pass (fixtures; one live Codex approval) | Single transition per request, stale generations expire, unsupported kinds declined (M1 to M3); live `item/commandExecution/requestApproval` approved once (M3 record) |
| A07 | Explicit Stop | Pass (fixtures; live B4 cancel) | Interrupt reaches the native turn, outcome confirmed or left `reconciling`, drafts kept (M1 to M4) |
| A08 | B4 managed local | Pass (live) | `research` project under `~/repos/b4app-live-check`: start, real turn, restart continuity, stop (M4 record) |
| A09 | B4 attached local | Pass (live) | Attached `b4 dev` survived coordinator kill and app Quit; cancellation worked (M3, M4 records) |
| A10 | B4 remote | Open: no compatible HTTPS endpoint deployed | HTTPS enforcement and bearer handling fixture-verified (M3) |
| A11 | Stream loss | Pass (fixtures; live B4 reattach) | Reattach finished with one server-side turn; snapshot merge never duplicates input (M3, M5) |
| A12 | Lost acknowledgement | Pass (fault injection) | `swallow` → `submission_unknown`, no repeat, `turn.abandon` releases the lock (M5 record) |
| A13 | App/runtime restart | Pass (integration and Mac) | Index returns, histories rebuilt from `thread/turns/list`, missing sessions and expired requests identified (M5); coordinator restart under a live managed server (M4) |
| A14 | Process ownership | Pass (process integration) | Concurrent starts converge on the lock; pid plus start time plus argv ownership; port conflicts stop nothing (M0, M4) |
| A15 | Auth and usage errors | Pass (fixtures) | Expired login → `auth_required` with a sign-in action; allowance failures surfaced; no billing-mode switch (M2, M5); not forced live by the spec's instruction |
| A16 | Renderer/secret boundaries | Pass (code review and focused checks) | `WorkspaceUI` imports no process, socket, file, or Keychain API (still true with `Theme/`: SwiftUI, CoreText, AppKit/UIKit for dynamic colours only); redaction at the coordinator boundary (M5 audit) |
| A17 | Window/Quit/wake | Partial (live Quit with the agent hosting; the window seen and driven on screen after the layout fix; the Quit dialog for in-process hosting and wake not driven) | This section, "Quit with the agent hosting"; the Quit dialog for in-process hosting and a real sleep remain unclicked |
| A18 | Project concurrency | Pass (integration) | Directory lock across two Codex threads and a Claude thread, held through a crash, released by abandon (`RecoveryTests`) |

### Open after M6

- Developer ID signing and notarisation: no certificate on this Mac (D-039).
- A live Claude inference turn (A03), a remote HTTPS B4 endpoint (A10), and a person at the window for the Quit dialog, the continuity banner, hover and context menus, and a real sleep across a live turn (A17).
- Removing a server registration and changing its port.

## 2026-10-31: LiveLoveApp visual system

Target: the same MacBook Pro. Screen control for the app was requested and declined in this session, so the window was not clicked; every surface was rendered offscreen instead, by `SnapshotTests` over a real coordinator with the fixture Codex and Claude runtimes, in both appearances (`docs/screenshots/threads-{light,dark}.png`; the full set lands wherever `B4APP_SNAPSHOT_DIR` points).

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Tests | `swift test` | Pass: 245 tests in 55 suites (5 new in `ThemeTests`: SVG parse and fit, font registration, fallback without fonts, palette contrast in both appearances) |
| macOS app | `xcodebuild build -scheme B4App-macOS` | Pass; `AppIcon.icns` and the `WorkspaceUI` resource bundle with the three fonts are inside the app |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Offscreen render | `B4APP_SNAPSHOT_DIR=<dir> swift test --filter SnapshotTests` | Pass: threads (pending approval, running and waiting dots, pinned and archived rows), empty threads, connections, local servers, diagnostics, light and dark |

### Seen in the renders

- The mark draws from the vendored SVG; Hanken Grotesk and JetBrains Mono are the faces in use; headings carry the tight tracking.
- The accent appears only on the "Waiting for you" badge and dot and on link buttons; running is an ink dot with a faint ring; failures use the danger red; everything else is ink and grey.
- Cards are hairline-bordered with radius 16, buttons are pills, no shadow or gradient anywhere; dark mode keeps every pairing above 4.5:1.
- The composer grows with its draft and the request card sits above it in the 720 pt reading column.

### Clicked later the same day (screen control granted)

The packaged window at first showed only its toolbar: the root's ideal height was 1458 pt in an 800 pt window (an infinite-height frame inside a split-view column) and the window centred the oversized view, so the sidebar and detail sat outside the visible area; `IdealSizeTests` now pins the root's ideal height. After the fix, seen and driven on screen: the sidebar (mark, surfaces, thread rows, link status), the Threads empty state and its button, the new-thread sheet (connection picker, directory, title, Create), and a thread created on the real Codex connection with the composer, toolbar Rename, Pin, Archive. Still not clicked: hover states, the context menu, the rename alert, the Quit dialog, the continuity banner, a sent turn.

## 2026-10-31: M5 daily-use behavior and recovery

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3). Fixture runs use the three fake runtimes; the live CLI smoke below ran the built `agent-workspace` and a CLI-spawned coordinator against `fake-codex.py` on scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` with `B4APP_CODEX_REQUEST_TIMEOUT=1`. No screen control was available in this session, so the macOS views were built and model-tested but not clicked.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 240 tests in 54 suites (22 new) in 22 s after a clean build |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass (includes the Quit dialog and the wake observer) |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

New fixture coverage, by acceptance row: A05 organization and drafts across a coordinator restart, the snapshot's active turns, model-level sidebar state, archived visibility, draft debounce and flush (`ThreadOrganizationTests`, `WorkspaceModelTests`); A11/A13 history rebuilt from `thread/turns/list` after the cache is lost, a partial cache merged without duplicating the live user message, a second merge a no-op, `thr_missing` → `missing` with the cache kept and sends refused, an account change (`FAKE_CODEX_EMAIL`) → `identity_changed` and back (`SnapshotMergeTests`, `ContinuityTests`); A12 `swallow` → `submission_unknown`, still unknown after reconcile, resend refused, `turn.abandon` then a `late ack` turn completing once with one native turn (`RecoveryTests`); A18 the directory lock across two Codex threads and a Claude thread (one through a `..` path), a free directory, held through a crash, released by abandon (`RecoveryTests`); A15 an expired login flipping the connection to `auth_required` with `connection.changed`, allowance failures recorded, the remediation table (`FailureTests`, `RemediationTests`); A17 `workspace.activeWork` naming local and remote turns, `stopLocalWork` cancelling the Codex turn and detaching from the attached B4 run, `workspace.reconcile` settling a B4 turn that finished while the coordinator was down with exactly one server-side turn, the clock-gap watcher firing once for a 25 s gap (`LifecycleTests`, `SleepWatcherTests`); A16 header lines and URL parameters masked, a `leak` turn redacted in the event, the thread read, and `doctor` (`LogRedactorTests`, `RedactionTests`).

### Live on this Mac (CLI against the fixture runtime)

| Scenario | How | Result |
| --- | --- | --- |
| Lost acknowledgement | `turn send --no-wait <id> please swallow this` | `error [submission_unknown] Codex did not acknowledge the turn; it may still have started.` exit 1; `thread show` printed `[turn … is reconciling; submission unknown]`. |
| Reconcile stays honest | `thread show --reconcile <id>` | Still `reconciling; submission unknown` (the fixture never started it); nothing was re-sent. |
| No automatic repeat | `turn send <id> hello again` | Refused `protocol_invalid` "A turn is still reconciling on this thread", exit 4. |
| Deliberate recovery | `turn abandon <id>` | `turn … terminal failed (abandoned)`, exit 0; the transcript ends with `[turnAbandoned]` after the user message. |
| Late acknowledgement | `turn send <id> late ack please` | The RPC response was dropped by the fixture; the turn still streamed "Hello from fake Codex." and ended `[turn completed]`, exit 0, one native turn. |
| Organization | `thread update <id> --title "Renamed smoke" --pin`, `--archive`, `thread list`, `thread list --archived`, `--unarchive --unpin` | Pinned and renamed row printed with `[pinned]`; archived thread hidden from `thread list` and shown with `[archived]` by `--archived`; unarchive restored it. |
| Diagnostics | `doctor --json` | `recentErrors` holds `codex:smoke-codex / submission_unknown` and nothing else. |

### Boundary audit (A16)

- `WorkspaceUI` imports only `SwiftUI`, `Observation`, `UniformTypeIdentifiers`, `WorkspaceProtocol`, and `WorkspaceClient` (Package.swift dependencies: `WorkspaceProtocol`, `WorkspaceClient`); no process, socket, file, or Keychain API is reachable from a view or the model.
- The credential value appears in `CredentialAdd.Params.value` on the 0600 socket and in `SecretStore.put` only; the router caches responses by operation id, never params; `connection.list`, `doctor`, and events carry `authReference` and `nativeScope`, never values.
- `print` is used only by the coordinator executable's two startup lines and the CLI; router log lines carry method names, error codes, and messages (messages are redacted at the boundary, D-035).
- `recentErrors`, adapter event messages, failed-turn messages, and `connection.changed` messages pass through `LogRedactor`; the CLI-spawned coordinator's stdout log is bounded by copy-truncate like server logs.

### Open after M5

- The Quit dialog, the continuity banner, the remediation button, the rename alert, the archived section, and the state dots were not driven on screen; `applicationShouldTerminate` is covered by the build and by the coordinator-side tests of what it calls.
- A real Mac sleep across a live turn, a real expired login, and allowance exhaustion were not exercised; the first needs the Mac, the other two are fixture-only by the spec's instruction.
- Everything open after M3 and M4 remains open: the remote HTTPS endpoint, `claude auth login`, removing registrations and changing ports, built artifacts.

## 2026-10-31: M4 managed B4 execution and the shared CLI

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Node v24.20.0 on `PATH` from nvm, no `b4` on `PATH`. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4-cli.py` (a `b4` stand-in serving the M3 fixture protocol) behind `fake-node.sh`, in scratch projects built by `Tests/CoordinatorTests/FakeB4Project.swift`. Live runs first registered the M3 scratch project in place under `/tmp` (`@b4run/cli` 0.15.8, one `gpt-5-mini` `agent()` route, `.b4` stores from M3) with `--env-file` pointing at this repository's gitignored `.env`, under scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR`; the built macOS app was launched from the command line with the same scratch directories. After the owner chose it, the project was copied to `~/repos/b4app-live-check` (node_modules and `.b4` included) and the registration, both launch modes, restart continuity, and stop were repeated there as the server `research` (last table row).

### Live against the real project and `@b4run/cli` 0.15.8

| Scenario | How | Result |
| --- | --- | --- |
| Register and inspect | `server add <project> --name live --env-file <b4app>/.env --port 3101` | Pass in 1.1 s: Node v24.20.0 (`path`), CLI 0.15.8 from the project's `package.json`, `b4 routes --json` found `/chat#agent`; the registration printed the trust line first. |
| Source mode start and a real turn | `server start live`; `connection add --kind b4 --server live --route /chat#agent`; `thread new`; `turn send … pong` | Pass: `b4 start --host 127.0.0.1 --port 3101` was ready in 1.1 s (pid owned, log shows `b4 start listening on http://127.0.0.1:3101` after B4's anonymous-auth notices); the connection stored `managed_local` with target `http://127.0.0.1:3101`; gpt-5-mini answered `pong` in 2.4 s. |
| Development mode and continuity across restart | `server stop`; `server add … --mode development`; `server start`; `server restart`; `turn send` on the same thread | Pass: the profile updated in place (same id, same port); `b4 dev` was ready in 1.9 s (`Loaded 1 variable(s)`, `B4.run dev ready at …`); `restart` took 2.6 s to generation 2 with a new pid; the next turn on the same thread recalled its earlier `pong`, so `.b4/{threads,checkpoints}.sqlite` survived the restart. |
| Coordinator restart with the server running | SIGTERM to the coordinator; `server status live` from a fresh coordinator | Pass: the `b4 dev` process stayed alive; the new coordinator reported `ready … (adopted)` with the same pid and `owned`; a turn completed; `server stop` ended the `b4 dev` parent and its runtime child (pid gone, port free). |
| Port conflict | `python3 -m http.server 3101`, then `server start live` | Refused `owned_process_conflict` "Port 3101 is in use by another process; nothing was stopped"; the Python server was still alive afterwards. Exit 1. |
| Attached server survives everything | `node node_modules/@b4run/cli/dist/index.js dev --port 3102` by hand; `connection add --url http://127.0.0.1:3102 …`; a turn; coordinator kill; app Quit; new coordinator | Pass: the hand-started server answered `pong`, never appeared in `server list`, and was still alive after the coordinator was killed, after the app quit, and under the next coordinator; only my own `kill` ended it. |
| GUI start, CLI inspect and stop (app-hosted coordinator) | Launch `Agent Workspace.app` with the scratch directories (lock pid = app pid 53028); `server start live`, `server list`, `server logs`, `turn send`, `server status --json`, then `tell application "Agent Workspace" to quit` | Pass: the CLI started the server through the app's in-process coordinator (pid 53317 owned, `b4 dev` ready), listed and tailed it, and ran a turn (`pong`); after Quit the app was gone, the lock released, and the managed server still alive. |
| CLI adopts after Quit, then the reverse order | `server status live` (CLI spawns a coordinator), a turn, `server stop`; relaunch the app, `server start`, `server stop`, Quit | Pass: adopted by verified identity (same pid), `pong`, stopped (pid gone); the relaunched app's coordinator started generation 5 as owned and stopped it; Quit left nothing behind. |
| Doctor | `agent-workspace doctor` | Managed servers appear as `b4` rows with the CLI path, version, health, port, mode, and project; attached endpoints keep their reachability rows. |
| The owner's chosen project | `server add ~/repos/b4app-live-check --name research --env-file <b4app>/.env --port 3101`; source start and a turn; `server add … --mode development`; start; a turn; `restart`; a turn; `server logs`; `server stop` | Pass: route `/chat#agent` found; `pong` in source mode; after the switch to development mode the same thread answered `pong` to "which word did you answer last time" and again after `restart` (`.b4` preserved across the mode change and the restart); the log tail showed `B4.run dev ready at http://127.0.0.1:3101`; stop left no process behind. |

Not exercised live: clicking Start / Stop / Restart / Connect / Logs in the Local servers view (built for macOS and iOS; no screen control in this session), a project whose `b4.config.ts` sets `env`, two different projects at once, a `b4 dev` file change mid-turn.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 218 tests in 44 suites (38 new) in 21 s; no fixture server left running afterwards |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

New fixture coverage: `WorkspaceProtocol` (server methods and their mutation flags, params round trips, `LocalServerRoute` keys, `server.changed`); `WorkspaceStorage` (migration `v2`, server rows with routes, update, unique names, connections by server); `WorkspacePlatform` (dotenv quoting, comments, escapes, no expansion; process identity of self and a child; spawn with output to a 0600 file and an exit status; group terminate reaching a grandchild; missing executable; redaction of bearers, `sk-` keys, and key/value pairs; log tail with offsets and copy-truncate bounding; port allocate and in-use detection); `LocalServerService` over the socket (registration with route discovery, refusals for a missing CLI, an old CLI, no config, a missing env file; profile matching and updates; env-file values reaching the child but never a result; source and development starts to ready; idempotent start; concurrent starts joining one launch; port conflict without a kill; restart generations; monitor detecting an exit; stop reaching a `b4 dev` grandchild whose parent ignores SIGTERM; re-adoption after a coordinator restart; a stale pid left alone; an unready start failing with the log tail; a start over a live owned instance marked `unhealthy` refused by pid with the instance still stoppable; a stop racing a start serialized so the new generation is owned and the old process gone; `b4 routes` stderr redacted before it reaches a result; logs tailed, redacted, and followable by offset; doctor rows); managed route connections (`offline` with the start hint while stopped and no thread created; a conversation through the managed server and `offline` after stop; stop refused with `turn_active` then forced, after which the turn is not `completed`, a stopped server stops again without force, and a reconciling turn does not block restart; a server exit marking the connection `offline`, its running turn `reconciling`, and the next turn refused `endpoint_unavailable` with `server_stopped`; a `workflow` route `incompatible` and an unknown route `not_found`). The platform port probe also sees a listener that set `SO_REUSEADDR` (as Node does) through a non-blocking connect and answers within 200 ms against a saturated backlog.

A fresh-context review of the whole branch found no critical issue and five important ones, all fixed with a failing test first: a start on an unhealthy owned server discarded its monitor and blamed another process; a stop racing a start could orphan an owned process behind a `stopped` row; `b4 routes` stderr reached the client unredacted; the CLI sent relative paths unresolved (`server add .` now resolves against the shell's directory, checked by a CLI smoke); and the server-exit test accepted a turn still `running`. Deferred minors are listed in the PR.

### Open after M4

- The Local servers view has not been driven on screen.
- Removing a registration, changing a port that route connections use, and the Quit choice dialog (spec 10.3) are not built; Quit keeps managed servers running.
- Built artifacts (`b4 build` + `node .b4/build/server.mjs`) and `b4 typegen` before `b4 start` are not run by the app.

## 2026-10-31: M3 B4 local and remote conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3). No `b4` on PATH. Fixture runs use `Tests/B4AdapterTests/Fixtures/fake-b4.py`, a stdlib Python server that implements the Agent Protocol subset the adapter uses with the shapes read from `@b4run/cli` 0.15.8 source and corrected from the live run. Live runs use a scratch project with `@b4run/cli` 0.15.8 project-installed, one `gpt-5-mini` `agent()` route, a `workspace/` directory, and `OPENAI_API_KEY` loaded by `b4 dev --env-file` from this repo's gitignored `.env` (the key was copied from the b4run checkout and checked against `GET /v1/models`, HTTP 200).

### Live against a real B4 server (`b4 dev` 0.15.8 on 127.0.0.1:3101)

| Scenario | How | Result |
| --- | --- | --- |
| Opt-in adapter test | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s: inspection `ready`, thread `t-…`, reply "pong" `completed`, cancel of a counting turn confirmed and finished `cancelled`, history `[userMessage, agentMessage, userMessage]`, reconcile of the first turn `completed`. |
| CLI attach and turns | `connection add --kind b4 --url http://127.0.0.1:3101 --route /chat#agent`, `thread new`, `turn send` | Pass: `ready / not_required`; "pong" streamed in 2.0 s; a second turn answered "pong" from the same native thread (continuity). |
| Real permission prompt | `turn send --no-wait <id> "Use your runBash tool to run exactly: ls -la …"`, `thread show`, `request respond <rid> --accept` | Pass: the turn parked `waiting_for_user` with a `command_approval` request carrying the server's `interrupt` envelope (`perm-…`, `kind: command`, `detail.command: "ls -la"`, `toolCallId`); `--accept` resumed it; the transcript ended with the tool card, then "AGENTS.md\nnotes.txt"; the turn was `completed`. |
| Tool card from live `step` frames | `turn send <id> "Use your runBash tool to run exactly: pwd …"` | Pass: `[toolCall started]`, `[toolCall completed] pwd`, one card labelled "Ran pwd" with the output, then the answer. No `step` or `usage` items in the transcript. |
| Parked prompt across a real server restart and a coordinator restart | park on `ls -la`; stop `b4 dev` and the coordinator; start `b4 dev` again on the same `.b4/{threads,checkpoints}.sqlite`; fresh coordinator `thread show`; `request respond --accept` | Pass: after the restart `GET /threads/:id` still read `interrupted` with `metadata.parked_route` and `GET /pending_interrupts` listed the same `perm-…` prompt; `thread show` on the fresh coordinator reconciled the turn to `waiting_for_user` with the request re-opened at adapter generation 2; `--accept` resumed the run, the tool card showed `ls -la`, the answer listed the files, and the turn ended `completed`. The server's turn list showed one `done` turn per prompt sent. |
| Raw protocol capture | `curl -N` of `runs/stream`, `GET /turns`, `GET /state`, `GET /pending_interrupts` | Recorded in `docs/research/2026-10-30-b4-runtime.md`. Two differences from the source reading were found and fixed before merging: `GET /turns` nests the list under `turns.turns` (the ordinal reconcile had silently fallen back to status-only and reported the wrong outcome), and `usage`/`step` events plus serialized `ToolMessage` outputs needed folding instead of rendering as items. |

Not exercised live: a remote HTTPS endpoint with a real endpoint credential, approval grants, `detached capacity`, the macOS forms (built, not clicked).

### Live Codex approval (M1 gate closed from this branch)

| Scenario | How | Result |
| --- | --- | --- |
| Approval under the owner's configuration | CLI thread, "create `/tmp/…` with a shell command" | No request: `~/.codex/config.toml` sets `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`, so Codex ran `printf hello > /tmp/…` directly. Honest result for daily use on this Mac. |
| Real `item/commandExecution/requestApproval` round trip | `B4APP_LIVE_CODEX=1 B4APP_LIVE_CODEX_APPROVALS=1 swift test --filter CodexLiveTests/commandApprovalRoundTrip` (the test alone asks `thread/start` for `on-request` + `workspace-write`) | Pass in 6.4 s: the request arrived as `command_approval` with `command: /bin/zsh -lc 'curl -sI https://example.com'`, `cwd`, and `reason: "Allow curl to access https://example.com outside the network-blocked sandbox?"`; `allow_once` → `{ decision: accept }`; the turn completed and the reply was `HTTP/2 200`. A first attempt that wrote under `/tmp` needed no approval because `workspace-write` keeps `/tmp` writable. |

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 180 tests in 35 suites (35 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live B4 (opt-in) | `B4APP_LIVE_B4_URL=http://127.0.0.1:3101 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live` | Pass in 3 s against `b4 dev` 0.15.8 with gpt-5-mini (see the live table) |

New fixture coverage: `B4TurnTranslator` (ordered streamed turn, tool calls paired with results and messages split around them, park keeps the turn open and the resume stream continues item numbering, failed and cancelled outcomes, final message from `done.output` when nothing streamed including LangChain envelopes, capability events and reasoning visible, reattach `state live:false` ends without an outcome, durable prompt re-open, transport-loss event); `B4Protocol` (route keys, HTTP error mapping, exact resume bodies, decision mapping, LangChain state projection); `B4Adapter` against the fixture (inspect, create, two consecutive turns with ordinals `turn-1`/`turn-2`, tool turn and `loadSession` history, park then `once` with a stale second answer refused, `always`/`deny`/decline all reaching the server, stop on a parked turn declining the prompt, hang then cancel with a later stop returning the known outcome, failed run, **dropped stream reattached with one server-side turn**, **parked prompt answerable after a server restart** under a new generation, **server restart mid-run fails the turn and the thread accepts the next one**, reconcile distinguishing recorded from unrecorded ordinals with a `submission_unknown` error event, bearer middleware 401 as `auth_required` then success with the credential, unknown route 404 and `workflow` route as compatibility results, malformed route as an error); `SessionService` over the socket (a B4 conversation beside Codex with both threads listed and re-adding the same endpoint returning the same connection, a permission answered through `request.respond` with the turn `waiting_for_user` in between, `credential.add` producing a reference the endpoint accepts while an unknown reference is refused and an anonymous turn fails `auth_required`, route and URL problems rejected with codes, **a parked B4 turn answerable after a coordinator restart** via `thread.read` reconciliation to `waiting_for_user`).

### Live on the target Mac (coordinator and CLI against the fixture server)

| Scenario | How | Result |
| --- | --- | --- |
| Credential path | `echo s3cret \| agent-workspace credential add fake-endpoint` with scratch `B4APP_RUNTIME_DIR`/`B4APP_DATA_DIR` | Pass: printed `Stored "fake-endpoint" as secret:<uuid>` and the `connection add` hint; the value appeared nowhere else. The item was written to the login keychain (service `b4app`) by the real `KeychainSecretStore` and removed afterwards. The TTY `readpassphrase` path was not exercised (no terminal in this session). |
| Attach an endpoint with the credential | `connection add --kind b4 --url http://127.0.0.1:<port> --route /chat#agent --auth-ref secret:<uuid> --name fake-b4` | Pass: `ready / auth=unknown`, `route /chat#agent (attached_local)`, message "Server reachable (readyz: ready). Model credentials are not verified by this check." Exit 0. |
| Workflow route | `connection add --kind b4 … --route /dispatch#workflow` | Stored as `incompatible` with "Route /dispatch#workflow is a workflow route. Conversations support standard agent routes only (D-023)." Exit 2. |
| Remote plain HTTP | `connection add --kind b4 --url http://agent.example.com …` | Refused `protocol_invalid` "Remote B4 endpoints must use HTTPS". Exit 4. |
| Thread and streamed turn | `thread new --connection fake-b4 --title smoke`, `turn send <id> hello there` | Pass: thread `native thr_1 route /chat#agent`; streamed "Hello from fake B4." then `[turn completed]`, exit 0. |
| Permission through the CLI | `turn send --no-wait <id> please approve`, `thread show`, `request respond <rid> --accept` | Pass: `thread show` listed the `command_approval` request with `command: rm -rf tmp` and the `request respond` hint; after `--accept` the transcript ended with "Approved (once). Command ran." and the turn was `completed`. |
| Stop a running turn | `turn send --no-wait <id> hang around`, `turn interrupt <id>` | Pass: `stopping`, then `turn-4 terminal cancelled`. |
| Reopen after a coordinator restart | `thread show` from a fresh coordinator process | Pass: three terminal turns and seven cached items; no reconciliation needed. |
| Missing credential | keychain item deleted, then `turn send <id> hello` | Failed honestly with `auth_required` "Credential secret:<uuid> is not in the credential store. Run `agent-workspace credential add` and update the connection." Exit 1. |
| No resubmission | `GET /threads/thr_1/turns` on the fixture after the session | `idle`, exactly one server-side turn per `turn send` (`run_2`, `run_6`, `run_13` all `done`). |
| Doctor | `agent-workspace doctor` | Lists each B4 connection as a runtime row with its reachability message. |

### Open after M3

- A compatible remote HTTPS endpoint with its real endpoint credential has not been attached; the local live run used no middleware.
- Approval grants (`approvals.grants`) are reviewed from source and fixture-tested only.
- The macOS Connections form and new-thread sheet for B4 build but were not clicked through in this session.
- Mac sleep/wake across a long SSE stream and the reattach cap (`detached capacity`) are untested.

## 2026-10-31: M2 Claude Code conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), Claude Code 2.1.282 at `~/.local/bin/claude`, **signed out** (`claude auth status --json` → `loggedIn: false`) for the whole session.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 145 tests in 30 suites (21 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Claude (opt-in) | `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive` | **Not run**: requires `claude auth login` first |

New fixture coverage: `ClaudeTurnTracker` (streamed turn in order, `result success` with `is_error` → failed with `auth_required`, interrupt → cancelled by flag and by `terminal_reason`, tool_use paired with its tool_result, permission and question requests with safe payloads and synthetic question ids, elicitation marked unanswerable, `control_cancel_request`, session state, `apiKeySource` conflict, process exit ending the turn and scoping the disconnect, transcript snapshots); `ClaudeSession` and `ClaudeAdapter` against `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (inspect and login URL capture, session + streamed turn, permission allowed then stale, permission denied with a failed tool result, question answers passed through by question text, elicitation auto-declined, hang + interrupt → cancelled, crash → failed turn + thread-scoped disconnect + resume on the next send with a new generation, failed result error code, `--resume` of a known session and `native_session_missing` for an unknown one, `loadSession` from the transcript file); `SessionService` over the socket (a Claude conversation beside a Codex thread with both connections listed, a Claude tool permission answered exactly once through `request.respond`, a Claude crash leaving the Codex request pending and both connections `ready`).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Protocol shapes while signed out | Raw `claude` launch with the adapter's argv, `initialize` + one `user` message on stdin | Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`: hooks before the handshake, `command_lifecycle`, `system/init` with `apiKeySource: none`, replayed user frame, synthetic `assistant` error, `result success` with `is_error: true`. `--resume` of an unknown id → `result error_during_execution`, exit 1. |
| Claude connection registration | `agent-workspace connection add --kind claude` (scratch directories) | Pass, honest: `ready / auth_required`, version 2.1.282, message "Not signed in. Run `claude auth login` or use Sign in from the Connections screen." Exit 0. |
| Thread creation while signed out | `agent-workspace thread new --connection claude --cwd <dir>` | Refused with `auth_required`, exit 1. No process was left behind. |
| Codex unaffected | `connection add --kind codex` in the same coordinator | `ready / authenticated` beside the Claude row. |

### Not exercised (open gates)

- Any Claude inference: streaming, a real `can_use_tool`, `AskUserQuestion`, the `result` after `interrupt`, and resume with `--resume`. Sign in with `claude auth login`, then run the live test; it prints the reply, the interrupt outcome, and the resume answer.
- `claude auth login` through the app or CLI (it opens the owner's browser; not triggered unattended).
- Interactive use of the macOS window (screen-recording permission declined).

## 2026-10-30: M1 Codex conversation

Target: the same MacBook Pro (macOS 26.5, Xcode 26.6, Swift 6.3.3), codex-cli 0.166.0 from the Homebrew cask, signed in with ChatGPT.

### Automated

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass |
| Tests | `swift test` | Pass: 124 tests in 26 suites (37 new) |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |
| Live Codex (opt-in) | `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` | Pass in 9.7 s: handshake, account, thread, "pong" turn, interrupt → cancelled, reopen with history |

New fixture coverage: `StreamingProcess` (echo, terminate, stderr tail, write after exit, missing executable); Codex event translation for a streamed turn, interrupted and failed turns with mapped error codes, approval requests with a safe payload, every server request method's kind and decline body, account notifications, thread status, history snapshots; `CodexAppServer` and `CodexAdapter` against `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (handshake and account, streamed turn, approval answered with the user's decision then stale on a second answer, unsupported permissions request declined automatically, user question answers passed through, `thread/resume` before `turn/start` and `native_session_missing`, interrupt → cancelled, process exit mid-turn then restart on the next send, failed turn error code); storage upsert by native item id with stable sequence, active-turn lookup, request expiry per connection, snapshot replacement keeping live items; protocol mutation flags for the nine new methods; `SessionService` over the real socket (whole conversation with user and assistant items persisted, second turn refused while one is active, retry with the same `operationId` returning the same turn, approval answered exactly once, runtime exit leaving the turn `reconciling` with submission `unknown` and refusing dispatch, failed dispatch keeping the user message, pending requests expiring and turns reconciling across a coordinator restart).

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| Codex connection registration | `agent-workspace connection add --kind codex` with scratch `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` | Pass. Found `/opt/homebrew/bin/codex` 0.166.0, `account/read` reported the ChatGPT account (`promax`), connection stored `ready / authenticated`, capabilities recorded. Exit 0. |
| New thread in a directory | `agent-workspace thread new --connection codex --cwd <dir> --title "Live check"` | Pass. `thread/start` returned native id `01a18f32-…`; the thread row carries the account email as `nativeScope`. |
| Real streamed turn | `agent-workspace turn send <id> Reply with exactly the single word: pong` | Pass in 3.5 s. Deltas streamed to the terminal, `[turn completed]`, exit 0. |
| Tool turn | `turn send <id> Read README.txt …` | Pass in 4.9 s. Codex ran `/bin/zsh -lc 'cat README.txt'` (shown as a tool card with its output), then answered with the file contents. No approval was requested under the user's Codex configuration, so the approval path was not exercised live. |
| Stop | `turn send … Count slowly from 1 to 3000 …` in the background, `turn interrupt <id>` after 6 s | Pass. The in-flight numbers drained, `[turn cancelled]`, exit 130; `thread show` lists the turn with a `reasoning` item and no assistant text. |
| Reopen the same native thread | `CodexLive` test: dispose the adapter, create a new one, `loadSession` | Pass. `thread/resume` + `thread/turns/list` returned the earlier user message and the "pong" reply. |
| macOS app hosts the coordinator during a live turn | Built `Agent Workspace.app` launched from the command line with the scratch directories; `agent-workspace doctor`, `thread list`, `turn send <id> … pong2` | Pass. The lock carried the app's pid (4700), the CLI reused it, the second turn completed through the app-hosted coordinator, and `thread show` listed both turns. |
| Conversation UI rendering | `ImageRenderer` of `TranscriptRow`, `RuntimeRequestList`, `ComposerView`, and `TurnStatusBadge` with representative items (throwaway test, not committed) | Pass. User bubble, Markdown assistant text, collapsed command card with status, live streaming text, "Turn stopped." note, "Waiting for you" badge, approval card with Allow once / Allow for session / Deny, question card, composer with Stop and a disabled Send while a turn is active. `ScrollView`, `TextEditor`, and `Picker` do not render through `ImageRenderer` and were checked by build only. |

### Not exercised (open gates)

- A real approval or user-question request from Codex. The coordinator, adapter, CLI, and UI paths are fixture-tested end to end; trigger one live by asking Codex to run a command outside its sandbox policy.
- Interactive use of the macOS window (screen-recording permission declined). The window was not clicked through; the shared SwiftUI code built for both platforms and rendered in isolation.
- `account/login/completed` from a signed-out state (the Mac stayed signed in).
- Mac sleep/wake with an app-server running; the minimal packaged Finder launch (M6).

## 2026-10-30: M0 baseline and Swift application shell (initial PR)

Target: MacBook Pro (Apple Silicon), macOS 26.5, Xcode 26.6, Swift 6.3.3, iPhone 17 Pro simulator (iOS 26.5).

### Automated (run locally; CI runs the same on `macos-26`)

| Check | Command | Result |
| --- | --- | --- |
| Format lint | `swift format lint --strict --recursive Sources Tests Apps Package.swift` | Pass |
| Build | `swift build` | Pass (11 targets) |
| Tests | `swift test` | Pass: 87 tests in 19 suites |
| macOS app | `xcodebuild build -scheme B4App-macOS -destination 'platform=macOS'` | Pass |
| iOS app | `xcodebuild build -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` | Pass |

Fixture coverage the spec calls out as easy to break: envelope and method validation (mutations require `operationId`, unknown methods, wrong version, non-object params), event cursor gaps and epoch changes, bounded replay returning `snapshot_required`, singleton lock (held lock reported without removal, release and reacquire), NDJSON and JSON-RPC framing across arbitrary chunk boundaries, SSE parsing across every chunk size with parked, failed, cancelled, snapshot-only, and reattach outcomes, CRLF split across chunks, Claude auth-mode conflict detection, Claude stream-json frame encoding and decoding (initialize, user, can_use_tool allow and deny, AskUserQuestion answer, system init, result), B4 HTTPS enforcement and offline mapping through a `URLProtocol` stub, native-id uniqueness per connection and scope, runtime request single transition, command runner timeout and missing executable.

### Live on the target Mac

| Scenario | How | Result |
| --- | --- | --- |
| CLI starts the coordinator and reports diagnostics | `.build/debug/agent-workspace doctor --json` with `B4APP_RUNTIME_DIR` and `B4APP_DATA_DIR` pointed at scratch directories | Pass. The CLI spawned `b4app-coordinator` from beside itself, the lock and socket were created with mode 0600 in a 0700 directory, the database opened in WAL mode. Exit 0. A second `doctor` reused the same coordinator pid. |
| CLI not-implemented commands | `agent-workspace server start research --json` | Pass. JSON error `not_implemented` with the milestone, exit 3. |
| Claude Code inspection | Through coordinator diagnostics | Found `~/.local/bin/claude` 2.1.282 through PATH. Earlier in the day the adapter reported `ready / authenticated` (claude.ai pro); by the time of the final run `claude auth status --json` itself reported logged out and the adapter reported `auth_required`, which is the honest result. No credential files were read. |
| Claude stream-json handshake | `claude` launched with the SDK's argv, one `initialize` control request on stdin, then EOF | Pass with no inference: one `control_response` frame, exit 0. Recorded in `docs/research/2026-10-30-claude-cli-stream-protocol.md`. |
| Codex inspection | Through coordinator diagnostics | `missing_executable` with install guidance (the CLI is not installed). Expected; not a pass of the Codex integration. |
| macOS app hosts the coordinator and shares it with the CLI | Built app launched from the command line with no coordinator running | Pass. The lock file carried the app's pid; `agent-workspace doctor` returned the same pid and `ready` runtime rows while the app was running. |
| Stale lock and socket files after an unclean exit | App killed with SIGTERM, then `doctor` | Pass. The next coordinator took the freed `flock`, replaced the socket file, and served the CLI. |
| iOS app renders the shell | Installed and launched on the iPhone 17 Pro simulator with `simctl`; screenshot captured with `simctl io` | Pass. Sidebar with Threads, Connections, Local servers, Diagnostics, the thread list, search, and the status "Coordinator unavailable: iOS cannot reach the Mac coordinator yet". A first build was letterboxed because XcodeGen overwrote the Info.plist; fixed by moving the keys into `project.yml`. |

### Not exercised (open gates)

- A screenshot of the macOS window could not be captured (screen-recording permission declined), so the macOS layout was verified only through the socket and the shared SwiftUI code that rendered on iOS.
- Packaging, Finder launch, LaunchAgent registration, signing, notarization. M6.
- Codex app-server handshake, sign-in, any turn. Blocked on installing the Codex CLI.
- Claude sessions beyond the handshake, permission bridge, interrupt. M2.
- B4 thread operations and managed server supervision. Blocked on selecting a trusted local project. M3 and M4.
- Keychain writes through `KeychainSecretStore`. The memory store was used in tests; the Keychain store is wired but untested live.
