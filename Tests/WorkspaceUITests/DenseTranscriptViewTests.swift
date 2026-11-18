#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// What the transcript draws, measured on hosted views at the reading column's width.
  @Suite(.serialized) @MainActor struct DenseTranscriptViewTests {
    // MARK: fixtures

    /// No message streams: every row draws its stored text.
    private let streams = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })

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

    private func row(_ item: DisplayItem) -> TranscriptRow { TranscriptRow(item: item, streams: streams) }

    private func line(
      counted: Int = 4, failed: Int = 0, state: DenseTranscript.ActivityLine.State = .ended,
      name: String? = nil, folded: Int = 1, duration: Int? = nil
    ) -> DenseTranscript.ActivityLine {
      DenseTranscript.ActivityLine(
        group: "t1",
        folded: (0..<folded).map {
          item("f\($0)", role: .assistant, type: "reasoning")
        }, counted: counted, failed: failed, declined: 0, state: state, runningName: name,
        startedAt: state == .ended ? nil : Timestamp.now(), duration: duration)
    }

    private func lineRow(_ line: DenseTranscript.ActivityLine, open: Bool = false) -> ActivityLineRow {
      ActivityLineRow(line: line, open: open, toggle: {})
    }

    // MARK: the one transcript

    @Test func aTurnIsTheMessageTheLineAndTheAnswer() {
      let items = fiveItems()
      let drawn = height(TranscriptContent(detail: detail(items), streams: streams, folds: TranscriptFolds()))
      let reference = column {
        row(items[0])
        lineRow(line())
        row(items[4])
      }
      #expect(drawn == height(reference))
      let open = height(
        TranscriptContent(detail: detail(items), streams: streams, folds: TranscriptFolds(open: ["t1"])))
      #expect(drawn < open)
    }

    /// Opened, the line and one row per folded item stand close together, between the message and the
    /// answer.
    @Test func anOpenTurnIsItsLineAndOneRowPerStep() {
      let items = fiveItems()
      let open = height(
        TranscriptContent(detail: detail(items), streams: streams, folds: TranscriptFolds(open: ["t1"])))
      let reference = column {
        row(items[0])
        VStack(alignment: .leading, spacing: 0) {
          lineRow(line(), open: true)
          ForEach(items[1...3]) { item in
            StepRowView(
              row: DenseTranscript.stepRow(item, in: .terminal), streams: streams, open: false, toggle: {})
          }
        }
        row(items[4])
      }
      #expect(open == height(reference))
    }

    @Test func aThreadFromHistoryDrawsAsAThreadWithATurn() {
      let withTurn = height(
        TranscriptContent(detail: detail(fiveItems()), streams: streams, folds: TranscriptFolds()))
      let history = height(
        TranscriptContent(
          detail: detail(fiveItems(turn: nil), turns: []), streams: streams, folds: TranscriptFolds())
      )
      #expect(history == withTurn)
    }

    /// A turn that ended with no outcome recorded (a synced status ahead of its outcome, or an
    /// outcome this build does not know) did not fail as far as anyone knows, and is not drawn as one.
    @Test func aTurnThatEndedWithNoOutcomeIsNotDrawnAsFailed() {
      let ended = TurnNoteRow(turn: turn(.terminal, nil))
      #expect(ended.text == "Turn ended.")
      #expect(!ended.isFailure)
      #expect(TurnNoteRow(turn: turn(.terminal, .failed)).isFailure)
      #expect(TurnNoteRow(turn: turn(.terminal, .cancelled)).text == "Turn stopped.")
      #expect(!TurnNoteRow(turn: turn(.terminal, .cancelled)).isFailure)
    }

    @Test func aFailedTurnsNoteIsDrawn() {
      let items = Array(fiveItems().prefix(1))
      #expect(TurnNoteRow(turn: turn(.terminal, .failed)).text == "Turn failed.")
      func content(_ turn: Turn) -> some View {
        TranscriptContent(detail: detail(items, turns: [turn]), streams: streams, folds: TranscriptFolds())
      }
      #expect(height(content(turn(.terminal, .failed))) > height(content(turn())))
    }

    // MARK: the line

    @Test func theLineReadsAsOneElement() {
      #expect(lineRow(line(counted: 4, failed: 1)).label == "4 steps, 1 failed, Show")
      #expect(lineRow(line(counted: 4, failed: 1, duration: 72)).label == "4 steps, 1 failed, 1m 12s, Show")
      #expect(lineRow(line(counted: 0)).label == "Show working")
      #expect(lineRow(line(counted: 0, folded: 0)).label == "")
      #expect(lineRow(line(state: .running, name: "swift test")).label == "swift test, Show")
      #expect(lineRow(line(state: .running, name: nil, folded: 0)).label == "Working")
      #expect(lineRow(line(counted: 4), open: true).label == "4 steps, Hide")
    }

    /// A running turn's line is one row high at a phone's width, whatever its step is called.
    @Test func aLongRunningNameKeepsTheLineOneRowHigh() {
      let long = String(repeating: "x", count: 200)
      let cut = lineRow(line(state: .running, name: long))
      let plain = height(lineRow(line(state: .running, name: nil)), width: 320)
      #expect(plain >= LLA.Metrics.row)
      #expect(height(cut, width: 320) == plain)
      #expect(height(lineRow(line(state: .stopping, folded: 0)), width: 320) == plain)
      // The action word is part of the label whatever the name's length.
      #expect(cut.label.hasSuffix(", Show"))
    }

    @Test func onlyTheFailedCountIsInDanger() {
      typealias Segment = ActivityLineRow.Segment
      var both = line(counted: 4, failed: 1)
      both.declined = 1
      #expect(
        lineRow(both).segments == [
          Segment(text: "4 steps", tone: .muted), Segment(text: ", ", tone: .muted),
          Segment(text: "1 failed", tone: .danger), Segment(text: ", ", tone: .muted),
          Segment(text: "1 declined", tone: .muted),
        ])
      both.duration = 72
      #expect(
        lineRow(both).segments.suffix(2) == [
          Segment(text: " · ", tone: .muted), Segment(text: "1m 12s", tone: .muted),
        ])
      #expect(lineRow(line(counted: 0)).segments.isEmpty)
    }

    /// A running line says how long it has run, in words, ahead of its action: the clock speaks it.
    @Test func aRunningLineSpeaksItsElapsedTime() throws {
      var running = line(state: .running, name: "swift test")
      running.startedAt = Timestamp.string(from: Date().addingTimeInterval(-75))
      let screen = HostedScreen(lineRow(running), size: CGSize(width: 400, height: 60))
      defer { screen.close() }
      let heard = screen.elements.compactMap(\.label)
      #expect(
        heard.contains("swift test, 1 minute 15 seconds, Show")
          || heard.contains("swift test, 1 minute 16 seconds, Show"), "\(heard)")
      // A line that opens says whether it is open, as a step row does, and keeps its spoken word.
      #expect(screen.value("activity-line") == "Collapsed")
      // An ended line has no clock to speak.
      let done = HostedScreen(lineRow(line(duration: 72)), size: CGSize(width: 400, height: 60))
      defer { done.close() }
      #expect(!done.elements.compactMap(\.label).contains { $0.hasSuffix("seconds") })
      let opened = HostedScreen(lineRow(line(duration: 72), open: true), size: CGSize(width: 400, height: 60))
      defer { opened.close() }
      #expect(opened.value("activity-line") == "Expanded")
      #expect(opened.label("activity-line") == "4 steps, 1m 12s, Hide")
      // A line with nothing to open is no control and has no state.
      let still = HostedScreen(
        lineRow(line(state: .running, name: nil, folded: 0)), size: CGSize(width: 400, height: 60))
      defer { still.close() }
      #expect(still.value("activity-line") != "Collapsed" && still.value("activity-line") != "Expanded")
    }

    /// Only a line that has not ended draws a clock.
    @Test func onlyALineThatHasNotEndedTicks() {
      for state: DenseTranscript.ActivityLine.State in [.running, .waiting, .stopping] {
        #expect(ActivityLineRow.ticks(line(state: state)), "\(state)")
      }
      #expect(!ActivityLineRow.ticks(line(duration: 72)))
    }

    /// The clock counts from the turn's start, once a second, and is the only thing that moves.
    @Test func theClockCountsAndTheProjectionDoesNot() async throws {
      let began = Timestamp.string(from: Date().addingTimeInterval(-42))
      let running = Turn(
        id: "t1", threadId: "clock-th", operationId: "op-t1", status: .running, createdAt: began)
      // A thread of its own: the projection counter is by thread, and other suites use "th".
      var first = fiveItems()[0]
      first.threadId = "clock-th"
      let screen = HostedScreen(
        TranscriptContent(
          detail: detail([first], turns: [running], thread: "clock-th"), streams: streams,
          folds: TranscriptFolds()),
        size: CGSize(width: 720, height: 400))
      defer { screen.close() }
      let before = DenseTranscript.projections(of: "clock-th")
      #expect(before > 0)
      // The running line draws its clock: 42 s since the turn began, spoken in words.
      #expect(
        screen.elements.compactMap(\.label).contains {
          $0.hasPrefix("Working, 4") && $0.hasSuffix(" seconds")
        })
      try await Task.sleep(for: .seconds(1.3))
      #expect(DenseTranscript.projections(of: "clock-th") == before)
    }

    @Test func stackedTheActionWordWraps() {
      func stacked(width: CGFloat) -> CGFloat {
        height(
          lineRow(line(counted: 0), open: true).environment(\.dynamicTypeSize, .accessibility5), width: width)
      }
      // "Hide working" alone on a row narrower than it takes a second line instead of running past it.
      #expect(stacked(width: 40) > stacked(width: 400))

      // A line with every part wraps as one text: the count is not squeezed by the parts after it.
      var every = line(counted: 4, failed: 1)
      every.declined = 1
      let both = lineRow(every)
        .environment(\.dynamicTypeSize, .accessibility5)
      let oneLine = height(
        Text("Show").font(LLAFont.small).environment(\.dynamicTypeSize, .accessibility5), width: 320)
      // macOS does not scale the type with `dynamicTypeSize`, so 320 pt holds the whole line here; 100 pt
      // is as tight for the Mac's type as 320 pt is for the phone's largest.
      for width: CGFloat in [320, 100] {
        let tall = height(both, width: width)
        #expect(tall <= oneLine * 5 + LLA.Space.xs, "\(width) pt: \(tall) pt against a line of \(oneLine) pt")
        let fitting = NSHostingController(rootView: both).sizeThatFits(
          in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        #expect(fitting.width <= width, "\(width) pt: \(fitting.width) pt wide")
      }
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
      let streams = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })
      init(_ detail: ThreadDetail) { self.detail = detail }
    }

    private struct HostView: View {
      let host: Host
      let folds: TranscriptFolds
      var body: some View {
        TranscriptView(detail: host.detail, streams: host.streams, folds: folds)
      }
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
  /// the real `TranscriptView` (its stack inside its `ScrollView`) hosted in a 720 by 480 window.
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
      return detail
    }

    /// The running reply of `twelveAndARunningTurn()` as it starts.
    private static let starting = ["n13": "Starting."]

    private func conversation() -> ConversationThread {
      ConversationThread(
        id: Self.thread, connectionId: "c1", nativeThreadId: "n-th", title: "th",
        createdAt: "2026-11-11T10:00:00Z", updatedAt: "2026-11-11T10:00:00Z")
    }

    /// A reply of `count` paragraphs, one line each: a single newline is a soft break, read as a space.
    private func lines(_ count: Int) -> String {
      (1...count).map { "Line \($0) of the streamed reply." }.joined(separator: "\n\n")
    }

    // MARK: the hosted transcript

    @Observable @MainActor final class Host {
      var detail: ThreadDetail
      let streams: MessageStreamStore
      /// Immediate reveal unless a ticker is given: then the reveal is paced and the test fires it.
      init(_ detail: ThreadDetail, ticker: ManualTicker? = nil) {
        self.detail = detail
        streams =
          ticker.map { ticker in MessageStreamStore(pacing: .paced, makeTicker: { ticker }) }
          ?? MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })
      }

      /// The reply `native` streams and shows `text`, as `detail.liveText[native] = text` did: a fresh
      /// stream, so a text that does not extend the last one replaces it.
      func live(_ native: String, _ text: String) {
        streams.reset()
        streams.append(text, to: native)
      }
    }

    private struct HostView: View {
      let host: Host
      let folds: TranscriptFolds
      var body: some View {
        TranscriptView(detail: host.detail, streams: host.streams, folds: folds)
      }
    }

    /// The window, the scroll view AppKit made for the transcript's `ScrollView`, and its clip view's
    /// origin (the document view is flipped: y grows downward from the transcript's top).
    @MainActor final class Hosted {
      let host: Host
      let folds: TranscriptFolds
      private let root: NSView
      private let window: NSWindow
      let scroll: NSScrollView

      init(
        _ detail: ThreadDetail, live: [String: String] = [:], ticker: ManualTicker? = nil
      ) throws {
        host = Host(detail, ticker: ticker)
        for (native, text) in live { host.streams.append(text, to: native) }
        folds = TranscriptFolds()
        let snapshot = SnapshotWindow(
          rootView: HostView(host: host, folds: folds).frame(width: 720, height: 480),
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
      /// transcript has laid out what it shows and nothing is left to scroll.
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

      /// The accessibility frames, in screen coordinates (y grows upward), of the elements under the
      /// transcript that `match` picks. The tree is read with the enhanced interface on, as a screen reader
      /// has it, and the setting is put back.
      func frames(_ match: (HostedScreen.Element) -> Bool) -> [CGRect] {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(old ?? false, forAttribute: enhanced) }
        var found: [CGRect] = []
        func walk(_ element: HostedScreen.Element) {
          if match(element), let frame = element.frame { found.append(frame) }
          element.children.forEach(walk)
        }
        walk(HostedScreen.Element(object: root))
        return found
      }

      /// Presses the first element under the transcript that `match` picks, with the tree read as
      /// `frames` reads it. False when there is none.
      func press(_ match: (HostedScreen.Element) -> Bool) -> Bool {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApplication.shared.accessibilitySetValue(old ?? false, forAttribute: enhanced) }
        func find(_ element: HostedScreen.Element) -> HostedScreen.Element? {
          if match(element) { return element }
          for child in element.children {
            if let found = find(child) { return found }
          }
          return nil
        }
        guard let found = find(HostedScreen.Element(object: root)) else { return false }
        return found.object.accessibilityPerformPress?() ?? false
      }

      /// Written when the transcript was a lazy stack, whose end moved as it was reached; kept as it is.
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

    /// Opening a step in a thread taller than the window holds the view, and the output is drawn under
    /// the pressed row without moving it: the view's top edge stays, and so does everything above the
    /// row's own bottom edge.
    @Test func openingAStepLeavesItsRowWhereItWas() async throws {
      let view = try Hosted(twelveTurns())
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      view.folds.release()
      #expect(!view.folds.holds)
      let origin = view.origin
      let closed = view.documentHeight
      func pressed() -> [CGRect] {
        view.frames { $0.identifier == "step-row" && ($0.label ?? "").hasSuffix("--filter s10-2") }
      }
      let before = try #require(pressed().first, "the pressed row is not in view")
      #expect(view.frames { $0.identifier == "step-output" }.isEmpty)

      view.folds.toggle("s10-2")
      #expect(view.folds.holds)
      try await view.until("the step's output is drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "moved by \(view.origin - origin)")
      #expect(view.folds.open == ["t10", "s10-2"])
      // The row's own top edge (maxY: screen coordinates grow upward) is where it was, and the output
      // stands under the row's bottom edge.
      let after = try #require(pressed().first, "the pressed row is gone from view")
      #expect(abs(after.maxY - before.maxY) <= 0.5, "the row moved by \(after.maxY - before.maxY)")
      let output = try #require(view.frames { $0.identifier == "step-output" }.first, "no output drawn")
      #expect(
        output.maxY <= after.minY + 0.5,
        "the output's top \(output.maxY) is above the row's bottom \(after.minY)")
    }

    /// "Show all" on an output at the end of the thread holds the view, as every toggle does: the lines
    /// are drawn under the step's row, which stays where it was, rather than pushing it up.
    @Test func showingAllOfAnOutputHoldsTheView() async throws {
      var detail = twelveTurns()
      let index = try #require(detail.items.firstIndex { $0.id == "s12-4" })
      detail.items[index] = item(
        "s12-4", turn: "t12", role: .tool, type: "commandExecution", sequence: 124,
        payload: [
          "command": "swift test --filter s12-4", "status": "completed",
          "aggregatedOutput": .string((1...25).map { "line \($0)" }.joined(separator: "\n")),
        ])
      let view = try Hosted(detail)
      defer { view.close() }
      view.folds.toggle("t12")
      view.folds.toggle("s12-4")
      try await view.settle()
      try await view.scrollToEnd()
      view.folds.release()
      try await view.settle()
      #expect(!view.folds.holds)
      #expect(view.atEnd || view.atDocumentEnd)
      func pressed() -> [CGRect] {
        view.frames { $0.identifier == "step-row" && ($0.label ?? "").hasSuffix("--filter s12-4") }
      }
      let before = try #require(pressed().first, "the step's row is not in view")
      let closed = view.documentHeight

      #expect(view.press { $0.role == .button && $0.label == "Show all 25 lines" })
      #expect(view.folds.holds)
      try await view.until("all the lines are drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      let after = try #require(pressed().first, "the step's row is gone from view")
      #expect(abs(after.maxY - before.maxY) <= 0.5, "the row moved by \(after.maxY - before.maxY)")
    }

    /// Twelve ended turns whose tenth turn's second step is a sub-agent's call with two children and
    /// its own result.
    private func twelveTurnsWithAnAgent() -> ThreadDetail {
      var detail = twelveTurns()
      guard let index = detail.items.firstIndex(where: { $0.id == "s10-2" }) else { return detail }
      detail.items[index] = item(
        "s10-2", turn: "t10", role: .tool, type: "toolUse", sequence: 102, native: "n-s10-2",
        payload: [
          "name": "Agent", "status": "completed", "output": "Three files.",
          "input": ["description": "Count Swift files in src", "prompt": "Count them."],
        ])
      for (offset, id) in ["c10-1", "c10-2"].enumerated() {
        detail.items.append(
          item(
            id, turn: "t10", role: .tool, type: "commandExecution", sequence: 106 + offset,
            payload: [
              "command": .string("ls --filter \(id)"), "status": "completed",
              "parentNativeItemId": "n-s10-2",
            ]))
      }
      return detail
    }

    /// Opening a sub-agent inside an opened turn holds the view like any step, leaves its row where it
    /// was, and draws its children one level further in than its own row, then its own result.
    @Test func openingAnAgentIndentsItsChildrenOneLevel() async throws {
      let view = try Hosted(twelveTurnsWithAnAgent())
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      view.folds.release()
      let origin = view.origin
      let closed = view.documentHeight
      func rows(_ suffix: String) -> [CGRect] {
        view.frames { $0.identifier == "step-row" && ($0.label ?? "").hasSuffix(suffix) }
      }
      let before = try #require(
        rows("Count Swift files in src · 2 steps").first, "the agent row is not in view")
      #expect(rows("--filter c10-1").isEmpty)

      view.folds.toggle("s10-2")
      #expect(view.folds.holds)
      try await view.until("the agent's steps are drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "moved by \(view.origin - origin)")
      let agent = try #require(rows("Count Swift files in src · 2 steps").first, "the agent row is gone")
      #expect(abs(agent.maxY - before.maxY) <= 0.5, "the row moved by \(agent.maxY - before.maxY)")
      let first = try #require(rows("--filter c10-1").first, "the first child is not drawn")
      let last = try #require(rows("--filter c10-2").first, "the second child is not drawn")
      #expect(abs(first.minX - agent.minX - StepRowView.level) <= 0.5, "\(first.minX) \(agent.minX)")
      #expect(abs(last.minX - first.minX) <= 0.5)
      // The children stand under the agent's row, and its own result under the last of them.
      #expect(first.maxY <= agent.minY + 0.5)
      let output = try #require(view.frames { $0.identifier == "step-output" }.first, "no result drawn")
      #expect(
        output.maxY <= last.minY + 0.5, "the result's top \(output.maxY), the child's bottom \(last.minY)")
    }

    @Test func aStreamDoesNotMoveAnOpenedTurn() async throws {
      let view = try Hosted(twelveAndARunningTurn(), live: Self.starting)
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
      view.host.live("n13", lines(20))
      view.host.detail.items.append(step("s13-1", turn: "t13", sequence: 132, status: "inProgress"))
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "the stream moved it by \(view.origin - origin)")
    }

    @Test func scrollingBackToTheEndFollowsTheStreamAgain() async throws {
      let view = try Hosted(twelveAndARunningTurn(), live: Self.starting)
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      view.folds.toggle("t10")
      try await view.settle()
      view.host.live("n13", lines(10))
      try await view.settle()
      #expect(view.folds.holds)

      try await view.scrollToEnd()
      try await view.until("the hold is released") { !view.folds.holds }
      let height = view.documentHeight
      view.host.live("n13", lines(30))
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
      let view = try Hosted(detail, live: ["n13": lines(4)])
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
      ended.turns[ended.turns.count - 1] = turn(13)
      view.host.streams.turnFinished()
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
      let view = try Hosted(detail, live: ["n1": "Starting."])
      defer { view.close() }
      try await view.settle()

      let closed = view.documentHeight
      view.folds.toggle("t1")
      try await view.until("the turn's steps are drawn") { view.documentHeight > closed + 1 }
      try await view.settle()
      #expect(view.documentHeight <= view.viewportHeight + 0.5, "the open turn should still fit")
      #expect(!view.folds.holds)

      view.host.live("n1", lines(60))
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
      let view = try Hosted(detail, live: ["n13": "Starting."])
      defer { view.close() }
      try await view.scrollToEnd()
      // The view follows the stream, as it does while a reply arrives.
      let streaming = view.documentHeight
      view.host.live("n13", lines(4))
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
      ended.turns[ended.turns.count - 1] = turn(13)
      view.host.streams.turnFinished()
      view.host.detail = ended
      try await view.until("the interim messages fold") { view.documentHeight < height - 1 }
      try await view.settle()
      #expect(abs(view.below - below) <= 0.5, "the answer moved by \(below - view.below)")
    }

    // MARK: a tall reply, and a long thread

    /// A thread whose first reply is several windows tall opens at its end, with the messages after
    /// the reply laid out. Run by itself too: a lazy stack passed this only after other tests had run.
    @Test func aThreadWithAVeryTallReplyOpensAtItsEnd() async throws {
      let detail = ThreadDetail(
        thread: conversation(), turns: [turn(1, .running)],
        items: [
          user("u1", turn: "t1", sequence: 1),
          message("m1", turn: "t1", sequence: 2, text: lines(120)),
          message("m2", turn: "t1", sequence: 3, text: "Run them like this."),
          message("m3", turn: "t1", sequence: 4, text: "End of the reading fixture."),
        ], requests: [])
      let view = try Hosted(detail)
      defer { view.close() }
      try await view.settle()
      #expect(view.documentHeight > 2_000, "the document is \(view.documentHeight) pt tall")
      #expect(view.atEnd || view.atDocumentEnd, "below the viewport: \(view.below)")
      #expect(!view.folds.holds)
    }

    /// A thread longer than a page draws its latest page and opens at its end; "Show earlier" draws
    /// a page more above and leaves the row that stood first where it was.
    @Test func aLongThreadDrawsItsLatestPageAndShowsEarlierInPlace() async throws {
      let turns = 120
      let detail = ThreadDetail(
        thread: conversation(), turns: (1...turns).map { turn($0) },
        items: (1...turns).flatMap { endedTurn($0, from: $0 * 10) }, requests: [])
      let all = DenseTranscript.entries(items: detail.items, turns: detail.turns, open: [])
      #expect(all.count == 360)
      let view = try Hosted(detail)
      defer { view.close() }
      try await view.settle()
      #expect(view.atEnd || view.atDocumentEnd, "below the viewport: \(view.below)")
      #expect(view.folds.shown == DenseTranscript.page)
      let page = view.documentHeight

      // Up to the top of what is drawn, as a reader looking for earlier messages.
      try await view.scroll(to: 0)
      #expect(view.folds.holds)
      let first = DenseTranscript.window(all, shown: DenseTranscript.page).entries.first?.id
      let fromEnd = view.documentHeight - view.origin
      view.folds.showEarlier(keeping: first)
      try await view.until("the earlier rows are drawn") { view.documentHeight > page * 1.5 }
      try await view.settle()
      #expect(view.folds.shown == 2 * DenseTranscript.page)
      #expect(view.folds.holds)
      // The row that stood first is still at the top of the view, under the button's row.
      let moved = (view.documentHeight - view.origin) - fromEnd
      #expect(abs(moved) <= LLA.Metrics.row + LLA.Space.l + LLA.Metrics.margin + 44, "it moved by \(moved)")
      #expect(view.origin > 1_000, "the view is at \(view.origin), not among the earlier rows' end")
    }

    // MARK: reading back (F14)

    /// A reader who scrolled back, with nothing opened, is left where they are while the reply streams
    /// and a step arrives; going back to the end follows the stream again.
    @Test func readingBackIsNotPulledToTheEndByTheStream() async throws {
      let view = try Hosted(twelveAndARunningTurn(), live: Self.starting)
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      let origin = view.origin

      let height = view.documentHeight
      view.host.live("n13", lines(20))
      view.host.detail.items.append(step("s13-1", turn: "t13", sequence: 132, status: "inProgress"))
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "the stream moved the reader by \(view.origin - origin)")

      try await view.scrollToEnd()
      let later = view.documentHeight
      view.host.live("n13", lines(40))
      try await view.until("the reply grows again") { view.documentHeight > later + 1 }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
    }

    /// The turn the reader was not following ends: the view stays where they are reading.
    @Test func readingBackIsNotPulledToTheEndWhenTheTurnEnds() async throws {
      let view = try Hosted(twelveAndARunningTurn(), live: Self.starting)
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      let origin = view.origin

      var ended = view.host.detail
      if let index = ended.items.firstIndex(where: { $0.id == "a13" }) {
        ended.items[index].payload = .object(["text": .string(lines(12))])
      }
      ended.turns[ended.turns.count - 1] = turn(13)
      let height = view.documentHeight
      view.host.streams.turnFinished()
      view.host.detail = ended
      try await view.until("the answer is drawn") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(abs(view.origin - origin) <= 0.5, "the turn's end moved the reader by \(view.origin - origin)")
    }

    // MARK: a paced reveal

    /// Waits for the transcript to tell the store it is on screen, and paces the reveal whatever the
    /// machine's Reduce Motion setting is: a runner with it on reveals at once, and no tick is asked for.
    private func paced(_ view: Hosted) async throws {
      try await view.until("the reveal is paced") {
        view.host.streams.setReduceMotion(false)
        return view.host.streams.pacing == .paced
      }
    }

    /// A reader at the end stays there while a reply taller than the window is revealed tick by tick.
    @Test func aPinnedReaderStaysAtTheEndThroughAPacedReveal() async throws {
      let ticker = ManualTicker()
      let view = try Hosted(twelveAndARunningTurn(), ticker: ticker)
      defer { view.close() }
      try await view.scrollToEnd()
      try await paced(view)
      view.host.streams.append(lines(40), to: "n13")
      #expect(ticker.running)
      var ticks = 0
      while ticker.running {
        ticker.fire()
        ticks += 1
        try await view.settle()
        // Following rests the end marker at the viewport's bottom edge, with the bottom padding below
        // it: from there to the end is at most 8 pt.
        #expect(
          view.below >= -0.5 && view.below - LLA.Metrics.margin <= 8,
          "after tick \(ticks), below the viewport: \(view.below)")
      }
      #expect(view.documentHeight > view.viewportHeight * 2)
    }

    /// A reader who scrolled back is left where they are while a reply is revealed tick by tick.
    @Test func aHeldReaderIsNotMovedByAPacedReveal() async throws {
      let ticker = ManualTicker()
      let view = try Hosted(twelveAndARunningTurn(), ticker: ticker)
      defer { view.close() }
      try await view.scrollToEnd()
      try await view.scroll(to: view.origin - 300)
      #expect(view.folds.holds)
      let origin = view.origin
      let height = view.documentHeight
      try await paced(view)
      view.host.streams.append(lines(40), to: "n13")
      #expect(ticker.running)
      var ticks = 0
      while ticker.running {
        ticker.fire()
        ticks += 1
        try await view.settle()
        #expect(abs(view.origin - origin) <= 0.5, "tick \(ticks) moved the reader by \(view.origin - origin)")
      }
      #expect(view.documentHeight > height + 1)
    }

    @Test func withNothingToggledTheTranscriptFollowsItsStream() async throws {
      let view = try Hosted(twelveAndARunningTurn(), live: Self.starting)
      defer { view.close() }
      try await view.scrollToEnd()
      let height = view.documentHeight
      view.host.live("n13", lines(20))
      try await view.until("the reply grows") { view.documentHeight > height + 1 }
      try await view.settle()
      #expect(view.atEnd, "below the viewport: \(view.below)")
    }
  }
#endif
