#if os(macOS)
  import AppKit
  import Foundation
  import StreamingMarkdown
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// A reply drawn as block markdown, measured on hosted views as `CodeFenceViewTests` does.
  @Suite(.serialized) @MainActor struct MarkdownViewTests {
    private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
      let host = NSHostingView(rootView: view.frame(width: width))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }

    /// Every block kind the parser makes: headings, a paragraph with inline markup, a nested ordered
    /// list, a task list, a quote, a table, fenced code and a break.
    static let everyKind = """
      # Release notes

      The build **passes** on both targets, `swift test` is green, and [the docs](https://example.com) \
      say why.

      ## What changed

      1. The parser
         - reads nested lists
           - three levels deep
      2. The views

      - [x] Headings
      - [ ] Tables

      > A quote with *emphasis*
      > over two lines.

      | Target | Time | Result |
      | :----- | ---: | :----: |
      | macOS | 12 s | pass |
      | iOS | 31 s | pass |

      ```swift
      let package = Package(name: "b4app")
      ```

      ---

      Done.
      """

    /// An assistant reply stored with `text`, streamed as `native` when it has one.
    private func reply(_ id: String, native: String?, text: String, thread: String = "th") -> DisplayItem {
      DisplayItem(
        id: id, threadId: thread, turnId: "t1", nativeItemId: native, role: .assistant,
        type: "agentMessage", payload: ["text": .string(text)], sequence: 1, provenance: .live)
    }

    @Test func everyBlockKindLaysOutWithinTheColumn() {
      let document = MarkdownParser.parse(Self.everyKind)
      let kinds = Set(document.blocks.map { Self.name(of: $0.kind) })
      #expect(kinds == ["heading", "paragraph", "list", "quote", "table", "code", "break"])
      let measured = size(MarkdownText(document: document), width: 420)
      #expect(measured.width <= 420.5, "the reply is \(measured.width) pt wide")
      #expect(measured.height > 0)
    }

    @Test func aWideTableScrollsInsideItsBlock() {
      let columns = (1...12).map { "Column \($0)" }
      let text =
        "| \(columns.joined(separator: " | ")) |\n|\(Array(repeating: "---", count: 12).joined(separator: "|"))|\n"
        + "| \(columns.map { "\($0) value" }.joined(separator: " | ")) |"
      let document = MarkdownParser.parse(text)
      guard case .table = document.blocks.first?.kind else {
        Issue.record("not a table: \(document.blocks)")
        return
      }
      let measured = size(MarkdownText(document: document), width: 320)
      #expect(measured.width <= 320.5, "the reply is \(measured.width) pt wide")
    }

    @Test func anEmptyDocumentDrawsNothing() {
      #expect(size(MarkdownText(document: .empty), width: 420).height == 0)
      #expect(size(MarkdownText(text: " \n"), width: 420).height == 0)
    }

    @Test func aSoftBreakIsASpaceAndAHardBreakIsALine() {
      let oneLine = size(MarkdownText(text: "one two"), width: 420).height
      #expect(size(MarkdownText(text: "one\ntwo"), width: 420).height == oneLine)
      #expect(size(MarkdownText(text: "one  \ntwo"), width: 420).height > oneLine)
    }

    @Test func aStreamedReplyAndTheSameReplyFromHistoryDrawTheSame() {
      let store = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })
      var rest = Substring(Self.everyKind)
      while !rest.isEmpty {
        store.append(String(rest.prefix(7)), to: "n1")
        rest = rest.dropFirst(7)
      }
      let final = Self.everyKind + "\n\n"
      store.complete("n1", finalText: final)
      let live = reply("a1", native: "n1", text: final)
      let streamed = store.document(for: live)
      let history = MarkdownParser.parse(Self.everyKind)
      #expect(streamed == history)
      #expect(
        size(MarkdownText(document: streamed), width: 420)
          == size(MarkdownText(document: history), width: 420))

      // The turn ends: the stored item draws the stream's last document, not a new parse of it.
      store.turnFinished()
      #expect(store.document(for: live) == history)
      #expect(store.settledParses == 0)
    }

    @Test func aSettledDocumentIsParsedOnce() {
      let store = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })
      let item = reply("a1", native: nil, text: Self.everyKind)
      let first = store.document(for: item)
      #expect(store.settledParses == 1)
      let second = store.document(for: item)
      #expect(first == second)
      #expect(store.settledParses == 1)
      // Another text for the same item is parsed afresh; another thread forgets the cache.
      _ = store.document(for: reply("a1", native: nil, text: "Changed."))
      #expect(store.settledParses == 2)
      store.reset()
      _ = store.document(for: reply("a1", native: nil, text: "Changed."))
      #expect(store.settledParses == 3)
    }

    #if DEBUG
      /// A token reaches only the row that reads its stream: the transcript's grouping is not run again.
      @Test(arguments: [false, true]) func aTokenDoesNotRerunTheGrouping(dense: Bool) async throws {
        let thread = "grouping-\(UUID().uuidString)"
        var turns: [Turn] = []
        var items: [DisplayItem] = []
        for number in 1...75 {
          let running = number == 75
          turns.append(
            Turn(
              id: "t\(number)", threadId: thread, operationId: "op-\(number)",
              status: running ? .running : .terminal, outcome: running ? nil : .completed))
          items.append(
            DisplayItem(
              id: "u\(number)", threadId: thread, turnId: "t\(number)", role: .user, type: "userMessage",
              payload: ["text": .string("Question \(number)")], sequence: number * 2, provenance: .live))
          items.append(
            DisplayItem(
              id: "a\(number)", threadId: thread, turnId: "t\(number)",
              nativeItemId: running ? "n-live" : nil,
              role: .assistant, type: "agentMessage",
              payload: ["text": .string(running ? "" : "Answer **\(number)**.")], sequence: number * 2 + 1,
              provenance: .live))
        }
        #expect(items.count == 150)
        let detail = ThreadDetail(
          thread: ConversationThread(
            id: thread, connectionId: "c1", nativeThreadId: "n-\(thread)", title: "Grouping",
            createdAt: "2026-11-17T10:00:00Z", updatedAt: "2026-11-17T10:00:00Z"),
          turns: turns, items: items, requests: [])
        let ticker = ManualTicker()
        let streams = MessageStreamStore(pacing: .paced, makeTicker: { ticker })
        let window = SnapshotWindow(
          rootView: TranscriptView(detail: detail, streams: streams, dense: dense).frame(
            width: 720, height: 480),
          untitled: true, size: CGSize(width: 720, height: 480))
        defer { window.window.close() }
        func pass() async {
          window.host.layoutSubtreeIfNeeded()
          Self.turnRunLoop()
          await Task.yield()
        }
        // The stream opens and shows its first words before the count is read.
        streams.append("Streaming ", to: "n-live")
        ticker.fire()
        for _ in 0..<10 { await pass() }
        let before = DenseTranscript.projections(of: thread)
        #expect(before > 0, "the transcript was never drawn")

        for index in 0..<50 {
          streams.append("word\(index) ", to: "n-live")
          ticker.fire()
          await pass()
        }
        // The backlog a tick a delta left drains.
        while ticker.running {
          ticker.fire()
          await pass()
        }
        for _ in 0..<10 { await pass() }
        #expect(streams.stream(for: "n-live")?.shown.hasSuffix("word49 ") == true)
        #expect(DenseTranscript.projections(of: thread) == before)
      }
    #endif

    /// Synchronous by design: `RunLoop.run` is unavailable from async code.
    private static func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }

    private static func name(of kind: MarkdownBlock.Kind) -> String {
      switch kind {
      case .paragraph: "paragraph"
      case .heading: "heading"
      case .thematicBreak: "break"
      case .code: "code"
      case .quote: "quote"
      case .list: "list"
      case .table: "table"
      }
    }
  }
#endif
