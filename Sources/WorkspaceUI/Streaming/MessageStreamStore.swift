import Foundation
import Observation
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

  @ObservationIgnored private let makeTicker: @MainActor () -> any RevealTicker

  public convenience init() {
    self.init(pacing: .paced, makeTicker: { DisplayTicker() })
  }

  init(pacing: RevealPacing, makeTicker: @escaping @MainActor () -> any RevealTicker) {
    self.pacing = pacing
    self.makeTicker = makeTicker
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
    for stream in streams.values {
      stream.pacing = .immediate
      stream.complete(finalText: stream.received)
    }
    forgetAll()
  }

  /// Another thread, no thread, or another account.
  func reset() {
    for stream in streams.values { stream.discard() }
    forgetAll()
  }

  /// The item's stream while the turn runs.
  func stream(for nativeItemId: String) -> MessageStream? { streams[nativeItemId] }

  func isStreaming(_ nativeItemId: String) -> Bool { streams[nativeItemId]?.phase == .streaming }

  /// What the row draws: the stream's shown text while it streams or while the stored text is only a
  /// prefix of it; otherwise the stored text.
  func text(for item: DisplayItem) -> String {
    let stored = item.payload["text"]?.stringValue ?? ""
    guard let id = item.nativeItemId, let stream = streams[id] else { return stored }
    if stream.phase == .streaming || stream.shown.utf8.starts(with: stored.utf8) { return stream.shown }
    return stored
  }

  private func forgetAll() {
    for stream in streams.values { stream.onReveal = nil }
    if !streams.isEmpty { streams = [:] }
  }
}
