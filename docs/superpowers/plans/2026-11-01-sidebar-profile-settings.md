# Sidebar, Profile Menu, and Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the surface rows in the sidebar with New thread / Search / More, one-line thread rows with runtime marks, and a profile button whose upward menu opens Settings (a window on the Mac, a sheet on the iPhone), GitHub, and Log out; show "Host disconnected" on the phone when no Mac is joined.

**Architecture:** Everything visible lives in `WorkspaceUI` and talks only to `WorkspaceClient`; the model gains an account, a settings request, and a search flag. The Mac app adds a `Settings` scene and a ⌘N command; the iPhone app's `MirrorHost` feeds the model the account, the host state, and a log-out action. `HubSync` keeps the hub's display name in memory and reports it through `HubStatus`.

**Tech Stack:** Swift 6, SwiftUI (macOS 26 / iOS 26), Swift Testing, the LLA theme in `Sources/WorkspaceUI/Theme/`.

**Spec:** `docs/superpowers/specs/2026-11-01-sidebar-profile-settings-design.md` (mockups in `docs/superpowers/specs/2026-11-01-sidebar-profile-settings/`). Read it before any task.

**Base:** this branch sits on `feat/m8b-organisation` (cacheplane/b4app#25, a03a230). Before Task 1, `git fetch origin` and, if #25 has merged, `git rebase --onto origin/main a03a230`; otherwise rebase onto the newest `origin/feat/m8b-organisation`. Never edit files in the M8b session's worktree.

## Global Constraints

- `WorkspaceUI` imports only SwiftUI, Foundation, `WorkspaceProtocol`, `WorkspaceClient`; AppKit/UIKit only inside `Theme/` behind `#if canImport`. `openSettings` is used only inside `#if os(macOS)`.
- No literal colours, radii, or font names outside `Theme/`. The cobalt accent is never used for the profile button, the menu panel, the marks, or the top rows.
- Icons are SF Symbols: `square.and.pencil` (New thread), `magnifyingglass` (Search), `ellipsis` (More), `chevron.up.chevron.down` (profile), `gearshape` (Settings), `arrow.up.right.square` (GitHub), `rectangle.portrait.and.arrow.right` (Log out), `person.fill` (not signed in avatar); settings pages `link`, `server.rack`, `waveform.path.ecg`.
- Shortcuts: New thread ⌘N, Search ⌘K, Settings ⌘, (from the `Settings` scene).
- GitHub URL: `https://github.com/cacheplane/b4app`.
- Copy, verbatim: "Not signed in"; "Coordinator connected" / "Connecting to coordinator…" / "Coordinator unavailable"; Mac log-out alert title "Log out of the hub?", message "This Mac stops syncing and the phone stops receiving its threads. Threads, connections, and servers stay on this Mac. To join again, run `agent-workspace hub join` with a new enrollment code."; iPhone message "This iPhone stops showing your threads until it joins again with a new enrollment code."; buttons "Log out" (destructive) and "Cancel"; "Host disconnected" / "Your Mac has left the hub. Its threads come back when it joins again."; search field prompt "Search threads"; archived result tag "Archived".
- D-047: nothing in a split-view column outside a scroll view may have a minimum height that grows with runtime text.
- Accessibility identifiers kept: `new-thread-toolbar` (now on the New thread row), `thread-row` (and its `accessibilityValue` of `threadState.rawValue`), `new-project`, `host-note`, `version-note`. New: `sidebar-search`, `sidebar-more`, `profile-button`, `profile-menu`, `settings-sidenav`, `search-palette`, `host-disconnected`.
- Every commit passes `swift format lint --strict --recursive Sources Tests Apps Package.swift` and ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No change under `Hub/`, to `Hub/API.md`, or to `Tests/Fixtures/sync/changes.json`.

## Review Focus

1. The phone before its first `GET /v1/devices` refresh (empty `devices` table) must not show "Host disconnected" (Task 8 test `emptyDeviceListIsNotDisconnected`).
2. Log out when the coordinator answers `hub.leave` with an error: the account stays, `lastError` is set, nothing crashes (Task 3 test `logOutFailureKeepsTheAccount`).
3. Names that break naive initials: one word, extra spaces, an empty display name, emoji (Task 3 test `initialsHandleOddNames`).
4. Searching for an untitled thread: the list shows "Untitled", so the query "untitled" must find it (Task 5 test `untitledThreadsMatchTheirShownTitle`).
5. Asking for a settings page while Settings is already open, or twice in a row: the page switches and the request fires each time (Task 4 test `openSettingsTwiceRequestsTwice`).

---

### Task 1: Runtime marks and the ghost colour

**Files:**
- Create: `Sources/WorkspaceUI/Resources/Brand/openai.svg`, `Sources/WorkspaceUI/Resources/Brand/anthropic.svg`
- Create: `Sources/WorkspaceUI/Theme/RuntimeMark.swift`
- Modify: `Sources/WorkspaceUI/Theme/LLAMark.swift` (`BrandArt.load`), `Sources/WorkspaceUI/Theme/LLATheme.swift` (palette)
- Test: `Tests/WorkspaceUITests/ThemeTests.swift`

**Interfaces:**
- Produces: `LLA.Palette.ghost` / `LLA.Color.ghost` (light `0xB8B8BC`, dark `0x5A5A5E`); `BrandArt.load(named: String) -> BrandArt?` (the `LLAMark.Variant` overload calls it with `variant.rawValue`); `public struct RuntimeMark: View { public init(kind: ConnectionKind, height: CGFloat = 14) }`.

- [ ] **Step 1: Vendor the marks.** Download `https://cdn.jsdelivr.net/npm/simple-icons@16.36.0/icons/openai.svg` and `.../anthropic.svg` (CC0 path data; the owner approved this download with the plan) into `Sources/WorkspaceUI/Resources/Brand/`. Keep only `viewBox` and the single `<path d>`; add a one-line XML comment naming Simple Icons 16.36.0, CC0, and that the trademarks are their owners'.

- [ ] **Step 2: Write the failing tests** in `ThemeTests`:

```swift
@Test func runtimeMarksLoad() throws {
  for name in ["openai", "anthropic"] {
    let art = try #require(BrandArt.load(named: name), "\(name).svg did not parse")
    #expect(!art.path.isEmpty)
    #expect(art.viewBox.width > 0 && art.viewBox.height > 0)
  }
}
```

Add `LLA.Palette.ghost` to the off-main-actor list in `dynamicColorsResolveOffTheMainActor` and change its expected count from 12 to 13. Add a comment in `contrast()`: the ghost marks are supplementary (the runtime is in the row's accessibility label), so `ghost` is exempt from the 3:1 graphics floor.

- [ ] **Step 3: Run** `swift test --filter ThemeTests`. Expected: FAIL (`load(named:)` and `ghost` undefined).

- [ ] **Step 4: Implement.** Add `ghost` to `Palette` and `Color`. Change `BrandArt`'s cache key to `String` and add `load(named:)`. If a mark uses a path command the parser lacks (relative `c`, `s`, `a`, or implicit repeats), extend `SVGPathData` and add the command to `parserHandlesRelativeAndCurveCommands`. `RuntimeMark` draws `.codex` with `openai`, `.claude` with `anthropic` (even-odd fill in `LLA.Color.ghost`, sized by height with the art's aspect), and `.b4` as `Text("B4")` in `LLAFont` semibold at `height * 0.8` in `ghost`; `.accessibilityHidden(true)` (the row speaks for it).

- [ ] **Step 5: Run** `swift test --filter ThemeTests`. Expected: PASS.

- [ ] **Step 6: Commit** `feat(ui): runtime marks and the ghost colour`.

### Task 2: The hub's display name on the Mac

**Files:**
- Modify: `Sources/WorkspaceProtocol/Commands.swift` (`HubStatus.Result`), `Sources/Coordinator/HubSync/HubSync.swift`
- Test: `Tests/CoordinatorTests/HubSyncTests.swift`

**Interfaces:**
- Produces: `HubStatus.Result.displayName: String?` (new init parameter `displayName: String? = nil`, placed after `username`). Synthesized `Codable` decodes it as absent from an older coordinator.

- [ ] **Step 1: Write the failing tests** in `HubSyncTests`: `joinReportsTheDisplayName` (after `h.join()`, `try await h.status().displayName == enrolled.user.displayName`), and `restartFetchesTheDisplayName`: join, close the harness's coordinator, start a new coordinator on the same paths and the same `FakeHubAPI`, then `waitUntil` `status().displayName == enrolled.user.displayName` (`FakeHubAPI.me()` answers with the enrolled device's user). If restarting the harness's coordinator is awkward, construct a second `HubSync` over the same database and fake, call `start()`, and assert on its `status()` instead. Also `leaveClearsTheDisplayName`.

- [ ] **Step 2: Run** `swift test --filter HubSyncTests`. Expected: FAIL (no `displayName`).

- [ ] **Step 3: Implement.** In `HubSync`, add `private var displayName: String?`: set from `enrolled.user.displayName` in `join`; in `start()`, when a link exists, a detached task calls `api.me()` and stores `user.displayName` (a failure is logged at debug and ignored); `leave()` sets it to nil; `status()` passes it.

- [ ] **Step 4: Run** `swift test --filter HubSyncTests` and `swift test --filter WorkspaceProtocolTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(hub): report the hub user's display name in hub status`.

### Task 3: The account and Log out in the model

**Files:**
- Create: `Sources/WorkspaceUI/WorkspaceAccount.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift`
- Test: `Tests/WorkspaceUITests/AccountModelTests.swift` (new); extend `ScriptedTransport` in `AttentionModelTests.swift` to answer `hub.status` from a settable `HubStatus.Result` (default not joined) and `hub.leave` (returns not joined, or throws a settable error)

**Interfaces:**
- Consumes: `HubStatus.Result.displayName` (Task 2).
- Produces:
  - `public struct WorkspaceAccount: Sendable, Equatable { public var username: String; public var displayName: String?; public var name: String; public var initials: String; public init(username: String, displayName: String?); public init?(status: HubStatus.Result) }` (`init?(status:)` is nil when `!joined` or `username` is nil; `name` is a non-blank `displayName`, else `username`).
  - `public enum AccountSource: Sendable { case coordinator, host }`
  - On `WorkspaceModel`: `public var account: WorkspaceAccount?`, `public var accountSource: AccountSource = .coordinator`, `public var hostLogOut: (@MainActor () async -> Void)?`, `public var hostDisconnected = false`, `public func refreshAccount() async`, `public func logOut() async`, `public var canLogOut: Bool` (account != nil, and on `.host` a `hostLogOut` is set).

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func initialsHandleOddNames() {
  #expect(WorkspaceAccount(username: "blove", displayName: "Brian Love").initials == "BL")
  #expect(WorkspaceAccount(username: "blove", displayName: "  Brian   de  Love ").initials == "BL")
  #expect(WorkspaceAccount(username: "cher", displayName: "Cher").initials == "C")
  #expect(WorkspaceAccount(username: "blove", displayName: "").initials == "BL")  // username's first two
  #expect(WorkspaceAccount(username: "blove", displayName: "").name == "blove")
  #expect(!WorkspaceAccount(username: "x", displayName: "🙂 Smile").initials.isEmpty)
}
@Test func notJoinedIsNotSignedIn() async throws { /* scripted status joined: false → refreshAccount → account == nil */ }
@Test func joinedStatusFillsTheAccount() async throws { /* joined, username "blove", displayName "Brian Love" → account?.name == "Brian Love" */ }
@Test func logOutSendsHubLeaveAndClearsTheAccount() async throws { /* calls(.hubLeave).count == 1, account == nil */ }
@Test func logOutFailureKeepsTheAccount() async throws { /* hub.leave throws → account unchanged, lastError != nil */ }
@Test func hostSourceIsNeverOverwritten() async throws { /* accountSource = .host, account set by hand, refreshAccount → unchanged, no hub.status call; logOut calls hostLogOut, not hub.leave */ }
```

Initials: uppercase first letter of the first and last whitespace-separated words of `name` (one word gives one letter); when `displayName` is blank, the first two letters of `username`, uppercased. Use `Character`, not `unicodeScalars`, so emoji stay whole.

- [ ] **Step 2: Run** `swift test --filter AccountModelTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `refreshAccount()` returns at once on `.host`; otherwise requests `HubStatus` and sets `account = WorkspaceAccount(status:)` (a failure leaves `account` as it is). Call it at the end of a successful `connect()`. `logOut()`: on `.host` awaits `hostLogOut`; otherwise sends `HubLeave` with `Self.mutation()` options through the model's existing `perform` path (so a failure sets `lastError`), then `refreshAccount()`.

- [ ] **Step 4: Run** `swift test --filter AccountModelTests` and `swift test --filter AttentionModelTests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(ui): the hub account and log out in the model`.

### Task 4: Settings pages replace surfaces

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (`Surface` → `SettingsPage`, `perform`, `markRead` guard at the `surface == .threads` check, `openThread`), `Sources/WorkspaceUI/ThreadListView.swift` (`detailShowsError`), `Sources/WorkspaceUI/ThreadsView.swift` ("Add connection"), `Sources/WorkspaceUI/ConnectionsView.swift`, `Sources/WorkspaceUI/LocalServersView.swift`, `Sources/WorkspaceUI/WorkspaceRootView.swift` (`detailOnScreen`, `detail` is always `ThreadsView`)
- Test: `Tests/WorkspaceUITests/RemediationTests.swift`, `Tests/WorkspaceUITests/AccountModelTests.swift`

**Interfaces:**
- Produces: `public enum SettingsPage: String, CaseIterable, Identifiable, Sendable { case connections, servers, diagnostics; public var title: String; public var systemImage: String }` (titles "Connections", "Local servers", "Diagnostics"); on the model `public var settingsPage: SettingsPage = .connections`, `public var settingsRequest = 0` (incremented per request; the root view observes it), `public var showSettingsSheet = false` (iPhone), `public var settingsVisible = false` (set by the settings views on appear/disappear), `public func openSettings(_ page: SettingsPage? = nil)`. `model.surface` and `Surface` are removed.

- [ ] **Step 1: Write the failing tests:** `remediationOpensSettingsAtThePage` (`await model.perform(.openConnections)` → `settingsPage == .connections`, `settingsRequest == 1`; `.openServers` → `.servers`, `2`) and `openSettingsTwiceRequestsTwice` (two `openSettings(.diagnostics)` calls → `settingsRequest == 2`, page `.diagnostics`; `openSettings()` keeps the page).

- [ ] **Step 2: Run** `swift test --filter RemediationTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `openSettings` sets the page when given and increments `settingsRequest`. `detailShowsError` keeps only the thread case (selected, listed, not loading). `ConnectionsView`/`LocalServersView` show `lastError` when `model.settingsVisible && model.settingsPage == .connections` (`.servers`). The read-mark guard and `detailOnScreen` drop their surface checks. Update every `Surface` use, including `SnapshotShell` (render `ThreadsView`; settings snapshots come in Task 9).

- [ ] **Step 4: Run** `swift build` and `swift test --filter WorkspaceUITests`. Expected: PASS.

- [ ] **Step 5: Commit** `refactor(ui): settings pages replace sidebar surfaces`.

### Task 5: Search palette

**Files:**
- Create: `Sources/WorkspaceUI/SearchPalette.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (remove `searchText` and its filter), `Sources/WorkspaceUI/ThreadListView.swift` (`sidebarSections` narrowed only by `connectionFilter`)
- Test: `Tests/WorkspaceUITests/SearchPaletteTests.swift` (new); move the search cases in `AttentionModelTests.swift:346` and `ThreadListTests.swift:42` into it

**Interfaces:**
- Produces: `enum ThreadSearch { static func results(in threads: [ConversationThread], query: String, limit: Int = 8) -> [ConversationThread]; static func step(_ index: Int, by delta: Int, count: Int) -> Int }`; `struct SearchPalette: View { init(model: WorkspaceModel) }`; on the model `public var showSearch = false`.

- [ ] **Step 1: Write the failing tests:** `emptyQueryListsLiveThreadsInAttentionOrder` (no archived, `Attention.ordered`, at most 8); `queryMatchesTitlesCaseInsensitively` ("PRICING" finds "Pricing page research"); `archivedMatchesComeAfterLiveOnes`; `untitledThreadsMatchTheirShownTitle` (a thread with `title == ""` is found by "untitled"); `stepClampsAtBothEnds` (`step(0, by: -1, count: 3) == 0`, `step(2, by: 1, count: 3) == 2`, `step(0, by: 1, count: 0) == 0`).

- [ ] **Step 2: Run** `swift test --filter SearchPaletteTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `ThreadSearch` (trim the query; match against the shown title; live matches in attention order, then archived matches in attention order; prefix `limit`). `SearchPalette`: on the Mac an overlay over a `LLA.Color.ink.opacity(0.18)` backdrop with a 560 pt card (`bg`, `rule` border, radius `LLA.Radius.card`) in the upper third: an `LLAField` with "Search threads" focused on appear, then result rows (`AttentionDot`, title, project name muted, an "Archived" tag in caption when archived, `RuntimeMark` trailing); the highlighted row has the `surfaceRaised` fill. Up/Down (`onKeyPress`) step the highlight, Return opens it (`model.selectedThreadId = id`, `showDetail()`, `openThread`), Escape or a backdrop click sets `showSearch = false`. On the iPhone the same content in a `.sheet` with a `NavigationStack` and a list. Identifier `search-palette`.

- [ ] **Step 4: Run** `swift test --filter WorkspaceUITests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(ui): search palette replaces the sidebar search field`.

### Task 6: The new sidebar

**Files:**
- Create: `Sources/WorkspaceUI/SidebarView.swift` (move `SidebarView`, `SidebarGroupLabel`, `SidebarTextRow` here from `WorkspaceRootView.swift`)
- Modify: `Sources/WorkspaceUI/ThreadListView.swift` (`ThreadRow`, `ProjectSectionsView.archive`, `ProjectFilterMenu` → `MoreMenu` content), `Sources/WorkspaceUI/WorkspaceRootView.swift`, `Apps/macOS/B4App/B4AppMac.swift` (⌘N)
- Test: `Tests/WorkspaceUITests/ThreadListTests.swift`

**Interfaces:**
- Consumes: `RuntimeMark` (Task 1), `model.showSearch`/`SearchPalette` (Task 5), `model.hostDisconnected` (Task 3).
- Produces: `struct SidebarActionRow: View { init(title: String, systemImage: String, shortcut: String?, action: () -> Void) }`; `struct MoreMenu: View { init(model: WorkspaceModel) }`.

- [ ] **Step 1: Write the failing test** `rowSpeaksItsReasonAndConnection` in `ThreadListTests`: build a `ThreadRow` for a needs-input thread and assert the accessibility hint string the row exposes (factor it as `ThreadRow.accessibilityHint(model:thread:) -> String`) equals `"\(model.reasonLine(for: thread)), \(connection label)"`.

- [ ] **Step 2: Run** `swift test --filter ThreadListTests`. Expected: FAIL.

- [ ] **Step 3: Implement the sidebar.** Remove the mark-and-title header, the sidebar's `navigationTitle`, the surface rows, the "Threads" label, `.searchable`, the toolbar "New thread" button, and the iPhone toolbar `ProjectFilterMenu`. At the top: `SidebarActionRow`s New thread (⌘N shown; disabled with today's help when `conversationReadyConnections` is empty; id `new-thread-toolbar`), Search (⌘K via `.keyboardShortcut("k")`; sets `showSearch`; id `sidebar-search`), and `MoreMenu` styled as the same row (`Menu` with `.menuIndicator(.hidden)`, id `sidebar-more`), then `LLA.Space.m`, then `ThreadListView`. On the iPhone the three rows are the first `Section` of the existing `List` (clear row background, no separators), and the thread rows the second, without a header. `SidebarActionRow` is `SidebarTextRow`'s shape with a leading SF Symbol in ink at the text size and the shortcut muted at the trailing edge. `MoreMenu` holds, on the Mac, a `Toggle("Show archived", isOn: $model.showArchived)` and, with more than one connection, the connection `Picker`; on the iPhone, the former `ProjectFilterMenu` items. Delete `ProjectSectionsView.archive`'s switch (the archived threads still list at the end while `showArchived` is on); keep "New Project…". With `model.hostDisconnected`, the three top rows are disabled and the list is replaced by `LLAEmptyState("Host disconnected", text: "Your Mac has left the hub. Its threads come back when it joins again.")` (id `host-disconnected`).

- [ ] **Step 4: Implement the row.** `ThreadRow` becomes one line: `AttentionDot`, the title (`lineLimit(1)`, semibold when loud), `Spacer(minLength: LLA.Space.s)`, `RuntimeMark(kind: connection.kind)`; drop the reason and detail lines and the `pin.fill` glyph (the Pinned group says it); `.accessibilityHint(Self.accessibilityHint(model:thread:))`; keep `accessibilityValue` and the context menu. `showsProject` goes.

- [ ] **Step 5: Wire ⌘N** in `B4AppMac`: `CommandGroup(replacing: .newItem) { Button("New Thread") { sharedModel.showNewThread = true }.keyboardShortcut("n").disabled(sharedModel.conversationReadyConnections.isEmpty) }`.

- [ ] **Step 6: Run** `swift test --filter WorkspaceUITests`, then `swift build`. Expected: PASS.

- [ ] **Step 7: Commit** `feat(ui): chat-style sidebar with one-line thread rows`.

### Task 7: Profile button, menu, and notices

**Files:**
- Create: `Sources/WorkspaceUI/ProfileMenu.swift`
- Modify: `Sources/WorkspaceUI/SidebarView.swift` (bottom inset), `Sources/WorkspaceUI/WorkspaceRootView.swift` (remove `LinkStatusView`)
- Test: `Tests/WorkspaceUITests/DetailMinimumSizeTests.swift`, `Tests/WorkspaceUITests/AccountModelTests.swift`

**Interfaces:**
- Consumes: `account`, `canLogOut`, `logOut()`, `openSettings(_:)` (Tasks 3–4).
- Produces: `struct SidebarFooter: View { init(model: WorkspaceModel) }` (notice + button + menu); `struct ProfileMenuPanel: View { init(model: WorkspaceModel, dismiss: () -> Void) }`; `enum WorkspaceLinks { static let github: URL }`; `extension WorkspaceModel { var linkStatusText: String }` (moved from `LinkStatusView.text`, without the error suffix).

- [ ] **Step 1: Write the failing tests.** In `DetailMinimumSizeTests`, `sidebarFooterStaysBounded`: a model with `hostNote` set to 3,000 characters, `hostActionTitle`/`hostAction` set, `expectedCoordinatorVersion = "0.0.0-mismatch"` so `versionMismatch` is non-nil, and `link == .unavailable`; `NSHostingController(rootView: SidebarFooter(model: model)).sizeThatFits(in: .zero).height <= 240` and the same at width 240. In `AccountModelTests`, `linkStatusTextNamesTheState` for the three states.

- [ ] **Step 2: Run** `swift test --filter DetailMinimumSizeTests`. Expected: FAIL (`SidebarFooter` undefined).

- [ ] **Step 3: Implement.** `SidebarFooter`: a `Hairline`, then the notice when any of `link == .unavailable` (caption "Coordinator unavailable: …" with a "Retry" `.llaLink` calling `connect()`), `hostNote` (with its action), or `versionMismatch` (with "Restart coordinator") is present, each `lineLimit(3)` with identifiers `host-note` / `version-note`; then the `ProfileButton`: 26 pt ink circle with `bg` initials (`person.fill` when `account == nil`), a 7 pt status dot at its corner (ink / muted / danger), the name (`account?.name ?? "Not signed in"`, `smallStrong`) over `linkStatusText` (caption, muted, one line), and `chevron.up.chevron.down` muted; raised fill on hover and while open; id `profile-button`. The panel is an overlay anchored above the button (bottom edge 6 pt above the button's top, same width), `bg` fill, `rule` border, radius 12, the theme's soft shadow, id `profile-menu`: Settings (⌘, shown; `openSettings()`), GitHub (`openURL(WorkspaceLinks.github)`), a divider, and Log out when `canLogOut`, which shows the platform's confirmation alert (copy in Global Constraints) and then `logOut()`. While open, a clear full-sidebar layer behind the panel dismisses it on click; Escape dismisses; Up/Down/Return move and choose. Opening the menu calls `refreshAccount()`. A short fade and rise, none under Reduce Motion.

- [ ] **Step 4: Run** `swift test --filter WorkspaceUITests`. Expected: PASS.

- [ ] **Step 5: Commit** `feat(ui): profile button with an upward menu`.

### Task 8: Settings window, iPhone sheet, and the phone's host state

**Files:**
- Create: `Sources/WorkspaceUI/SettingsView.swift`
- Create: `Sources/WorkspaceSync/DevicePresence.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceRootView.swift` (observe `settingsRequest`), `Apps/macOS/B4App/B4AppMac.swift` (`Settings` scene), `Apps/iOS/B4App/MirrorHost.swift`, `Apps/iOS/B4App/B4AppiOS.swift`
- Test: `Tests/WorkspaceSyncTests/DevicePresenceTests.swift` (new), `Tests/WorkspaceUITests/DetailMinimumSizeTests.swift`

**Interfaces:**
- Consumes: `SettingsPage`, `settingsRequest`, `showSettingsSheet`, `settingsVisible` (Task 4); `accountSource`, `account`, `hostLogOut`, `hostDisconnected` (Task 3); `MirrorStore.devices()`, `HubAPI.me()`, `MirrorHost.disconnect()`, `MirrorStore.clearRows()` (existing).
- Produces: `public struct WorkspaceSettingsView: View { public init(model: WorkspaceModel) }`; `struct SettingsSheet: View`; `extension Array where Element == DeviceInfo { public var hostDisconnected: Bool }`; `MirrorHost.wire(_ model: WorkspaceModel)`, `MirrorHost.logOut() async`.

- [ ] **Step 1: Write the failing tests** in `DevicePresenceTests`: `emptyDeviceListIsNotDisconnected` (`[].hostDisconnected == false`); `onlyRevokedMacsIsDisconnected`; `phonesDoNotCount` (a live `ios` device and a revoked `macos` one → true); `oneLiveMacOfTwoIsConnected` (false). In `DetailMinimumSizeTests`, `settingsFitsItsMinimum`: `NSHostingController(rootView: WorkspaceSettingsView(model:))` at `.zero` is at most 760 × 500 for each `SettingsPage`.

- [ ] **Step 2: Run** `swift test --filter DevicePresenceTests`. Expected: FAIL.

- [ ] **Step 3: Implement presence:** disconnected when the list is non-empty and has no device with `platform == "macos"` and `revokedAt == nil`.

- [ ] **Step 4: Implement Settings.** `WorkspaceSettingsView`: an `HStack` (not a nested split view) of a 200 pt sidenav on `surface` (stacks in a `ScrollView`; `SidebarActionRow`-style rows for each `SettingsPage`, selected raised and semibold; id `settings-sidenav`), a hairline, and the page on `bg` with the page title as a heading; sets `settingsVisible` on appear/disappear; `.frame(minWidth: 760, minHeight: 500)`. `SettingsSheet`: `NavigationStack` titled "Settings" with a Done button and an inset list of the pages, each pushing its view. In `WorkspaceRootView`, `.onChange(of: model.settingsRequest)` calls `openSettings()` on macOS and sets `showSettingsSheet = true` on iOS; iOS presents `.sheet(isPresented: $model.showSettingsSheet) { SettingsSheet(model:) }`. In `B4AppMac`, add `Settings { WorkspaceSettingsView(model: sharedModel) }` with `.windowResizability(.contentMinSize)`. Connection cards in `ConnectionsView` show `RuntimeMark` before their title.

- [ ] **Step 5: Implement the phone.** `MirrorHost.wire(model)` sets `accountSource = .host`, `hostLogOut = { await MirrorHost.shared.logOut() }`, and the account from the stored link's username, then fetches `me()` once per `startSync` to fill `displayName`; after each published batch and status update it sets `model.hostDisconnected = (try? store.devices())?.hostDisconnected ?? false`. `logOut()` awaits `disconnect()`, then `try? store?.clearRows()`, and clears `model.account` and `hostDisconnected`. `B4AppiOS` calls `host.wire(model)` from a `.task` on the root. Update `disconnect()`'s doc comment (now reachable from Log out).

- [ ] **Step 6: Run** `swift test --filter DevicePresenceTests`, `swift test --filter DetailMinimumSizeTests`, then `./Scripts/generate-project.sh` and both `xcodebuild` builds (commands in AGENTS.md). Expected: PASS and `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit** `feat: Settings window and sheet, and Host disconnected on the phone`.

### Task 9: Snapshots, docs, and the gates

**Files:**
- Modify: `Tests/WorkspaceUITests/SnapshotTests.swift`, `docs/decisions.md`, `docs/verification.md`

- [ ] **Step 1: Snapshots.** In `rendersEverySurfaceInBothAppearances`, per appearance capture `sidebar-<s>.png` (thread open), `profile-menu-<s>.png` (render `ProfileMenuPanel` inside the shell when the overlay is not captured), `not-signed-in-<s>.png`, `notice-<s>.png` (a host note set), `search-<s>.png` (palette open with "re"), `host-disconnected-<s>.png`, and `settings-<page>-<s>.png` for each `SettingsPage` by rendering `WorkspaceSettingsView` in its own `SnapshotWindow` at 760 × 500. Remove the old surface captures.

- [ ] **Step 2: Run** `B4APP_SNAPSHOT_DIR=$TMPDIR/b4snap swift test --filter SnapshotTests` and look at every PNG against the mockups; fix what does not match.

- [ ] **Step 3: Docs.** Add D-051 at the top of `docs/decisions.md` in the log's style: the sidebar's shape, the profile menu as the app's own upward panel (why not `Menu`), Settings as a `Settings` scene with an `HStack` sidenav, the one-line rows and real marks (Simple Icons 16.36.0, CC0, the ghost token's contrast exemption), Log out as `hub leave` / the phone's unlink, "Host disconnected" from the mirror's `devices` table, the display name held in memory, and the login screen deferred to its own project. Add a `docs/verification.md` section with the commands below and their results.

- [ ] **Step 4: Gates.** Run `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift test`, and both `xcodebuild` builds. Expected: lint silent, tests pass, both `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit** `docs: D-051 and gate results for the sidebar redesign`, push the branch, and open a draft PR to `main` (based on `feat/m8b-organisation` until #25 merges) with the body ending `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
