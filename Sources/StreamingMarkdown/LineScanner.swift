/// What one line is, outside the block that is open. Static functions over a line without its
/// line ending; each returns nil when the line is not that thing.
enum LineScanner {
  struct FenceOpening: Equatable {
    let mark: Character
    let count: Int
    let language: String?
  }

  static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

  /// The line without up to three leading spaces, or nil when it is indented further.
  static func unindented(_ line: Substring) -> Substring? {
    let body = line.drop { $0 == " " }
    return line.count - body.count <= 3 ? body : nil
  }

  /// Three or more of one of `-`, `*`, `_`, with spaces and tabs between, and nothing else.
  static func thematicBreak(_ line: Substring) -> Bool {
    guard let body = unindented(line), let mark = body.first, "-*_".contains(mark) else { return false }
    var count = 0
    for character in body {
      if character == mark {
        count += 1
      } else if character != " " && character != "\t" {
        return false
      }
    }
    return count >= 3
  }

  /// One to six `#`, then a space, a tab or the line's end; the closing `#`s are dropped.
  static func heading(_ line: Substring) -> (level: Int, text: String)? {
    guard let body = unindented(line) else { return nil }
    let marks = body.prefix { $0 == "#" }
    guard (1...6).contains(marks.count) else { return nil }
    let rest = body.dropFirst(marks.count)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    var text = trimmed(rest)
    let closing = text.reversed().prefix { $0 == "#" }.count
    if closing > 0 {
      let before = text.dropLast(closing)
      if before.isEmpty || before.last == " " || before.last == "\t" { text = trimmed(before) }
    }
    return (marks.count, String(text))
  }

  /// Three or more backticks or tildes, indented at most three spaces. A backtick opener holding
  /// another backtick is inline code, not a fence.
  static func fenceOpening(_ line: Substring) -> FenceOpening? {
    guard let body = unindented(line), let mark = body.first, mark == "`" || mark == "~" else { return nil }
    let run = body.prefix { $0 == mark }
    guard run.count >= 3 else { return nil }
    let info = body.dropFirst(run.count)
    if mark == "`", info.contains("`") { return nil }
    let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return FenceOpening(mark: mark, count: run.count, language: language)
  }

  /// At least as many of the same mark as the opener and nothing else.
  static func closesFence(_ line: Substring, _ opening: FenceOpening) -> Bool {
    guard let body = unindented(line) else { return false }
    let run = body.prefix { $0 == opening.mark }
    return run.count >= opening.count && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
  }

  /// The text without whitespace at either end.
  static func trimmed(_ text: Substring) -> Substring {
    var result = text.drop { $0.isWhitespace }
    while let last = result.last, last.isWhitespace { result = result.dropLast() }
    return result
  }

  // MARK: Containers

  /// What is left of a line once some containers' markers are taken off, and the column it starts
  /// at, so a tab in it still counts to the next multiple of four.
  struct Rest: Equatable {
    var text: Substring
    var column: Int
  }

  /// A list's kind: a bullet (`-`, `*`, `+`) or the delimiter after an ordered item's number.
  struct ListMarker: Equatable {
    let ordered: Bool
    let mark: Character
  }

  struct ItemOpening: Equatable {
    let marker: ListMarker
    /// The item's number; 1 for a bullet.
    let start: Int
    /// The item's content column, counted from the start of the text the marker was found in.
    let width: Int
    let task: Bool?
    /// The text after the marker (and after the task box, when there is one).
    let content: Rest
  }

  /// Columns of spaces and tabs at the start of the text.
  static func indent(_ rest: Rest) -> Int {
    var column = rest.column
    for character in rest.text {
      if character == " " {
        column += 1
      } else if character == "\t" {
        column += 4 - column % 4
      } else {
        break
      }
    }
    return column - rest.column
  }

  /// The text with `count` columns of leading spaces and tabs taken off (fewer when it has fewer).
  /// A tab only partly taken off leaves its other columns as spaces.
  static func dropIndent(_ rest: Rest, _ count: Int) -> Rest {
    let target = rest.column + count
    var column = rest.column
    var index = rest.text.startIndex
    while column < target, index < rest.text.endIndex {
      let character = rest.text[index]
      guard character == " " || character == "\t" else { break }
      let next = character == "\t" ? column + 4 - column % 4 : column + 1
      if next > target {
        let spaces = String(repeating: " ", count: next - target)
        return Rest(text: Substring(spaces + rest.text[rest.text.index(after: index)...]), column: target)
      }
      column = next
      index = rest.text.index(after: index)
    }
    return Rest(text: rest.text[index...], column: column)
  }

  /// After at most three columns of indent, a `>` and one optional space: the text after them.
  static func quoteContent(_ rest: Rest) -> Rest? {
    let spaces = indent(rest)
    guard spaces <= 3 else { return nil }
    let body = dropIndent(rest, spaces)
    guard body.text.first == ">" else { return nil }
    let after = Rest(text: body.text.dropFirst(), column: body.column + 1)
    return indent(after) > 0 ? dropIndent(after, 1) : after
  }

  /// A list item's marker after at most three columns of indent: `-`, `*` or `+`, or one to nine
  /// digits then `.` or `)`, followed by a space, a tab or the line's end. A thematic break is not one.
  static func itemOpening(_ rest: Rest) -> ItemOpening? {
    let spaces = indent(rest)
    guard spaces <= 3, !thematicBreak(rest.text) else { return nil }
    let body = dropIndent(rest, spaces)
    guard let first = body.text.first else { return nil }
    let marker: ListMarker
    var start = 1
    var length = 1
    if "-*+".contains(first) {
      marker = ListMarker(ordered: false, mark: first)
    } else {
      let digits = body.text.prefix { $0.isASCII && $0.isNumber }
      guard (1...9).contains(digits.count), let mark = body.text.dropFirst(digits.count).first,
        mark == "." || mark == ")", let number = Int(digits)
      else { return nil }
      marker = ListMarker(ordered: true, mark: mark)
      start = number
      length = digits.count + 1
    }
    let after = Rest(text: body.text.dropFirst(length), column: body.column + length)
    guard after.text.isEmpty || after.text.first == " " || after.text.first == "\t" else { return nil }
    if isBlank(after.text) {
      let content = Rest(text: after.text[after.text.endIndex...], column: after.column + 1)
      return ItemOpening(
        marker: marker, start: start, width: spaces + length + 1, task: nil, content: content)
    }
    let gap = indent(after)
    var content = dropIndent(after, gap)
    var task: Bool?
    let boxes = [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
    if let (box, checked) = boxes.first(where: { content.text.hasPrefix($0.0) }) {
      task = checked
      content = Rest(text: content.text.dropFirst(box.count), column: content.column + box.count)
    }
    return ItemOpening(
      marker: marker, start: start, width: spaces + length + gap, task: task, content: content)
  }

  /// A heading, a thematic break or a fence opener: a line that cannot continue a paragraph.
  static func startsLeafBlock(_ line: Substring) -> Bool {
    thematicBreak(line) || heading(line) != nil || fenceOpening(line) != nil
  }

  // MARK: Tables

  /// A line read as a table row: its cells, and whether it holds a pipe that splits it.
  struct TableRow: Equatable {
    var cells: [String]
    var splits: Bool
  }

  /// The cells of a line. A pipe splits unless it is escaped (`\|`, which is a literal pipe in the
  /// cell) or inside a backtick code span; a leading and a trailing pipe are optional and make no
  /// cell. Cell text is trimmed. A line with no splitting pipe is one cell.
  static func tableRow(_ line: Substring) -> TableRow {
    let chars = Array(trimmed(line))
    var parts: [String] = []
    var current = ""
    var splits = false
    var endsWithSplit = false
    var index = 0
    while index < chars.count {
      let character = chars[index]
      if character == "\\", index + 1 < chars.count, chars[index + 1] == "|" {
        current.append("|")
        index += 2
      } else if character == "`" {
        let length = chars[index...].prefix { $0 == "`" }.count
        let end = codeSpanEnd(chars, from: index + length, length: length) ?? index + length
        var inner = index
        while inner < end {
          if chars[inner] == "\\", inner + 1 < end, chars[inner + 1] == "|" {
            current.append("|")
            inner += 2
          } else {
            current.append(chars[inner])
            inner += 1
          }
        }
        index = end
      } else if character == "|" {
        parts.append(current)
        current = ""
        splits = true
        endsWithSplit = index == chars.count - 1
        index += 1
      } else {
        current.append(character)
        index += 1
      }
    }
    parts.append(current)
    if splits {
      if chars.first == "|" { parts.removeFirst() }
      if endsWithSplit { parts.removeLast() }
    }
    return TableRow(cells: parts.map { String(trimmed(Substring($0))) }, splits: splits)
  }

  /// Where the code span opened by a run of `length` backticks ends (after its closing run), or nil
  /// when the run has no closer, so it is text.
  private static func codeSpanEnd(_ chars: [Character], from start: Int, length: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "`" {
        let run = chars[index...].prefix { $0 == "`" }.count
        if run == length { return index + run }
        index += run
      } else {
        index += 1
      }
    }
    return nil
  }

  /// A table's header row: it has a splitting pipe and at least one cell.
  static func tableHeader(_ line: Substring) -> [String]? {
    let row = tableRow(line)
    return row.splits && !row.cells.isEmpty ? row.cells : nil
  }

  /// A delimiter row: cells of `-` with an optional `:` at either end, and a splitting pipe. Returns
  /// one alignment per cell.
  static func delimiterRow(_ line: Substring) -> [MarkdownTable.Alignment?]? {
    guard unindented(line) != nil else { return nil }
    let row = tableRow(line)
    guard row.splits, !row.cells.isEmpty else { return nil }
    var alignments: [MarkdownTable.Alignment?] = []
    for cell in row.cells {
      let left = cell.hasPrefix(":")
      let right = cell.count > 1 && cell.hasSuffix(":")
      let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right ? 1 : 0)
      guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
      alignments.append(left && right ? .center : left ? .leading : right ? .trailing : nil)
    }
    return alignments
  }
}
