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

  @Test func environmentsAreListedByLatestActivity() async throws {
    let model = try await ListFixture.model()
    // b4app's newest thread is at minute 58, Marketing site's at 50, and Docs has no threads.
    #expect(
      model.filterEnvironments.map(\.id) == [ListFixture.b4app, ListFixture.marketing, ListFixture.docs])
  }

  @Test func newThreadFromAHeadingPreselectsItsEnvironment() async throws {
    let transport = ScriptedTransport()
    let model = try await ListFixture.model(transport)
    transport.emit(try .viewSettingsChanged(ViewSettings(arrangement: .byEnvironment)))
    try await waitUntil("by environment") { model.viewSettings.arrangement == .byEnvironment }
    guard case .byEnvironment(let groups) = model.listLayout.body else {
      Issue.record("By environment: \(model.listLayout.body)")
      return
    }
    // Docs has no live threads, so no heading; "No folder" is last.
    #expect(groups.map(\.title) == ["b4app", "Marketing site", "No folder"])
    model.selectedThreadId = "asks"
    await model.openNewThread(in: groups[1])
    #expect(model.selectedThreadId == nil)
    #expect(model.newThreadDraft.environmentId == ListFixture.marketing)
    // "No folder" preselects no folder, replacing the choice before it.
    await model.openNewThread(in: groups[2])
    #expect(model.newThreadDraft.isNoFolder)
    await model.openNewThread(in: groups[0])
    #expect(model.newThreadDraft.environmentId == ListFixture.b4app)
  }

  @Test func theHeadingSpeaksExpandedOrCollapsedAndTheMostUrgentState() {
    #expect(EnvironmentHeading.accessibilityValue(isCollapsed: false, mostUrgent: .approve) == "expanded")
    #expect(
      EnvironmentHeading.accessibilityValue(isCollapsed: true, mostUrgent: .approve)
        == "collapsed, Needs your approval")
    #expect(EnvironmentHeading.accessibilityValue(isCollapsed: true, mostUrgent: nil) == "collapsed")
    let group = ListLayout.Group(id: "p", title: "Docs", environmentId: "p", threads: [])
    #expect(EnvironmentHeading.newThreadTitle(group) == "New thread in Docs")
    #expect(EnvironmentHeading.groupGap == 8)
    #if os(macOS)
      #expect(EnvironmentHeading.height == 28)
    #endif
  }

  @Test func theListIsNeedsYouFirstByDefaultWithoutAPinnedGroup() async throws {
    let model = try await ListFixture.model()
    guard case .needsYouFirst(let top, let lower) = model.listLayout.body else {
      Issue.record("the default arrangement: \(model.listLayout.body)")
      return
    }
    #expect(top.map(\.id) == ["asks", "failed", "unread"])
    // The pinned working thread leads the working threads; it is not lifted above the top list.
    guard case .rows(let rows, tiny: false) = lower else {
      Issue.record("Small: \(lower)")
      return
    }
    #expect(rows.map(\.id) == ["pinned", "busy", "quiet", "copy", "loose"])
    #expect(model.listLayout.archived.isEmpty)

    // The connection filter narrows both lists.
    model.connectionFilter = "c2"
    #expect(
      model.listLayout.body
        == .needsYouFirst(top: [], lower: .rows(rows.filter { $0.connectionId == "c2" }, tiny: false)))
  }

  @Test func theStowedRowSpeaksItsTextAndWhatItDoes() {
    #expect(
      StowedThreadsRow.accessibilityLabel(ListLayout.collapsedLabel(count: 9, working: 2))
        == "9 more, 2 working, Show threads that don't need you")
    #expect(
      StowedThreadsRow.accessibilityLabel("2 working") == "2 working, Show threads that don't need you")
  }

  @Test func tinyRowsAreTwentyPointsWithEightPointMarks() {
    #expect(LLA.Metrics.threadRowTiny == 20)
    #expect(LLA.Metrics.markTiny == 8)
    #expect(ThreadListView.gap == 24)
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
