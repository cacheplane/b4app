import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite(.serialized) @MainActor struct ThreadListTests {
  @Test func collapsedEnvironmentsRoundTripThroughACommaJoinedString() {
    #expect(CollapsedEnvironments.parse("") == [])
    #expect(CollapsedEnvironments.parse("b,a,,b") == ["a", "b"])
    #expect(CollapsedEnvironments.encode(["b", "a"]) == "a,b")
    #expect(CollapsedEnvironments.encode([]) == "")
    #expect(CollapsedEnvironments.parse(CollapsedEnvironments.encode(["x", "other"])) == ["x", "other"])
  }

  @Test func filterMenuListsEnvironmentsByLatestActivityAndOtherOnlyWhenPresent() async throws {
    let model = try await ListFixture.model()
    // b4app's newest thread is at minute 58, Marketing site's at 50, and Docs has no threads.
    #expect(
      model.filterEnvironments.map(\.id) == [ListFixture.b4app, ListFixture.marketing, ListFixture.docs])
    #expect(model.hasOtherThreads)
    #expect(model.filterTitle == "All environments")
    model.environmentFilter = .environment(ListFixture.marketing)
    #expect(model.filterTitle == "Marketing site")
    model.environmentFilter = .other
    #expect(model.filterTitle == "No folder")
    model.environmentFilter = .archived
    #expect(model.filterTitle == "Archived")
  }

  @Test func macSectionsKeepAnEmptyManualEnvironmentSoItCanBeRenamedOrDeleted() async throws {
    let model = try await ListFixture.model()
    #expect(model.sidebarSections.map(\.title) == ["b4app", "Marketing site", "Docs", "No folder"])
    #expect(model.sidebarSections.first { $0.id == ListFixture.docs }?.threads.isEmpty == true)
    // A connection filter narrows the list; it does not pad it with empty environments.
    model.connectionFilter = "c2"
    #expect(model.sidebarSections.map(\.title) == ["Marketing site"])
  }

  @Test func environmentNameIsTheDisplayNameAndNilForOther() async throws {
    let model = try await ListFixture.model()
    let thread = try #require(model.threads.first { $0.id == "asks" })
    #expect(model.environmentName(for: thread) == "b4app")
    let loose = try #require(model.threads.first { $0.id == "loose" })
    #expect(model.environmentName(for: loose) == nil)
  }

  @Test func markAsUnreadIsOfferedOnlyForAReadReply() async throws {
    let model = try await ListFixture.model()
    func offered(_ id: String) -> Bool { model.canMarkUnread(model.threads.first { $0.id == id }!) }
    #expect(offered("quiet"))
    #expect(!offered("unread"))
    #expect(!offered("asks"))
    #expect(!offered("busy"))
    #expect(!offered("failed"))
    // A failure stays failed once read, but un-reading it is still offered (it returns to the badge).
    var readFailure = try #require(model.threads.first { $0.id == "failed" })
    readFailure.readTurnId = "t4"
    #expect(model.canMarkUnread(readFailure))
  }

  @Test func rowSpeaksItsReasonAndConnection() async throws {
    // The row shows only the title and the state's mark; the state, why it sits there, and where it
    // runs are spoken in its label (not a hint, which VoiceOver users can turn off), and a pinned row
    // says so.
    let model = try await ListFixture.model()
    let asks = try #require(model.threads.first { $0.id == "asks" })
    let label = try #require(model.connection(id: asks.connectionId)?.label)
    #expect(model.state(of: asks) == .reply)
    #expect(
      ThreadRow.accessibilityLabel(model: model, thread: asks)
        == "\(asks.title), Needs your reply, \(model.reasonLine(for: asks)), \(label)")
    var pinned = asks
    pinned.pinned = true
    #expect(ThreadRow.accessibilityLabel(model: model, thread: pinned).hasPrefix("Pinned, \(asks.title), "))
    var untitled = asks
    untitled.title = ""
    #expect(ThreadRow.accessibilityLabel(model: model, thread: untitled).hasPrefix("Untitled, "))
  }

  @Test func diagnosticsWordsTheUploadCounts() {
    #expect(DiagnosticsView.uploads(0, "refused") == "None")
    #expect(DiagnosticsView.uploads(1, "waiting to upload") == "1 change waiting to upload")
    #expect(DiagnosticsView.uploads(2, "refused") == "2 changes refused")
  }

  @Test func aListFailureShowsInTheSidebarUnlessTheDetailAlreadyShowsIt() async throws {
    let model = try await ListFixture.model()
    #expect(model.sidebarError() == nil)  // no error, no banner
    model.lastError = "That folder already belongs to another environment."

    model.selectedThreadId = nil
    #expect(model.sidebarError() == "That folder already belongs to another environment.")

    // An open thread shows it in the composer, so the list does not repeat it...
    model.selectedThreadId = "asks"
    #expect(model.sidebarError() == nil)
    // ...unless the detail is not on screen (the iPhone's single column).
    #expect(model.sidebarError(detailVisible: false) != nil)
    // A selection that no longer exists shows nothing in the detail.
    model.selectedThreadId = "gone"
    #expect(model.sidebarError() != nil)

    model.lastError = nil
    #expect(model.sidebarError(detailVisible: false) == nil)
  }
}
