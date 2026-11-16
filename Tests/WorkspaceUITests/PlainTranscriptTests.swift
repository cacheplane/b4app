import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What a thread draws at normal density, decided without SwiftUI: every item, an ended turn's open
/// steps settled, and each turn's note with its turn.
@Suite struct PlainTranscriptTests {
  private func item(
    _ id: String, turn: String? = "t1", role: DisplayItemRole, type: String, status: String? = nil
  ) -> DisplayItem {
    DisplayItem(
      id: id, threadId: "th", turnId: turn, role: role, type: type,
      payload: status.map { .object(["status": .string($0)]) } ?? .object([:]), sequence: 0,
      provenance: .live)
  }
  private func user(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .user, type: "userMessage")
  }
  private func step(_ id: String, turn: String? = "t1", status: String = "completed") -> DisplayItem {
    item(id, turn: turn, role: .tool, type: "commandExecution", status: status)
  }
  private func message(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .assistant, type: "agentMessage")
  }
  private func turn(
    _ id: String, _ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed
  )
    -> Turn
  { Turn(id: id, threadId: "th", operationId: "op-\(id)", status: status, outcome: outcome) }

  private func ids(_ entries: [DenseTranscript.Entry]) -> [String] { entries.map(\.id) }
  private func status(_ id: String, in entries: [DenseTranscript.Entry]) -> String? {
    for case .item(let item) in entries where item.id == id { return item.payload["status"]?.stringValue }
    return nil
  }

  @Test func everyItemIsDrawnInTheOrderGiven() {
    let items = [user("u1"), step("k1"), message("m1"), step("k2"), message("m2")]
    let result = DenseTranscript.plain(items: items, turns: [turn("t1")])
    #expect(ids(result) == ["u1", "k1", "m1", "k2", "m2"])
    #expect(status("k1", in: result) == "completed")
  }

  /// F11: the stored step is still `inProgress`, and the turn was stopped. It never reads as running.
  @Test func aStoppedTurnsOpenStepIsUnfinished() {
    let items = [user("u1"), step("k1"), step("k2", status: "inProgress")]
    let result = DenseTranscript.plain(items: items, turns: [turn("t1", .terminal, .cancelled)])
    #expect(status("k1", in: result) == "completed")
    #expect(status("k2", in: result) == "stopped")
    #expect(DenseTranscript.statusLabel("stopped") == "Unfinished")
  }

  @Test func aFailedOrCompletedTurnsOpenStepIsUnfinishedToo() {
    for outcome in [TurnOutcome.failed, .completed] {
      let result = DenseTranscript.plain(
        items: [user("u1"), step("k1", status: "inProgress")], turns: [turn("t1", .terminal, outcome)])
      #expect(status("k1", in: result) == "stopped")
    }
  }

  @Test(arguments: [TurnStatus.submitting, .running, .waitingForUser, .stopping])
  func aRunningTurnsOpenStepStaysInProgress(_ running: TurnStatus) {
    let result = DenseTranscript.plain(
      items: [user("u1"), step("k1", status: "inProgress")], turns: [turn("t1", running, nil)])
    #expect(status("k1", in: result) == "inProgress")
  }

  /// F12: the runtime went away mid-turn. Nothing says whether the step ran on.
  @Test func aTurnWhoseOutcomeIsUnknownHasAnUnknownStep() {
    let result = DenseTranscript.plain(
      items: [user("u1"), step("k1", status: "inProgress")], turns: [turn("t1", .reconciling, nil)])
    #expect(status("k1", in: result) == "unknown")
    #expect(!ids(result).contains("note-t1"))
  }

  @Test func failedAndDeclinedStepsKeepTheirOutcome() {
    let items = [user("u1"), step("k1", status: "failed"), step("k2", status: "declined")]
    let result = DenseTranscript.plain(items: items, turns: [turn("t1", .terminal, .failed)])
    #expect(status("k1", in: result) == "failed")
    #expect(status("k2", in: result) == "declined")
  }

  /// The note stands after its own turn, not after the thread.
  // MARK: the running line (D-239)

  private func running(_ entries: [DenseTranscript.Entry]) -> [DenseTranscript.RunningLine] {
    entries.compactMap { if case .running(let line) = $0 { line } else { nil } }
  }
  private func named(_ id: String, status: String, command: String) -> DisplayItem {
    var item = step(id, status: status)
    item.payload = .object(["status": .string(status), "command": .string(command)])
    return item
  }

  /// Between a send and the first item, and after it: a running turn ends in a line.
  @Test(arguments: [TurnStatus.submitting, .running, .stopping])
  func aRunningTurnEndsInALineThatSaysWorking(_ status: TurnStatus) {
    let waiting = DenseTranscript.plain(items: [user("u1")], turns: [turn("t1", status, nil)])
    #expect(ids(waiting) == ["u1", "running-t1"])
    #expect(running(waiting).map(\.text) == ["Working"])
    let streaming = DenseTranscript.plain(
      items: [user("u1"), message("m1")], turns: [turn("t1", status, nil)])
    #expect(ids(streaming) == ["u1", "m1", "running-t1"])
  }

  @Test func theLineNamesTheNewestOpenStep() {
    let entries = DenseTranscript.plain(
      items: [
        user("u1"), named("s1", status: "completed", command: "ls"),
        named("s2", status: "inProgress", command: "swift build"),
        named("s3", status: "inProgress", command: "swift test\n--filter x"),
      ], turns: [turn("t1", .running, nil)])
    #expect(running(entries).map(\.text) == ["swift test"])
  }

  @Test func aTurnWaitingForAnAnswerSaysSo() {
    let entries = DenseTranscript.plain(
      items: [user("u1"), named("s1", status: "inProgress", command: "rm -rf build")],
      turns: [turn("t1", .waitingForUser, nil)])
    #expect(running(entries).map(\.text) == ["Waiting for you"])
  }

  /// An ended turn, one whose outcome is unknown, and history have no line.
  @Test func onlyARunningTurnHasALine() {
    for ended in [turn("t1"), turn("t1", .terminal, .failed), turn("t1", .reconciling, nil)] {
      #expect(running(DenseTranscript.plain(items: [user("u1"), step("s1")], turns: [ended])).isEmpty)
    }
    #expect(running(DenseTranscript.plain(items: [user("u1", turn: nil)], turns: [])).isEmpty)
  }

  /// The line stands after its own turn's last item, and a running turn with no items yet (begun on
  /// another device) has it at the end.
  @Test func theLineStandsWithItsTurn() {
    let entries = DenseTranscript.plain(
      items: [user("u1"), message("m1"), user("u2", turn: "t2")],
      turns: [turn("t1"), turn("t2", .running, nil), turn("t3", .running, nil)])
    #expect(ids(entries) == ["u1", "m1", "u2", "running-t2", "running-t3"])
  }

  @Test func aTurnsNoteFollowsItsLastItem() {
    let items = [
      user("u1"), step("k1", status: "inProgress"),
      user("u2", turn: "t2"), step("k2", turn: "t2"), message("m2", turn: "t2"),
      user("u3", turn: "t3"), step("k3", turn: "t3", status: "failed"),
    ]
    let turns = [turn("t1", .terminal, .cancelled), turn("t2"), turn("t3", .terminal, .failed)]
    #expect(
      ids(DenseTranscript.plain(items: items, turns: turns))
        == ["u1", "k1", "note-t1", "u2", "k2", "m2", "u3", "k3", "note-t3"])
  }

  @Test func aTurnWithNoItemsKeepsItsNoteAtTheEnd() {
    let result = DenseTranscript.plain(
      items: [user("u1"), message("m1")], turns: [turn("t1"), turn("t2", .terminal, .failed)])
    #expect(ids(result) == ["u1", "m1", "note-t2"])
  }

  /// F13: history rows have no turn. They belong to the user message before them, and a step the
  /// history left open is not drawn as running; one that follows a running turn's items is.
  @Test func historyStepsSettleByTheGroupTheyFollow() {
    let history = DenseTranscript.plain(
      items: [user("u1", turn: nil), step("k1", turn: nil, status: "inProgress")], turns: [])
    #expect(status("k1", in: history) == "stopped")
    let live = DenseTranscript.plain(
      items: [user("u1"), step("k1", turn: nil, status: "inProgress")], turns: [turn("t1", .running, nil)])
    #expect(status("k1", in: live) == "inProgress")
  }

  @Test func theStoredItemIsUntouchedAndOnlyToolsSettle() {
    let open = step("k1", status: "inProgress")
    let reasoning = item("r1", role: .assistant, type: "reasoning", status: "inProgress")
    let result = DenseTranscript.plain(
      items: [user("u1"), open, reasoning], turns: [turn("t1", .terminal, .cancelled)])
    #expect(open.payload["status"] == .string("inProgress"))
    #expect(status("r1", in: result) == "inProgress")
  }

  @Test func theBadgeWordsAreWordsAndUnknownStatusesAreShownAsTheyAre() {
    #expect(DenseTranscript.statusLabel("inProgress") == "In progress")
    #expect(DenseTranscript.statusLabel("completed") == "Completed")
    #expect(DenseTranscript.statusLabel("failed") == "Failed")
    #expect(DenseTranscript.statusLabel("declined") == "Declined")
    #expect(DenseTranscript.statusLabel("unknown") == "Unknown")
    #expect(DenseTranscript.statusLabel("somethingNew") == "somethingNew")
  }

  // MARK: the window of latest rows

  private func entries(_ count: Int, usersAt users: Set<Int> = []) -> [DenseTranscript.Entry] {
    (0..<count).map { index in
      .item(users.contains(index) ? user("e\(index)") : message("e\(index)"))
    }
  }

  @Test func aThreadWithinAPageIsDrawnWhole() {
    let all = entries(DenseTranscript.page)
    #expect(DenseTranscript.window(all, shown: DenseTranscript.page) == .init(hidden: 0, entries: all))
    #expect(DenseTranscript.window([], shown: DenseTranscript.page) == .init(hidden: 0, entries: []))
  }

  @Test func aLongerThreadDrawsItsLatestPage() {
    let all = entries(400)
    let window = DenseTranscript.window(all, shown: DenseTranscript.page)
    #expect(window.hidden == 250)
    #expect(window.entries.map(\.id) == all.suffix(150).map(\.id))
    // A page more.
    #expect(DenseTranscript.window(all, shown: 2 * DenseTranscript.page).hidden == 100)
    #expect(DenseTranscript.window(all, shown: 3 * DenseTranscript.page).hidden == 0)
  }

  /// The cut moves back to a user's message that stands just before it, and no further than that.
  @Test func theWindowBeginsAtANearbyUserMessage() {
    let near = DenseTranscript.window(entries(400, usersAt: [100, 240]), shown: DenseTranscript.page)
    #expect(near.hidden == 240)
    #expect(near.entries.first?.id == "e240")
    let onTheCut = DenseTranscript.window(entries(400, usersAt: [250]), shown: DenseTranscript.page)
    #expect(onTheCut.hidden == 250)
    let far = DenseTranscript.window(entries(400, usersAt: [100]), shown: DenseTranscript.page)
    #expect(far.hidden == 250)
  }

  /// Nothing is dropped or drawn twice: what is hidden and what is drawn make the thread.
  @Test func hiddenAndDrawnMakeTheWholeThread() {
    let all = entries(1_000, usersAt: Set(stride(from: 0, to: 1_000, by: 7)))
    for pages in 1...8 {
      let window = DenseTranscript.window(all, shown: pages * DenseTranscript.page)
      #expect(all.prefix(window.hidden).map(\.id) + window.entries.map(\.id) == all.map(\.id))
    }
  }
}
