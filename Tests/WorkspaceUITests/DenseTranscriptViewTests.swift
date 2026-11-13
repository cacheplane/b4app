#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// What the transcript draws at each density, measured on hosted views at the reading column's width.
  @Suite(.serialized) @MainActor struct DenseTranscriptViewTests {
    // MARK: fixtures

    private func item(
      _ id: String, turn: String? = "t1", role: DisplayItemRole, type: String, status: String? = nil,
      payload: [String: JSONValue] = [:], thread: String = "th"
    ) -> DisplayItem {
      var members = payload
      if let status { members["status"] = .string(status) }
      return DisplayItem(
        id: id, threadId: thread, turnId: turn, role: role, type: type, payload: .object(members),
        sequence: 0, provenance: .live)
    }

    /// A user message, reasoning, two commands and an answer, numbered in order.
    private func fiveItems(turn: String? = "t1") -> [DisplayItem] {
      [
        item(
          "u1", turn: turn, role: .user, type: "userMessage",
          payload: ["text": .string("Fix the build")]),
        item(
          "r1", turn: turn, role: .assistant, type: "reasoning",
          payload: ["text": .string("Looking at the failure first.")]),
        item(
          "c1", turn: turn, role: .tool, type: "commandExecution", status: "completed",
          payload: ["command": .string("swift build")]),
        item(
          "c2", turn: turn, role: .tool, type: "commandExecution", status: "completed",
          payload: ["command": .string("swift test")]),
        item(
          "a1", turn: turn, role: .assistant, type: "agentMessage",
          payload: ["text": .string("The build passes now.")]),
      ].enumerated().map { index, item in
        var copy = item
        copy.sequence = index + 1
        return copy
      }
    }

    private func turn(_ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed) -> Turn {
      Turn(id: "t1", threadId: "th", operationId: "op-t1", status: status, outcome: outcome)
    }

    private func conversation(_ id: String) -> ConversationThread {
      ConversationThread(
        id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, createdAt: "2026-11-11T10:00:00Z",
        updatedAt: "2026-11-11T10:00:00Z")
    }

    private func detail(
      _ items: [DisplayItem], turns: [Turn]? = nil, thread: String = "th"
    ) -> ThreadDetail {
      ThreadDetail(
        thread: conversation(thread), turns: turns ?? [turn()], items: items, requests: [])
    }

    private func height<V: View>(_ view: V, width: CGFloat = 720) -> CGFloat {
      let host = NSHostingView(rootView: view.frame(width: width))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    /// The transcript's spacing, padding and end marker around `rows`.
    private func column<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
      VStack(alignment: .leading, spacing: LLA.Space.l) {
        rows()
        Color.clear.frame(height: 1)
      }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Metrics.margin)
      .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
      .frame(maxWidth: .infinity)
    }

    private func row(_ item: DisplayItem) -> TranscriptRow { TranscriptRow(item: item, liveText: nil) }

    private func line(
      counted: Int = 4, failed: Int = 0, running: Bool = false, name: String? = nil
    ) -> DenseTranscript.StepsLine {
      DenseTranscript.StepsLine(
        group: "t1", folded: [], counted: counted, failed: failed, declined: 0, running: running,
        waiting: false, runningName: name)
    }

    private func lineRow(_ line: DenseTranscript.StepsLine, open: Bool = false) -> StepsLineRow {
      StepsLineRow(line: line, open: open, toggle: {})
    }

    // MARK: density

    @Test func normalDensityIsTodaysTranscript() {
      let items = fiveItems()
      let content = TranscriptContent(
        detail: detail(items), dense: false, folds: TranscriptFolds(), lazy: false)
      let reference = column { ForEach(items) { row($0) } }
      #expect(height(content) == height(reference))
    }

    @Test func denseIsShorterByTheFoldedSteps() {
      let items = fiveItems()
      let normal = height(
        TranscriptContent(detail: detail(items), dense: false, folds: TranscriptFolds(), lazy: false))
      let dense = height(
        TranscriptContent(detail: detail(items), dense: true, folds: TranscriptFolds(), lazy: false))
      #expect(dense < normal)
      let reference = column {
        row(items[0])
        lineRow(line())
        row(items[4])
      }
      #expect(dense == height(reference))
    }

    @Test func anOpenTurnIsAsTallAsNormalPlusTheLine() {
      let items = fiveItems()
      let normal = height(
        TranscriptContent(detail: detail(items), dense: false, folds: TranscriptFolds(), lazy: false))
      let open = height(
        TranscriptContent(
          detail: detail(items), dense: true, folds: TranscriptFolds(open: ["t1"]), lazy: false))
      #expect(open == normal + height(lineRow(line(), open: true)) + LLA.Space.l)
    }

    @Test func aThreadFromHistoryIsDenseToo() {
      let withTurn = height(
        TranscriptContent(detail: detail(fiveItems()), dense: true, folds: TranscriptFolds(), lazy: false))
      let history = height(
        TranscriptContent(
          detail: detail(fiveItems(turn: nil), turns: []), dense: true, folds: TranscriptFolds(), lazy: false)
      )
      #expect(history == withTurn)
    }

    @Test func aFailedTurnsNoteIsDrawnAtBothDensities() {
      let items = Array(fiveItems().prefix(1))
      #expect(TurnNoteRow(turn: turn(.terminal, .failed)).text == "Turn failed.")
      for dense in [false, true] {
        func content(_ turn: Turn) -> some View {
          TranscriptContent(
            detail: detail(items, turns: [turn]), dense: dense, folds: TranscriptFolds(), lazy: false)
        }
        let withNote = height(content(turn(.terminal, .failed)))
        let without = height(content(turn()))
        #expect(withNote > without, "dense: \(dense)")
      }
    }

    // MARK: the line

    @Test func theLineReadsAsOneElement() {
      #expect(lineRow(line(counted: 4, failed: 1)).label == "4 steps, 1 failed, Show")
      #expect(lineRow(line(counted: 0)).label == "Show working")
      #expect(lineRow(line(running: true, name: "swift test")).label == "swift test, Show")
      #expect(lineRow(line(counted: 4), open: true).label == "4 steps, Hide")
    }

    @Test func aLongRunningNameKeepsTheLineOneLineHigh() {
      let long = String(repeating: "x", count: DenseTranscript.nameLimit)
      let cut = lineRow(line(running: true, name: long))
      let plain = lineRow(line(running: true, name: nil))
      #expect(height(cut, width: 320) == height(plain, width: 320))
      // The action word is part of the label whatever the name's length.
      #expect(cut.label.hasSuffix(", Show"))
    }

    @Test func anAnswerKeepsItsRowWhenItsTurnEnds() throws {
      var items = fiveItems()
      items.insert(
        item(
          "a0", role: .assistant, type: "agentMessage", payload: ["text": .string("On it.")]), at: 1)
      items = items.enumerated().map { index, item in
        var copy = item
        copy.sequence = index + 1
        return copy
      }
      func answerId(_ turn: Turn) throws -> String {
        let entries = DenseTranscript.entries(items: items, turns: [turn], open: [])
        return try #require(
          entries.last {
            if case .item(let item) = $0 { return item.role == .assistant }
            return false
          }?.id)
      }
      #expect(try answerId(turn(.running, nil)) == "a1")
      #expect(try answerId(turn()) == "a1")
    }

    // MARK: forgetting

    @Observable @MainActor final class Host {
      var detail: ThreadDetail
      init(_ detail: ThreadDetail) { self.detail = detail }
    }

    private struct HostView: View {
      let host: Host
      let folds: TranscriptFolds
      var body: some View { TranscriptView(detail: host.detail, dense: true, folds: folds) }
    }

    @Test func openTurnsAreForgottenWithTheThread() async throws {
      let first = detail(fiveItems())
      let other = detail(
        fiveItems().map { item in
          var copy = item
          copy.id = "o-\(item.id)"
          copy.threadId = "other"
          return copy
        }, thread: "other")
      let host = Host(first)
      let folds = TranscriptFolds()
      let window = SnapshotWindow(
        rootView: HostView(host: host, folds: folds).frame(width: 720, height: 560),
        size: CGSize(width: 720, height: 560))
      defer { window.close() }
      folds.toggle("t1")
      #expect(folds.open == ["t1"])
      host.detail = other
      try await waitUntil("the turn is closed") { folds.open.isEmpty }
      host.detail = first
      window.host.layoutSubtreeIfNeeded()
      #expect(folds.open.isEmpty)
    }
  }
#endif
