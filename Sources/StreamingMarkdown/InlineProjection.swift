import Foundation

/// Guesses for inline markup that is still arriving, so an open leaf never draws a raw `**` or a
/// half-typed link.
enum InlineProjection {
  /// `text` with unfinished inline markup closed, for drawing while it streams.
  static func closed(_ text: String) -> String {
    var scan = Scan()
    return scan.closed(text)
  }

  /// A resumable left-to-right scan over the UTF-8 bytes (every mark is ASCII). `extend(to:)` decides
  /// only what later text cannot change and stops before the rest, so a scan kept between reads of
  /// a growing text reads each byte about once; `closed` finishes a copy as if the text ended there.
  /// `InlineProjection.closed` is the same scan run once over the whole text.
  ///
  /// Each emphasis opener is pushed and popped once. A backtick run opens a code span at once when
  /// a non-space follows it (the span's text is the same whether or not a closer comes); when a
  /// space follows, it is text unless a closer comes, so the scan notes where it was (a candidate)
  /// and goes back there if the closer arrives. A link destination is skipped until its `)`.
  struct Scan: Equatable, Sendable {
    private struct Opener: Equatable, Sendable {
      let mark: UInt8
      var length: Int
    }

    private struct Bracket: Equatable, Sendable {
      /// Where the `[` (or the `!` of `![`) is in the output.
      let start: Int
      let image: Bool
    }

    /// What the scan has decided up to `position`; `out` only grows while it is in `.text`.
    private struct Decided: Equatable, Sendable {
      var out: [UInt8] = []
      var openers: [Opener] = []
      /// How many openers of each mark are on the stack, so a closer knows at once whether one is.
      var openCount: [UInt8: Int] = [:]
      var brackets: [Bracket] = []
    }

    private enum Mode: Equatable, Sendable {
      case text
      /// Inside a code span opened by a run of `length` backticks at input index `start`.
      case code(length: Int, start: Int)
      /// After `](`: the destination of the link whose `]` is at input index `close`.
      case destination(Bracket, close: Int)
    }

    /// A backtick run followed by a space, read as text: if a run of the same length comes, the
    /// scan returns to `decided` and the run opens a code span instead. The snapshot keeps the
    /// output's length, not the output: the output only grows until then, so going back cuts it.
    private struct Candidate: Equatable, Sendable {
      let length: Int
      let start: Int
      /// `decided` as it was, with an empty `out`.
      let decided: Decided
      let outCount: Int
    }

    private var input: [UInt8] = []
    /// The next input byte to decide.
    private var position = 0
    private var decided = Decided()
    private var mode = Mode.text
    private var candidates: [Candidate] = []

    /// Scans `text` as far as later text cannot change, reusing what was scanned when `text` starts
    /// with the text scanned before, and returns it with unfinished markup closed.
    mutating func closed(_ text: String) -> String {
      extend(to: text)
      var end = self
      end.advance(atEnd: true)
      return end.output()
    }

    /// Takes `text` as the scan's input: only the new bytes when it extends the old input, all of it
    /// otherwise. The prefix check is one memory compare.
    mutating func extend(to text: String) {
      var text = text
      text.withUTF8 { new in
        let old = input.count
        let extends =
          new.count >= old
          && (old == 0
            || input.withUnsafeBufferPointer { memcmp($0.baseAddress!, new.baseAddress!, old) == 0 })
        if !extends { self = Scan() }
        if new.count > input.count {
          input.append(contentsOf: UnsafeBufferPointer(rebasing: new[input.count...]))
        }
      }
      advance(atEnd: false)
    }

    // MARK: Scanning

    /// Decides bytes from `position`. Unless `atEnd`, it stops before anything the next byte could
    /// change: a run that touches the end, or a mark whose meaning depends on what follows it.
    private mutating func advance(atEnd: Bool) {
      while position < input.count {
        let moved: Bool
        switch mode {
        case .text: moved = textStep(atEnd: atEnd)
        case .code(let length, _): moved = skipStep(atEnd: atEnd, closingCode: length)
        case .destination: moved = skipStep(atEnd: atEnd, closingCode: nil)
        }
        if !moved { return }
      }
    }

    /// One token of text. Returns false when it needs the next byte.
    private mutating func textStep(atEnd: Bool) -> Bool {
      let index = position
      let byte = input[index]
      let hasNext = index + 1 < input.count
      switch byte {
      case .backslash:
        guard hasNext || atEnd else { return false }
        let end = index + (hasNext && input[index + 1].isASCIIPunctuation ? 2 : 1)
        decided.out += input[index..<end]
        position = end
      case .backtick:
        let end = runEnd(at: index)
        guard end < input.count || atEnd else { return false }
        if resolveCandidate(runAt: index, end: end) { return true }
        if end == input.count {
          position = end  // a trailing run with nothing after it is held
        } else if input[end].isSpace {
          var snapshot = decided
          snapshot.out = []
          candidates.append(
            Candidate(length: end - index, start: index, decided: snapshot, outCount: decided.out.count))
          decided.out += input[index..<end]
          position = end
        } else {
          mode = .code(length: end - index, start: index)
          position = end
        }
      case .asterisk, .underscore, .tilde:
        let end = runEnd(at: index)
        guard end < input.count || atEnd else { return false }
        delimiterRun(at: index, end: end)
        position = end
      case .openBracket:
        decided.brackets.append(Bracket(start: decided.out.count, image: false))
        decided.out.append(byte)
        position += 1
      case .bang:
        guard hasNext || atEnd else { return false }
        if hasNext, input[index + 1] == .openBracket {
          decided.brackets.append(Bracket(start: decided.out.count, image: true))
          decided.out += input[index...index + 1]
          position += 2
        } else {
          decided.out.append(byte)
          position += 1
        }
      case .closeBracket:
        guard hasNext || atEnd else { return false }
        if hasNext, input[index + 1] == .openParen, let bracket = decided.brackets.popLast() {
          mode = .destination(bracket, close: index)
          position += 2
        } else {
          if !decided.brackets.isEmpty { decided.brackets.removeLast() }
          decided.out.append(byte)
          position += 1
        }
      default:
        decided.out.append(byte)
        position += 1
      }
      return true
    }

    /// One byte or backtick run of a code span or a link destination, whose text is not scanned.
    /// Returns false when it needs the next byte.
    private mutating func skipStep(atEnd: Bool, closingCode length: Int?) -> Bool {
      let index = position
      let byte = input[index]
      if byte == .backtick {
        let end = runEnd(at: index)
        guard end < input.count || atEnd else { return false }
        if resolveCandidate(runAt: index, end: end) { return true }
        if case .code(let length, let start) = mode, end - index == length {
          decided.out += input[start..<end]
          mode = .text
        }
        position = end
        return true
      }
      if length == nil, byte == .closeParen, case .destination(_, let close) = mode {
        decided.out += input[close...index]
        mode = .text
      }
      position += 1
      return true
    }

    /// A backtick run of the length of an earlier candidate closes that candidate's code span: the
    /// scan returns to the candidate and copies the span whole.
    private mutating func resolveCandidate(runAt index: Int, end: Int) -> Bool {
      guard let found = candidates.firstIndex(where: { $0.length == end - index }) else { return false }
      let candidate = candidates[found]
      candidates.removeSubrange(found...)
      var out: [UInt8] = []
      swap(&out, &decided.out)
      out.removeSubrange(candidate.outCount...)
      out += input[candidate.start..<end]
      decided = candidate.decided
      swap(&out, &decided.out)
      mode = .text
      position = end
      return true
    }

    /// A run of `*`, `_` or `~`: it closes what it can, opens with what is left when a non-space
    /// follows it, and is dropped when it ends the text unmatched.
    private mutating func delimiterRun(at index: Int, end: Int) {
      let mark = input[index]
      let length = end - index
      let trailing = end == input.count
      // Strikethrough is exactly two tildes; any other tilde run is text.
      guard mark != .tilde || length == 2 else {
        if !trailing { decided.out += input[index..<end] }
        return
      }
      let spaceBefore = index == 0 || input[index - 1].isSpace
      let spaceAfter = trailing || input[end].isSpace
      var canOpen = !spaceAfter
      var canClose = !spaceBefore
      if mark == .underscore {
        // An intraword `_` never opens or closes.
        if wordCharacter(before: index) { canOpen = false }
        if !trailing, wordCharacter(at: end) { canClose = false }
      }
      var left = length
      if canClose {
        while left > 0, decided.openCount[mark, default: 0] > 0 {
          while let top = decided.openers.last, top.mark != mark { popOpener() }
          let last = decided.openers.count - 1
          let used = min(left, decided.openers[last].length)
          decided.openers[last].length -= used
          left -= used
          if decided.openers[last].length == 0 { popOpener() }
        }
      }
      if trailing {
        // What did not close is held.
        decided.out += input[index..<(end - left)]
        return
      }
      decided.out += input[index..<end]
      if left > 0, canOpen {
        decided.openers.append(Opener(mark: mark, length: left))
        decided.openCount[mark, default: 0] += 1
      }
    }

    private mutating func popOpener() {
      let opener = decided.openers.removeLast()
      decided.openCount[opener.mark, default: 0] -= 1
    }

    private func runEnd(at index: Int) -> Int {
      var end = index
      while end < input.count, input[end] == input[index] { end += 1 }
      return end
    }

    // MARK: The result

    /// The text of a finished scan with every open span closed, innermost first, before any trailing
    /// whitespace.
    private func output() -> String {
      var out = decided.out
      var closers: [UInt8] = []
      switch mode {
      case .text:
        break
      case .code(let length, let start):
        out += input[start...]
        closers += [UInt8](repeating: .backtick, count: length)
      case .destination(let bracket, _):
        // A link whose destination is still arriving shows its text only.
        out.removeSubrange(bracket.start..<(bracket.start + (bracket.image ? 2 : 1)))
      }
      for opener in decided.openers.reversed() {
        closers += [UInt8](repeating: opener.mark, count: opener.length)
      }
      var body = out.count
      if !closers.isEmpty {
        while body > 0, out[body - 1].isSpace { body -= 1 }
      }
      let total = out.count + closers.count
      return out.withUnsafeBufferPointer { head in
        closers.withUnsafeBufferPointer { tail in
          String(unsafeUninitializedCapacity: total) { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            if body > 0 { memcpy(base, head.baseAddress!, body) }
            if !closers.isEmpty { memcpy(base + body, tail.baseAddress!, closers.count) }
            if out.count > body {
              memcpy(base + body + closers.count, head.baseAddress! + body, out.count - body)
            }
            return total
          }
        }
      }
    }

    private func wordCharacter(at index: Int) -> Bool {
      let byte = input[index]
      if byte < 0x80 { return byte.isASCIIAlphanumeric }
      var end = index + 1
      while end < input.count, input[end] & 0xC0 == 0x80 { end += 1 }
      return Self.alphanumeric(input[index..<end])
    }

    private func wordCharacter(before index: Int) -> Bool {
      guard index > 0 else { return false }
      let byte = input[index - 1]
      if byte < 0x80 { return byte.isASCIIAlphanumeric }
      var start = index - 1
      while start > 0, input[start] & 0xC0 == 0x80 { start -= 1 }
      return Self.alphanumeric(input[start..<index])
    }

    private static func alphanumeric(_ scalarBytes: ArraySlice<UInt8>) -> Bool {
      guard let scalar = String(decoding: scalarBytes, as: UTF8.self).unicodeScalars.first else {
        return false
      }
      return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
  }
}

extension UInt8 {
  fileprivate static let backtick = UInt8(ascii: "`")
  fileprivate static let backslash = UInt8(ascii: "\\")
  fileprivate static let asterisk = UInt8(ascii: "*")
  fileprivate static let underscore = UInt8(ascii: "_")
  fileprivate static let tilde = UInt8(ascii: "~")
  fileprivate static let bang = UInt8(ascii: "!")
  fileprivate static let openBracket = UInt8(ascii: "[")
  fileprivate static let closeBracket = UInt8(ascii: "]")
  fileprivate static let openParen = UInt8(ascii: "(")
  fileprivate static let closeParen = UInt8(ascii: ")")

  fileprivate var isSpace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }

  fileprivate var isASCIIAlphanumeric: Bool {
    (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
  }

  fileprivate var isASCIIPunctuation: Bool {
    (0x21...0x2F).contains(self) || (0x3A...0x40).contains(self) || (0x5B...0x60).contains(self)
      || (0x7B...0x7E).contains(self)
  }
}
