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

    @Test func onlyTheFailedCountIsInDanger() {
      typealias Segment = StepsLineRow.Segment
      let both = DenseTranscript.StepsLine(
        group: "t1", folded: [], counted: 4, failed: 1, declined: 1, running: false, waiting: false,
        runningName: nil)
      #expect(
        lineRow(both).segments == [
          Segment(text: "4 steps", tone: .muted), Segment(text: ", ", tone: .muted),
          Segment(text: "1 failed", tone: .danger), Segment(text: ", ", tone: .muted),
          Segment(text: "1 declined", tone: .muted),
        ])
      #expect(lineRow(line(counted: 0)).segments.isEmpty)
    }

    @Test func stackedTheActionWordWraps() {
      func stacked(width: CGFloat) -> CGFloat {
        height(
          lineRow(line(counted: 0), open: true).environment(\.dynamicTypeSize, .accessibility5), width: width)
      }
      // "Hide working" alone on a row narrower than it takes a second line instead of running past it.
      #expect(stacked(width: 40) > stacked(width: 400))
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

  /// Where the transcript's scroll view stands when a turn is opened and the stream goes on, read from
  /// the real `TranscriptView` (its lazy stack inside its `ScrollView`) hosted in a 720 by 480 window.
  @Suite(.serialized) @MainActor struct TranscriptScrollTests {
    // MARK: fixtures

    private static let thread = "th"

    private func item(
      _ id: String, turn: String, role: DisplayItemRole, type: String, sequence: Int,
      native: String? = nil, payload: [String: JSONValue] = [:]
    ) -> DisplayItem {
      DisplayItem(
        id: id, threadId: Self.thread, turnId: turn, nativeItemId: native, role: role, type: type,
        payload: .object(payload), sequence: sequence, provenance: .live)
    }

    private func turn(_ number: Int, _ status: TurnStatus = .terminal) -> Turn {
      Turn(
        id: "t\(number)", threadId: Self.thread, operationId: "op-\(number)", status: status,
        outcome: status == .terminal ? .completed : nil,
        createdAt: String(format: "2026-11-11T10:%02d:00Z", number))
    }

    private func message(
      _ id: String, turn: String, sequence: Int, native: String? = nil, text: String
    )
      -> DisplayItem
    {
      item(
        id, turn: turn, role: .assistant, type: "agentMessage", sequence: sequence, native: native,
        payload: ["text": .string(text)])
    }

    private func step(_ id: String, turn: String, sequence: Int, status: String = "completed") -> DisplayItem
    {
      item(
        id, turn: turn, role: .tool, type: "commandExecution", sequence: sequence,
        payload: ["command": .string("swift test --filter \(id)"), "status": .string(status)])
    }

    private func user(_ id: String, turn: String, sequence: Int) -> DisplayItem {
      item(
        id, turn: turn, role: .user, type: "userMessage", sequence: sequence,
        payload: ["text": .string("Next, please: \(id)")])
    }

    /// One ended turn: the message, four steps and the answer, from `sequence` on.
    private func endedTurn(_ number: Int, from sequence: Int) -> [DisplayItem] {
      let id = "t\(number)"
      return [user("u\(number)", turn: id, sequence: sequence)]
        + (1...4).map { step("s\(number)-\($0)", turn: id, sequence: sequence + $0) }
        + [message("a\(number)", turn: id, sequence: sequence + 5, text: "Turn \(number) is done.")]
    }

    /// Twelve ended turns, each of four steps.
    private func twelveTurns() -> ThreadDetail {
      ThreadDetail(
        thread: conversation(), turns: (1...12).map { turn($0) },
        items: (1...12).flatMap { endedTurn($0, from: $0 * 10) }, requests: [])
    }

    /// Twelve ended turns and a thirteenth running, its reply streaming as `n13`.
    private func twelveAndARunningTurn() -> ThreadDetail {
      var detail = twelveTurns()
      detail.turns.append(turn(13, .running))
      detail.items += [
        user("u13", turn: "t13", sequence: 130),
        message("a13", turn: "t13", sequence: 131, native: "n13", text: ""),
      ]
      detail.liveText["n13"] = "Starting."
      return detail
    }

    private func conversation() -> ConversationThread {
      ConversationThread(
        id: Self.thread, connectionId: "c1", nativeThreadId: "n-th", title: "th",
        createdAt: "2026-11-11T10:00:00Z", updatedAt: "2026-11-11T10:00:00Z")
    }

    private func lines(_ count: Int) -> String {
      (1...count).map { "Line \($0) of the streamed reply." }.joined(separator: "\n")
    }

    // MARK: the hosted transcript

    @Observable @MainActor final class Host {
      var detail: ThreadDetail
      init(_ detail: ThreadDetail) { self.detail = detail }
    }

    private struct HostView: View {
      let host: Host
      let folds: TranscriptFolds
      let dense: Bool
      var body: some View { TranscriptView(detail: host.detail, dense: dense, folds: folds) }
    }

    /// The window, the scroll view AppKit made for the transcript's `ScrollView`, and its clip view's
    /// origin (the document view is flipped: y grows downward from the transcript's top).
    @MainActor final class Hosted {
      let host: Host
      let folds: TranscriptFolds
      private let root: NSView
      private let window: NSWindow
      let scroll: NSScrollView

      init(_ detail: ThreadDetail, dense: Bool = true) throws {
        host = Host(detail)
        folds = TranscriptFolds()
        let snapshot = SnapshotWindow(
          rootView: HostView(host: host, folds: folds, dense: dense).frame(width: 720, height: 480),
          untitled: true, size: CGSize(width: 720, height: 480))
        root = snapshot.host
        window = snapshot.window
        root.layoutSubtreeIfNeeded()
        scroll = try #require(Self.scrollView(in: root), "no NSScrollView under the hosting view")
        #expect(scroll.documentView?.isFlipped == true)
      }

      private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
          if let found = scrollView(in: subview) { return found }
        }
        return nil
      }

      func close() { window.close() }

      var origin: CGFloat { scroll.contentView.bounds.origin.y }
      var documentHeight: CGFloat { scroll.documentView?.frame.height ?? 0 }
      var viewportHeight: CGFloat { scroll.contentView.bounds.height }
      /// From the viewport's bottom edge to the document's.
      var below: CGFloat { documentHeight - (origin + viewportHeight) }
      /// The end marker is in view: following the stream (`scrollTo("bottom")`) puts the 1 pt marker at
      /// the viewport's bottom edge, leaving the transcript's bottom padding below it; a reader's scroll
      /// to the end leaves nothing below.
      var atEnd: Bool { below >= -0.5 && below <= LLA.Metrics.margin + 1.5 }
      /// Nothing at all below the viewport.
      var atDocumentEnd: Bool { abs(below) <= 0.5 }

      /// One layout pass and one turn of the main run loop.
      private func pass() async {
        root.layoutSubtreeIfNeeded()
        turnRunLoop()
        await Task.yield()
      }

      /// Synchronous by design: `RunLoop.run` is unavailable from async code.
      private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }

      /// Returns once `condition` holds after a pass. No clock decides the outcome: the timeout only
      /// ends a test that would otherwise hang.
      func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition() {
          guard ContinuousClock.now < deadline else {
            throw WorkspaceError(.internalError, "timed out waiting for \(what)")
          }
          await pass()
        }
      }

      /// Returns once the origin and the document's height have not moved for ten passes in a row: the
      /// lazy stack has laid out what it shows and nothing is left to scroll.
      func settle() async throws {
        var last = (origin, documentHeight)
        var still = 0
        try await until("the transcript to settle") {
          let now = (origin, documentHeight)
          still = abs(now.0 - last.0) < 0.01 && abs(now.1 - last.1) < 0.01 ? still + 1 : 0
          last = now
          return still >= 10
        }
      }

      /// How far a reader's scroll to the end moves the view from where it is: at most the bottom padding
      /// when the end marker is already in view. Read when the document's height may still be estimated.
      func distanceToEnd() async throws -> CGFloat {
        let from = origin
        try await scrollToEnd()
        return origin - from
      }

      /// Moves the clip view as a reader's scroll would, and lets the transcript see it.
      func scroll(to y: CGFloat) async throws {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
      }

      /// The lazy stack sizes rows it has not drawn by estimate, so the end moves as it is reached.
      func scrollToEnd() async throws {
        try await settle()
        try await until("the end") {
          if atDocumentEnd { return true }
          scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - viewportHeight)))
          scroll.reflectScrolledClipView(scroll.contentView)
          return false
        }
        try await settle()
        #expect(atDocumentEnd, "below the viewport: \(below)")
      }
    }

    // MARK: opening a turn

    @Test func openingATurnLeavesItsLineWhereItWas() async throws {
      let view = try Hosted(twelveTurns())
      defer { view.close() }
      try await view.scrollToEnd()
      let origin = view.origin
      let closed = view.documentHeight

      view.folds.toggle("t12")
      try await view.until("the turn's steps are drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "moved by \(view.origin - origin)")
      #expect(view.documentHeight > closed)

      let open = view.documentHeight
      view.folds.toggle("t12")
      try await view.until("the turn's steps are gone") { view.documentHeight < open - 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5 || view.atDocumentEnd, "moved by \(view.origin - origin)")
    }

    @Test func aStreamDoesNotMoveAnOpenedTurn() async throws {
      let view = try Hosted(twelveAndARunningTurn())
      defer { view.close() }
      try await view.scrollToEnd()
      // Reading back a little, where the tenth turn is.
      try await view.scroll(to: view.origin - 300)
      let origin = view.origin

      view.folds.toggle("t10")
      try await view.settle()
      #expect(view.folds.holds)
      #expect(abs(view.origin - origin) <= 0.5, "opening moved it by \(view.origin - origin)")

      let height = view.documentHeight
      view.host.detail.liveText["n13"] = lines(20)
      view.host.detail.items.append(step("s13-1", turn: "t13", sequence: 132, status: "inProgress"))
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "the stream moved it by \(view.origin - origin)")
    }

    @Test func scrollingBackToTheEndFollowsTheStreamAgain() async throws {
      let view = try Hosted(twelveAndARunningTurn())
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      view.host.detail.liveText["n13"] = lines(10)
      try await view.settle()
      #expect(view.folds.holds)

      try await view.scrollToEnd()
      try await view.until("the hold is released") { !view.folds.holds }
      let height = view.documentHeight
      view.host.detail.liveText["n13"] = lines(30)
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
      #expect(!view.folds.holds)
    }

    @Test func aTurnEndingDoesNotMoveAnOpenedTurn() async throws {
      var detail = twelveTurns()
      detail.turns.append(turn(13, .running))
      detail.items += [
        user("u13", turn: "t13", sequence: 130),
        message("m13-1", turn: "t13", sequence: 131, text: "Looking at the build first."),
        step("s13-1", turn: "t13", sequence: 132),
        message("a13", turn: "t13", sequence: 133, native: "n13", text: ""),
      ]
      detail.liveText["n13"] = lines(4)
      let view = try Hosted(detail)
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      #expect(view.folds.holds)
      let origin = view.origin
      let height = view.documentHeight

      var ended = view.host.detail
      if let index = ended.items.firstIndex(where: { $0.id == "a13" }) {
        ended.items[index].payload = .object(["text": .string(lines(4))])
      }
      ended.liveText = [:]
      ended.turns[ended.turns.count - 1] = turn(13)
      view.host.detail = ended
      try await view.until("the interim message folds") { view.documentHeight < height - 1 }
      try await view.settle()
      #expect(view.folds.holds)
      #expect(abs(view.origin - origin) <= 0.5, "the turn's end moved it by \(view.origin - origin)")
    }

    @Test func anotherThreadShownWhileHeldOpensAtItsEnd() async throws {
      let view = try Hosted(twelveTurns())
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      #expect(view.folds.holds)

      // Another long thread with as many items and turns, so no count changes with the switch.
      var other = twelveTurns()
      other.thread.id = "other"
      other.turns = other.turns.map { turn in
        var copy = turn
        copy.id = "o-\(turn.id)"
        copy.threadId = "other"
        return copy
      }
      other.items = other.items.map { item in
        var copy = item
        copy.id = "o-\(item.id)"
        copy.threadId = "other"
        copy.turnId = item.turnId.map { "o-\($0)" }
        return copy
      }
      view.host.detail = other
      try await view.until("the turn is closed") { view.folds.open.isEmpty }
      try await view.settle()
      #expect(!view.folds.holds)
      // The document's height is still the lazy stack's estimate for rows of the old thread it has not
      // laid out again, so the end is found by going there, as a reader would.
      let short = try await view.distanceToEnd()
      #expect(short >= -0.5 && short <= LLA.Metrics.margin + 1.5, "short of the end by \(short)")
    }

    @Test func sendingAMessageReleasesTheHold() async throws {
      let view = try Hosted(twelveTurns())
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      #expect(view.folds.holds)

      let height = view.documentHeight
      view.host.detail.turns.append(turn(13, .running))
      view.host.detail.items.append(user("u13", turn: "t13", sequence: 130))
      try await view.until("the message is drawn") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(!view.folds.holds)
      #expect(view.atEnd, "below the viewport: \(view.below)")
    }

    @Test func aShortThreadStillFollowsItsStream() async throws {
      var detail = ThreadDetail(thread: conversation(), turns: [turn(1, .running)], items: [], requests: [])
      detail.items =
        [user("u1", turn: "t1", sequence: 1)]
        + (1...4).map { step("s1-\($0)", turn: "t1", sequence: 1 + $0) }
        + [message("a1", turn: "t1", sequence: 6, native: "n1", text: "")]
      detail.liveText["n1"] = "Starting."
      let view = try Hosted(detail)
      defer { view.close() }
      try await view.settle()

      let closed = view.documentHeight
      view.folds.toggle("t1")
      try await view.until("the turn's steps are drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      #expect(view.documentHeight <= view.viewportHeight + 0.5, "the open turn should still fit")
      #expect(!view.folds.holds)

      view.host.detail.liveText["n1"] = lines(60)
      try await view.until("the reply outgrows the window") {
        view.documentHeight > view.viewportHeight * 2
      }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
    }

    @Test func theAnswerStaysPutWhenItsTurnEnds() async throws {
      var detail = twelveTurns()
      detail.turns.append(turn(13, .running))
      detail.items += [
        user("u13", turn: "t13", sequence: 130),
        message("m13-1", turn: "t13", sequence: 131, text: "Looking at the build first."),
        step("s13-1", turn: "t13", sequence: 132),
        message("m13-2", turn: "t13", sequence: 133, text: "The test target fails to link."),
        step("s13-2", turn: "t13", sequence: 134),
        message("m13-3", turn: "t13", sequence: 135, text: "Fixed the link; running the tests again."),
        step("s13-3", turn: "t13", sequence: 136),
        message("a13", turn: "t13", sequence: 137, native: "n13", text: ""),
      ]
      detail.liveText["n13"] = "Starting."
      let view = try Hosted(detail)
      defer { view.close() }
      try await view.scrollToEnd()
      // The view follows the stream, as it does while a reply arrives.
      let streaming = view.documentHeight
      view.host.detail.liveText["n13"] = lines(4)
      try await view.until("the reply grows") { view.documentHeight > streaming + 1 }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
      // The answer is the last row: from its bottom edge to the document's end is the transcript's
      // bottom padding and end marker, whatever is folded above it.
      let below = view.below
      let height = view.documentHeight

      var ended = view.host.detail
      if let index = ended.items.firstIndex(where: { $0.id == "a13" }) {
        ended.items[index].payload = .object(["text": .string(lines(4))])
      }
      ended.liveText = [:]
      ended.turns[ended.turns.count - 1] = turn(13)
      view.host.detail = ended
      try await view.until("the interim messages fold") { view.documentHeight < height - 1 }
      try await view.settle()
      #expect(abs(view.below - below) <= 0.5, "the answer moved by \(below - view.below)")
    }

    @Test func withNothingToggledNormalDensityScrollsAsToday() async throws {
      let view = try Hosted(twelveAndARunningTurn(), dense: false)
      defer { view.close() }
      try await view.scrollToEnd()
      let height = view.documentHeight
      view.host.detail.liveText["n13"] = lines(20)
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
    }
  }
#endif
