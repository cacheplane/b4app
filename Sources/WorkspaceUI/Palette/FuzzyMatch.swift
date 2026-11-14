import Foundation

/// Forgiving matching for the palette: several terms, each found in a title (or, at half weight, in
/// what else the row is known by), ranked so the plainest match comes first. Local and synchronous;
/// nothing here reads anything but the strings it is given.
nonisolated enum FuzzyMatch {
  /// One folded character: the first scalar of the character with case and diacritics dropped.
  typealias Unit = UInt32

  /// A string prepared once for many queries. There is one unit per character of the original, so a
  /// match's positions index the original for highlighting.
  struct Text: Sendable, Equatable {
    let original: String
    let folded: [Unit]
    /// Whether each character starts a word: the first, or one after a space, mark, or symbol.
    let starts: [Bool]

    init(_ string: String) {
      original = string
      var folded: [Unit] = []
      var starts: [Bool] = []
      folded.reserveCapacity(string.count)
      starts.reserveCapacity(string.count)
      var afterBoundary = true
      for character in string {
        folded.append(FuzzyMatch.fold(character))
        starts.append(afterBoundary)
        afterBoundary = character.isWhitespace || character.isPunctuation || character.isSymbol
      }
      self.folded = folded
      self.starts = starts
    }
  }

  static func fold(_ character: Character) -> Unit {
    if let ascii = character.asciiValue {
      return Unit(ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii)
    }
    let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    return folded.unicodeScalars.first?.value ?? 0
  }

  /// The query's terms, folded. No terms means no query.
  static func terms(_ query: String) -> [[Unit]] {
    query.split(whereSeparator: \.isWhitespace).map { $0.map(fold) }
  }

  struct Hit: Equatable, Sendable {
    var score: Int
    /// The matched character offsets in the title, for emphasis.
    var positions: Set<Int>
  }

  /// One row against the query: every term must be found in `title`, or failing that in `also` (the
  /// row's secondary words and aliases). Nil when a term is found in neither.
  /// `positions` off skips collecting the matched offsets: ranking a long list needs only the score,
  /// and the few rows that are listed are matched again for their emphasis.
  static func match(_ terms: [[Unit]], title: Text, also: [Text] = [], positions collect: Bool = true) -> Hit?
  {
    var total = 0
    var positions = Set<Int>()
    for term in terms {
      if let own = score(term, in: title, positions: collect) {
        total += own.score
        positions.formUnion(own.positions)
        continue
      }
      // An alias that is the whole term is as good as the title; anything else of `also` is half.
      var best = 0
      for other in also {
        guard let found = score(term, in: other, positions: false) else { continue }
        best = max(best, found.score == Score.exact ? Score.exact : found.score / 2)
      }
      guard best > 0 else { return nil }
      total += best
    }
    return Hit(score: total, positions: positions)
  }

  enum Score {
    static let exact = 1000
    static let prefix = 800
    static let wordStart = 600
    static let inside = 400
    static let scattered = 200
  }

  /// One term in one field: the whole field, its start, the start of a word, anywhere inside, or
  /// (for two characters or more) its letters as the initials of words, or in order from the start
  /// of a word within a short span.
  static func score(_ term: [Unit], in text: Text, positions collect: Bool = true) -> Hit? {
    let field = text.folded
    guard !term.isEmpty, term.count <= field.count else { return nil }
    if let at = firstRange(of: term, in: field) {
      let score =
        term.count == field.count
        ? Score.exact : at == 0 ? Score.prefix : text.starts[at] ? Score.wordStart : Score.inside
      return Hit(score: score, positions: collect ? Set(at..<(at + term.count)) : [])
    }
    guard term.count >= 2 else { return nil }
    // Initials: each letter starts a word, in order ("rnd" for "Release notes draft").
    var initials: [Int] = []
    var next = 0
    for offset in field.indices where next < term.count && text.starts[offset] && field[offset] == term[next]
    {
      initials.append(offset)
      next += 1
    }
    if next == term.count { return Hit(score: Score.scattered, positions: collect ? Set(initials) : []) }
    var from = 0
    var positions: [Int] = []
    for unit in term {
      guard let found = field[from...].firstIndex(of: unit) else { return nil }
      positions.append(found)
      from = found + 1
    }
    guard let first = positions.first, let last = positions.last, text.starts[first],
      last - first < term.count * 3
    else { return nil }
    return Hit(
      score: Score.scattered - 1 - (last - first + 1 - term.count), positions: collect ? Set(positions) : [])
  }

  private static func firstRange(of term: [Unit], in field: [Unit]) -> Int? {
    let last = field.count - term.count
    let head = term[0]
    var start = 0
    while start <= last {
      if field[start] == head {
        var offset = 1
        while offset < term.count, field[start + offset] == term[offset] { offset += 1 }
        if offset == term.count { return start }
      }
      start += 1
    }
    return nil
  }

  /// `title` cut into runs of matched and unmatched characters, in order.
  static func runs(of title: String, matched: Set<Int>) -> [(text: String, matched: Bool)] {
    guard !matched.isEmpty else { return [(title, false)] }
    var runs: [(text: String, matched: Bool)] = []
    for (offset, character) in title.enumerated() {
      let hit = matched.contains(offset)
      if let last = runs.indices.last, runs[last].matched == hit {
        runs[last].text.append(character)
      } else {
        runs.append((String(character), hit))
      }
    }
    return runs
  }
}
