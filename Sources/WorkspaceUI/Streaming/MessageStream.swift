import Foundation
import Observation
import StreamingMarkdown

public enum RevealPacing: Sendable { case paced, immediate }

/// The owner of one streaming assistant message: the text received, how much of it the reader has
/// been shown, and the parser that reads the shown text. Text only grows (`append`); a paced tick
/// reveals a slice of the backlog and pushes it to the parser, so there is at most one parse and
/// one redraw per frame whatever the rate of deltas.
@MainActor @Observable final class MessageStream {
  enum Phase: Sendable { case streaming, complete }

  private(set) var document: MarkdownDocument = .empty
  private(set) var phase: Phase = .streaming
  /// The revealed text.
  private(set) var shown = ""

  @ObservationIgnored private(set) var received = ""
  /// Called after each change of `shown`.
  @ObservationIgnored var onReveal: (@MainActor () -> Void)?
  @ObservationIgnored var pacing: RevealPacing {
    didSet {
      guard pacing == .immediate, oldValue != .immediate else { return }
      revealAll()
      backlogChars = 0
      settle()
    }
  }

  @ObservationIgnored private let ticker: any RevealTicker
  @ObservationIgnored private var parser = MarkdownParser()
  /// How much of `received` is shown, in UTF-8 bytes (always on a scalar boundary).
  @ObservationIgnored private var revealed = 0
  @ObservationIgnored private var revealedPrefix: String?
  /// The least step a tick takes, raised when `complete` is called so the backlog drains in time.
  @ObservationIgnored private var minimumStep = 1
  @ObservationIgnored private var completing = false
  /// The Characters not yet shown, counted when text arrives and reduced by each tick, so a tick
  /// does not walk the backlog.
  @ObservationIgnored private var backlogChars = 0

  init(pacing: RevealPacing, ticker: any RevealTicker, revealedPrefix: String = "") {
    self.pacing = pacing
    self.ticker = ticker
    self.revealedPrefix = revealedPrefix.isEmpty ? nil : revealedPrefix
    ticker.onTick = { [weak self] in self?.tick() }
  }

  /// False once `complete` was called, while the backlog may still be draining: `append` then does
  /// nothing.
  var isAccepting: Bool { !completing }

  /// Stops revealing without showing the rest: the stream is about to be dropped, so nothing more is
  /// parsed or reported.
  func discard() {
    onReveal = nil
    ticker.stop()
  }

  func append(_ delta: String) {
    guard !completing, !delta.isEmpty else { return }
    received += delta
    applyPrefix()
    if pacing == .immediate { revealAll() }
    recount()
    settle()
  }

  func complete(finalText: String) {
    guard !completing else { return }
    completing = true
    if finalText.utf8.starts(with: received.utf8) {
      let from = finalText.utf8.index(finalText.utf8.startIndex, offsetBy: received.utf8.count)
      received += String(finalText[from...])
    } else if received.utf8.starts(with: finalText.utf8) {
      // The stale case: nothing is removed.
    } else {
      replace(with: finalText)
    }
    applyPrefix()
    if pacing == .immediate { revealAll() }
    recount()
    minimumStep = max(minimumStep, (backlogChars + 8) / 9)
    settle()
  }

  // MARK: - Reveal

  private var backlogStart: String.Index {
    received.utf8.index(received.utf8.startIndex, offsetBy: revealed)
  }

  private func recount() { backlogChars = received[backlogStart...].count }

  private func applyPrefix() {
    guard let prefix = revealedPrefix, !received.isEmpty else { return }
    revealedPrefix = nil
    reveal(upTo: replayedLength(of: prefix))
  }

  private func tick() {
    guard revealed < received.utf8.count else {
      settle()
      return
    }
    if backlogChars == 0 { recount() }
    let step = min(backlogChars, max(minimumStep, (backlogChars + 11) / 12))
    let start = backlogStart
    let end = received.index(start, offsetBy: step, limitedBy: received.endIndex) ?? received.endIndex
    reveal(upTo: received.utf8.distance(from: received.utf8.startIndex, to: end))
    backlogChars -= step
    settle()
  }

  private func revealAll() { reveal(upTo: received.utf8.count) }

  /// Shows `received` up to the UTF-8 offset `end`, which is on a scalar boundary.
  private func reveal(upTo end: Int) {
    guard end > revealed else { return }
    let from = backlogStart
    let to = received.utf8.index(received.utf8.startIndex, offsetBy: end)
    let slice = String(received[from..<to])
    revealed = end
    parser.push(slice)
    shown += slice
    document = parser.document
    onReveal?()
  }

  /// A final text that differs from what arrived: a new parser takes it, all of it shown at once.
  private func replace(with text: String) {
    received = text
    parser = MarkdownParser()
    parser.push(text)
    revealed = text.utf8.count
    shown = text
    backlogChars = 0
    document = parser.document
    onReveal?()
  }

  /// The ticker runs while there is something to reveal; once a completed stream has nothing left
  /// the parser is finished, once.
  private func settle() {
    if revealed < received.utf8.count {
      if pacing == .paced { ticker.start() } else { ticker.stop() }
      return
    }
    ticker.stop()
    if completing && phase == .streaming {
      parser.finish()
      document = parser.document
      phase = .complete
    }
  }

  /// The length in UTF-8 bytes, cut on a character boundary of `received`, of the text it shares
  /// with `prefix`.
  private func replayedLength(of prefix: String) -> Int {
    var shared = 0
    for (a, b) in zip(received.utf8, prefix.utf8) {
      guard a == b else { break }
      shared += 1
    }
    var end = 0
    var index = received.startIndex
    while index < received.endIndex {
      let next = received.index(after: index)
      let offset = received.utf8.distance(from: received.utf8.startIndex, to: next)
      guard offset <= shared else { break }
      end = offset
      index = next
    }
    return end
  }
}
