import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// Settings, Display: the Dense switch; and the view-options menu's three ways of drawing
/// the threads that do not need the owner.
@Suite @MainActor struct DisplaySettingsTests {
  @Test func displayIsTheSecondPageOnTheMacOnly() {
    #if os(macOS)
      #expect(
        SettingsPage.allCases == [.account, .display, .connections, .servers, .remoteAccess, .diagnostics])
    #else
      #expect(SettingsPage.allCases == [.account, .connections, .servers, .diagnostics])
    #endif
    #expect(SettingsPage.display.title == "Display")
  }

  /// A thread draws the same at either density, so the setting's default is what the account starts on.
  @Test func densityStartsNormal() {
    #expect(ViewSettings().density == .normal)
  }

  @Test func theSwitchSaysDenseAndWhatItDoes() {
    #expect(DisplaySettingsView.denseLabel == "Dense")
    #expect(
      DisplaySettingsView.denseDescription
        == "Tighter rows for the threads that don\u{2019}t need you, and a composer without its pickers.")
  }

  @Test func theMenuOffersShownCollapsedHidden() {
    #expect(ViewOptions.quietThreads == [.shown, .collapsed, .hidden])
    #expect(ViewOptions.quietThreads.map(ViewOptions.title) == ["Shown", "Collapsed", "Hidden"])
    #expect(ViewOptions.quietThreadsTitle == "Threads that don\u{2019}t need you")
  }

  /// Where the Mac draws tight rows while `tightQuietRows`: the lower list, the rows Collapsed's and
  /// Hidden's rows open, and the selected row kept out of the stow; never the top list or the archived
  /// rows ("By environment" draws its groups apart, at their own size).
  #if os(macOS)
    @Test func onlyTheQuietPlacesAreTight() {
      let tight: [ThreadListView.RowPlace] = [.lower, .collapsedOpened, .hiddenOpened, .selected]
      for place in ThreadListView.RowPlace.allCases {
        #expect(ThreadListView.tiny(place, tight: true) == tight.contains(place), "\(place)")
        #expect(!ThreadListView.tiny(place, tight: false), "\(place)")
      }
    }
  #endif
}
