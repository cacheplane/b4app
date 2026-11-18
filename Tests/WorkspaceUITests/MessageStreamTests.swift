import StreamingMarkdown
import Testing

@testable import WorkspaceUI

@Suite @MainActor struct MessageStreamTests {
  @Test func immediatePacingShowsEachDeltaAtOnce() {
    let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
    stream.append("# Hi\n\nthe")
    #expect(stream.shown == "# Hi\n\nthe")
    #expect(stream.document.blocks.count == 2)
  }

  @Test func pacedRevealMovesByATwelfthOfTheBacklogPerTick() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append(String(repeating: "a", count: 120))
    #expect(stream.shown.isEmpty && ticker.running)
    ticker.fire()
    #expect(stream.shown.count == 10)  // ceil(120 / 12)
    ticker.fire()
    #expect(stream.shown.count == 20)  // 10 + ceil(110 / 12)
  }

  @Test func aSmallBacklogTricklesOneCharacterPerTickAndTheTickerStopsWhenEmpty() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append("abc")
    ticker.fire(3)
    #expect(stream.shown == "abc" && !ticker.running)
    stream.append("d")
    #expect(ticker.running)
  }

  @Test func completionDrainsWithinNineTicksAndFinishesOnce() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append(String(repeating: "a", count: 900) + " **bo")
    stream.complete(finalText: stream.received)
    #expect(stream.phase == .streaming)
    ticker.fire(9)
    #expect(stream.shown == stream.received && stream.phase == .complete && !ticker.running)
    #expect(stream.document == MarkdownParser.parse(stream.received))  // no guess left: "**bo" literal
  }

  @Test func aFinalTextThatExtendsTheReceivedTextIsAppended() {
    let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
    stream.append("Hello")
    stream.complete(finalText: "Hello there")
    #expect(stream.shown == "Hello there" && stream.phase == .complete)
  }

  @Test func aFinalTextThatDiffersReplacesTheTextAtOnce() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append("Hello wor")
    ticker.fire(2)
    stream.complete(finalText: "Goodbye")
    #expect(stream.shown == "Goodbye" && stream.phase == .complete)
    #expect(stream.document == MarkdownParser.parse("Goodbye"))
  }

  @Test func aStaleFinalTextRemovesNothing() {
    let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
    stream.append("Hello there")
    stream.complete(finalText: "Hel")
    #expect(stream.shown == "Hello there" && stream.phase == .complete)
    stream.complete(finalText: "")
    stream.append("x")
    #expect(stream.shown == "Hello there")
  }

  @Test func aRevealedPrefixIsNotReplayed() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker, revealedPrefix: "Hello the")
    stream.append("Hello there, friend")
    #expect(stream.shown == "Hello the")
    let other = MessageStream(pacing: .paced, ticker: ManualTicker(), revealedPrefix: "Hello")
    other.append("Goodbye")
    #expect(other.shown.isEmpty)
  }

  @Test func switchingToImmediateRevealsEverything() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append(String(repeating: "a", count: 500))
    stream.pacing = .immediate
    #expect(stream.shown.count == 500 && !ticker.running)
  }

  @Test func aRevealNeverCutsAGrapheme() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    let family = "👨‍👩‍👧‍👦"
    let scalars = Array(family.unicodeScalars)
    stream.append(String(String.UnicodeScalarView(scalars.prefix(3))))  // a delta ending mid-grapheme
    stream.append(String(String.UnicodeScalarView(scalars.dropFirst(3))) + "e\u{301}")
    var seen: [String] = []
    while ticker.running {
      ticker.fire()
      seen.append(stream.shown)
    }
    #expect(seen.allSatisfy { $0.isEmpty || $0 == family || $0 == family + "e\u{301}" })
  }

  @Test func onRevealFiresOncePerReveal() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    var count = 0
    stream.onReveal = { count += 1 }
    stream.append(String(repeating: "a", count: 30))
    #expect(count == 0)
    ticker.fire()
    #expect(count == 1)
    ticker.fire(2)
    #expect(count == 3)
    stream.pacing = .immediate
    #expect(count == 4)
  }

  @Test func aDiscardedStreamIsNotKeptAliveByItsTicker() {
    let ticker = DisplayTicker()
    weak var weakStream: MessageStream?
    do {
      let stream = MessageStream(pacing: .paced, ticker: ticker)
      stream.append("abc")
      weakStream = stream
    }
    #expect(weakStream == nil)
    ticker.stop()
  }

  @Test func aLaterDeltaThatExtendsARevealedGraphemeIsRevealed() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append("e")
    while ticker.running { ticker.fire() }
    #expect(stream.shown == "e")
    stream.append("\u{301}")
    while ticker.running { ticker.fire() }
    #expect(stream.shown == "e\u{301}")
    stream.complete(finalText: "e\u{301}")
    #expect(stream.phase == .complete)
    #expect(stream.document == MarkdownParser.parse("e\u{301}"))
  }

  @Test func aSplitEmojiSequenceIsCompletedByALaterDelta() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    let family = "👨‍👩‍👧‍👦"
    let scalars = Array(family.unicodeScalars)
    stream.append(String(String.UnicodeScalarView(scalars.prefix(1))))
    while ticker.running { ticker.fire() }
    stream.append(String(String.UnicodeScalarView(scalars.dropFirst(1))))
    while ticker.running { ticker.fire() }
    #expect(stream.shown == family)
    stream.complete(finalText: family)
    #expect(stream.document == MarkdownParser.parse(family))
  }

  @Test func completingRightAfterAnExtensionDrainsAndFinishesOnce() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker)
    stream.append("caf")
    stream.append("e")
    ticker.fire(4)
    stream.append("\u{301}")
    stream.complete(finalText: "cafe\u{301} au lait")
    ticker.fire(9)
    #expect(stream.shown == "cafe\u{301} au lait" && stream.phase == .complete && !ticker.running)
    #expect(stream.document == MarkdownParser.parse("cafe\u{301} au lait"))
  }

  @Test func aCompletionWithNoDeltaHonoursTheRevealedPrefix() {
    let ticker = ManualTicker()
    let stream = MessageStream(pacing: .paced, ticker: ticker, revealedPrefix: "Hello")
    stream.complete(finalText: "Hello there")
    #expect(stream.shown == "Hello")
    ticker.fire(9)
    #expect(stream.shown == "Hello there" && stream.phase == .complete)
  }

  @Test func aStoppedDisplayTickerDoesNotTickAgain() async throws {
    let ticker = DisplayTicker()
    var ticks = 0
    ticker.onTick = { ticks += 1 }
    ticker.start()
    try await Task.sleep(for: .milliseconds(100))
    #expect(ticks > 0)
    ticker.stop()
    let atStop = ticks
    try await Task.sleep(for: .milliseconds(100))
    #expect(ticks == atStop)
  }

  @Test func restartingADisplayTickerRunsOneLoop() async throws {
    let ticker = DisplayTicker()
    var ticks = 0
    ticker.onTick = { ticks += 1 }
    for _ in 0..<5 {
      ticker.start()
      ticker.stop()
    }
    ticker.start()
    try await Task.sleep(for: .milliseconds(300))
    ticker.stop()
    // One loop gives about 18 ticks in 300 ms; six loops would give about 108.
    #expect(ticks < 40)
  }
}
