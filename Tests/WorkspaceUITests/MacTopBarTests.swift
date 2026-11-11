import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The Mac's top bar (thread list redraw, Task 6): view options, search, and new thread are icon
/// buttons in the sidebar's top bar, not rows in the sidebar; with the sidebar hidden, search and new
/// thread move to the main view's toolbar.
@Suite @MainActor struct MacTopBarTests {
  @Test func sidebarBarIsViewOptionsSearchNewThreadInThatOrder() {
    let bar = TopBarButton.sidebar(.automatic)
    #expect(bar == [.viewOptions, .search, .newThread])
    #expect(bar.map(\.systemImage) == ["line.3.horizontal.decrease", "magnifyingglass", "square.and.pencil"])
    #expect(bar.map(\.identifier) == ["view-options", "sidebar-search", "new-thread-toolbar"])
    // New thread in ink; the others muted.
    #expect(bar.map(\.isInk) == [false, false, true])
  }

  /// The hidden sidebar's items would stay in the window's toolbar (AppKit keeps them), so it declares
  /// none; view options is not in the main view.
  @Test func hiddenSidebarPutsSearchAndNewThreadInTheMainView() {
    #expect(TopBarButton.sidebar(.detailOnly).isEmpty)
    #expect(TopBarButton.mainView(.detailOnly) == [.search, .newThread])
    for shown in [NavigationSplitViewVisibility.automatic, .all, .doubleColumn] {
      #expect(TopBarButton.sidebar(shown) == [.viewOptions, .search, .newThread])
      #expect(TopBarButton.mainView(shown).isEmpty)
    }
  }

  /// ⌘K and ⌘N are the app's File menu commands (one declaration each, reachable with the sidebar
  /// hidden and over the palette or the composer); the buttons name them in their help.
  @Test func shortcutsAreCommandKAndCommandN() {
    #expect(TopBarButton.search.shortcut == KeyboardShortcut("k"))
    #expect(TopBarButton.newThread.shortcut == KeyboardShortcut("n"))
    #expect(TopBarButton.viewOptions.shortcut == nil)
    #expect(TopBarButton.search.help(entryReason: nil) == "Search (\u{2318}K)")
    #expect(TopBarButton.newThread.help(entryReason: nil) == "New thread (\u{2318}N)")
  }

  @Test func newThreadIsOffWithTheEntryReasonAsItsHelp() async throws {
    let blocked = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    let reason = try #require(blocked.newThreadEntryReason)
    #expect(!TopBarButton.newThread.isEnabled(entryReason: reason))
    #expect(TopBarButton.newThread.help(entryReason: reason) == reason)

    let ready = try await ListFixture.model()
    #expect(ready.newThreadEntryReason == nil)
    #expect(TopBarButton.newThread.isEnabled(entryReason: ready.newThreadEntryReason))
    // Search and view options stay on: every thread is still browsable.
    #expect(TopBarButton.search.isEnabled(entryReason: reason))
    #expect(TopBarButton.viewOptions.isEnabled(entryReason: reason))
    #expect(TopBarButton.search.help(entryReason: reason) == "Search (\u{2318}K)")
  }
}
