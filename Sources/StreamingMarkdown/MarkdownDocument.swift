/// The blocks of a markdown text, as the parser has them so far.
public struct MarkdownDocument: Equatable, Sendable {
  public var blocks: [MarkdownBlock]

  public init(blocks: [MarkdownBlock] = []) { self.blocks = blocks }

  public static let empty = MarkdownDocument()
}

public struct MarkdownBlock: Equatable, Sendable, Identifiable {
  /// The block's path of positions: "3" at the top level, "3.1.0" inside containers.
  public let id: String
  public let kind: Kind

  public init(id: String, kind: Kind) {
    self.id = id
    self.kind = kind
  }

  public enum Kind: Equatable, Sendable {
    /// The paragraph's inline source.
    case paragraph(String)
    /// `level` is 1...6.
    case heading(level: Int, text: String)
    case thematicBreak
    case code(language: String?, text: String, closed: Bool)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
  }
}

public struct MarkdownList: Equatable, Sendable {
  public let ordered: Bool
  /// 1 for an unordered list.
  public let start: Int
  public let items: [MarkdownListItem]

  public init(ordered: Bool, start: Int, items: [MarkdownListItem]) {
    self.ordered = ordered
    self.start = start
    self.items = items
  }
}

public struct MarkdownListItem: Equatable, Sendable, Identifiable {
  public let id: String
  /// nil: not a task item; false: unchecked; true: checked.
  public let task: Bool?
  public let blocks: [MarkdownBlock]

  public init(id: String, task: Bool?, blocks: [MarkdownBlock]) {
    self.id = id
    self.task = task
    self.blocks = blocks
  }
}

public struct MarkdownTable: Equatable, Sendable {
  public enum Alignment: Equatable, Sendable { case leading, center, trailing }

  public let alignments: [Alignment?]
  /// Inline source per cell.
  public let header: [String]
  /// Each row padded or cut to `header.count`.
  public let rows: [[String]]

  public init(alignments: [Alignment?], header: [String], rows: [[String]]) {
    self.alignments = alignments
    self.header = header
    self.rows = rows
  }
}
