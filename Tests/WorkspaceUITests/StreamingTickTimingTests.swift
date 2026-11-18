#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// The time one tick of a paced reveal takes in a hosted transcript: the reveal, the parse and the
  /// layout that follows, in a thread of 150 rows. A guard against a gross regression, not a frame-time
  /// measurement of the running app. `B4APP_TIMING_DIR=<dir>` also writes the numbers to
  /// `<dir>/streaming-tick.json`.
  @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_TIMING"] != nil)) @MainActor
  struct StreamingTickTimingTests {
    @Test func aTickOfAPacedRevealInALongThreadIsCheap() async throws {
      let thread = "timing-\(UUID().uuidString)"
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
            id: "a\(number)", threadId: thread, turnId: "t\(number)", nativeItemId: running ? "n-live" : nil,
            role: .assistant, type: "agentMessage",
            payload: [
              "text": .string(
                running ? "" : "Answer **\(number)** with `code` and a [link](https://example.com).")
            ],
            sequence: number * 2 + 1, provenance: .live))
      }
      #expect(items.count == 150)
      let detail = ThreadDetail(
        thread: ConversationThread(
          id: thread, connectionId: "c1", nativeThreadId: "n-\(thread)", title: "Timing",
          createdAt: "2026-11-17T10:00:00Z", updatedAt: "2026-11-17T10:00:00Z"),
        turns: turns, items: items, requests: [])
      let ticker = ManualTicker()
      let streams = MessageStreamStore(pacing: .paced, makeTicker: { ticker })
      let window = SnapshotWindow(
        rootView: TranscriptView(detail: detail, streams: streams, dense: false).frame(
          width: 720, height: 480),
        untitled: true, size: CGSize(width: 720, height: 480))
      defer { window.window.close() }
      let root = window.host
      for _ in 0..<10 { await pass(root) }

      // Every block kind three times over, arriving 24 characters a tick, as a fast stream would.
      let reply = Array(repeating: MarkdownViewTests.everyKind, count: 3).joined(separator: "\n\n")
      var rest = Substring(reply)
      var times: [Duration] = []
      let clock = ContinuousClock()
      func tick() async {
        var start = clock.now
        ticker.fire()
        root.layoutSubtreeIfNeeded()
        var spent = clock.now - start
        turnRunLoop()
        await Task.yield()
        // Work SwiftUI deferred to the run loop is laid out here.
        start = clock.now
        root.layoutSubtreeIfNeeded()
        spent += clock.now - start
        times.append(spent)
      }
      while !rest.isEmpty {
        streams.append(String(rest.prefix(24)), to: "n-live")
        rest = rest.dropFirst(24)
        await tick()
      }
      streams.complete("n-live", finalText: reply)
      while ticker.running { await tick() }
      #expect(streams.stream(for: "n-live")?.shown == reply)

      let sorted = times.sorted()
      let median = sorted[sorted.count / 2]
      let worst = sorted[sorted.count - 1]
      #expect(worst < .milliseconds(250), "worst tick \(worst), median \(median), \(times.count) ticks")
      if let directory = ProcessInfo.processInfo.environment["B4APP_TIMING_DIR"] {
        func ms(_ duration: Duration) -> Double {
          Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        let numbers: [String: Double] = [
          "ticks": Double(times.count), "characters": Double(reply.count), "medianMs": ms(median),
          "p95Ms": ms(sorted[sorted.count * 95 / 100]), "worstMs": ms(worst),
        ]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: numbers, options: [.sortedKeys, .prettyPrinted])
          .write(to: URL(fileURLWithPath: "\(directory)/streaming-tick.json"))
      }
    }

    private func pass(_ root: NSView) async {
      root.layoutSubtreeIfNeeded()
      turnRunLoop()
      await Task.yield()
    }

    /// Synchronous by design: `RunLoop.run` is unavailable from async code.
    private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  }
#endif
