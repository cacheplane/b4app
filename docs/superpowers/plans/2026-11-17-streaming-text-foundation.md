# Streaming Text Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reply's text streams evenly and is drawn as real markdown, and a token redraws one block instead of the transcript.

**Architecture:** A new Foundation-only target, `StreamingMarkdown`, holds an append-only block parser: finished blocks are frozen, the open tail is projected with guesses for unfinished syntax. In `WorkspaceUI`, one `@Observable` `MessageStream` per streaming message owns the received text, a paced reveal and a parser; a `MessageStreamStore` on `WorkspaceModel` replaces `ThreadDetail.liveText`. `MarkdownText` becomes a view over a `MarkdownDocument` with one `Equatable` view per block.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), Foundation's `AttributedString(markdown:)` for inline text. No new package.

**Spec:** `docs/superpowers/specs/2026-11-17-streaming-text-foundation-design.md`. Read it before any task; the plan argues from it. Read `AGENTS.md` too.

## Global Constraints

- `StreamingMarkdown` imports Foundation only. `WorkspaceUI` imports only `WorkspaceProtocol`, `WorkspaceClient` and `StreamingMarkdown`. Everything links on iOS.
- No wire, storage or sync change. `Sources/Coordinator`, `Sources/WorkspaceMirror/MirrorTransport.swift` and `Sources/WorkspaceProtocol` are not edited.
- Spacing, colours and type in views come from `LLA` and `LLAFont` tokens (`Sources/WorkspaceUI/Theme/`); no literal colours or font sizes in block views.
- Before every commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift` and `swift build`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Not built here (spec "Non-goals"): the activity line, syntax colouring, diff view, cross-block selection, remote images, raw HTML, math, footnotes, link reference definitions, setext headings, indented code blocks, lazy rows.
- Pacing values, verbatim from the spec: 60 ticks per second; step `max(1, ceil(backlog / 12))` characters on a grapheme boundary; remainder revealed within 150 ms of completion (9 ticks); no pacing under Reduce Motion or when the thread is off screen.
- Links: only `http`, `https` and `mailto` open.

## Review Focus

Inputs the spec implies but does not name, most likely first. Each has a test in the task that owns the code.

1. **CRLF line endings** (`\r\n`, and a delta that ends between `\r` and `\n`): same document as with `\n`. Task 1.
2. **One very long line with no newline** (minified JSON, 100,000 characters, streamed): the open-line projection stays within the linear budget and the row does not hang. Task 5.
3. **Deep nesting** (40 `>` in a row, lists 20 levels deep): no stack overflow; containers nest to depth 16 and deeper markers are literal text. Task 2.
4. **A reply that is empty or only whitespace**, live and settled: an empty document, a row that draws nothing, no crash. Tasks 1 and 8.
5. **A delta that splits a grapheme** (a ZWJ emoji sequence, a combining accent) with a reveal step landing where the split was: once the whole grapheme has arrived, a step never shows part of it. Task 6.

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/StreamingMarkdown/MarkdownDocument.swift` | The value model: `MarkdownDocument`, `MarkdownBlock`, list, item and table types |
| `Sources/StreamingMarkdown/MarkdownParser.swift` | The public parser: `push`, `finish`, `document`; line buffer; committed blocks |
| `Sources/StreamingMarkdown/BlockState.swift` | The open top-level block: container stack, open leaf, handling one completed line |
| `Sources/StreamingMarkdown/LineScanner.swift` | Pure line classifiers: fence open and close, heading, thematic break, list marker, quote marker, table row and delimiter row |
| `Sources/StreamingMarkdown/OpenLineProjection.swift` | What the unfinished line is drawn as; holds |
| `Sources/StreamingMarkdown/InlineProjection.swift` | Closing unfinished inline markup in a string |
| `Tests/StreamingMarkdownTests/Outline.swift` | Test helper: a document as indented text |
| `Tests/StreamingMarkdownTests/*Tests.swift` | One suite per task below |
| `Tests/StreamingMarkdownTests/Corpus/*.md` | Documents for the invariance tests |
| `Sources/WorkspaceUI/Streaming/MessageStream.swift` | One streaming message: received text, reveal, parser |
| `Sources/WorkspaceUI/Streaming/RevealTicker.swift` | The tick source protocol, `DisplayTicker`, `ManualTicker` |
| `Sources/WorkspaceUI/Streaming/MessageStreamStore.swift` | The open thread's streams, shown texts, settled-document cache |
| `Sources/WorkspaceUI/Markdown/MarkdownText.swift` | `MarkdownText` over a document; block views; `InlineText` |
| `Sources/WorkspaceUI/Markdown/MarkdownTableView.swift` | The table block |
| `Sources/WorkspaceUI/Markdown/LinkPolicy.swift` | Which link schemes open |

`CodeFence` and `Clipboard` stay in `TranscriptView.swift`. `Sources/WorkspaceUI/MarkdownBlocks.swift` and `Tests/WorkspaceUITests/MarkdownBlocksTests.swift` are deleted in Task 8.

Suggested pull requests: Tasks 1 to 5 (the parser, nothing uses it yet), then Tasks 6 to 9.

---

### Task 1: The target, the model, and leaf blocks

Paragraphs, headings, thematic breaks and fenced code, for text that is complete (`finish()` called). No guesses yet: until Task 4, `document` before `finish()` returns the committed blocks plus the open block as if its completed lines were all there was, ignoring the open line.

**Files:**
- Modify: `Package.swift` (add `.target(name: "StreamingMarkdown", swiftSettings: concurrency)`, a library product, and `.testTarget(name: "StreamingMarkdownTests", dependencies: ["StreamingMarkdown"], resources: [.copy("Corpus")], swiftSettings: concurrency)`). Check `.github/workflows` for an explicit list of test targets and add the new one where "everything else" is listed.
- Create: `Sources/StreamingMarkdown/MarkdownDocument.swift`, `MarkdownParser.swift`, `BlockState.swift`, `LineScanner.swift`
- Create: `Tests/StreamingMarkdownTests/Outline.swift`, `LeafBlockTests.swift`, `Corpus/.gitkeep`

**Interfaces:**
- Produces:

```swift
public struct MarkdownDocument: Equatable, Sendable {
  public var blocks: [MarkdownBlock]
  public static let empty: MarkdownDocument
}

public struct MarkdownBlock: Equatable, Sendable, Identifiable {
  public let id: String          // path of positions: "3", "3.1.0"
  public let kind: Kind
  public indirect enum Kind: Equatable, Sendable {
    case paragraph(String)                                   // inline source
    case heading(level: Int, text: String)                   // level 1...6
    case thematicBreak
    case code(language: String?, text: String, closed: Bool)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
  }
}

public struct MarkdownList: Equatable, Sendable {
  public let ordered: Bool
  public let start: Int          // 1 for unordered
  public let items: [MarkdownListItem]
}

public struct MarkdownListItem: Equatable, Sendable, Identifiable {
  public let id: String
  public let task: Bool?         // nil: not a task item; false: unchecked; true: checked
  public let blocks: [MarkdownBlock]
}

public struct MarkdownTable: Equatable, Sendable {
  public enum Alignment: Equatable, Sendable { case leading, center, trailing }
  public let alignments: [Alignment?]
  public let header: [String]    // inline source per cell
  public let rows: [[String]]    // each padded or cut to header.count
}

public struct MarkdownParser: Sendable {
  public init()
  public mutating func push(_ text: String)
  public mutating func finish()
  public var document: MarkdownDocument { get }
  public static func parse(_ text: String) -> MarkdownDocument   // push, finish, document
}
```

- Ids: a top-level block's id is its index. A quote's children are `<id>.<n>`; a list item is `<listId>.<n>`; an item's blocks are `<itemId>.<n>`.
- Paragraph text: lines are joined with one space (soft break). A line ending in two or more spaces or a backslash is a hard break: the marker is removed and the lines are joined with `\n`. Leading whitespace of each line and trailing whitespace of the last are dropped.
- Fence rules, moved from `MarkdownBlocks` (`Sources/WorkspaceUI/MarkdownBlocks.swift`): opens on three or more backticks or tildes indented at most three spaces; a backtick opener holding another backtick is not a fence; closes on at least as many of the same character and nothing else; `language` is the first word after the opener; code text is the lines between, joined by `\n`, exactly as written.
- `Outline.swift` (test target): `func outline(_ document: MarkdownDocument) -> String`, one line per block, two spaces of indent per level, ids omitted:

```
p "text"
h2 "text"
hr
code swift closed "line1\nline2"      // language "-" when nil; closed | open
quote
list ul                               // or: list ol 3
  item                                // or: item [ ] / item [x]
table l c r -                         // one mark per column; "-" for nil
  head "a" | "b"
  row "1" | "2"
```

- [ ] **Step 1: Write the failing tests** in `LeafBlockTests.swift`:

```swift
@Suite struct LeafBlockTests {
  private func parsed(_ text: String) -> String { outline(MarkdownParser.parse(text)) }
  private let fence = "```"

  @Test func paragraphsAreSplitByBlankLinesAndSoftBreaksAreSpaces() {
    #expect(parsed("one\ntwo\n\nthree") == "p \"one two\"\np \"three\"")
  }
  @Test func aHardBreakKeepsTheLineBreak() {
    #expect(parsed("one  \ntwo\\\nthree") == "p \"one\\ntwo\\nthree\"")
  }
  @Test func headingsTakeTheirLevelAndDropClosingHashes() {
    #expect(parsed("# A\n###### B ##\n####### C\n#D") == "h1 \"A\"\nh6 \"B\"\np \"####### C #D\"")
  }
  @Test func threeOrMoreMarksAloneAreAThematicBreak() {
    #expect(parsed("a\n\n---\n***\n_ _ _\n--") == "p \"a\"\nhr\nhr\nhr\np \"--\"")
  }
  @Test func aTitleThenDashesIsAParagraphAndABreakNotASetextHeading() {
    #expect(parsed("Title\n---") == "p \"Title\"\nhr")
  }
  @Test func aFenceIsCodeWithItsLanguageAndExactText() {
    #expect(parsed("Run:\n\(fence)bash\n  ls -la\n\n# not a heading\n\(fence)\nDone.")
      == "p \"Run:\"\ncode bash closed \"  ls -la\\n\\n# not a heading\"\np \"Done.\"")
  }
  @Test func tildeFencesAndLongerFencesHoldShorterOnes() {
    #expect(parsed("~~~\n\(fence)\n~~~") == "code - closed \"\(fence)\"")
    #expect(parsed("````\n\(fence)\n````") == "code - closed \"\(fence)\"")
  }
  @Test func aBacktickOpenerHoldingABacktickIsNotAFence() {
    #expect(parsed("\(fence)a`b") == "p \"\(fence)a`b\"")
  }
  @Test func anUnclosedFenceStaysCodeMarkedOpenAfterFinish() {
    #expect(parsed("\(fence)swift\nlet a") == "code swift open \"let a\"")
  }
  @Test func indentedTextIsAParagraphNotCode() {
    #expect(parsed("    let v = 1") == "p \"let v = 1\"")
  }
  @Test func blankEdgesAndEmptyTextGiveNoBlocks() {
    #expect(MarkdownParser.parse("") == .empty)
    #expect(MarkdownParser.parse(" \n\n\t\n") == .empty)
    #expect(MarkdownParser.parse("\n\nhi  \n\n") == MarkdownParser.parse("hi"))
  }
  @Test func crlfLineEndingsParseAsLf() {
    let text = "# A\r\n\r\n\(fence)\r\nx\r\n\(fence)\r\n"
    #expect(MarkdownParser.parse(text) == MarkdownParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n")))
    var split = MarkdownParser()
    split.push("a\r"); split.push("\nb"); split.finish()
    #expect(outline(split.document) == "p \"a b\"")
  }
  @Test func theLastLineIsNotDroppedWithoutATrailingNewline() {
    #expect(parsed("a\n\nb") == "p \"a\"\np \"b\"")
  }
  @Test func idsArePositionsAndCommittedBlocksKeepTheirValue() {
    var parser = MarkdownParser()
    parser.push("a\n\nb\n\n")
    let first = parser.document.blocks[0]
    parser.push("c\n\n")
    #expect(parser.document.blocks.map(\.id) == ["0", "1", "2"])
    #expect(parser.document.blocks[0] == first)
  }
}
```

- [ ] **Step 2: Run** `swift test --filter LeafBlockTests`. Expected: fails to compile (no `MarkdownParser`).
- [ ] **Step 3: Implement** the model, `Outline.swift`, `LineScanner` (static functions over `Substring`, each returning an optional parsed value), and the parser. `push` appends to a line buffer and hands each completed line (without its `\n` and any trailing `\r`) to the open block state; a line that closes the open top-level block moves it to `committed: [MarkdownBlock]`. A `\r` at the end of the buffer waits for the next push. `finish()` hands the buffer over as a last line and closes everything. Line dispatch order outside a fence: blank, thematic break, heading, fence opener, paragraph continuation.
- [ ] **Step 4: Run** `swift test --filter LeafBlockTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(markdown): StreamingMarkdown target with leaf blocks`.

---

### Task 2: Containers: quotes and lists

**Files:**
- Modify: `Sources/StreamingMarkdown/BlockState.swift`, `LineScanner.swift`
- Create: `Tests/StreamingMarkdownTests/ContainerTests.swift`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `.quote` and `.list` blocks. Rules the tests do not fully pin:
  - A list marker is `-`, `*` or `+`, or one to nine digits then `.` or `)`, followed by a space or the end of the line, indented less than the enclosing content column plus four.
  - An item's content column is the column of the first non-space character after the marker (marker width plus one when the rest is blank). A line belongs to the item when it is blank or indented to at least that column. A tab counts to the next multiple of four.
  - A different bullet character, or switching between bullet and ordered, starts a new list.
  - Task state: an item whose text begins `[ ] `, `[x] ` or `[X] `.
  - A blank line between items does not end the list. A list ends at a non-blank line that is not indented to the item's content column, is not a marker of the same list, and is not a lazy continuation.
  - Lazy continuation: a non-blank line that is not itself a block start, directly after a paragraph line inside a quote or item, continues that paragraph.
  - Containers nest to depth 16. A marker that would open a seventeenth level is paragraph text.

- [ ] **Step 1: Write the failing tests** in `ContainerTests.swift` (same `parsed` helper):

```swift
@Test func aBulletListHoldsItsItems() {
  #expect(parsed("- a\n- b") == "list ul\n  item\n    p \"a\"\n  item\n    p \"b\"")
}
@Test func anOrderedListKeepsItsStart() {
  #expect(parsed("3. a\n4. b") == "list ol 3\n  item\n    p \"a\"\n  item\n    p \"b\"")
}
@Test func aBlankLineBetweenItemsDoesNotSplitTheList() {
  #expect(parsed("- a\n\n- b") == parsed("- a\n- b"))
}
@Test func anItemHoldsFencedCodeAndASecondParagraph() {
  #expect(parsed("1. Run:\n\n   ```sh\n   ls\n   ```\n\n   Then stop.\n2. Next")
    == "list ol 1\n  item\n    p \"Run:\"\n    code sh closed \"ls\"\n    p \"Then stop.\"\n  item\n    p \"Next\"")
}
@Test func listsNestByIndent() {
  #expect(parsed("- a\n  - b\n    - c\n- d")
    == "list ul\n  item\n    p \"a\"\n    list ul\n      item\n        p \"b\"\n        list ul\n          item\n            p \"c\"\n  item\n    p \"d\"")
}
@Test func taskItemsCarryTheirState() {
  #expect(parsed("- [ ] a\n- [x] b\n- c") == "list ul\n  item [ ]\n    p \"a\"\n  item [x]\n    p \"b\"\n  item\n    p \"c\"")
}
@Test func aDifferentMarkerStartsANewList() {
  #expect(parsed("- a\n1. b") == "list ul\n  item\n    p \"a\"\nlist ol 1\n  item\n    p \"b\"")
}
@Test func anUnindentedParagraphAfterABlankLineEndsTheList() {
  #expect(parsed("- a\n\nb") == "list ul\n  item\n    p \"a\"\np \"b\"")
}
@Test func aQuoteHoldsBlocksIncludingListsAndQuotes() {
  #expect(parsed("> # T\n> - a\n> > deep") == "quote\n  h1 \"T\"\n  list ul\n    item\n      p \"a\"\n  quote\n    p \"deep\"")
}
@Test func aLazyLineContinuesTheParagraphInAQuoteOrItem() {
  #expect(parsed("> a\nb") == "quote\n  p \"a b\"")
  #expect(parsed("- a\nb") == "list ul\n  item\n    p \"a b\"")
}
@Test func aParagraphThenAQuoteAreSiblings() {   // cacheplane's `a\n> q` bug
  #expect(parsed("a\n> q") == "p \"a\"\nquote\n  p \"q\"")
}
@Test func aQuoteInsideAnItem() {
  #expect(parsed("- a\n  > q") == "list ul\n  item\n    p \"a\"\n    quote\n      p \"q\"")
}
@Test func twoSpacesTimesThreeAndATabIndentTheSame() {
  #expect(parsed("- a\n\t- b") == parsed("- a\n    - b"))
}
@Test func nestingStopsAtSixteenLevelsWithoutCrashing() {
  let deep = String(repeating: "> ", count: 40) + "x"
  let doc = MarkdownParser.parse(deep)
  #expect(outline(doc).split(separator: "\n").count == 17)      // 16 quotes and one paragraph
  #expect(outline(doc).hasSuffix("p \"" + String(repeating: "> ", count: 24) + "x\""))
  _ = MarkdownParser.parse((0..<20).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n"))
}
@Test func nestedIdsArePaths() {
  let doc = MarkdownParser.parse("a\n\n- x\n- y\n  > q")
  guard case .list(let list) = doc.blocks[1].kind else { Issue.record("not a list"); return }
  #expect(list.items.map(\.id) == ["1.0", "1.1"])
  #expect(list.items[1].blocks.map(\.id) == ["1.1.0", "1.1.1"])
}
```

- [ ] **Step 2: Run** `swift test --filter ContainerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the container stack in `BlockState`: for each line, match the open containers' continuation in order (a quote consumes `>` and one optional space; an item consumes its content column of indent), close the unmatched ones unless the line is a lazy continuation, then open new containers from the remainder, then hand the rest to the leaf logic of Task 1. Only the top-level block is committed to the parser; nested blocks are built when the top-level block closes or `document` is read.
- [ ] **Step 4: Run** `swift test --filter "ContainerTests|LeafBlockTests"`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(markdown): nested quotes and lists`.

---

### Task 3: Tables

**Files:**
- Modify: `Sources/StreamingMarkdown/BlockState.swift`, `LineScanner.swift`
- Create: `Tests/StreamingMarkdownTests/TableTests.swift`

**Interfaces:**
- Produces: `.table`. A table needs a header row (a line holding an unescaped `|`) followed by a delimiter row (cells of `-` with optional leading and trailing `:`), with the same cell count. Leading and trailing pipes are optional. Body rows follow until a blank line or a line that starts another block. A row is padded with empty cells or cut to the header's count. `\|` inside a cell is a literal pipe and does not split. A pipe inside a backtick code span does not split. Cell text is trimmed. Tables work inside quotes and items.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func aHeaderAndDelimiterRowMakeATable() {
  #expect(parsed("| a | b |\n|---|:-:|\n| 1 | 2 |") == "table - c\n  head \"a\" | \"b\"\n  row \"1\" | \"2\"")
}
@Test func alignmentsComeFromTheDelimiterRow() {
  #expect(parsed("a|b|c\n:--|--:|:-:").hasPrefix("table l r c"))
}
@Test func rowsArePaddedOrCutToTheHeader() {
  #expect(parsed("|a|b|\n|-|-|\n|1|\n|1|2|3|") == "table - -\n  head \"a\" | \"b\"\n  row \"1\" | \"\"\n  row \"1\" | \"2\"")
}
@Test func aHeaderWithNoDelimiterRowIsAParagraph() {
  #expect(parsed("| a | b |\nplain") == "p \"| a | b | plain\"")
}
@Test func aMismatchedDelimiterRowIsNotATable() {
  #expect(parsed("| a | b |\n|---|").hasPrefix("p "))
}
@Test func escapedPipesAndPipesInCodeDoNotSplit() {
  #expect(parsed("|a|b|\n|-|-|\n|x \\| y|`p|q`|") == "table - -\n  head \"a\" | \"b\"\n  row \"x | y\" | \"`p|q`\"")
}
@Test func aBlankLineEndsTheTable() {
  #expect(parsed("|a|\n|-|\n|1|\n\nafter").hasSuffix("p \"after\""))
}
@Test func aTableInsideAQuoteAndAnItem() {
  #expect(parsed("> |a|\n> |-|\n> |1|").hasPrefix("quote\n  table -"))
  #expect(parsed("- x\n\n  |a|\n  |-|\n  |1|").contains("    table -"))
}
```

- [ ] **Step 2: Run** `swift test --filter TableTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep a pending header on the leaf state: a paragraph's first line that scans as a table row is remembered; if the next line is a matching delimiter row the leaf becomes a table, otherwise it stays a paragraph.
- [ ] **Step 4: Run** `swift test --filter StreamingMarkdownTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(markdown): tables`.

---

### Task 4: The projection of the open line

`document` before `finish()` now includes the unfinished line, with the spec's guesses ("The projection" table). Computed on a copy of the open state on each read; never stored.

**Files:**
- Create: `Sources/StreamingMarkdown/OpenLineProjection.swift`, `InlineProjection.swift`
- Modify: `Sources/StreamingMarkdown/MarkdownParser.swift` (`document`)
- Create: `Tests/StreamingMarkdownTests/ProjectionTests.swift`, `InlineProjectionTests.swift`

**Interfaces:**
- Produces:

```swift
enum InlineProjection {
  /// `text` with unfinished inline markup closed, for drawing while it streams.
  static func closed(_ text: String) -> String
}
```

- `InlineProjection.closed` rules:
  - An unclosed `**`, `*`, `_`, `~~` or backtick run gets its closer appended at the end, innermost first, only when a non-space character directly follows the opener.
  - `_` between two alphanumerics never opens.
  - A trailing unmatched run with nothing after it is removed from the output (it is held).
  - `[text](` followed by anything without the closing `)` becomes `text`. `[text` with no `]` yet stays as written.
  - `![alt](…` unfinished becomes `alt`.
  - Text inside a closed or projected code span is not scanned.
- The projection applies `closed` to the open leaf's text only (the paragraph, heading or cell the open line is in), and only before `finish()`.
- Holds (the open line contributes nothing yet): a line that is so far only whitespace and one of `-`, `*`, `+`, `--`, `**`, `__`, `_`, digits, or digits then `.` or `)`; inside a fence, a line that is so far only one or two of the fence character (after allowed indent); the line after a pending table header while it could still be a delimiter row (only `|`, `-`, `:` and spaces).
- A held line still counts for containers: `> -` projects the quote.

- [ ] **Step 1: Write the failing tests.** `ProjectionTests.swift`, with a helper that pushes without finishing:

```swift
private func open(_ text: String) -> String {
  var parser = MarkdownParser(); parser.push(text); return outline(parser.document)
}
@Test func aHeadingAppearsAtItsMarker() {
  #expect(open("#") == "h1 \"\"")
  #expect(open("## Ti") == "h2 \"Ti\"")
}
@Test func aBareMarkerIsHeldAndAMarkerWithASpaceIsAnItem() {
  #expect(open("-") == "")
  #expect(open("1.") == "")
  #expect(open("- ") == "list ul\n  item")
  #expect(open("a\n\n1") == "p \"a\"")
  #expect(open("- [x] d") == "list ul\n  item [x]\n    p \"d\"")
}
@Test func twoDashesAreHeldAndThreeAreABreak() {
  #expect(open("a\n\n--") == "p \"a\"")
  #expect(open("a\n\n---") == "p \"a\"\nhr")
}
@Test func aQuoteAppearsAtItsMarker() {
  #expect(open("> q") == "quote\n  p \"q\"")
  #expect(open("> -") == "quote")
}
@Test func anOpenFenceIsCodeAndItsClosingRunNeverFlashes() {
  #expect(open("```sw") == "code - open \"\"")          // language is taken when the line completes
  #expect(open("```swift\nlet a") == "code swift open \"let a\"")
  #expect(open("```swift\nlet a\n``") == "code swift open \"let a\"")
  #expect(open("```swift\nlet a\n```") == "code swift closed \"let a\"")
}
@Test func aTableAppearsAtItsFirstClosedHeaderCell() {
  #expect(open("| Na") == "p \"| Na\"")
  #expect(open("| Name |") == "table -\n  head \"Name\"")
  #expect(open("| Name | Ag") == "table - -\n  head \"Name\" | \"Ag\"")
}
@Test func thePendingHeaderStaysATableWhileTheDelimiterRowArrives() {
  #expect(open("| a | b |\n|--") == "table - -\n  head \"a\" | \"b\"")
  #expect(open("| a | b |\n|---|---|\n") == "table - -\n  head \"a\" | \"b\"")
}
@Test func aHalfTypedBodyRowIsARowPaddedToTheHeader() {
  #expect(open("| a | b |\n|---|---|\n| 1") == "table - -\n  head \"a\" | \"b\"\n  row \"1\" | \"\"")
}
@Test func aHeaderWhoseNextLineIsNotADelimiterRevertsToAParagraph() {
  #expect(open("| a | b |\nplain\n\n") == "p \"| a | b | plain\"")
}
@Test func unfinishedInlineMarkupIsClosedInTheOpenLeafOnly() {
  #expect(open("done **b\n\nnow **bo") == "p \"done **b\"\np \"now **bo**\"")
}
@Test func finishRemovesEveryGuess() {
  var parser = MarkdownParser(); parser.push("**bold"); parser.finish()
  #expect(outline(parser.document) == "p \"**bold\"")
  parser = MarkdownParser(); parser.push("-"); parser.finish()
  #expect(outline(parser.document) == "p \"-\"")
}
@Test func readingTheDocumentDoesNotChangeTheParser() {
  var a = MarkdownParser(), b = MarkdownParser()
  a.push("| a |"); _ = a.document; a.push("\nplain\n"); a.finish()
  b.push("| a |\nplain\n"); b.finish()
  #expect(a.document == b.document)
}
```

`InlineProjectionTests.swift`:

```swift
@Test func closesUnfinishedEmphasis() {
  #expect(InlineProjection.closed("a **bo") == "a **bo**")
  #expect(InlineProjection.closed("a *it") == "a *it*")
  #expect(InlineProjection.closed("~~gone") == "~~gone~~")
  #expect(InlineProjection.closed("**bold *it") == "**bold *it***")
  #expect(InlineProjection.closed("run `ls -") == "run `ls -`")
}
@Test func leavesArithmeticAndFinishedMarkupAlone() {
  #expect(InlineProjection.closed("2 * 3") == "2 * 3")
  #expect(InlineProjection.closed("**done** and") == "**done** and")
  #expect(InlineProjection.closed("snake_case_name") == "snake_case_name")
  #expect(InlineProjection.closed("`a * b`") == "`a * b`")
}
@Test func holdsATrailingOpenerWithNothingAfterIt() {
  #expect(InlineProjection.closed("a **") == "a ")
  #expect(InlineProjection.closed("a `") == "a ")
}
@Test func aHalfTypedLinkShowsItsTextOnly() {
  #expect(InlineProjection.closed("see [the docs](https://exa") == "see the docs")
  #expect(InlineProjection.closed("see [the docs](https://example.com) now") == "see [the docs](https://example.com) now")
  #expect(InlineProjection.closed("see [the do") == "see [the do")
  #expect(InlineProjection.closed("![a cat](http") == "a cat")
}
```

- [ ] **Step 2: Run** `swift test --filter "ProjectionTests|InlineProjectionTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** `document` copies the open block state, applies the open line to the copy through the same line handler with a `projecting` flag (which enables the holds and the first-closed-cell table rule), builds the blocks, and applies `InlineProjection.closed` to the open leaf's text. `InlineProjection.closed` is one left-to-right scan keeping a stack of open delimiters; it must be linear in the text's length.
- [ ] **Step 4: Run** `swift test --filter StreamingMarkdownTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(markdown): project the unfinished line`.

---

### Task 5: Invariance, adversarial input and the linear budget

**Files:**
- Create: `Tests/StreamingMarkdownTests/Corpus/` documents: `leafs.md`, `nested-lists.md`, `code-in-list.md`, `quotes.md`, `tables.md`, `inline.md`, `mixed-reply.md`, `crlf.md` (written with `\r\n`), plus at least three real assistant replies copied from `Tests/ClaudeAdapterTests/Fixtures/`, `Tests/CodexAdapterTests/Fixtures/` or `docs/research/2026-11-14-agent-chat-hill-climb.md` captures
- Create: `Tests/StreamingMarkdownTests/InvarianceTests.swift`, `StressTests.swift`

**Interfaces:**
- Consumes: `MarkdownParser`.
- Produces: `func corpus() -> [(name: String, text: String)]` (test target, reads `Bundle.module`).

- [ ] **Step 1: Write the tests.** `InvarianceTests.swift`:

```swift
@Test(arguments: corpus().map(\.name)) func everyTwoWaySplitEndsInTheSameDocument(name: String)
// for each index i in text.indices: push(prefix); push(suffix); finish() == MarkdownParser.parse(text)

@Test(arguments: corpus().map(\.name)) func oneCharacterAtATimeEndsInTheSameDocument(name: String)

@Test(arguments: corpus().map(\.name)) func seededRandomSplitsEndInTheSameDocument(name: String)
// 200 splittings from a SplitMix64 seeded with the document's name hash; chunk sizes 1...40

@Test(arguments: corpus().map(\.name)) func everyPrefixProjectsTheSameHoweverItArrived(name: String)
// for each prefix: one push vs character pushes give equal `document` (no finish)

@Test(arguments: corpus().map(\.name)) func aCommittedBlockNeverChanges(name: String)
// push one character at a time; once blocks[i] has a successor at top level, blocks[i] equals its
// value in the final document. The one allowed exception is none: a pending table header is not
// committed until its next line is known.
```

`StressTests.swift`:

```swift
@Test func adversarialInputNeverCrashes()
// 500 strings of length 0...400 drawn from "*_`[]()!\\#>|-~:. \n\t\r0123456789ax" (SplitMix64, fixed seed):
// push in random chunks, read `document` after every push, finish.

@Test func oneHundredThousandCharactersOneAtATimeStayLinear()
// mixed-reply.md repeated to 100,000 characters, pushed per character, reading `document` every 16
// pushes. Measure with ContinuousClock. Assert total < 4 s in debug and that the second half takes
// < 3x the first half (growth check).

@Test func oneLongLineWithNoNewlineStaysLinear()
// 100,000 characters of `{"k":"v **x** `y` [z](u)",` repeated, pushed in 64-character chunks,
// reading `document` after each push. Assert total < 4 s in debug.
```

- [ ] **Step 2: Run** `swift test --filter "InvarianceTests|StressTests"`. Fix any parser defect the tests find in the task that owns it (add a named regression test there). If `oneLongLineWithNoNewlineStaysLinear` fails because each read rescans the whole open line, cache the inline scan state for the open line in the parser so each push scans only the new characters.
- [ ] **Step 3: Run** `swift test --filter StreamingMarkdownTests`. Expected: PASS. Note the two stress timings for the gate record (Task 9).
- [ ] **Step 4: Commit** `test(markdown): split invariance and linear-time checks`.

---

### Task 6: `MessageStream` and the paced reveal

**Files:**
- Modify: `Package.swift` (`WorkspaceUI` depends on `StreamingMarkdown`)
- Create: `Sources/WorkspaceUI/Streaming/RevealTicker.swift`, `MessageStream.swift`
- Create: `Tests/WorkspaceUITests/MessageStreamTests.swift`

**Interfaces:**
- Consumes: `MarkdownParser`, `MarkdownDocument`.
- Produces:

```swift
@MainActor protocol RevealTicker: AnyObject {
  var onTick: (@MainActor () -> Void)? { get set }
  func start()      // idempotent
  func stop()       // idempotent
}
@MainActor final class DisplayTicker: RevealTicker    // 60 ticks per second while started
@MainActor final class ManualTicker: RevealTicker {   // tests
  private(set) var running: Bool
  func fire(_ count: Int = 1)                          // calls onTick while running
}

enum RevealPacing: Sendable { case paced, immediate }

@MainActor @Observable final class MessageStream {
  enum Phase: Sendable { case streaming, complete }
  init(pacing: RevealPacing, ticker: any RevealTicker, revealedPrefix: String = "")
  private(set) var document: MarkdownDocument
  private(set) var phase: Phase
  var pacing: RevealPacing            // set to .immediate: everything received is revealed now
  var received: String { get }
  var shown: String { get }           // the revealed text
  func append(_ delta: String)
  func complete(finalText: String)
}
```

- `revealedPrefix`: text the reader has already seen for this item. The first appended text is revealed at once up to the length of the prefix it shares with `revealedPrefix`.
- Only `document` and `phase` are observed; mark the text, parser and counters `@ObservationIgnored`.
- `complete`: if `finalText` starts with `received`, the rest is appended; if `received` starts with `finalText` (the stale case), nothing is removed; otherwise a new parser takes `finalText` and all of it is revealed at once. Then the step becomes `max(step, ceil(backlogAtCompletion / 9))`, and when the backlog reaches zero the parser's `finish()` is called once, `phase` becomes `.complete` and the ticker stops. A second `complete` does nothing.
- After completion, `append` is ignored (the store opens a new stream instead, Task 7).

- [ ] **Step 1: Write the failing tests** (`@Suite @MainActor struct MessageStreamTests`):

```swift
@Test func immediatePacingShowsEachDeltaAtOnce() {
  let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
  stream.append("# Hi\n\nthe"); #expect(stream.shown == "# Hi\n\nthe")
  #expect(stream.document.blocks.count == 2)
}
@Test func pacedRevealMovesByATwelfthOfTheBacklogPerTick() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  stream.append(String(repeating: "a", count: 120))
  #expect(stream.shown.isEmpty && ticker.running)
  ticker.fire(); #expect(stream.shown.count == 10)        // ceil(120 / 12)
  ticker.fire(); #expect(stream.shown.count == 20)        // 10 + ceil(110 / 12)
}
@Test func aSmallBacklogTricklesOneCharacterPerTickAndTheTickerStopsWhenEmpty() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  stream.append("abc"); ticker.fire(3)
  #expect(stream.shown == "abc" && !ticker.running)
  stream.append("d"); #expect(ticker.running)
}
@Test func completionDrainsWithinNineTicksAndFinishesOnce() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  stream.append(String(repeating: "a", count: 900) + " **bo")
  stream.complete(finalText: stream.received)
  #expect(stream.phase == .streaming)
  ticker.fire(9)
  #expect(stream.shown == stream.received && stream.phase == .complete && !ticker.running)
  #expect(stream.document == MarkdownParser.parse(stream.received))   // no guess left: "**bo" literal
}
@Test func aFinalTextThatExtendsTheReceivedTextIsAppended() {
  let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
  stream.append("Hello"); stream.complete(finalText: "Hello there")
  #expect(stream.shown == "Hello there" && stream.phase == .complete)
}
@Test func aFinalTextThatDiffersReplacesTheTextAtOnce() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  stream.append("Hello wor"); ticker.fire(2); stream.complete(finalText: "Goodbye")
  #expect(stream.shown == "Goodbye" && stream.phase == .complete)
}
@Test func aStaleFinalTextRemovesNothing() {
  let stream = MessageStream(pacing: .immediate, ticker: ManualTicker())
  stream.append("Hello there"); stream.complete(finalText: "Hel")
  #expect(stream.shown == "Hello there" && stream.phase == .complete)
  stream.complete(finalText: ""); stream.append("x")
  #expect(stream.shown == "Hello there")
}
@Test func aRevealedPrefixIsNotReplayed() {
  let ticker = ManualTicker()
  let stream = MessageStream(pacing: .paced, ticker: ticker, revealedPrefix: "Hello the")
  stream.append("Hello there, friend")
  #expect(stream.shown == "Hello the")
  let other = MessageStream(pacing: .paced, ticker: ManualTicker(), revealedPrefix: "Hello")
  other.append("Goodbye"); #expect(other.shown.isEmpty)
}
@Test func switchingToImmediateRevealsEverything() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  stream.append(String(repeating: "a", count: 500)); stream.pacing = .immediate
  #expect(stream.shown.count == 500 && !ticker.running)
}
@Test func aRevealNeverCutsAGrapheme() {
  let ticker = ManualTicker(); let stream = MessageStream(pacing: .paced, ticker: ticker)
  let family = "👨‍👩‍👧‍👦"; let scalars = Array(family.unicodeScalars)
  stream.append(String(String.UnicodeScalarView(scalars.prefix(3))))     // a delta ending mid-grapheme
  stream.append(String(String.UnicodeScalarView(scalars.dropFirst(3))) + "e\u{301}")
  var seen: [String] = []
  while ticker.running { ticker.fire(); seen.append(stream.shown) }
  #expect(seen.allSatisfy { $0.isEmpty || $0 == family || $0 == family + "e\u{301}" })
}
```

- [ ] **Step 2: Run** `swift test --filter MessageStreamTests`. Expected: fails to compile.
- [ ] **Step 3: Implement.** The stream keeps `received: String` and a revealed `String.Index`; a tick advances the index by the step counted in `Character`s (so never inside a grapheme) and pushes that slice to the parser, then sets `document`. The index stays valid when a later delta extends the last grapheme, because a `Character` boundary is always a scalar boundary; the slice pushed to the parser is `received[revealed...]` up to the new index. `DisplayTicker` may be a `Task` on the main actor sleeping `1/60` s per loop; it holds `onTick` weakly enough that a discarded stream stops ticking.
- [ ] **Step 4: Run** `swift test --filter MessageStreamTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(ui): MessageStream with paced reveal`.

---

### Task 7: `MessageStreamStore` and the model

Replaces `ThreadDetail.liveText`. Views still draw as before after this task: `TranscriptRow` reads the stream's `shown` text where it read `liveText`.

**Files:**
- Create: `Sources/WorkspaceUI/Streaming/MessageStreamStore.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (`ThreadDetail.liveText` at `:75` removed; the reload at `:1147-1151`; `applyToDetail` at `:1868-1907`; wherever `detail` is set to another thread or to nil, and the account reset)
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (`:161` and `:236`, `TranscriptRow.liveText`), `Sources/WorkspaceUI/ThreadsView.swift:119-123` (pass `model.streams`)
- Create: `Tests/WorkspaceUITests/MessageStreamStoreTests.swift`
- Modify: `Tests/WorkspaceUITests/MirrorModelTests.swift` (21 uses of `liveText`), `DenseTranscriptViewTests.swift` (17), `SnapshotTests.swift` (1)

**Interfaces:**
- Consumes: `MessageStream`, `RevealTicker`, `RevealPacing`.
- Produces:

```swift
@MainActor @Observable public final class MessageStreamStore {
  public init()                                                      // DisplayTicker, .paced
  init(pacing: RevealPacing, makeTicker: @escaping @MainActor () -> any RevealTicker)
  public var pacing: RevealPacing                                     // applied to every open stream
  func append(_ delta: String, to nativeItemId: String)
  func complete(_ nativeItemId: String, finalText: String)
  func turnFinished()            // completes every open stream with its received text; forgets shown texts
  func reset()                   // another thread, no thread, or another account
  func stream(for nativeItemId: String) -> MessageStream?             // while the turn runs
  func isStreaming(_ nativeItemId: String) -> Bool                    // phase == .streaming
  func text(for item: DisplayItem) -> String                          // what the row draws (until Task 8)
  var revision: Int { get }      // observed; bumps on every reveal of any stream (for the scroll follower)
}
extension WorkspaceModel { public var streams: MessageStreamStore { get } }
```

- Rules ("Never less than was shown" in the spec):
  - `append` to an id with no stream, or whose stream is complete, opens a new stream with `revealedPrefix:` the last stream's `shown` text for that id (empty if none).
  - `complete` on an id with no stream does nothing.
  - `text(for:)` and (Task 8) `document(for:)`: if the item has a `nativeItemId` with a stream and the stored text (`item.payload["text"]`) is a strict prefix of the stream's `shown` text or equal to it, the stream wins; if the stream is still streaming, the stream wins; otherwise the stored text wins. After `turnFinished()` there are no streams, so the stored text wins.
  - The dictionary of streams is observed (a row re-evaluates when its stream appears or goes). `revision` is observed. Everything else is `@ObservationIgnored`.
- `WorkspaceModel.applyToDetail`: `.messageDelta` calls `streams.append` and returns without assigning `detail`. `.messageCompleted` calls `streams.complete(nativeId, finalText: item.payload["text"]?.stringValue ?? "")` after the upsert; `.toolCompleted` no longer touches text. `.turnFinished` calls `streams.turnFinished()`. The reload of the same thread mid-reply (`:1147`) leaves the store alone; opening another thread, closing the detail, and the account reset call `streams.reset()`.

- [ ] **Step 1: Write the failing tests** in `MessageStreamStoreTests.swift` (`@MainActor`; `item(_ native: String, text: String) -> DisplayItem` builds an assistant `agentMessage`; store built with `.immediate` unless noted):

```swift
@Test func aDeltaOpensAStreamAndTheRowDrawsItsText() {
  store.append("Hel", to: "m1"); store.append("lo", to: "m1")
  #expect(store.text(for: item("m1", text: "")) == "Hello" && store.isStreaming("m1"))
}
@Test func aCompletionWithTheFullTextHandsOverToTheStoredItem() {
  store.append("Hello", to: "m1"); store.complete("m1", finalText: "Hello there")
  #expect(!store.isStreaming("m1"))
  #expect(store.text(for: item("m1", text: "Hello there")) == "Hello there")
}
@Test func aStaleCompletionDoesNotBlankTheRow() {                 // the phone's gap
  store.append("Hello there", to: "m1"); store.complete("m1", finalText: "")
  #expect(store.text(for: item("m1", text: "")) == "Hello there")
}
@Test func aWholeTextDeltaAfterAGapContinuesFromTheReadersPlace() {
  let ticker = ManualTicker()
  let store = MessageStreamStore(pacing: .paced, makeTicker: { ticker })
  store.append("Hello there", to: "m1"); ticker.fire(11)
  store.complete("m1", finalText: ""); ticker.fire(9)
  store.append("Hello there, friend", to: "m1")
  #expect(store.stream(for: "m1")?.shown == "Hello there" && store.isStreaming("m1"))
}
@Test func theStoredTextWinsOnceTheTurnFinishes() {
  store.append("Hello there", to: "m1"); store.turnFinished()
  #expect(store.stream(for: "m1") == nil)
  #expect(store.text(for: item("m1", text: "Hello")) == "Hello")
}
@Test func aStoredTextThatDivergesFromACompletedStreamWins() {
  store.append("Hello", to: "m1"); store.complete("m1", finalText: "Hello")
  #expect(store.text(for: item("m1", text: "Rewritten")) == "Rewritten")
}
@Test func resetForgetsEverything()                               // append, reset, stream(for:) == nil
@Test func changingPacingAppliesToOpenStreams()                   // paced store, append 500, pacing = .immediate, shown.count == 500
@Test func revisionBumpsOnEachReveal()
```

Add to `MirrorModelTests` (or the suite that already drives `WorkspaceModel` with events; follow its existing helpers):

```swift
@Test func aDeltaDoesNotReassignTheOpenThreadsDetail()
// withObservationTracking { _ = model.detail } onChange: { changed = true }; apply a message.delta
// event; #expect(!changed); #expect(model.streams.text(for: thatItem) == "the delta")
```

- [ ] **Step 2: Run** `swift test --filter MessageStreamStoreTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the store and the model changes. Give `WorkspaceModel` a `streams` property (an initializer parameter with a default, so tests pass an immediate store).
- [ ] **Step 4: Port the existing tests.** Every test that set or read `detail.liveText` now goes through the model's store built with `.immediate` pacing: a set becomes `streams.append(text, to: id)`, a read becomes `streams.stream(for: id)?.shown` or `streams.text(for: item)`. Assertions stay as they are. `TranscriptView` and `TranscriptContent` take `streams: MessageStreamStore`; `TranscriptRow` takes the text from `streams.text(for: item)` and `streaming` from `streams.isStreaming`. Remove `.onChange(of: detail.liveText)`; in its place add a zero-size leaf view inside the scroll content that reads `streams.revision` and calls `follow` on change (the spec allows this leaf; `TranscriptView.body` itself must not read the store's per-token state).
- [ ] **Step 5: Run** `swift test --filter WorkspaceUITests`. Expected: PASS, including `TranscriptScrollTests` and the snapshots unchanged.
- [ ] **Step 6: Commit** `feat(ui): streams live outside ThreadDetail`.

---

### Task 8: The block views

**Files:**
- Create: `Sources/WorkspaceUI/Markdown/MarkdownText.swift`, `MarkdownTableView.swift`, `LinkPolicy.swift`
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (remove `MarkdownText` and `MarkdownProse` at `:443-489`; `TranscriptRow` at `:405-413`; `TranscriptView` sets the store's pacing)
- Modify: `Sources/WorkspaceUI/Streaming/MessageStreamStore.swift` (`document(for:)`, the settled cache; remove `text(for:)` if nothing else uses it)
- Delete: `Sources/WorkspaceUI/MarkdownBlocks.swift`, `Tests/WorkspaceUITests/MarkdownBlocksTests.swift`
- Create: `Tests/WorkspaceUITests/MarkdownViewTests.swift`, `LinkPolicyTests.swift`
- Modify: `Tests/WorkspaceUITests/CodeFenceViewTests.swift`, `DenseTranscriptViewTests.swift` (two paced scroll tests), any other user of `MarkdownText(text:)`

**Interfaces:**
- Consumes: `MarkdownDocument`, `MarkdownParser.parse`, `MessageStreamStore`.
- Produces:

```swift
struct MarkdownText: View, Equatable {
  let document: MarkdownDocument
  var streaming = false
  init(document: MarkdownDocument, streaming: Bool = false)
  init(text: String, streaming: Bool = false)      // MarkdownParser.parse(text); for callers with settled text
}
struct MarkdownBlockView: View, Equatable { let block: MarkdownBlock; let streaming: Bool }
struct InlineText: View, Equatable { let source: String }   // AttributedString(markdown:) inline-only, links filtered

enum LinkPolicy {
  static func opens(_ url: URL) -> Bool           // scheme is http, https or mailto, case-insensitive
  static func filtered(_ text: AttributedString) -> AttributedString   // removes .link from runs that do not open
}

extension MessageStreamStore {
  func document(for item: DisplayItem) -> MarkdownDocument
  // Same choice as text(for:). The stream's document when the stream wins; otherwise
  // MarkdownParser.parse(stored text), cached by item id and text in an @ObservationIgnored dictionary
  // that reset() clears. On completion, when the final text equals the stream's received text, the
  // stream's document is stored as that cache entry.
}
```

- View decisions:
  - `MarkdownText`: `VStack(alignment: .leading, spacing: LLA.Space.m)` of `MarkdownBlockView(...).equatable()` in a `ForEach` keyed by `block.id`.
  - Paragraph: `InlineText` with `.llaBody()`, `.lineSpacing(4)`, `.textSelection(.enabled)`, as `MarkdownProse` has today.
  - Heading: `InlineText` in the three largest text styles `LLAFont` already defines for content (read `Sources/WorkspaceUI/Theme/` and pick existing styles; level 1, level 2, levels 3 to 6); `.accessibilityAddTraits(.isHeader)`.
  - Thematic break: a 1 pt rule in `LLA.Color.rule`.
  - Code: `CodeFence(language:code:copyable: closed || !streaming)`.
  - Quote: an `HStack` with a 2 pt `LLA.Color.rule` bar and the child blocks in `LLA.Color.muted`.
  - List: one row per item: a marker column (a bullet, the number `start + index` with a `.`, or a checkbox symbol with `accessibilityLabel` "Done" or "Not done") right-aligned in a fixed-width column with tabular digits, then the item's blocks in a `VStack`. Nested lists indent because they sit in the content column.
  - Table (`MarkdownTableView`): a `Grid` with `LLA.Space.m` horizontal and `LLA.Space.s` vertical cell padding, header cells in the body font's semibold weight, a `LLA.Color.rule` hairline under the header and between rows, each cell an `InlineText` aligned by its column; wrapped in `ScrollView(.horizontal)` with the grid's `fixedSize(horizontal: true, vertical: true)`, as `CodeFence` scrolls.
  - `InlineText` caches nothing itself: its `Equatable` conformance keeps a frozen block from re-parsing. It falls back to plain `Text(source)` when Foundation rejects the source.
  - `TranscriptRow` for `agentMessage`: `MarkdownText(document: streams.document(for: item), streaming: ...)`. The `.trimmingCharacters` call goes (spec "Blank edges"). An empty document draws nothing.
  - `TranscriptView` sets `streams.pacing` from `@Environment(\.accessibilityReduceMotion)` (`.immediate` when on, `.paced` otherwise) on appear and on change, and to `.immediate` on disappear.

- [ ] **Step 1: Write the failing tests.** `LinkPolicyTests.swift`:

```swift
@Test func onlyWebAndMailLinksOpen() {
  for good in ["https://example.com", "HTTP://example.com", "mailto:a@example.com"] { #expect(LinkPolicy.opens(URL(string: good)!)) }
  for bad in ["javascript:alert(1)", "file:///etc/passwd", "b4app://x", "tel:123", "data:text/html,x"] { #expect(!LinkPolicy.opens(URL(string: bad)!)) }
}
@Test func aLinkThatDoesNotOpenKeepsItsTextAndLosesItsLink() {
  let parsed = try! AttributedString(markdown: "[a](file:///x) [b](https://example.com)")
  let filtered = LinkPolicy.filtered(parsed)
  #expect(String(filtered.characters) == "a b")
  #expect(filtered.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
}
```

`MarkdownViewTests.swift` (macOS, hosted with `NSHostingView` as `CodeFenceViewTests` does; `size(_:width:)` copied from there):

```swift
@Test func everyBlockKindLaysOutWithinTheColumn()
// one document using every kind (heading, paragraph, nested list, task list, quote, table, code,
// break): fittingSize.width <= 420.5 at width 420, height > 0.
@Test func aWideTableScrollsInsideItsBlock()
// a 12-column table at width 320: width <= 320.5.
@Test func anEmptyDocumentDrawsNothing()
// MarkdownText(document: .empty) and MarkdownText(text: " \n") have height 0.
@Test func aSoftBreakIsASpaceAndAHardBreakIsALine()
// height of "one\ntwo" == height of "one two"; height of "one  \ntwo" > height of "one two".
@Test func aStreamedReplyAndTheSameReplyFromHistoryDrawTheSame()
// stream mixed-reply text into an immediate store, complete with the same text plus "\n\n", then
// compare store.document(for: liveItem) with MarkdownParser.parse(text) (equal), and their sizes.
@Test func aSettledDocumentIsParsedOnce()
// store.document(for: item) twice returns equal values and the second call does not re-parse
// (assert through a parse counter the store exposes to tests, `settledParses`).
@Test func aTokenDoesNotRerunTheGrouping()
// host a TranscriptView over a 150-item detail with one streaming item; record
// DenseTranscript's projection calls through a test counter; append 50 deltas with fired ticks;
// the counter did not move.
```

For the last test add an internal, test-only counter to the projection entry points in `DenseTranscript.swift` (`nonisolated(unsafe) static var projections = 0` behind `#if DEBUG`), incremented in `plain(items:turns:)` and `entries(items:turns:open:)`.

In `DenseTranscriptViewTests.swift`, beside `TranscriptScrollTests`, using its existing harness with a paced store and a `ManualTicker`:

```swift
@Test func aPinnedReaderStaysAtTheEndThroughAPacedReveal()
// append a reply taller than the viewport; fire ticks until the ticker stops, laying out after each;
// after every tick the distance from the end is <= 8 pt.
@Test func aHeldReaderIsNotMovedByAPacedReveal()
// scroll up to hold; append and fire as above; the content offset does not change.
```

- [ ] **Step 2: Run** `swift test --filter "LinkPolicyTests|MarkdownViewTests"`. Expected: fails to compile.
- [ ] **Step 3: Implement** the views, `LinkPolicy`, `document(for:)` and the cache; switch `TranscriptRow`; delete `MarkdownBlocks.swift`, `MarkdownBlocksTests.swift`, `MarkdownProse`.
- [ ] **Step 4: Update `CodeFenceViewTests`.** `MarkdownBlocks.split(...)` assertions become `MarkdownParser.parse(...)` outline-free equivalents (compare `blocks.map(\.kind)`); `aReplyWithNoFenceIsDrawnAsBefore` compares `MarkdownText(text:)` with itself built from a document (the "one text" special case is gone) or is removed if it then asserts nothing.
- [ ] **Step 5: Run** `swift test --filter WorkspaceUITests`. Expected: PASS except snapshots whose replies hold block markdown; inspect each changed image, then re-record them the way `SnapshotTests.swift` documents (`B4APP_SNAPSHOT_DIR`).
- [ ] **Step 6: Run** `./Scripts/generate-project.sh` and both `xcodebuild build` commands from `AGENTS.md` ("Commands"). Expected: both build.
- [ ] **Step 7: Commit** `feat(ui): draw replies as block markdown`.

---

### Task 9: Captures, measurements and records

**Files:**
- Modify: `Tests/WorkspaceUITests/SnapshotTests.swift` (new captures), `docs/screenshots/`
- Create: `docs/verification/2026-11-17-streaming-text-foundation.md` (use the day the gate runs), `docs/decisions/D-NNN-streaming-text-foundation.md`
- Modify: `docs/milestones.md`, `docs/research/2026-11-14-agent-chat-hill-climb.md` (defect 17's row), `AGENTS.md` ("Layout": one bullet for `Sources/StreamingMarkdown` and `Sources/WorkspaceUI/Streaming/`)

- [ ] **Step 1: Add snapshots:** one reply using every construct, in light and dark, normal and dense, at the Mac column and at a phone width, following the pattern of `ListSnapshotTests.denseThreads`. Save the captures as `docs/screenshots/transcript-markdown-*`.
- [ ] **Step 2: Measure, release build.** `swift test -c release --filter StressTests` for the parser timings. For frame time, run the Mac app (`xcodebuild ... -configuration Release`) against the fake Claude runtime streaming a long reply into a thread of at least 150 rows, and record the main-thread time per frame with Instruments' SwiftUI or Time Profiler template; repeat on an iPhone Simulator. Budget: no frame over 16 ms from our code on the Mac. If the budget is missed, stop and report rather than tuning blindly.
- [ ] **Step 3: Tune the pacing on a live stream** (`B4APP_LIVE_CLAUDE=1` session or the owner's Mac): confirm `12` and `9` read as even flow with no felt lag; change them only with the owner's agreement, and update the spec's line and the constants together.
- [ ] **Step 4: Write the gate record** (first line `## YYYY-MM-DD: Streaming text foundation`): what was run, the timings, what was not verified (name the iPhone hardware and VoiceOver gaps plainly).
- [ ] **Step 5: Write the decision** with the number from `Scripts/docs-index.sh --next`, taken when the pull request opens: the parser and its deviations from CommonMark, the per-message owner, the paced reveal and its numbers, the link policy, the gap rule on the phone; "amends D-236"; notes that D-237's per-token cost no longer applies to text.
- [ ] **Step 6: Run** `Scripts/docs-index.sh --check`, `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift build`, `swift test`. Expected: all pass.
- [ ] **Step 7: Commit** `docs: streaming text foundation gate and decision`.
