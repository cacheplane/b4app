import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite @MainActor struct MessageStreamStoreTests {
  let store = MessageStreamStore(pacing: .immediate, makeTicker: { ManualTicker() })

  /// An assistant reply whose stream is `native`, stored with `text`.
  private func item(_ native: String, text: String) -> DisplayItem {
    DisplayItem(
      id: "item-\(native)", threadId: "th", turnId: "t1", nativeItemId: native, role: .assistant,
      type: "agentMessage", payload: ["text": .string(text)], sequence: 1, provenance: .live)
  }

  @Test func aDeltaOpensAStreamAndTheRowDrawsItsText() {
    store.append("Hel", to: "m1")
    store.append("lo", to: "m1")
    #expect(store.text(for: item("m1", text: "")) == "Hello" && store.isStreaming("m1"))
  }

  @Test func aCompletionWithTheFullTextHandsOverToTheStoredItem() {
    store.append("Hello", to: "m1")
    store.complete("m1", finalText: "Hello there")
    #expect(!store.isStreaming("m1"))
    #expect(store.text(for: item("m1", text: "Hello there")) == "Hello there")
  }

  @Test func aStaleCompletionDoesNotBlankTheRow() {  // the phone's gap
    store.append("Hello there", to: "m1")
    store.complete("m1", finalText: "")
    #expect(store.text(for: item("m1", text: "")) == "Hello there")
  }

  @Test func aWholeTextDeltaAfterAGapContinuesFromTheReadersPlace() {
    let ticker = ManualTicker()
    let store = MessageStreamStore(pacing: .paced, makeTicker: { ticker })
    store.append("Hello there", to: "m1")
    ticker.fire(11)
    store.complete("m1", finalText: "")
    ticker.fire(9)
    store.append("Hello there, friend", to: "m1")
    #expect(store.stream(for: "m1")?.shown == "Hello there" && store.isStreaming("m1"))
  }

  @Test func theStoredTextWinsOnceTheTurnFinishes() {
    store.append("Hello there", to: "m1")
    store.turnFinished()
    #expect(store.stream(for: "m1") == nil)
    #expect(store.text(for: item("m1", text: "Hello")) == "Hello")
  }

  @Test func aStoredTextThatDivergesFromACompletedStreamWins() {
    store.append("Hello", to: "m1")
    store.complete("m1", finalText: "Hello")
    #expect(store.text(for: item("m1", text: "Rewritten")) == "Rewritten")
  }

  @Test func resetForgetsEverything() {
    store.append("Hello", to: "m1")
    store.append("Other", to: "m2")
    store.reset()
    #expect(store.stream(for: "m1") == nil && store.stream(for: "m2") == nil)
    #expect(store.text(for: item("m1", text: "")) == "")
    // Nothing of the forgotten stream is replayed into the next one.
    store.append("Next", to: "m1")
    #expect(store.stream(for: "m1")?.shown == "Next")
  }

  @Test func changingPacingAppliesToOpenStreams() {
    let ticker = ManualTicker()
    let store = MessageStreamStore(pacing: .paced, makeTicker: { ticker })
    store.append(String(repeating: "a", count: 500), to: "m1")
    #expect(store.stream(for: "m1")?.shown.isEmpty == true)
    store.pacing = .immediate
    #expect(store.stream(for: "m1")?.shown.count == 500)
  }

  @Test func revisionBumpsOnEachReveal() {
    var tickers: [ManualTicker] = []
    let store = MessageStreamStore(
      pacing: .paced,
      makeTicker: {
        let ticker = ManualTicker()
        tickers.append(ticker)
        return ticker
      })
    let start = store.revision
    store.append(String(repeating: "a", count: 24), to: "m1")
    #expect(store.revision == start)  // nothing revealed yet
    tickers[0].fire()
    #expect(store.revision == start + 1)
    tickers[0].fire()
    #expect(store.revision == start + 2)
    store.append("b", to: "m2")
    tickers[1].fire()  // any stream's reveal
    #expect(store.revision == start + 3)
  }
}
