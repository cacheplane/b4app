import Foundation
import Observation
import StreamingMarkdown
import WorkspaceProtocol

/// The streaming assistant messages of the open thread, by native item id, held outside
/// `ThreadDetail` so a delta re-evaluates only the row that reads its stream.
///
/// Never less than was shown: until the turn finishes, a completion carrying stale or empty text (the
/// phone's gap) leaves the row drawing what it showed, and a later delta for the same item id opens
/// a new stream that continues from the reader's place instead of replaying.
@MainActor @Observable public final class MessageStreamStore {
  /// Observed, so a row re-evaluates when its stream appears or goes.
  private var streams: [String: MessageStream] = [:]
  /// Bumps on every reveal of any stream; the transcript's follower reads it.
  private(set) var revision = 0

  /// Applied to every open stream, and to the streams opened later.
  @ObservationIgnored public var pacing: RevealPacing {
    didSet {
      guard pacing != oldValue else { return }
      for stream in streams.values { stream.pacing = pacing }
    }
  }

  /// The pacing the store was made with: paced in the app, immediate for a test that drives no
  /// ticker. The reader gets it while the transcript is on screen and Reduce Motion is off.
  @ObservationIgnored private let preferredPacing: RevealPacing

  @ObservationIgnored private let makeTicker: @MainActor () -> any RevealTicker

  /// A settled reply's document and the text it was parsed from.
  private typealias Settled = (text: String, document: MarkdownDocument)
  /// Settled replies by item id. A cache: reading it never changes what a view observes.
  @ObservationIgnored private var settled: [String: Settled] = [:]
  /// The last documents of the streams a turn's end let go, by native item id, with the text each
  /// received: the row takes one in place of a parse when its stored text is that text.
  @ObservationIgnored private var handedOver: [String: Settled] = [:]
  /// How many times a settled text was parsed; read by tests.
  @ObservationIgnored private(set) var settledParses = 0

  public convenience init() {
    self.init(pacing: .paced, makeTicker: { DisplayTicker() })
  }

  init(pacing: RevealPacing, makeTicker: @escaping @MainActor () -> any RevealTicker) {
    self.pacing = pacing
    preferredPacing = pacing
    self.makeTicker = makeTicker
  }

  /// How many transcripts draw this store: a thread's new transcript can appear before the last one
  /// has gone, so a count rather than a flag.
  @ObservationIgnored private var transcripts = 0
  @ObservationIgnored private var reduceMotion = false

  /// With Reduce Motion on, or no transcript on screen, every stream shows what it has received at
  /// once; otherwise the store's own pacing applies.
  func transcriptAppeared(reduceMotion: Bool) {
    transcripts += 1
    self.reduceMotion = reduceMotion
    updatePacing()
  }

  func transcriptDisappeared() {
    transcripts = max(transcripts - 1, 0)
    updatePacing()
  }

  func setReduceMotion(_ on: Bool) {
    reduceMotion = on
    updatePacing()
  }

  private func updatePacing() {
    pacing = transcripts > 0 && !reduceMotion ? preferredPacing : .immediate
  }

  func append(_ delta: String, to nativeItemId: String) {
    guard !delta.isEmpty else { return }
    let previous = streams[nativeItemId]
    if let previous, previous.isAccepting {
      previous.append(delta)
      return
    }
    // A completed stream may still be draining its backlog (the phone sends a gap's completion and
    // the whole-text delta back to back): it shows the rest now, and the new stream starts from it.
    if let previous, previous.phase == .streaming { previous.pacing = .immediate }
    previous?.discard()
    let stream = MessageStream(
      pacing: pacing, ticker: makeTicker(), revealedPrefix: previous?.shown ?? "")
    stream.onReveal = { [weak self] in self?.revision += 1 }
    streams[nativeItemId] = stream
    stream.append(delta)
  }

  func complete(_ nativeItemId: String, finalText: String) {
    streams[nativeItemId]?.complete(finalText: finalText)
  }

  /// Completes every open stream with what it received, then forgets them all: the stored items'
  /// texts win from here.
  func turnFinished() {
    for (id, stream) in streams {
      stream.pacing = .immediate
      stream.complete(finalText: stream.received)
      handedOver[id] = (stream.received, stream.document)
    }
    forgetAll()
  }

  /// Another thread, no thread, or another account.
  func reset() {
    for stream in streams.values { stream.discard() }
    forgetAll()
    settled = [:]
    handedOver = [:]
  }

  /// The item's stream while the turn runs.
  func stream(for nativeItemId: String) -> MessageStream? { streams[nativeItemId] }

  func isStreaming(_ nativeItemId: String) -> Bool { streams[nativeItemId]?.phase == .streaming }

  /// What the row draws: the stream's shown text while it streams or while the stored text is only a
  /// prefix of it; otherwise the stored text.
  func text(for item: DisplayItem) -> String {
    let stored = item.payload["text"]?.stringValue ?? ""
    return winningStream(for: item, stored: stored)?.shown ?? stored
  }

  /// The document the row draws, chosen as `text(for:)` chooses. The stream's own document when it
  /// wins, so a reveal re-evaluates only the row that reads that stream; otherwise the stored text
  /// parsed once, cached by item id and text, or the last document of the item's stream when the turn's
  /// end handed it over with this very text.
  func document(for item: DisplayItem) -> MarkdownDocument {
    let stored = item.payload["text"]?.stringValue ?? ""
    if let stream = winningStream(for: item, stored: stored) { return stream.document }
    if let entry = settled[item.id], entry.text == stored { return entry.document }
    let document: MarkdownDocument
    if let id = item.nativeItemId, let handed = handedOver.removeValue(forKey: id), handed.text == stored {
      document = handed.document
    } else {
      settledParses += 1
      document = MarkdownParser.parse(stored)
    }
    settled[item.id] = (stored, document)
    return document
  }

  private func winningStream(for item: DisplayItem, stored: String) -> MessageStream? {
    guard let id = item.nativeItemId, let stream = streams[id] else { return nil }
    return stream.phase == .streaming || stream.shown.utf8.starts(with: stored.utf8) ? stream : nil
  }

  private func forgetAll() {
    for stream in streams.values { stream.onReveal = nil }
    if !streams.isEmpty { streams = [:] }
  }
}
