/// The top-level block the parser has open: the stack of open containers (quotes, lists and items,
/// outermost first) and the one open leaf inside the innermost of them.
///
/// The open block's storage is plain stored properties that `accept` mutates in place. Never pull
/// the storage out of an enum payload into a local `var` to append to it: the enum still holds the
/// array, so the append copies the whole array on every line. The containers follow the same rule:
/// each `Container` keeps its finished children, which are appended through `containers[index]`,
/// and the open leaf's lines live here, outside the stack, so a line of a fence inside an item
/// touches only `fenceText`.
///
/// This file handles complete lines. The unfinished line is projected by the extension in
/// `OpenLineProjection.swift`, on a copy whose `openLine` is set; the members it needs are internal
/// for it, and the hooks here are the only places a complete line's handling checks `openLine`.
struct BlockState: Equatable, Sendable {
  /// Quotes and items nest this deep; a marker that would open one more level is text.
  static let maxDepth = 16

  enum Leaf: Equatable, Sendable {
    case none, paragraph, fence, table
  }

  struct Container: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case quote
      case list(LineScanner.ListMarker, start: Int)
      /// `width` is the item's content column, counted from its parent's content.
      case item(width: Int, task: Bool?)
    }

    let kind: Kind
    /// The container's id, a path of positions.
    let id: String
    /// A quote's or item's finished children.
    var blocks: [MarkdownBlock] = []
    /// A list's finished items; the open item is the next container on the stack.
    var items: [MarkdownListItem] = []

    /// The id of this container's next child.
    var nextChildID: String {
      "\(id).\(kind.isList ? items.count : blocks.count)"
    }
  }

  struct ParagraphLine: Equatable, Sendable {
    /// The line without whitespace at either end.
    let text: String
    /// The text with a hard break's marker removed, when the line ends in one.
    let hardText: String?
  }

  enum Opening {
    case quote
    case item(LineScanner.ItemOpening)
  }

  /// The open containers, outermost first.
  private(set) var containers: [Container] = []
  /// The open leaf, which belongs to the innermost container (or to the top level).
  var leaf = Leaf.none
  var paragraphLines: [ParagraphLine] = []
  var fence: LineScanner.FenceOpening?
  /// The open fence's code, kept joined as lines arrive so a read does not join them again.
  var fenceText = ""
  var fenceHasLines = false
  /// The cells of the paragraph's first line when it reads as a table header; the next line decides.
  var pendingHeader: [String]?
  /// The open table's columns and rows, appended to in place as its lines arrive.
  var tableAlignments: [MarkdownTable.Alignment?] = []
  var tableHeader: [String] = []
  var tableRows: [[String]] = []
  /// Top-level blocks handed back so far, which is the parser's committed count: the position, and
  /// so the id, of the next top-level block.
  private var emitted = 0
  /// Top-level blocks finished by the line being handled.
  private var finished: [MarkdownBlock.Kind] = []
  /// Set only on the copy a projection works on (`OpenLineProjection.swift`): the line it is given
  /// is the unfinished one.
  var openLine: OpenLine?

  /// Takes one complete line. Returns the top-level blocks the line finished, in order.
  mutating func accept(_ line: Substring) -> [MarkdownBlock.Kind] {
    if openLine != nil, line.isEmpty {
      projectEmptyLine()
      return drain()
    }
    var rest = LineScanner.Rest(text: line, column: 0)
    var matched = 0
    while matched < containers.count, let next = Self.continuation(of: containers[matched].kind, rest) {
      rest = next
      matched += 1
    }
    if leaf == .fence, matched == containers.count {
      if openLine != nil { projectFenceLine(rest.text) } else { fenceLine(rest.text) }
      return drain()
    }
    let depth = containers[..<matched].count { !$0.kind.isList }
    // Only a paragraph whose containers all continue on this line can be interrupted; one in a
    // container the line left is closing anyway (or the line is lazy text when nothing opens).
    let interrupting = leaf == .paragraph && matched == containers.count
    let (openings, content) = Self.openings(
      in: rest, room: Self.maxDepth - depth, interruptingParagraph: interrupting,
      holdingBareMarker: openLine != nil)
    if openLine != nil,
      holdsOpenLine(content.text, leafContinues: openings.isEmpty && matched == containers.count)
    {
      openHeld(openings, keeping: matched)
      return drain()
    }
    if matched < containers.count, leaf == .paragraph, openings.isEmpty, !LineScanner.isBlank(content.text),
      !LineScanner.startsLeafBlock(content.text)
    {
      // A lazy continuation: the paragraph goes on and every container stays open.
      paragraphLines.append(Self.paragraphLine(content.text))
      pendingHeader = nil
      return drain()
    }
    if !openings.isEmpty { closeLeaf() }
    closeContainers(to: matched)
    for opening in openings { open(opening) }
    closeListWithoutItem()
    leafLine(content.text)
    return drain()
  }

  /// Ends the open block, if any.
  mutating func close() -> [MarkdownBlock.Kind] {
    closeLeaf()
    closeContainers(to: 0)
    return drain()
  }

  /// The open top-level block as it reads now, from the complete lines.
  func current() -> MarkdownBlock.Kind? {
    wrapping(currentLeaf())
  }

  /// The open top-level block with `leaf` as its open leaf. Rebuilds only the open path: each open
  /// container's finished children are reused.
  func wrapping(_ leaf: MarkdownBlock.Kind?) -> MarkdownBlock.Kind? {
    var block = leaf
    var item: MarkdownListItem?
    for container in containers.reversed() {
      var blocks = container.blocks
      if let block { blocks.append(MarkdownBlock(id: container.nextChildID, kind: block)) }
      switch container.kind {
      case .quote:
        block = .quote(blocks)
      case .item(_, let task):
        item = MarkdownListItem(id: container.id, task: task, blocks: blocks)
        block = nil
      case .list(let marker, let start):
        var items = container.items
        if let item { items.append(item) }
        item = nil
        block = .list(MarkdownList(ordered: marker.ordered, start: start, items: items))
      }
    }
    return block
  }

  // MARK: Containers

  /// The text after a container's continuation marker, or nil when the line does not continue it.
  /// A list always continues; whether its open item does is decided by the item.
  private static func continuation(of kind: Container.Kind, _ rest: LineScanner.Rest) -> LineScanner.Rest? {
    switch kind {
    case .quote:
      return LineScanner.quoteContent(rest)
    case .list:
      return rest
    case .item(let width, _):
      if LineScanner.isBlank(rest.text) { return LineScanner.dropIndent(rest, width) }
      return LineScanner.indent(rest) >= width ? LineScanner.dropIndent(rest, width) : nil
    }
  }

  /// The quotes and items that start the text, at most `room` of them, and the text after them.
  /// When the line would interrupt an open paragraph, a first item does so only when it has text
  /// and, if ordered, starts at 1 (the paragraph's container is never a list, so the item would
  /// start a new one). When `holdingBareMarker`, an item marker that ends the text (no space after
  /// it yet) opens nothing: the next character decides.
  static func openings(
    in text: LineScanner.Rest, room: Int, interruptingParagraph: Bool, holdingBareMarker: Bool = false
  ) -> (
    [Opening], LineScanner.Rest
  ) {
    var openings: [Opening] = []
    var rest = text
    while openings.count < room {
      if let content = LineScanner.quoteContent(rest) {
        openings.append(.quote)
        rest = content
      } else if let item = LineScanner.itemOpening(rest) {
        if holdingBareMarker, item.content.text.isEmpty, let last = rest.text.last, !last.isWhitespace {
          break
        }
        if openings.isEmpty, interruptingParagraph,
          item.start != 1 || LineScanner.isBlank(item.content.text)
        {
          break
        }
        openings.append(.item(item))
        rest = item.content
      } else {
        break
      }
    }
    return (openings, rest)
  }

  mutating func open(_ opening: Opening) {
    switch opening {
    case .quote:
      closeListWithoutItem()
      push(.quote)
    case .item(let item):
      if case .list(let marker, _) = containers.last?.kind, marker != item.marker { closeListWithoutItem() }
      if !(containers.last?.kind.isList ?? false) { push(.list(item.marker, start: item.start)) }
      push(.item(width: item.width, task: item.task))
    }
  }

  private mutating func push(_ kind: Container.Kind) {
    let id = containers.last?.nextChildID ?? String(emitted)
    containers.append(Container(kind: kind, id: id))
  }

  /// A list is open only while an item in it is; one left innermost by a line is finished.
  mutating func closeListWithoutItem() {
    if containers.last?.kind.isList ?? false { closeContainers(to: containers.count - 1) }
  }

  /// Closes the open leaf and the containers from `count` in, folding each into its parent.
  mutating func closeContainers(to count: Int) {
    if containers.count > count { closeLeaf() }
    while containers.count > count {
      let container = containers.removeLast()
      switch container.kind {
      case .quote:
        emit(.quote(container.blocks))
      case .list(let marker, let start):
        emit(.list(MarkdownList(ordered: marker.ordered, start: start, items: container.items)))
      case .item(_, let task):
        // An item's parent is always its list.
        containers[containers.count - 1].items.append(
          MarkdownListItem(id: container.id, task: task, blocks: container.blocks))
      }
    }
  }

  /// Hands a finished block to the innermost container, or back to the parser at the top level.
  mutating func emit(_ kind: MarkdownBlock.Kind) {
    if containers.isEmpty {
      finished.append(kind)
      emitted += 1
    } else {
      let last = containers.count - 1
      containers[last].blocks.append(MarkdownBlock(id: containers[last].nextChildID, kind: kind))
    }
  }

  private mutating func drain() -> [MarkdownBlock.Kind] {
    defer { finished = [] }
    return finished
  }

  // MARK: The leaf

  /// One line for the innermost container's leaf, with the containers' markers taken off.
  private mutating func leafLine(_ line: Substring) {
    if openLine != nil {
      projectLeafLine(line)
      return
    }
    if LineScanner.isBlank(line) {
      closeLeaf()
    } else if LineScanner.thematicBreak(line) {
      closeLeaf()
      emit(.thematicBreak)
    } else if let heading = LineScanner.heading(line) {
      closeLeaf()
      emit(.heading(level: heading.level, text: heading.text))
    } else if let opening = LineScanner.fenceOpening(line) {
      closeLeaf()
      leaf = .fence
      fence = opening
    } else if leaf == .table {
      tableRows.append(LineScanner.fit(LineScanner.tableRow(line).cells, to: tableHeader.count))
    } else if let alignments = delimiterRowForPendingHeader(line) {
      startTable(alignments: alignments)
    } else {
      pendingHeader = leaf != .paragraph ? LineScanner.tableHeader(line) : nil
      leaf = .paragraph
      paragraphLines.append(Self.paragraphLine(line))
    }
  }

  /// The alignments of `line` when it is the delimiter row of the open paragraph's pending header.
  func delimiterRowForPendingHeader(_ line: Substring) -> [MarkdownTable.Alignment?]? {
    guard leaf == .paragraph, let header = pendingHeader, paragraphLines.count == 1,
      let alignments = LineScanner.delimiterRow(line), alignments.count == header.count
    else { return nil }
    return alignments
  }

  /// Turns the open paragraph's pending header into the open table.
  mutating func startTable(alignments: [MarkdownTable.Alignment?]) {
    leaf = .table
    tableAlignments = alignments
    tableHeader = pendingHeader ?? []
    pendingHeader = nil
    paragraphLines = []
  }

  /// A line inside the open fence: its closer, or one more line of code.
  mutating func fenceLine(_ line: Substring) {
    if let fence, LineScanner.closesFence(line, fence) {
      emit(.code(language: fence.language, text: fenceText, closed: true))
      resetLeaf()
      return
    }
    if fenceHasLines { fenceText += "\n" }
    fenceText += line
    fenceHasLines = true
  }

  /// Ends the open leaf. A leaf a line closes is finished, so nothing is guessed in it even on a
  /// projection.
  mutating func closeLeaf() {
    if let kind = currentLeaf() { emit(kind) }
    resetLeaf()
  }

  /// The open leaf, from the complete lines.
  func currentLeaf() -> MarkdownBlock.Kind? {
    switch leaf {
    case .none:
      return nil
    case .paragraph:
      return .paragraph(paragraphText())
    case .fence:
      return .code(language: fence?.language, text: fenceText, closed: false)
    case .table:
      return .table(MarkdownTable(alignments: tableAlignments, header: tableHeader, rows: tableRows))
    }
  }

  private mutating func resetLeaf() {
    leaf = .none
    paragraphLines = []
    fence = nil
    fenceText = ""
    fenceHasLines = false
    pendingHeader = nil
    tableAlignments = []
    tableHeader = []
    tableRows = []
  }

  /// The open paragraph's text: its lines joined by line breaks, each without a hard break's marker.
  /// Rebuilt on every read: one copy of the text.
  func paragraphText() -> String {
    var text = ""
    for (index, line) in paragraphLines.enumerated() {
      if index == paragraphLines.count - 1 {
        text += line.text
      } else {
        text += (line.hardText ?? line.text) + "\n"
      }
    }
    return text
  }

  static func paragraphLine(_ line: Substring) -> ParagraphLine {
    let text = LineScanner.trimmed(line)
    let spaces = line.reversed().prefix { $0 == " " }.count
    if spaces >= 2 {
      return ParagraphLine(text: String(text), hardText: String(text))
    }
    if text.last == "\\" {
      return ParagraphLine(text: String(text), hardText: String(LineScanner.trimmed(text.dropLast())))
    }
    return ParagraphLine(text: String(text), hardText: nil)
  }
}

extension BlockState.Container.Kind {
  var isList: Bool {
    if case .list = self { return true }
    return false
  }
}
