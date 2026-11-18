import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

#if os(macOS)
  import AppKit
  import SwiftUI
#endif

/// An opened turn's rows, decided without SwiftUI: one row per step, in sequence order.
@Suite struct StepRowTests {
  // MARK: fixtures

  private static let began = "2026-11-18T10:00:00.000Z"

  private func item(
    _ id: String, turn: String? = "t1", role: DisplayItemRole, type: String, status: String? = nil,
    payload: [String: JSONValue] = [:]
  ) -> DisplayItem {
    var members = payload
    if let status { members["status"] = .string(status) }
    return DisplayItem(
      id: id, threadId: "th", turnId: turn, role: role, type: type, payload: .object(members), sequence: 0,
      provenance: .live, createdAt: Self.began)
  }

  private func numbered(_ items: [DisplayItem]) -> [DisplayItem] {
    items.enumerated().map { index, item in
      var copy = item
      copy.sequence = index + 1
      return copy
    }
  }

  private func turn(_ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed) -> Turn {
    Turn(
      id: "t1", threadId: "th", operationId: "op-t1", status: status, outcome: outcome, createdAt: Self.began,
      updatedAt: Self.began)
  }

  private func rows(_ entries: [DenseTranscript.Entry]) -> [DenseTranscript.StepRow] {
    entries.compactMap { entry in
      if case .step(let row) = entry { return row }
      return nil
    }
  }

  /// A user's message, then every kind of folded item, then the answer.
  private var everyKind: [DisplayItem] {
    let plan = TaskList(steps: [.init(text: "Build", status: .completed)])
    return numbered([
      item("u1", role: .user, type: "userMessage", payload: ["text": .string("Fix it.")]),
      item(
        "c1", role: .tool, type: "commandExecution", status: "completed", payload: ["command": "swift build"]),
      item(
        "f1", role: .tool, type: "fileChange", status: "failed",
        payload: ["changes": [["path": "Sources/A.swift", "diff": "+a"]]]),
      item(
        "c2", role: .tool, type: "commandExecution", status: "declined", payload: ["command": "rm -rf .build"]
      ),
      item(
        "c3", role: .tool, type: "commandExecution", status: "inProgress", payload: ["command": "swift test"]),
      item("r1", role: .assistant, type: "reasoning", payload: ["text": "Looking at the link first."]),
      item("m1", role: .assistant, type: "agentMessage", payload: ["text": "Building now."]),
      item("p1", role: .tool, type: TaskList.itemType, payload: plan.payload.objectValue ?? [:]),
      item("x1", role: .tool, type: "somethingNew"),
      item("a1", role: .assistant, type: "agentMessage", payload: ["text": "Done."]),
    ])
  }

  // MARK: the projection

  @Test func anOpenedTurnDrawsOneRowPerItemInOrder() throws {
    let entries = DenseTranscript.entries(items: everyKind, turns: [turn()], open: ["t1"])
    #expect(
      entries.map(\.id) == ["u1", "steps-t1", "c1", "f1", "c2", "c3", "r1", "m1", "p1", "x1", "a1"])
    // The answer is what the closed turn shows: still an item.
    guard case .item(let answer)? = entries.last else {
      Issue.record("the answer is not an item")
      return
    }
    #expect(answer.id == "a1")
    let steps = rows(entries)
    #expect(steps.map(\.kind) == [.step, .step, .step, .step, .thought, .message, .plan, .other])
    #expect(steps.map(\.mark) == [.done, .failed, .declined, .unfinished, .none, .none, .none, .none])
    #expect(steps.allSatisfy { $0.depth == 1 && $0.duration == nil && $0.startedAt == nil })
    #expect(
      Array(steps.map(\.title).prefix(5)) == [
        "swift build", "File change (1 file)", "rm -rf .build", "swift test", "Thought",
      ])
    #expect(steps[3].item.payload["status"] == .string("stopped"))
  }

  @Test func aClosedTurnDrawsNoStepRows() {
    let entries = DenseTranscript.entries(items: everyKind, turns: [turn()], open: [])
    #expect(rows(entries).isEmpty)
    #expect(entries.map(\.id) == ["u1", "steps-t1", "a1"])
  }

  @Test func aRunningTurnsOpenStepRunsFromItsStart() throws {
    let entries = DenseTranscript.entries(items: everyKind, turns: [turn(.running, nil)], open: ["t1"])
    let open = try #require(rows(entries).first { $0.id == "c3" })
    #expect(open.mark == .running)
    #expect(open.startedAt == Self.began)
    #expect(open.spoken == "Running, swift test")
    // While it runs, its messages and plan stand outside the fold as they do closed.
    #expect(rows(entries).map(\.id) == ["c1", "f1", "c2", "c3", "r1", "x1"])
    for id in ["m1", "p1", "a1"] {
      #expect(entries.contains { if case .item(let item) = $0 { item.id == id } else { false } }, "\(id)")
    }
  }

  /// A turn waiting for the user moves nothing: its open step is still, with no clock.
  @Test func aWaitingTurnsOpenStepWaitsWithNoClock() throws {
    let entries = DenseTranscript.entries(
      items: everyKind, turns: [turn(.waitingForUser, nil)], open: ["t1"])
    let open = try #require(rows(entries).first { $0.id == "c3" })
    #expect(open.mark == .waiting)
    #expect(open.startedAt == nil)
    #expect(open.state == "Waiting")
    #expect(open.spoken == "Waiting, swift test")
    #expect(!rows(entries).contains { $0.mark == .running || $0.startedAt != nil })
  }

  /// A stopping turn's line is marked, and so is its open step, which keeps its clock.
  @Test func aStoppingTurnsOpenStepStillRuns() throws {
    let entries = DenseTranscript.entries(items: everyKind, turns: [turn(.stopping, nil)], open: ["t1"])
    let open = try #require(rows(entries).first { $0.id == "c3" })
    #expect(open.mark == .running)
    #expect(open.startedAt == Self.began)
    #expect(open.spoken == "Running, swift test")
  }

  /// Any other working row is a step row with no time, even while it runs.
  @Test func anUncountedRunningItemHasNoClock() throws {
    let items = numbered([
      item("u1", role: .user, type: "userMessage"),
      item("x1", role: .tool, type: "somethingNew", status: "inProgress"),
    ])
    let entries = DenseTranscript.entries(items: items, turns: [turn(.running, nil)], open: ["t1"])
    let other = try #require(rows(entries).first)
    #expect(other.kind == .other)
    #expect(other.mark == .running)
    #expect(other.startedAt == nil)
  }

  @Test func theRowIsSpokenAsStateTitleAndTime() throws {
    let entries = DenseTranscript.entries(items: everyKind, turns: [turn()], open: ["t1"])
    var steps = rows(entries)
    #expect(steps[0].spoken == "Completed, swift build")
    #expect(steps[1].spoken == "Failed, File change (1 file)")
    #expect(steps[2].spoken == "Declined, rm -rf .build")
    #expect(steps[3].spoken == "Unfinished, swift test")
    #expect(steps[4].spoken == "Thought")
    steps[0].duration = 24
    #expect(steps[0].spoken == "Completed, swift build, 24 seconds")
  }

  @Test func aStepWithNothingToShowDoesNotOpen() {
    // Only a working directory: no input, output, exit code, change or raw text.
    let bare = item(
      "c1", role: .tool, type: "commandExecution", status: "completed",
      payload: ["command": "ls", "cwd": "/work"])
    #expect(!DenseTranscript.stepRow(bare, in: .terminal).opens)
    var output = bare
    output.payload = ["command": "ls", "cwd": "/work", "aggregatedOutput": "a\nb", "status": "completed"]
    #expect(DenseTranscript.stepRow(output, in: .terminal).opens)
    // Anything else keeps its raw payload to show.
    #expect(DenseTranscript.stepRow(item("x", role: .tool, type: "somethingNew"), in: .terminal).opens)
    // A thought opens to its text, and has nothing to open without one.
    #expect(
      DenseTranscript.stepRow(
        item("r", role: .assistant, type: "reasoning", payload: ["text": "Hm."]), in: .terminal
      ).opens)
    #expect(!DenseTranscript.stepRow(item("r", role: .assistant, type: "reasoning"), in: .terminal).opens)
  }

  /// D-223's turnless items before the first group: work is a step row (no line stands above it) and
  /// never reads as running; a system item is still drawn as it is.
  @Test func turnlessWorkBeforeAnyGroupIsAStepRow() throws {
    let entries = DenseTranscript.entries(
      items: numbered([
        item("s0", turn: nil, role: .system, type: "contextCompaction"),
        item("k0", turn: nil, role: .tool, type: "toolCall", status: "inProgress"),
        item("r0", turn: nil, role: .assistant, type: "reasoning", payload: ["text": "Hm."]),
        item("u1", role: .user, type: "userMessage"),
      ]), turns: [turn()], open: [])
    #expect(entries.map(\.id) == ["s0", "k0", "r0", "u1"])
    let steps = rows(entries)
    #expect(steps.map(\.id) == ["k0", "r0"])
    #expect(steps.map(\.mark) == [.unfinished, .none])
    #expect(steps.allSatisfy { $0.depth == 1 })
  }

  /// No tool or reasoning item is ever drawn by `TranscriptRow`, open or closed, running or not.
  @Test func workIsNeverAnItem() {
    for status in [TurnStatus.terminal, .running, .waitingForUser, .reconciling] {
      for open: Set<String> in [[], ["t1"]] {
        let entries = DenseTranscript.entries(items: everyKind, turns: [turn(status, nil)], open: open)
        for case .item(let item) in entries {
          let isPlan = item.type == TaskList.itemType
          #expect(!DenseTranscript.isWork(item) || isPlan, "\(item.id), \(status), \(open)")
        }
      }
    }
  }

  @Test func anOpenIdWhoseItemIsGoneChangesNothing() {
    let items = everyKind
    let plain = DenseTranscript.entries(items: items, turns: [turn()], open: ["t1"])
    #expect(DenseTranscript.entries(items: items, turns: [turn()], open: ["t1", "gone", "c1"]) == plain)
  }

  // MARK: the window

  /// An opened turn of 400 steps: the window is the latest page, every entry in it stands on its own,
  /// and nothing is lost between what is hidden and what is drawn.
  @Test func theWindowOfAnOpenedLongTurn() {
    let items = numbered(
      [item("u1", role: .user, type: "userMessage")]
        + (1...400).map {
          item(
            "c\($0)", role: .tool, type: "commandExecution", status: "completed", payload: ["command": "ls"])
        } + [item("a1", role: .assistant, type: "agentMessage", payload: ["text": "Done."])])
    let all = DenseTranscript.entries(items: items, turns: [turn()], open: ["t1"])
    #expect(all.count == 403)
    let window = DenseTranscript.window(all, shown: DenseTranscript.page)
    // The user's message is far above the cut: the window is exactly the page.
    #expect(window.entries.count == DenseTranscript.page)
    #expect(window.hidden + window.entries.count == all.count)
    #expect(Array(all.prefix(window.hidden)) + window.entries == all)
    for entry in window.entries {
      guard case .step(let row) = entry else {
        #expect(entry.id == "a1")
        continue
      }
      #expect(row.kind == .step && row.depth == 1 && row.mark == .done)
    }
    // Within reach, the window begins at the user's message.
    let near = DenseTranscript.window(all, shown: all.count - 10)
    #expect(near.hidden == 0 && near.entries.first?.id == "u1")
  }

  /// A step row joins the run of the line or step before it; nothing else does.
  @Test func runsKeepALineAndItsRowsTogether() {
    var second = item("u2", turn: "t2", role: .user, type: "userMessage")
    second.sequence = 100
    let entries = DenseTranscript.entries(items: everyKind + [second], turns: [turn()], open: ["t1"])
    let runs = DenseTranscript.runs(entries)
    #expect(runs.flatMap { $0 } == entries)
    #expect(
      runs.map { $0.map(\.id) } == [
        ["u1"], ["steps-t1", "c1", "f1", "c2", "c3", "r1", "m1", "p1", "x1"], ["a1"], ["u2"],
      ])
  }
}

#if os(macOS)
  /// The row as it is drawn.
  @Suite(.serialized) @MainActor struct StepRowViewTests {
    private let streams = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })

    private func command(_ command: String, status: String = "completed") -> DenseTranscript.StepRow {
      DenseTranscript.stepRow(
        DisplayItem(
          id: "c1", threadId: "th", turnId: "t1", role: .tool, type: "commandExecution",
          payload: ["command": .string(command), "status": .string(status), "aggregatedOutput": "ok"],
          sequence: 1, provenance: .live), in: .running)
    }

    private func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
      let host = NSHostingView(rootView: view.frame(width: width))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    private func view(_ row: DenseTranscript.StepRow, open: Bool = false) -> StepRowView {
      StepRowView(row: row, streams: streams, open: open, toggle: {})
    }

    @Test func aRowIsOneLineCutAtItsTail() {
      let long = command(String(repeating: "swift test --filter Something ", count: 10))
      #expect(height(view(long), width: 320) == height(view(command("ls")), width: 320))
    }

    /// At an accessibility size the title wraps rather than being cut, and the row grows with it.
    @Test func atAnAccessibilitySizeTheTitleWraps() {
      let long = command(String(repeating: "swift test --filter Something ", count: 10))
      func stacked(_ row: DenseTranscript.StepRow) -> CGFloat {
        height(view(row).environment(\.dynamicTypeSize, .accessibility5), width: 320)
      }
      #expect(stacked(long) > stacked(command("ls")) * 2)
      let fitting = NSHostingController(
        rootView: view(long).environment(\.dynamicTypeSize, .accessibility5)
      ).sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
      #expect(fitting.width <= 320)
    }

    @Test func openedAStepDrawsItsOutputUnderIt() {
      let row = command("swift build")
      #expect(height(view(row, open: true), width: 600) > height(view(row), width: 600))
      // A row with nothing to open draws nothing more, whatever `open` says.
      var bare = row
      bare.opens = false
      #expect(height(view(bare, open: true), width: 600) == height(view(bare), width: 600))
    }

    /// An agent's row is one line opened or not: its children and its result are rows of their own, the
    /// result an `AgentOutputRow` after the children. Its "Show" is not spoken: the button's value is.
    @Test func anAgentRowDrawsItsResultApart() {
      let agent = DenseTranscript.stepRow(
        DisplayItem(
          id: "k1", threadId: "th", turnId: "t1", role: .tool, type: "toolUse",
          payload: [
            "name": "Agent", "status": "completed", "output": "Three files.",
            "input": ["description": "Count Swift files in src"],
          ], sequence: 1, provenance: .live), in: .terminal)
      #expect(agent.kind == .agent(steps: 0) && agent.opens)
      #expect(height(view(agent, open: true), width: 600) == height(view(agent), width: 600))
      #expect(height(AgentOutputRow(row: agent), width: 600) > 0)
      let screen = HostedScreen(VStack { view(agent) }, size: CGSize(width: 400, height: 80))
      defer { screen.close() }
      #expect(screen.label("step-row") == "Completed, Agent: Count Swift files in src")
      #expect(screen.value("step-row") == "Collapsed")
    }

    @Test func theRowIsOneElementSpokenStateFirst() {
      let screen = HostedScreen(
        VStack { view(command("swift build", status: "failed")) }, size: CGSize(width: 400, height: 80))
      defer { screen.close() }
      let heard = screen.elements.compactMap(\.label)
      #expect(heard.contains("Failed, swift build"), "\(heard)")
    }

    /// A row that opens is a button whose value says whether it is open; one that does not is no button.
    @Test func anOpenableRowIsAButtonWithItsState() throws {
      func element(_ row: DenseTranscript.StepRow, open: Bool) -> (NSAccessibility.Role?, String?, String?) {
        let screen = HostedScreen(VStack { view(row, open: open) }, size: CGSize(width: 400, height: 200))
        defer { screen.close() }
        let found = screen.element("step-row")
        return (found?.role, found?.value, found?.label)
      }
      let row = command("swift build")
      let closed = element(row, open: false)
      #expect(closed.0 == .button, "\(String(describing: closed))")
      #expect(closed.1 == "Collapsed", "\(String(describing: closed))")
      #expect(closed.2 == "Completed, swift build", "\(String(describing: closed))")
      let opened = element(row, open: true)
      #expect(opened.0 == .button, "\(String(describing: opened))")
      #expect(opened.1 == "Expanded", "\(String(describing: opened))")
      var bare = row
      bare.opens = false
      let still = element(bare, open: false)
      #expect(still.0 != nil && still.0 != .button, "\(String(describing: still))")
      #expect(still.1 != "Collapsed" && still.1 != "Expanded", "\(String(describing: still))")
    }

    /// A running step's clock speaks its time after the title.
    @Test func aRunningRowSpeaksItsClock() {
      var row = command("swift test", status: "inProgress")
      row.startedAt = Timestamp.string(from: Date().addingTimeInterval(-24))
      let screen = HostedScreen(VStack { view(row) }, size: CGSize(width: 400, height: 80))
      defer { screen.close() }
      let heard = screen.elements.compactMap(\.label)
      #expect(
        heard.contains("Running, swift test, 24 seconds")
          || heard.contains("Running, swift test, 25 seconds"),
        "\(heard)")
    }

    /// An open id whose item is gone draws nothing different.
    @Test func aStaleOpenIdChangesNothingDrawn() {
      let items = [
        DisplayItem(
          id: "u1", threadId: "th", turnId: "t1", role: .user, type: "userMessage",
          payload: ["text": "Go."], sequence: 1, provenance: .live),
        DisplayItem(
          id: "c1", threadId: "th", turnId: "t1", role: .tool, type: "commandExecution",
          payload: ["command": "ls", "status": "completed"], sequence: 2, provenance: .live),
      ]
      let detail = ThreadDetail(
        thread: ConversationThread(
          id: "th", connectionId: "c", nativeThreadId: "n", title: "th", createdAt: "2026-11-11T10:00:00Z",
          updatedAt: "2026-11-11T10:00:00Z"),
        turns: [Turn(id: "t1", threadId: "th", operationId: "op", status: .terminal, outcome: .completed)],
        items: items, requests: [])
      func drawn(_ open: Set<String>) -> CGFloat {
        height(
          TranscriptContent(detail: detail, streams: streams, folds: TranscriptFolds(open: open)), width: 720)
      }
      #expect(drawn(["t1", "gone"]) == drawn(["t1"]))
      #expect(drawn(["t1"]) > drawn([]))
    }
  }
#endif
