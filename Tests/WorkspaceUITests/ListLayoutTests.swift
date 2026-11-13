import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The two arrangements: "Needs you first" (decisions 6, 7, and 10), the top list, the lower list drawn
/// by `quietThreads`, and the archived block; and "By environment" (decision 8), one group per
/// environment with live threads, by name, "No folder" last.
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
    _ threads: [ConversationThread], _ settings: ViewSettings = ViewSettings(),
    environments: [WorkEnvironment] = [], selection: ListLayout.Selection? = nil
  ) -> ListLayout {
    ListLayout.build(threads: threads, environments: environments, settings: settings, selection: selection)
  }

  private func groups(
    _ threads: [ConversationThread], _ environments: [WorkEnvironment]
  ) -> [ListLayout.Group]? {
    let built = layout(threads, ViewSettings(arrangement: .byEnvironment), environments: environments)
    guard case .byEnvironment(let groups) = built.body else { return nil }
    return groups
  }

  private let named = [
    WorkEnvironment(id: "pz", name: "zulu"),
    WorkEnvironment(id: "pa", name: "Alpha"),
    WorkEnvironment(id: "pm", name: "mike"),
    WorkEnvironment(id: "pb", name: "alpha"),
  ]

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
      Issue.record("Shown draws rows: \(built.lower)")
      return
    }
    #expect(lower.map(\.id) == ["working-new", "working-old", "quiet-new", "quiet-old"])
    #expect(!tiny)
  }

  @Test func collapsedStowsWorkingAndQuietAndCountsBoth() throws {
    var threads = mixed
    threads += (0..<5).map { thread("quiet-\($0)", .quiet, at: 0) }
    let built = try #require(parts(layout(threads, ViewSettings(quietThreads: .collapsed))))
    guard case .collapsed(let count, let working, let stowed, nil) = built.lower else {
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
    guard case .hidden(let working, nil) = built.lower else {
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
    // Collapsed still offers the quiet threads; Shown draws them.
    #expect(!layout(threads, ViewSettings(quietThreads: .collapsed)).body.drawsNothing)
    #expect(!layout(threads).body.drawsNothing)
    #expect(layout([]).body.drawsNothing)
    // Hidden's row sits apart from the list: working threads alone draw nothing above the archive.
    let working = layout([thread("w", .working, at: 1)], ViewSettings(quietThreads: .hidden))
    #expect(!working.body.drawsNothing)
    #expect(!working.body.drawsAboveArchive)
    #expect(layout(threads, ViewSettings(quietThreads: .collapsed)).body.drawsAboveArchive)
  }

  /// The opened stowed rows (per window) stay open only while the same row stows something: changing
  /// the arrangement or the mode, or the stowed set emptying, closes them, so a Collapsed or Hidden row
  /// never comes back already open.
  @Test func theStowedRowsCloseWhenWhatTheyStowChanges() throws {
    let quiet = thread("q", .quiet, at: 1)
    let working = thread("w", .working, at: 2)
    let both = [quiet, working]
    #expect(layout(both, ViewSettings(quietThreads: .collapsed)).stowing == .collapsed)
    #expect(layout([quiet], ViewSettings(quietThreads: .collapsed)).stowing == .collapsed)
    #expect(layout(both, ViewSettings(quietThreads: .hidden)).stowing == .hidden)
    // Nothing stowed: Collapsed with no threads below the top list, Hidden with nothing working.
    #expect(layout([thread("a", .approve, at: 1)], ViewSettings(quietThreads: .collapsed)).stowing == nil)
    #expect(layout([quiet], ViewSettings(quietThreads: .hidden)).stowing == nil)
    // Rows, or another arrangement, stow nothing.
    #expect(layout(both).stowing == nil)
    #expect(layout(both, ViewSettings(density: .dense)).stowing == nil)
    #expect(
      layout(both, ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed)).stowing == nil)

    func staysOpen(_ from: ListLayout, _ to: ListLayout) -> Bool {
      ListLayout.keepsStowedOpen(from: from.stowing, to: to.stowing)
    }
    let collapsed = layout(both, ViewSettings(quietThreads: .collapsed))
    // The stowed set changing but not emptying keeps it open.
    #expect(staysOpen(collapsed, layout([quiet], ViewSettings(quietThreads: .collapsed))))
    #expect(
      staysOpen(
        layout(both, ViewSettings(quietThreads: .hidden)),
        layout([working, thread("w2", .working, at: 3)], ViewSettings(quietThreads: .hidden))))
    // The arrangement changing, the mode changing, or the set emptying closes it.
    #expect(
      !staysOpen(collapsed, layout(both, ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed)))
    )
    #expect(!staysOpen(collapsed, layout(both, ViewSettings(quietThreads: .hidden))))
    #expect(!staysOpen(collapsed, layout(both, ViewSettings(quietThreads: .shown))))
    #expect(
      !staysOpen(
        layout(both, ViewSettings(quietThreads: .hidden)),
        layout([quiet], ViewSettings(quietThreads: .hidden))))
    #expect(
      !staysOpen(collapsed, layout([thread("a", .approve, at: 1)], ViewSettings(quietThreads: .collapsed))))
    #expect(!ListLayout.keepsStowedOpen(from: nil, to: nil))
  }

  /// "No threads yet." prints only when there is no live thread and no archived row is drawn, on both
  /// platforms.
  @Test func noThreadsYetIsNotPrintedAboveArchivedRows() throws {
    let archivedOnly = [thread("old", .quiet, at: 1, archived: true)]
    #expect(!layout(archivedOnly, ViewSettings(showArchived: true)).saysNoThreadsYet(hasLiveThreads: false))
    #expect(layout(archivedOnly).saysNoThreadsYet(hasLiveThreads: false))
    #expect(layout([]).saysNoThreadsYet(hasLiveThreads: false))
    #expect(!layout([thread("q", .quiet, at: 1)]).saysNoThreadsYet(hasLiveThreads: true))
  }

  @Test func denseAppliesOnlyToTheLowerList() throws {
    let built = try #require(parts(layout(mixed, ViewSettings(density: .dense))))
    #expect(built.top.count == 5)
    guard case .rows(let lower, let tiny) = built.lower else {
      Issue.record("Dense draws rows: \(built.lower)")
      return
    }
    #expect(tiny)
    #expect(lower.count == 4)
    // Normal is the same rows at their own size.
    #expect(try #require(parts(layout(mixed))).lower == .rows(lower, tiny: false))
  }

  // MARK: By environment

  @Test func groupsSortByNameAndNoFolderIsLast() throws {
    let threads = [
      thread("loose", .approve, at: 9),
      thread("z", .quiet, at: 1, environment: "pz"),
      thread("m", .quiet, at: 2, environment: "pm"),
      thread("a", .quiet, at: 3, environment: "pa"),
      thread("b", .quiet, at: 4, environment: "pb"),
    ]
    let built = try #require(groups(threads, named))
    // By name, ignoring case; "Alpha" and "alpha" tie and fall back to their ids. "No folder" is last
    // although it holds the only thread that needs you.
    #expect(built.map(\.title) == ["Alpha", "alpha", "mike", "zulu", "No folder"])
    #expect(built.map(\.id) == ["pa", "pb", "pm", "pz", ListLayout.Group.noFolderId])
    #expect(built.map(\.environmentId) == ["pa", "pb", "pm", "pz", nil])
  }

  @Test func groupOrderDoesNotChangeWhenAThreadNeedsYou() throws {
    var threads = [
      thread("a", .quiet, at: 1, environment: "pa"),
      thread("z", .working, at: 2, environment: "pz"),
    ]
    let before = try #require(groups(threads, named)).map(\.id)
    #expect(before == ["pa", "pz"])
    threads[1] = thread("z", .approve, at: 3, environment: "pz")
    #expect(try #require(groups(threads, named)).map(\.id) == before)
  }

  @Test func anEnvironmentWithNoLiveThreadsHasNoGroup() throws {
    let threads = [
      thread("a", .quiet, at: 1, environment: "pa"),
      // Mike's only thread is archived; zulu and the second alpha have none.
      thread("m", .finished, at: 2, archived: true, environment: "pm"),
    ]
    #expect(try #require(groups(threads, named)).map(\.id) == ["pa"])
    // Shown archived threads are the archived block, never a group.
    let shown = layout(
      threads, ViewSettings(arrangement: .byEnvironment, showArchived: true), environments: named)
    #expect(
      shown.body
        == .byEnvironment([
          ListLayout.Group(
            id: "pa", title: "Alpha", environmentId: "pa", threads: [threads[0]])
        ]))
    #expect(shown.archived.map(\.id) == ["m"])
    // No threads at all: no group, not even "No folder".
    #expect(try #require(groups([], named)).isEmpty)
  }

  @Test func threadsInsideAGroupAreInStateOrder() throws {
    let threads = mixed.map { thread in
      var filed = thread
      filed.environmentId = "pa"
      return filed
    }
    let built = try #require(groups(threads, named))
    #expect(built.count == 1)
    #expect(
      built[0].threads.map(\.id) == [
        "approve-new", "approve-old", "reply", "failed", "finished", "working-new", "working-old",
        "quiet-new", "quiet-old",
      ])
  }

  @Test func aCollapsedGroupReportsItsMostUrgentState() throws {
    let threads = [
      thread("q", .quiet, at: 9, environment: "pa"),
      thread("w", .working, at: 8, environment: "pa"),
      thread("ap", .approve, at: 1, environment: "pa"),
      thread("f", .finished, at: 5, environment: "pz"),
      thread("q2", .quiet, at: 5, environment: "pm"),
    ]
    let built = try #require(groups(threads, named))
    #expect(built.map(\.mostUrgent) == [.approve, .quiet, .finished])
    #expect(ListLayout.Group(id: "x", title: "x", environmentId: nil, threads: []).mostUrgent == nil)
  }

  @Test func aThreadWhoseEnvironmentIsUnknownIsUnderNoFolder() throws {
    let threads = [
      thread("gone", .reply, at: 2, environment: "deleted"),
      thread("loose", .quiet, at: 3),
      thread("a", .quiet, at: 1, environment: "pa"),
    ]
    let built = try #require(groups(threads, named))
    #expect(built.map(\.title) == ["Alpha", "No folder"])
    #expect(built.last?.threads.map(\.id) == ["gone", "loose"])
  }

  // MARK: The selected thread

  /// C2: under Collapsed or Hidden the selected thread is never stowed. It is drawn as an ordinary row
  /// where the lower list starts, counted in neither "N more" nor "N working", and it is not among the
  /// stowed rows, so it appears once whether they are open or closed.
  @Test func theSelectedThreadIsNeverStowed() throws {
    let threads = [
      thread("top", .finished, at: 9),
      thread("w", .working, at: 5),
      thread("q", .quiet, at: 3),
      thread("q2", .quiet, at: 1),
    ]
    let onQuiet = ListLayout.Selection(threadId: "q", held: .quiet)
    let collapsed = try #require(
      parts(layout(threads, ViewSettings(quietThreads: .collapsed), selection: onQuiet)))
    #expect(collapsed.top == ["top"])
    #expect(
      collapsed.lower
        == .collapsed(count: 2, working: 1, threads: [threads[1], threads[3]], selected: threads[2]))

    let hidden = try #require(parts(layout(threads, ViewSettings(quietThreads: .hidden), selection: onQuiet)))
    #expect(hidden.lower == .hidden(working: [threads[1]], selected: threads[2]))

    // A selected working thread is not in Hidden's "N working": nothing else works, so no row stows.
    let onWorking = ListLayout.Selection(threadId: "w", held: .working)
    let hiddenWorking = layout(threads, ViewSettings(quietThreads: .hidden), selection: onWorking)
    #expect(try #require(parts(hiddenWorking)).lower == .hidden(working: [], selected: threads[1]))
    #expect(hiddenWorking.stowing == nil)
    #expect(hiddenWorking.body.drawsAboveArchive)
    #expect(!hiddenWorking.body.drawsNothing)

    // With nothing else stowed the Collapsed row is absent: the count is 0 and nothing stows.
    let alone = layout([threads[0], threads[2]], ViewSettings(quietThreads: .collapsed), selection: onQuiet)
    #expect(
      try #require(parts(alone)).lower == .collapsed(count: 0, working: 0, threads: [], selected: threads[2]))
    #expect(alone.stowing == nil)
    #expect(!alone.body.drawsNothing)
    #expect(alone.body.drawsAboveArchive)

    // A selected thread in the top list stays there and pulls nothing out of the stowed rows.
    let onTop = ListLayout.Selection(threadId: "top", held: .finished)
    #expect(
      try #require(parts(layout(threads, ViewSettings(quietThreads: .collapsed), selection: onTop))).lower
        == .collapsed(count: 3, working: 1, threads: Array(threads[1...]), selected: nil))

    // Shown draws every row already, at either density: a selection changes nothing.
    for density in ViewSettings.Density.allCases {
      #expect(
        layout(threads, ViewSettings(density: density), selection: onQuiet)
          == layout(threads, ViewSettings(density: density)))
    }
  }

  /// C6: the selected thread is ordered by the most urgent state it has had since it was selected
  /// (`held`), so a finished thread read on opening keeps its slot in the top list; without a hold it
  /// takes its real place. Only the order and top-list membership change: `Attention.state(of:)` and
  /// the group's mark stay the real state.
  @Test func aHeldThreadKeepsTheSlotOfItsMostUrgentState() throws {
    // "t" was finished when selected and has been read since: it is quiet now.
    let threads = [
      thread("a", .approve, at: 5),
      thread("t", .quiet, at: 4),
      thread("f", .finished, at: 3),
      thread("q", .quiet, at: 9),
    ]
    let released = try #require(parts(layout(threads)))
    #expect(released.top == ["a", "f"])
    #expect(released.lower == .rows([threads[3], threads[1]], tiny: false))

    let held = ListLayout.Selection(threadId: "t", held: .finished)
    let holding = try #require(parts(layout(threads, selection: held)))
    #expect(holding.top == ["a", "t", "f"])
    #expect(holding.lower == .rows([threads[3]], tiny: false))
    #expect(Attention.state(of: threads[1]) == .quiet)

    // Under Collapsed it stays in the top list, not stowed and not the selected row; released, it is stowed.
    let collapsed = try #require(
      parts(layout(threads, ViewSettings(quietThreads: .collapsed), selection: held)))
    #expect(collapsed.top == ["a", "t", "f"])
    #expect(collapsed.lower == .collapsed(count: 1, working: 0, threads: [threads[3]], selected: nil))
    let stowed = try #require(parts(layout(threads, ViewSettings(quietThreads: .collapsed))))
    #expect(
      stowed.lower == .collapsed(count: 2, working: 0, threads: [threads[3], threads[1]], selected: nil))

    // A hold of approve orders it among the approvals, newest first.
    let asks = ListLayout.Selection(threadId: "t", held: .approve)
    #expect(try #require(parts(layout(threads, selection: asks))).top == ["a", "t", "f"])
    var newer = threads
    newer[1] = thread("t", .quiet, at: 6)
    #expect(try #require(parts(layout(newer, selection: asks))).top == ["t", "a", "f"])

    // A hold never lowers a thread: the real state wins when it is more urgent.
    let stale = ListLayout.Selection(threadId: "f", held: .quiet)
    #expect(try #require(parts(layout(threads, selection: stale))).top == ["a", "f"])
  }

  @Test func aHeldThreadKeepsItsPlaceInsideItsGroup() throws {
    let threads = [
      thread("a", .approve, at: 5, environment: "pa"),
      thread("t", .quiet, at: 4, environment: "pa"),
      thread("f", .finished, at: 3, environment: "pa"),
      thread("w", .working, at: 9, environment: "pa"),
    ]
    let settings = ViewSettings(arrangement: .byEnvironment)
    let held = layout(
      threads, settings, environments: named, selection: ListLayout.Selection(threadId: "t", held: .finished))
    guard case .byEnvironment(let groups) = held.body else {
      Issue.record("By environment: \(held.body)")
      return
    }
    #expect(groups.map { $0.threads.map(\.id) } == [["a", "t", "f", "w"]])
    #expect(try #require(self.groups(threads, named)).map { $0.threads.map(\.id) } == [["a", "f", "w", "t"]])

    // The collapsed heading's mark is the most urgent real state, whatever the order.
    let quietFirst = ListLayout.Group(
      id: "pa", title: "Alpha", environmentId: "pa", threads: [threads[1], threads[3]])
    #expect(quietFirst.mostUrgent == .working)
  }
}
