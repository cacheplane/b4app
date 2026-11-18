/// The projection of the unfinished line: `document` before `finish()` applies the text after the
/// last newline to a copy of the open state, with markers the next character decides held and
/// unfinished syntax guessed, so a streaming reply never flashes raw markdown. The copy is thrown
/// away after the read, so a wrong guess reverts by itself.
extension BlockState {
  /// What a projection keeps beside the block state, on the copy it works on.
  struct OpenLine: Equatable, Sendable {
    /// The inline scan of the open leaf's text, which the parser keeps between reads.
    var inline: InlineProjection.Scan
    /// The open fence's unfinished line, kept apart so the projection does not append to `fenceText`.
    var fenceLine: Substring?
  }

  struct Projection {
    /// Top-level blocks the unfinished line finishes before the open one.
    var finished: [MarkdownBlock.Kind]
    var open: MarkdownBlock.Kind?
    /// The inline scan advanced over the open leaf's text, for the parser to keep.
    var inline: InlineProjection.Scan
  }

  /// The open top-level block with the unfinished line applied. Works on a copy: the state itself
  /// never sees the line. `inline` is the scan of the open leaf's text from the last projection;
  /// when the text has only grown since, only the new characters are scanned.
  func projection(of line: Substring, inline: InlineProjection.Scan) -> Projection {
    var copy = self
    copy.openLine = OpenLine(inline: inline)
    let finished = copy.accept(line)
    let leaf = copy.projectedLeaf()
    return Projection(finished: finished, open: copy.wrapping(leaf), inline: copy.openLine?.inline ?? inline)
  }

  // MARK: Hooks from `accept`

  /// Nothing of the next line yet: every container stays open, and a pending header is a table.
  mutating func projectEmptyLine() {
    _ = holdsOpenLine("", leafContinues: true)
  }

  /// A held line still opens the containers it starts with; it closes nothing otherwise, since the
  /// next character may make it a continuation.
  mutating func openHeld(_ openings: [Opening], keeping matched: Int) {
    guard !openings.isEmpty else { return }
    closeLeaf()
    closeContainers(to: matched)
    for opening in openings { open(opening) }
    closeListWithoutItem()
  }

  /// Whether the unfinished line, with the containers' markers taken off, contributes nothing yet.
  /// `leafContinues` says the line is in the open leaf's container with no new container before it;
  /// then a pending header's next line that could still be its delimiter row turns the header into
  /// a table (with no alignments yet) and is held.
  mutating func holdsOpenLine(_ line: Substring, leafContinues: Bool) -> Bool {
    if leafContinues, leaf == .paragraph, paragraphLines.count == 1, let header = pendingHeader,
      paragraphLines[0].text.first == "|", line.allSatisfy({ "|-: \t".contains($0) }),
      LineScanner.delimiterRow(line)?.count != header.count
    {
      startTable(alignments: Array(repeating: nil, count: header.count))
      return true
    }
    return Self.isUndecided(line)
  }

  /// A line that is so far blank, or only whitespace and one of `-`, `*`, `+`, `--`, `**`, `__`,
  /// `_`, digits, or digits then `.` or `)`: the next character decides between a list item, a
  /// thematic break and text.
  static func isUndecided(_ line: Substring) -> Bool {
    let body = LineScanner.trimmed(line)
    if body.isEmpty { return true }
    for marker in ["-", "*", "+", "--", "**", "__", "_"] where body == marker { return true }
    let digits = body.prefix { $0.isASCII && $0.isNumber }
    guard (1...9).contains(digits.count) else { return false }
    let after = body.dropFirst(digits.count)
    return after.isEmpty || after == "." || after == ")"
  }

  /// The unfinished line inside the open fence: its closer, a run of the fence's mark too short to
  /// close it yet (held, so a closing fence never flashes as code), or the code's next line.
  mutating func projectFenceLine(_ line: Substring) {
    guard let fence else { return }
    if LineScanner.closesFence(line, fence) {
      fenceLine(line)
    } else if let body = LineScanner.unindented(line), body.allSatisfy({ $0 == fence.mark }),
      body.count < fence.count
    {
      return
    } else {
      openLine?.fenceLine = line
    }
  }

  /// The unfinished line for the innermost container's leaf, once it is not held.
  mutating func projectLeafLine(_ line: Substring) {
    if LineScanner.isBlank(line) {
      closeLeaf()
    } else if LineScanner.thematicBreak(line) {
      closeLeaf()
      emit(.thematicBreak)
    } else if let heading = LineScanner.heading(line) {
      closeLeaf()
      emit(.heading(level: heading.level, text: closedInline(heading.text)))
    } else if let opening = LineScanner.fenceOpening(line) {
      closeLeaf()
      leaf = .fence
      // The language is taken when the opener's line completes.
      fence = LineScanner.FenceOpening(mark: opening.mark, count: opening.count, language: nil)
    } else if leaf == .table {
      tableRows.append(LineScanner.fit(closingTypedCell(LineScanner.tableRow(line)), to: tableHeader.count))
    } else if let alignments = delimiterRowForPendingHeader(line) {
      startTable(alignments: alignments)
    } else if leaf != .paragraph, let cells = projectedHeader(line) {
      // A first line that has closed its first cell is drawn as a header-only table.
      closeLeaf()
      leaf = .table
      tableHeader = cells
      tableAlignments = Array(repeating: nil, count: cells.count)
    } else {
      // The copy is thrown away, so whether this line is a header is not worth reading.
      pendingHeader = nil
      leaf = .paragraph
      paragraphLines.append(Self.paragraphLine(line))
    }
  }

  // MARK: The open leaf

  /// The leaf the unfinished line is in: its unfinished inline markup is closed, a paragraph with
  /// nothing to draw yet is left out, and the fence's unfinished line is added.
  mutating func projectedLeaf() -> MarkdownBlock.Kind? {
    switch leaf {
    case .paragraph:
      let text = closedInline(paragraphText())
      return text.allSatisfy(\.isWhitespace) ? nil : .paragraph(text)
    case .fence:
      guard let line = openLine?.fenceLine else { return currentLeaf() }
      // One copy of the code per read: accepted, as it is bounded by the open block.
      return .code(
        language: fence?.language, text: fenceText + (fenceHasLines ? "\n" : "") + line, closed: false)
    case .none, .table:
      return currentLeaf()
    }
  }

  /// The cells of an unfinished first line that starts with a pipe and has closed its first cell,
  /// with the cell being typed closed; nil otherwise.
  private mutating func projectedHeader(_ line: Substring) -> [String]? {
    guard LineScanner.trimmed(line).first == "|" else { return nil }
    let row = LineScanner.tableRow(line)
    guard row.closedCount > 0 else { return nil }
    return closingTypedCell(row)
  }

  /// A row's cells with unfinished inline markup closed in the cell still being typed; the cells a
  /// pipe has closed are finished.
  private mutating func closingTypedCell(_ row: LineScanner.TableRow) -> [String] {
    var cells = row.cells
    if row.closedCount < cells.count {
      cells[row.closedCount] = closedInline(cells[row.closedCount])
    }
    return cells
  }

  /// `text` with unfinished inline markup closed, through the scan the parser keeps, so a text that
  /// has only grown since the last read is scanned only where it is new.
  private mutating func closedInline(_ text: String) -> String {
    guard openLine != nil else { return InlineProjection.closed(text) }
    return openLine!.inline.closed(text)
  }
}
