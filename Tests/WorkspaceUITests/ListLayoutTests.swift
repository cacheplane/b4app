import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The "Needs you first" arrangement (decisions 6, 7, and 10): the top list, the lower list drawn by
/// `quietThreads`, and the archived block.
@Suite struct ListLayoutTests {
  private func stamp(_ minute: Int) -> String {
    Timestamp.string(from: Date(timeIntervalSince1970: 1_793_000_000 + Double(minute) * 60))
  }

  private enum Kind { case approve, reply, failed, finished, working, quiet }

  private func thread(
    _ id: String, _ kind: Kind, at minute: Int, pinned: Bool = false, archived: Bool = false,
    environment: String? = nil
  ) -> ConversationThread {
    let turn = "u-\(id)"
    let activity: ThreadActivity
    var read: String?
    switch kind {
    case .approve:
      activity = ThreadActivity(pendingRequests: 1, pendingApprovals: 1, lastActivityAt: stamp(minute))
    case .reply:
      activity = ThreadActivity(pendingRequests: 1, lastActivityAt: stamp(minute))
    case .failed:
      activity = ThreadActivity(
        latestTurnId: turn, latestTurnStatus: .terminal, latestTurnOutcome: .failed,
        lastActivityAt: stamp(minute))
    case .finished:
      activity = ThreadActivity(
        latestTurnId: turn, latestTurnStatus: .terminal, latestTurnOutcome: .completed,
        lastActivityAt: stamp(minute))
    case .working:
      activity = ThreadActivity(latestTurnId: turn, latestTurnStatus: .running, lastActivityAt: stamp(minute))
    case .quiet:
      activity = ThreadActivity(
        latestTurnId: turn, latestTurnStatus: .terminal, latestTurnOutcome: .completed,
        lastActivityAt: stamp(minute))
      read = turn
    }
    return ConversationThread(
      id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, pinned: pinned, archived: archived,
      createdAt: stamp(0), updatedAt: stamp(0), environmentId: environment, readTurnId: read,
      activity: activity)
  }

  private func layout(
    _ threads: [ConversationThread], _ settings: ViewSettings = ViewSettings()
  ) -> ListLayout {
    ListLayout.build(threads: threads, environments: [], settings: settings)
  }

  private func parts(_ layout: ListLayout) -> (top: [String], lower: ListLayout.Lower)? {
    guard case .needsYouFirst(let top, let lower) = layout.body else { return nil }
    return (top.map(\.id), lower)
  }

  private var mixed: [ConversationThread] {
    [
      thread("quiet-old", .quiet, at: 1),
      thread("finished", .finished, at: 9),
      thread("working-old", .working, at: 2),
      thread("reply", .reply, at: 3),
      thread("failed", .failed, at: 8),
      thread("approve-old", .approve, at: 4),
      thread("quiet-new", .quiet, at: 7),
      thread("approve-new", .approve, at: 5),
      thread("working-new", .working, at: 6),
    ]
  }

  @Test func theTopListIsApproveReplyFailedFinishedNewestFirst() throws {
    let built = try #require(parts(layout(mixed)))
    #expect(built.top == ["approve-new", "approve-old", "reply", "failed", "finished"])
  }

  @Test func aPinnedThreadSortsFirstWithinItsStateOnly() throws {
    let threads = [
      thread("approve", .approve, at: 1),
      thread("finished-pinned", .finished, at: 2, pinned: true),
      thread("finished", .finished, at: 9),
      thread("quiet-pinned", .quiet, at: 1, pinned: true),
      thread("working", .working, at: 3),
      thread("quiet", .quiet, at: 5),
    ]
    let built = try #require(parts(layout(threads)))
    // A pin never lifts a thread above a more urgent state, and there is no Pinned group.
    #expect(built.top == ["approve", "finished-pinned", "finished"])
    #expect(built.lower == .rows([threads[4], threads[3], threads[5]], tiny: false))
  }

  @Test func theLowerListIsWorkingThenQuiet() throws {
    let built = try #require(parts(layout(mixed)))
    guard case .rows(let lower, let tiny) = built.lower else {
      Issue.record("Small draws rows: \(built.lower)")
      return
    }
    #expect(lower.map(\.id) == ["working-new", "working-old", "quiet-new", "quiet-old"])
    #expect(!tiny)
  }

  @Test func collapsedStowsWorkingAndQuietAndCountsBoth() throws {
    var threads = mixed
    threads += (0..<5).map { thread("quiet-\($0)", .quiet, at: 0) }
    let built = try #require(parts(layout(threads, ViewSettings(quietThreads: .collapsed))))
    guard case .collapsed(let count, let working, let stowed) = built.lower else {
      Issue.record("Collapsed stows the lower list: \(built.lower)")
      return
    }
    #expect(count == 9)
    #expect(working == 2)
    #expect(stowed.count == 9)
    #expect(stowed.prefix(2).map(\.id) == ["working-new", "working-old"])
    // The top list is unchanged by how the lower list is drawn.
    #expect(built.top == ["approve-new", "approve-old", "reply", "failed", "finished"])
  }

  @Test func collapsedLabels() {
    #expect(ListLayout.collapsedLabel(count: 9, working: 0) == "9 more")
    #expect(ListLayout.collapsedLabel(count: 9, working: 2) == "9 more, 2 working")
    #expect(ListLayout.collapsedLabel(count: 1, working: 0) == "1 more")
  }

  @Test func hiddenKeepsOnlyWorkingAndIsNilLabelWithNone() throws {
    let built = try #require(parts(layout(mixed, ViewSettings(quietThreads: .hidden))))
    guard case .hidden(let working) = built.lower else {
      Issue.record("Hidden keeps the working threads: \(built.lower)")
      return
    }
    #expect(working.map(\.id) == ["working-new", "working-old"])
    #expect(ListLayout.hiddenLabel(working: 2) == "2 working")
    #expect(ListLayout.hiddenLabel(working: 1) == "1 working")
    #expect(ListLayout.hiddenLabel(working: 0) == nil)
  }

  @Test func aStowedThreadThatNeedsYouIsInTheTopList() throws {
    let settings = ViewSettings(quietThreads: .collapsed)
    var threads = [thread("a", .working, at: 2), thread("b", .quiet, at: 1), thread("c", .finished, at: 3)]
    let before = try #require(parts(layout(threads, settings)))
    #expect(before.top == ["c"])
    #expect(before.lower == .collapsed(count: 2, working: 1, threads: [threads[0], threads[1]]))

    // "a" now asks for an approval: it moves to the top at once and is no longer stowed.
    threads[0] = thread("a", .approve, at: 4)
    let after = try #require(parts(layout(threads, settings)))
    #expect(after.top == ["a", "c"])
    #expect(after.lower == .collapsed(count: 1, working: 0, threads: [threads[1]]))

    // The same under Hidden.
    let hidden = try #require(parts(layout(threads, ViewSettings(quietThreads: .hidden))))
    #expect(hidden.top == ["a", "c"])
    #expect(hidden.lower == .hidden(working: []))
  }

  @Test func archivedAreABlockOnlyWhenShown() throws {
    let threads = [
      thread("live", .quiet, at: 1),
      thread("archived-old", .finished, at: 2, archived: true),
      thread("archived-new", .quiet, at: 5, archived: true),
    ]
    let hiddenArchive = layout(threads)
    #expect(hiddenArchive.archived.isEmpty)
    #expect(try #require(parts(hiddenArchive)).lower == .rows([threads[0]], tiny: false))

    // Shown: a final block, newest first whatever their state, and never in the arrangement's body.
    let shown = layout(threads, ViewSettings(showArchived: true))
    #expect(shown.archived.map(\.id) == ["archived-new", "archived-old"])
    let body = try #require(parts(shown))
    #expect(body.top.isEmpty)
    #expect(body.lower == .rows([threads[0]], tiny: false))

    // In both arrangements.
    let grouped = layout(threads, ViewSettings(arrangement: .byEnvironment, showArchived: true))
    #expect(grouped.archived.map(\.id) == ["archived-new", "archived-old"])
    guard case .byEnvironment(let groups) = grouped.body else {
      Issue.record("By environment: \(grouped.body)")
      return
    }
    #expect(groups.flatMap(\.threads).map(\.id) == ["live"])
  }

  @Test func nothingButQuietWithHiddenIsAnEmptyBody() throws {
    let threads = [thread("a", .quiet, at: 1), thread("b", .quiet, at: 2)]
    let built = layout(threads, ViewSettings(quietThreads: .hidden))
    #expect(built.body == .needsYouFirst(top: [], lower: .hidden(working: [])))
    #expect(built.archived.isEmpty)
    #expect(built.body.drawsNothing)
    // Collapsed still offers the quiet threads; Small draws them.
    #expect(!layout(threads, ViewSettings(quietThreads: .collapsed)).body.drawsNothing)
    #expect(!layout(threads).body.drawsNothing)
    #expect(layout([]).body.drawsNothing)
    // Hidden's row sits apart from the list: working threads alone draw nothing above the archive.
    let working = layout([thread("w", .working, at: 1)], ViewSettings(quietThreads: .hidden))
    #expect(!working.body.drawsNothing)
    #expect(!working.body.drawsAboveArchive)
    #expect(layout(threads, ViewSettings(quietThreads: .collapsed)).body.drawsAboveArchive)
  }

  @Test func tinyAppliesOnlyToTheLowerList() throws {
    let built = try #require(parts(layout(mixed, ViewSettings(quietThreads: .tiny))))
    #expect(built.top.count == 5)
    guard case .rows(let lower, let tiny) = built.lower else {
      Issue.record("Tiny draws rows: \(built.lower)")
      return
    }
    #expect(tiny)
    #expect(lower.count == 4)
    // Small is the same rows at their own size.
    #expect(try #require(parts(layout(mixed))).lower == .rows(lower, tiny: false))
  }
}
