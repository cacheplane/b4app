import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

private func thread(
  _ id: String, _ title: String, minute: Int, archived: Bool = false, pending: Int = 0
) -> ConversationThread {
  let at = String(format: "2026-11-01T10:%02d:00Z", minute)
  return ConversationThread(
    id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: title, archived: archived, createdAt: at,
    updatedAt: at,
    activity: ThreadActivity(
      latestTurnId: "u-\(id)", latestTurnStatus: .terminal, pendingRequests: pending, lastActivityAt: at))
}

@Suite struct SearchPaletteTests {
  private let threads = [
    thread("old", "Pricing page research", minute: 1),
    thread("new", "Release notes", minute: 9),
    thread("asks", "Refactor the sidebar", minute: 2, pending: 1),
    thread("gone", "Pricing archive", minute: 8, archived: true),
    thread("blank", "", minute: 3),
  ]

  @Test func emptyQueryListsLiveThreadsInAttentionOrder() {
    let results = ThreadSearch.results(in: threads, query: "  ")
    #expect(results.map(\.id) == Attention.ordered(threads.filter { !$0.archived }).map(\.id))
    #expect(results.first?.id == "asks")
    let many = (0..<20).map { thread("t\($0)", "T \($0)", minute: $0) }
    #expect(ThreadSearch.results(in: many, query: "").count == 8)
  }

  @Test func queryMatchesTitlesCaseInsensitively() {
    #expect(ThreadSearch.results(in: threads, query: "PRICING page").map(\.id) == ["old"])
    #expect(ThreadSearch.results(in: threads, query: "re").map(\.id).contains("new"))
  }

  @Test func archivedMatchesComeAfterLiveOnes() {
    // The archived match is newer, but live threads come first.
    #expect(ThreadSearch.results(in: threads, query: "pricing").map(\.id) == ["old", "gone"])
  }

  @Test func untitledThreadsMatchTheirShownTitle() {
    #expect(ThreadSearch.results(in: threads, query: "untitled").map(\.id) == ["blank"])
  }

  @Test func stepClampsAtBothEnds() {
    #expect(ThreadSearch.step(0, by: -1, count: 3) == 0)
    #expect(ThreadSearch.step(2, by: 1, count: 3) == 2)
    #expect(ThreadSearch.step(1, by: 1, count: 3) == 2)
    #expect(ThreadSearch.step(0, by: 1, count: 0) == 0)
  }
}
