# Sidebar, profile menu, and Settings window

Date: 2026-11-01. Owner: Brian Love. Status: approved by the owner on 2026-11-01. Calls marked *(my call)* were made by the designer and can be reversed cheaply; everything else is the owner's. Mockups from the brainstorm, in `2026-11-01-sidebar-profile-settings/` beside this file (open in a browser; colours and type are the app's, the line icons stand in for SF Symbols and the real marks): `sidebar.html`, the sidebar with the profile menu open, and `settings.html`, the Settings window beside the iPhone Settings sheet (the owner approved both: "looks good, using the correct visual identity and layout", "this looks correct").

## Intent

The app's left sidebar should read like the sidebar of Claude, ChatGPT, or T3: the threads are the app, and everything else gets out of the way. Today the sidebar opens with the app's mark and name, then four surface rows (Threads, Connections, Local servers, Diagnostics), then the thread list, with the coordinator status pinned at the bottom. The surfaces other than Threads are things Brian visits rarely; they move into a Settings window opened from a profile menu at the bottom of the sidebar, the way a chat app keeps account and settings under the user's name.

## Goals

- The sidebar is, top to bottom: **New thread**, **Search**, **More**, the thread list, and a **profile button** pinned to the bottom.
- The profile button shows an avatar with initials, the user's name, a second line with the coordinator status, and an up-down chevron. It opens the **profile menu upward, always**: Settings, GitHub, a divider, Log out. More items will be added later.
- **Settings** opens a window designed like Xcode's settings: a left sidenav in the sidebar's style with Connections, Local servers, and Diagnostics, the selected page on the right.
- The **Threads** surface option is gone; the main window's detail is always the thread (or the empty state).
- Thread rows are **one line**: the attention dot, the title, and the runtime's real mark, ghosted, at the trailing edge.
- The iPhone presents the same functions on its compact width.

## Non-goals

- **The login screen.** The owner wants the app gated by a login screen where you sign up or sign in with Sign in with Apple or a passkey in the system password manager. That needs the hub to become an identity provider (WebAuthn relying party, Apple token verification, `apple-app-site-association` on the hub's domain, the associated-domains and Sign in with Apple entitlements), which is the hub's M8d sign-in work. It is a separate project with its own design, after this one.
- Searching message content. Search covers thread titles, as today.
- Restyling or changing the content of the Connections, Local servers, and Diagnostics pages beyond moving them and showing the runtime marks.
- Any change to the hub itself (`Hub/`). The client-side sync changes are limited to the three named under "Sync changes" below.
- Telling a sleeping or offline Mac from a live one on the phone. That is M8c's presence; this change reacts only to the Mac having left the hub.

## Anti-goals

- Anything that looks like Electron or a web page in a window: custom title bars, web-style hamburger menus, faux-native controls. Native window chrome, split views, and the macOS Settings scene stay.
- Breaking the LLA rules (`2026-10-31-lla-visual-system-design.md`): no eyebrows or section labels above the top rows, no uppercase, no accent sprawl. The cobalt accent is not used for the profile button, the menu, or the marks.
- A sidebar whose footer can grow with runtime text and blank the window again (D-047).

## Sequencing and base

M8b (cacheplane/b4app#25, draft, branch `feat/m8b-organisation`) rewrites the same sidebar: `ThreadListView`, a "Pinned" group, collapsible project sections and "Other" on the Mac, a flat list with a `ProjectFilterMenu` in the toolbar on the iPhone, the `AttentionDot`, and a three-line `ThreadRow` (title, reason, "Project · Connection"). This redesign is built **on top of #25's thread list**, not beside it. The owner decides when #25 merges. Implementation starts from `feat/m8b-organisation` (or `main` once #25 has merged) on the branch `blove/sidebar-profile-menu`, and the PR targets `main`; while #25 is unmerged the PR stays a draft and is rebased when #25 lands. Nothing in the M8b session's worktree is touched, and the sync changes below are written only after #25 has merged, since they build on its mirror `devices` table and `MirrorSchema` migrations. Decision numbers D-048 to D-050 are taken by #25 and D-051 by #26 (distribution), and D-052 by #27 (coordinator robustness), so this design is recorded as **D-053**.

## The sidebar

From the top of the sidebar column (below the native window controls and the sidebar toggle):

1. **No mark and no title.** The `LLAMarkView` + "Agent Workspace" header and the sidebar's `navigationTitle` go. The detail's `navigationTitle` (the thread title) still names the window.
2. **New thread** row: `square.and.pencil` SF Symbol, "New thread", the shortcut ⌘N shown muted at the trailing edge. Opens the existing `NewThreadSheet`. Disabled with today's help text when there is no ready connection. It replaces the toolbar's "New thread" button (the accessibility identifier `new-thread-toolbar` moves to it). ⌘N is wired by replacing the empty `CommandGroup(replacing: .newItem)` with a "New Thread" command.
3. **Search** row: `magnifyingglass`, "Search", ⌘K. Opens the search palette (below). The always-visible `.searchable` field goes.
4. **More** row: `ellipsis`, "More". A menu for app features that do not deserve a row. At first it holds *(my call)*: on the Mac, "Show archived" (a toggle over `showArchived`, replacing #25's inline "Archived (n)" switch at the bottom of the list; the archived threads still appear at the bottom of the list while it is on) and, when there is more than one connection, the connection filter; on the iPhone, the contents of #25's `ProjectFilterMenu` (the project filter including "Archived", "Rename project…" for the selected project, and the connection filter), whose toolbar item goes away.
5. A gap of `LLA.Space.m`, then **the thread list**: #25's `ThreadListView` with its Pinned group, project sections, and "Other" on the Mac and its flat list on the iPhone. There is no "Threads" label above it. Project section headings stay; they are groupings, not eyebrows. #25's "New Project…" button stays where #25 puts it, at the end of the list *(my call)*.
6. **The profile button**, pinned to the bottom (a `safeAreaInset(edge: .bottom)` as `LinkStatusView` is today), above a hairline.

The top rows use the sidebar row style that exists today (`SidebarTextRow`: `LLAFont.small`, ink, radius `LLA.Radius.input`, raised fill on hover/press), with an SF Symbol at the sidebar's text size in ink. Icons are SF Symbols, never bitmaps, so they stay sharp; the line icons in the mockups were stand-ins.

### Thread rows

One line: the `AttentionDot`, the title (`lineLimit(1)`, semibold when selected), a flexible gap, and the runtime mark at the trailing edge. The reason line and the "Project · Connection" line from #25's `ThreadRow` are dropped from the visible row *(the owner's call)*. They move into the row's accessibility label and value so VoiceOver still says them *(my call)*. The context menu, selection fill, and swipe actions on the iPhone are unchanged.

### Runtime marks

The real marks *(the owner's call)*: the OpenAI mark for Codex, the Anthropic mark for Claude Code. B4 has no logo in `~/repos/b4`, so B4 connections show "B4" set in `LLAFont` semibold at the mark's size as a monogram *(my call, until the owner supplies a mark)*. The marks are single-colour shapes drawn in a new ghost token added to `Theme/` (light about `#B8B8BC`, dark about `#5A5A5E`, the same muted family as `rule` and `muted`), 14 pt high, so they read in light and dark. They are supplementary (the runtime is also in the row's accessibility label), so they are exempt from the 3:1 graphics contrast check *(my call)*; `ThemeTests` records that exemption by name. The SVG path data comes from Simple Icons (CC0) and is vendored under `Sources/WorkspaceUI/Resources/Brand/` beside the LLA art, rendered through the existing `BrandArt`/`SVGPathData` loader (extend the parser if a mark uses a path command it lacks). The trademarks remain their owners'; this is a personal tool. The same mark appears on the connection cards in Settings → Connections.

## The profile button and menu

**Button.** A 26 pt circular avatar (ink fill, `bg`-coloured initials in `LLAFont` semibold), the name (`LLAFont.smallStrong`), a second line (`LLAFont.caption`, muted, one line, truncating) with the coordinator status, and a `chevron.up.chevron.down` in muted at the trailing edge. The whole row is one button with the raised fill on hover and while the menu is open.

- **Name.** The hub user's display name, "Brian Love" *(the owner's call)*, with initials from its first and last words ("BL"). The username ("blove") shows only until the display name is known. See "Sync changes" for where it comes from.
- **Not joined.** The button reads "Not signed in", with a person glyph in the avatar instead of initials *(my call)*. When the login screen exists, the app shows that screen instead.
- **Status line.** "Coordinator connected", "Connecting to coordinator…", or "Coordinator unavailable", with a 7 pt dot on the avatar's corner (ink when ready, muted while connecting, danger when unavailable; never the accent).
- **Notices.** `LinkStatusView`'s extra lines (the host note with its action, the version mismatch with "Restart coordinator", and "Retry" when the coordinator is unavailable) are not part of the button. When any is present, a compact notice sits directly above the profile button, inside the bottom inset, styled like today's notes: caption text, `lineLimit(3)`, its action as an `.llaLink` button *(my call)*. With nothing to say there is no notice. Its minimum height is bounded whatever the text (D-047).

**Menu.** It must open upward always, which a SwiftUI `Menu` or `NSMenu` cannot promise (AppKit opens it downward when there is room), so the menu is the app's own panel: a card (`bg` fill, `rule` border, radius 12, the LLA soft shadow) anchored to the profile button's top edge, as wide as the button, overlaid on the sidebar, so it never changes the sidebar's layout or minimum size. It dismisses on a click outside, Escape, or choosing an item; arrow keys move between items and Return chooses *(my call)*. Items (SF Symbol, label, muted shortcut):

1. **Settings** (`gearshape`, ⌘,). On the Mac, opens the Settings window (`@Environment(\.openSettings)`); on the iPhone, presents the Settings sheet.
2. **GitHub** (`arrow.up.right.square`). Opens `https://github.com/cacheplane/b4app` in the default browser through `openURL`.
3. Divider.
4. **Log out** (`rectangle.portrait.and.arrow.right`). On both platforms, only while joined *(hidden when not joined: my call)*. On the Mac: Asks first: "Log out of the hub? This Mac stops syncing and the phone stops receiving its threads. Threads, connections, and servers stay on this Mac. To join again, run `agent-workspace hub join` with a new enrollment code." with "Log out" (destructive) and "Cancel". Then it sends `HubLeave` through `WorkspaceClient`, exactly what `agent-workspace hub leave` does, and refreshes the hub status, so the button reads "Not signed in". Rejoining stays on the command line (`agent-workspace hub join`) until the login project replaces it *(my call)*; this change adds no join sheet.

   On the iPhone *(the owner's call: the phone keeps its menu and Log out)*, Log out asks "Log out of the hub? This iPhone stops showing your threads until it joins again with a new enrollment code." with "Log out" (destructive) and "Cancel", then revokes this phone at the hub (`DELETE /v1/devices/self`, best effort), forgets its token in the Keychain, empties the mirror, and returns to the existing Connect screen.

The menu carries no header line (no username or organisation above the items) *(the owner removed it)*.

## The phone when its Mac has left

When the Mac logs out, the phone's pulls keep succeeding and bring nothing new, so today the phone would go on showing the last threads with no sign anything changed. Instead *(the owner's call)*, the phone shows **"Host disconnected"** as its content: the thread list is replaced by an `LLAEmptyState` titled "Host disconnected" with the text "Your Mac has left the hub. Its threads come back when it joins again." *(wording my call)*. New thread, Search, and More are disabled, and no thread can be opened. The profile button and its menu (Settings, GitHub, Log out) keep working.

The phone is in this state when the mirror's `devices` table (#25, refreshed from `GET /v1/devices` on each pull cycle) holds no macOS device without a `revokedAt` *(my call: with two Macs, the phone stays usable while either is joined)*. It leaves the state on its own once a Mac joins again and appears in the next refresh. A Mac that is merely asleep or offline does not trigger it (M8c presence).

## Search palette

Opened by the Search row or ⌘K *(the owner confirmed the ChatGPT-style palette)*. On the Mac, a card about 560 pt wide centred in the window's upper third over a dimmed backdrop: a text field with the `magnifyingglass` and "Search threads", then up to about eight results. Each result is the attention dot, the title, the project name muted, and the runtime mark. Typing filters titles live, case-insensitively, the same matching `searchText` does now; with an empty field it lists threads in attention order *(my call)*. Archived threads match too, marked "Archived" *(my call)*. Up and down move the highlight, Return opens the thread (and moves the iPhone to the detail column), Escape or a click on the backdrop closes it. On the iPhone, the palette is a sheet with the field focused and the results as a list. The palette has its own query; the sidebar list is no longer narrowed by search, so `searchText`'s role in the list filter goes.

## Settings

### Mac

A `Settings` scene in `B4AppMac` hosting a new public `WorkspaceSettingsView(model:)` from `WorkspaceUI`, so ⌘, and the app menu's "Settings…" work natively. The window is a split view: a 200 pt sidenav on the `surface` fill with three rows in the sidebar row style (SF Symbol and label: Connections `link`, Local servers `server.rack`, Diagnostics `waveform.path.ecg` *(icons my call)*), and the page on `bg`, titled by the page's name. It is resizable with a minimum of about 760 × 500 *(my call)*. The sidenav uses stacks in a scroll view, not `List`, for the same reason the main sidebar does (a `List` drew nothing in a split-view sidebar on macOS 26).

The pages are today's `ConnectionsView`, `LocalServersView`, and `DiagnosticsView`, unchanged except for the runtime marks on connection cards and whatever the move requires (their `.navigationTitle`, error placement, the `model.surface ==` checks). The Diagnostics "Refresh" toolbar button stays on that page.

### iPhone

The profile menu's Settings presents a sheet: a `NavigationStack` titled "Settings" with a Done button and an inset list of the same three rows; tapping one pushes its page inside the sheet. The pages behave on the phone as they do today.

### Opening a page from elsewhere

Places that today set `model.surface` to a settings page (the empty state's "Add connection", `Remediation`'s `.openConnections` and `.openServers`) instead ask the model to open Settings at that page: the model records the requested page and a request the root view observes, and the root view calls `openSettings()` on the Mac or presents the sheet on the iPhone. The `Surface` enum loses `.threads` and becomes the settings page enum; the main window's detail is always `ThreadsView`.

## Platforms and boundaries

- All of this lives in `WorkspaceUI` and the two app targets, and talks only to `WorkspaceClient` (`HubStatus`, `HubLeave`, and what the surfaces already send). No process, socket, file, or secret is touched by the UI. `WorkspaceUI` stays free of AppKit and UIKit imports outside `Theme/`; `openSettings` is wrapped in `#if os(macOS)`.
- On the iPhone the account name and the host-disconnected flag come from `MirrorHost` (see "Sync changes"); the status line is the shared shell's existing link text.
- The macOS "Coordinator" menu stays as it is.

## Tests and gates

- `SnapshotTests`: the new sidebar (Mac shell), the sidebar with the profile menu open (render the panel's content directly if the overlay cannot be captured), "Not signed in", a coordinator notice above the button, the search palette with results, and the Settings window on each page, in light and dark; existing surface snapshots move under Settings. The iPhone sidebar and Settings sheet where the harness renders them.
- `DetailMinimumSizeTests` (D-047): the sidebar's bottom inset with a 3,000-character host note and version mismatch has a bounded minimum height, and the Settings window's split view fits its minimum size at any page content.
- Model tests: hub status populates the account and initials (display name, then username fallback); Log out sends `HubLeave` and clears the account; the host-disconnected state disables the top rows and replaces the list; "Not signed in" when not joined; opening Settings at a page from `Remediation`; palette filtering, ordering, archived marking, and keyboard selection logic (kept in a testable type, not in the view).
- Mirror and sync tests (fixture, `FakeHubAPI`): the host-disconnected flag from a `devices` table with only revoked, one live, and two Macs; the phone's log-out revokes, deletes the token, and empties the mirror, and still unlinks when the revoke fails; `HubSync` reports the display name from enrollment and from `/v1/me`.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift test`, both `xcodebuild` schemes (`B4App-macOS`; `B4App-iOS` for `generic/platform=iOS Simulator`, after `./Scripts/generate-project.sh`).
- Docs: D-053 in `docs/decisions.md`, gate results in `docs/verification.md`.

## Left to the builder

Exact spacing, the panel's animation (a short fade and rise, none under Reduce Motion), hover states, how the palette's keyboard handling is wired, the snapshot harness changes, and the precise ghost colour values (keep them in `Theme/` with the others).

## Sync changes

Three small client-side changes, made after #25 merges, in the areas #25 leaves them; no hub change and no new hub route:

1. **Display name on the Mac.** `HubSync` keeps the `displayName` it already receives at enrollment, and fetches `GET /v1/me` once when it starts for a Mac that joined before this change. It holds the name in memory rather than adding a storage column *(my call: no migration; the name returns on the first successful request after launch)*. `HubStatus.Result` gains an optional `displayName`, decoded leniently so an older coordinator still answers.
2. **Display name and host state on the phone.** `MirrorSync` (or `MirrorHost`) fetches `GET /v1/me` the same way, and `MirrorHost` exposes the display name and a "host disconnected" flag computed from the mirror's `devices` table. `MirrorHost` hands both to the model the way `CoordinatorHost.wire` hands the Mac's hooks over, so `WorkspaceUI` never reads the mirror directly.
3. **Unlinking the phone.** `MirrorHost` gains a log-out path: revoke this device through the existing `HubAPI` (`DELETE /v1/devices/self`; a failure is logged, not fatal), delete the token from the `SecretStore`, close and delete the mirror database, and set `isLinked` to false so `B4AppiOS` shows `HubConnectView`.

The hub wire contract (`Hub/API.md`, `Tests/Fixtures/sync/changes.json`) is unchanged.
