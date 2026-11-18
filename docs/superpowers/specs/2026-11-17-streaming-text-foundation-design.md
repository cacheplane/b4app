# Streaming text foundation for the transcript: design

Date: 2026-11-17. Status: draft for the owner's approval. Nothing here is built.

## Intent

The transcript's renderer is new and raw. The owner wants two things from it: text that streams smoothly, and agent activity (tools, sub-agents, steps) collapsed to one quiet line that still shows the agent is working. He chose to start with a new foundation rather than patch the current views.

This document is the first of two. It covers the text half: how a reply's text gets from a delta to the screen. The activity line is the second design, written after this one is approved, and it builds on the per-message owner introduced here.

The foundation carries over what threadplane (`~/repos/angular-agent-framework`) and its parser (`~/repos/cacheplane/packages/partial-markdown`) learned, as a design, not as a translation.

## How it works today

- `WorkspaceModel.applyToDetail` (`Sources/WorkspaceUI/WorkspaceModel.swift:1869`) appends each `message.delta` to `ThreadDetail.liveText[itemId]` and reassigns `detail`. `detail` is one observed value, so every token re-runs the grouping over all items and re-evaluates up to 150 rows (D-237 states this cost). Nothing coalesces or paces deltas.
- `MarkdownText` (`Sources/WorkspaceUI/TranscriptView.swift:445`) re-splits the whole reply on each change with `MarkdownBlocks.split`, a fence splitter. Prose goes through `AttributedString(markdown:)` with inline-only syntax, so headings, lists, tables and quotes show as literal text (D-236 "Not done"; defect 17 in `docs/research/2026-11-14-agent-chat-hill-climb.md`).
- On the phone, deltas come through the relay in bursts. After a relink the Mac sends a catch-up with its whole text so far; `MirrorTransport.relayed` (`Sources/WorkspaceMirror/MirrorTransport.swift:734`) compares it with what the model was given and passes on only the unseen rest as an ordinary delta. On a gap or a mismatch it instead sends the model a `message.completed` carrying the item as last known (`cleared`, often with stale or empty text), and later an ordinary delta with the whole text for the same item id. The model never sees a catch-up marker.

## Goals

- A reply reads as an even flow of text, on the Mac and on the phone, however bursty the deltas are.
- A token redraws the streaming reply's last block, not the transcript.
- Headings, lists (nested, ordered, task), block quotes, tables, fenced code, thematic breaks and inline markup are drawn as such, while streaming and after.
- Unfinished syntax never flashes as raw text and never makes the layout jump more than the arriving text requires: a table is a table from its first header cell, an open fence is a code block, an unclosed `**` is bold.
- The final drawing of a reply is the same however its text was split into deltas, and the same as when the thread is opened later from history.
- Dense and normal density, and both platforms, get this through the one shared view.

## Non-goals

- The activity line, the "working" cue, sub-agent grouping, and streaming of reasoning or command output. They are the second design.
- Syntax colouring in code blocks, and a diff view. Threadplane has neither to borrow; they are later work on top of the block views.
- Selecting text across blocks, and Copy for a whole message (D-236's cost stays).
- Loading remote images. `![alt](url)` draws as its alt text.
- Raw HTML, math, footnotes, link reference definitions, setext headings and indented code blocks. Each draws as literal text (see "Deviations").
- Lazy rows or virtualisation. D-237 stands.
- The user's own messages and reasoning text. They stay as they are drawn today.

## Anti-goals

- Text that replays, flickers or reorders: after a catch-up on the phone, a reconcile, or the completed row replacing the live text.
- A block that changes kind after it was shown as finished.
- A pacing delay the reader can feel as lag behind the agent, or text still trickling out after the turn has ended.
- A parser whose cost per delta grows with the length of the reply. The cacheplane parser rebuilds and diffs the whole tree on each push; pushed one character at a time, a 2,140-character mixed document took 31 s (measured against its 0.5.11 build during this design). Its design is worth porting; that part is not.

## Constraints

- `WorkspaceUI` imports only `WorkspaceProtocol` and `WorkspaceClient`; the parser adds no third-party package.
- Everything links on iOS.
- No wire, storage or sync change. The coordinator's events and `MirrorTransport` stay as they are; the model receives the same events it does today.
- `Scripts/docs-index.sh --check` and `swift format lint --strict` pass. The existing transcript tests keep their assertions: the ones that set `detail.liveText` (about 45 call sites in `MirrorModelTests`, `DenseTranscriptViewTests` and `SnapshotTests`) are ported to the stream store with a clock that reveals at once, and snapshots change only where markdown is now drawn.

## Approaches

Three engines were considered for the markdown.

1. **Our own append-only block parser in Swift (chosen by the owner).** Finished blocks are frozen and only the open tail is re-read, with unfinished syntax guessed. Inline text stays on Foundation's parser. No dependency, and full control over the half-typed cases, which is where smoothness comes from. It costs the most to write and covers the markdown agents emit rather than all of CommonMark.
2. **Apple's swift-markdown, re-parsing the message each frame.** Full GitHub-flavoured correctness for less code. It has no notion of unfinished input, so half-typed syntax would be patched before each parse (threadplane's second stage, which it replaced), and it adds a C dependency to `WorkspaceUI`.
3. **A ready-made SwiftUI renderer.** Dropped: streaming behaviour and theming would be out of our hands.

The owner also directed that the parser draw on what was built in `~/repos/cacheplane`.

## Design

Three parts: a parser, an owner per streaming message, and the block views.

### 1. The parser: a new target, `StreamingMarkdown`

A Foundation-only library target with its own test target, so it is tested without SwiftUI and can be measured alone. `WorkspaceUI` depends on it. (My call; the alternative is a folder inside `WorkspaceUI`.)

```swift
public struct MarkdownParser: Sendable {
  public init()
  public mutating func push(_ text: String)   // appended text only
  public mutating func finish()               // the text is complete; no more guesses
  public var document: MarkdownDocument { get } // committed blocks + the open tail's projection
}
```

**Model.** `MarkdownDocument` is `[Block]`. `Block` is an `Equatable`, `Sendable` value with a stable `id` and a kind:

- `paragraph(inline)`, `heading(level, inline)`, `thematicBreak`
- `code(language, text, closed)`
- `quote([Block])`
- `list(ordered, start, [Item])`, where `Item` has an id, an optional task state and `[Block]`
- `table(alignments, header: [inline], rows: [[inline]])`

`inline` is the block's inline source text as a `String`, not a parsed tree: the views hand it to Foundation (below). A block's `id` is its path of positions (`3`, `3.1.0`), so an id never changes once assigned and children are keyed by position, as threadplane keys them.

**Lines.** `push` splits on newlines. Each completed line is handled once and never read again. The text after the last newline is the open line and is kept in a buffer. This is cacheplane's structure.

**Containers.** The parser keeps a stack of open containers (document, quote, list, item) and one open leaf, as CommonMark describes. This is where the port departs from cacheplane, whose containers are shallow: there a fence inside a list item closes the list, and a blank line between items makes two lists. Agents write fenced code inside list items constantly, so here:

- A list item holds any blocks: paragraphs, fenced code, nested lists, quotes, tables.
- A quote holds any blocks, including nested quotes and lists.
- A blank line between items does not end the list. Loose and tight lists draw the same.
- An unindented line after a paragraph inside a quote or item continues that paragraph (lazy continuation).

**Freezing.** A top-level block is committed when a later line closes it. Committed blocks are stored once and never revisited; `document` returns them unchanged, so their values compare equal across pushes. Work per push is bounded by the open top-level block's open line and its container path, not by the reply. A long open code block appends lines; it does not re-read them.

**The projection.** `document` is the committed blocks plus a projection of the open block with the open line applied. The projection is computed on a copy of the open state and thrown away on the next push, so a wrong guess reverts by itself and never reaches committed state. There is one tree: no second synthetic "pending" node beside it (cacheplane's 0.5.8 reversal; threadplane's leaked fence delimiters).

What the projection guesses, taken from cacheplane's rules unless marked:

| Open line | Drawn as |
| --- | --- |
| `#` to `######` then a space or end | An empty heading of that level, then its text |
| `- `, `* `, `+ `, `1. ` (marker and space) | A list item, empty until text arrives |
| A bare `-`, `*`, `+`, `1.` with no space | Nothing yet (held; the next character decides). Cacheplane shows it as a paragraph; holding one or two characters avoids a paragraph turning into a list. (My call) |
| `- [ ] ` / `- [x] ` | A task item |
| `>` | A quote |
| A fence opener | An open code block; the language is taken when the line completes |
| Inside a fence, one or two fence characters at the start of the line | Held, so a closing fence never flashes as code |
| `\| a \|` (first cell closed), no table open | A header-only table |
| The line after a pending header | Held while it could still be the delimiter row; the header stays a table |
| A partial row starting with `\|` in an open table | A row, padded to the header's width |
| `--`, `**`, `__` alone at the start of a line | Held (could be a thematic break) |
| Unclosed `**`, `*`, `_`, `~~`, `` ` `` in the open leaf | Closed at the end of the text, only when content directly follows the opener, so `2 * 3` and a trailing `**` stay literal. An intraword `_` never opens |
| `[text](` with the URL still arriving | `text`, as plain text, until the `)` arrives. Cacheplane shows the raw source. (My call) |

If the delimiter row never arrives, the committed result is a paragraph, as in cacheplane. This is the one accepted case of a block changing kind, and it happens before the block is committed.

After `finish()` nothing is guessed: the buffer is flushed as a last line (cacheplane 0.3.2 dropped it), open blocks are closed, and an unclosed `**` is literal text. An unclosed fence stays a code block with `closed: false`, as `MarkdownBlocks` has it today.

**Deviations from CommonMark and GFM**, all deliberate:

- No setext headings: `Title` then `---` is a paragraph and a thematic break. This removes a paragraph that turns into a heading one line later.
- No indented code blocks: indented text outside a list is a paragraph.
- Raw HTML, link reference definitions, footnotes and math are literal text.
- A soft line break inside a paragraph draws as a space; a hard break (two trailing spaces or a backslash) draws as a line break. Today's renderer keeps every newline. (My call)

**Replacing `MarkdownBlocks`.** `MarkdownBlocks.split` and its tests are removed; its fence rules (tilde and backtick, a backtick opener holding another backtick is inline code, at most three spaces of indent) move into the parser with their tests.

### 2. The owner: one `MessageStream` per streaming message

```swift
@MainActor @Observable final class MessageStream {
  private(set) var document: MarkdownDocument
  private(set) var phase: Phase            // .streaming, .complete
  func append(_ delta: String)
  func complete(finalText: String)
}
```

- `WorkspaceModel` keeps the streams of the open thread in a store keyed by native item id, held outside `ThreadDetail`. `ThreadDetail.liveText` is removed. A delta no longer reassigns `detail`, so the grouping and the other rows are not re-evaluated; only the row that reads this stream's `document` is. `TranscriptView` takes the store as a parameter, so tests supply one.
- The stream owns the received text, the parser, and how much of the text has been revealed.
- **Append only.** `append` is the only growth, and deltas are appended as they arrive: the stream never derives a delta by comparing two texts (threadplane's lessons 1 and 2). The phone's transport already hands the model only the unseen rest of a catch-up, and it is not changed.
- **Completion is explicit.** `complete` is called from `message.completed` (and for every open stream on `turn.finished`, with the received text), never inferred from quiet time. If the final text extends the received text, the remainder is appended; if it differs otherwise, a new parser parses the final text and the result is shown at once. Then the remaining text is revealed and `finish()` is called once.
- **Never less than was shown.** The transport's gap completion carries stale or empty text, and deltas for the same item id can follow it. So the store remembers, per item id, the text last shown for it until the turn finishes. While the turn runs:
  - a completion whose text is a strict prefix of the shown text (the stale case) leaves the row drawing the shown text, marked complete, with nothing guessed;
  - a delta for an item id whose stream completed opens a new stream. Its reveal starts at the end of the prefix its text shares with the shown text, so a whole-text delta after a gap continues from the reader's place instead of replaying.
  When the turn finishes, the stored item's text wins. Today the same gap blanks the live text and then shows it again whole. (My call.)
- **Settled items.** A row that is not streaming draws from a document parsed once from its stored text (push the whole text, then finish) and cached by item id and text. A stream's last document becomes that cache entry on completion when the final text matches, so the row does not re-parse or change when the stored item replaces the live one. The cache is dropped with the thread.
- **Blank edges.** `TranscriptRow` trims the text today. The parser makes that unnecessary and the row stops doing it: blank lines at either end produce no block, and `finish()` drops trailing whitespace on the last line. A streamed reply and the same reply opened from history therefore give equal documents whatever whitespace surrounds them; a test asserts it.

**Paced reveal.** The stream reveals text on a frame tick rather than as it arrives:

- While there is unrevealed text, a tick (60 per second, from an injected clock so tests drive it) moves the revealed count forward and pushes that slice to the parser. So there is at most one parse and one redraw per frame, whatever the delta rate.
- The step per tick is `max(1, ceil(backlog / 12))` characters, cut on a grapheme boundary: the backlog is always about 200 ms from empty, small backlogs trickle and large ones move fast. (My call; the numbers are tuned on a real stream before the gate.)
- On `complete`, the remainder is revealed within 150 ms.
- With Reduce Motion on, there is no pacing: each tick reveals everything received.
- When the thread is not on screen the stream reveals everything at once and stops ticking.

### 3. The views

`MarkdownText` becomes a view over a `MarkdownDocument`: a `VStack` of block views keyed by block id, each `Equatable` on its block value so a frozen block is skipped without a body evaluation.

- **Paragraph, heading, cell:** the block's inline source through `AttributedString(markdown:)` with inline-only syntax, as `MarkdownProse` does today, with the projection's closers already applied. Headings use the LLA type scale (three sizes; levels 4 to 6 share the smallest). The parsed `AttributedString` is cached by source text.
- **Links:** `http`, `https` and `mailto` open through the environment's `openURL`; any other scheme draws as plain text. (My call. The code comment says links are inert, but `Text` makes them tappable today with no scheme check.)
- **List:** marker column and content column; nested lists indent by the content column; a task item draws a checked or unchecked mark with its state in words for VoiceOver.
- **Quote:** a hairline rule on the leading edge, muted text.
- **Table:** a `Grid` with a header row and hairline rules, column alignment from the delimiter row, scrolling sideways inside the block when wider than the column, as code does.
- **Code:** today's `CodeFence`, unchanged: Copy appears when the fence closes or the reply completes.
- **Thematic break:** a hairline.

Spacing, colours and type come from `LLA` tokens; nothing is hard-coded in the block views.

**Following the end.** `TranscriptView` follows on `detail.liveText` changes today. With that gone, following a growing reply rests on the scroll view's size-change anchor (`.defaultScrollAnchor(.bottom, for: .sizeChanges)`), which is already set and is the React threadplane model (follow content height, not tokens). The hold rules (D-233) do not change. If the existing scroll tests show the anchor alone is not enough, the builder may observe the stream's revealed count from a zero-size leaf view that calls `follow`; `TranscriptView`'s own body must not read the stream.

## Testing

- **Parser, per construct:** each block kind, nesting (code in an item, list in a quote, quote in an item, three list levels), and each row of the projection table, checked at every step of a growing input ("exactly one table, no paragraph holding raw pipes").
- **Split invariance:** a corpus of documents (the constructs above, plus recorded agent replies from the fake runtimes and from the hill-climb captures). For each: every two-way split, one character at a time, and seeded random splits must end in the same document as a single push. For every prefix, one push and character-by-character pushes give the same projected document.
- **Never crashes, stays linear:** seeded adversarial input (long runs of `*_\`[!\\#>|-`); 100,000 characters pushed one at a time within a time budget recorded in the gate.
- **Stream:** with a fake clock: pacing steps, drain on completion, Reduce Motion, a completed text that extends or differs from the received text, completion called exactly once, and the gap sequences the phone's transport produces (a stale completion, then a whole-text delta for the same id; a catch-up's rest as an ordinary delta) with no text removed or replayed.
- **Scrolling:** the ported scroll and hold tests (D-233) run with immediate reveal. Two new ones run under pacing: a pinned reader stays at the end through a paced reveal, and a held reader is not moved by one.
- **Views:** hosted macOS views as `CodeFenceViewTests` does, one per block kind; snapshots for a reply using every construct, light and dark, normal and dense, Mac and phone widths.
- **One row redraws:** a test that streams into one row of a hosted transcript and asserts the grouping projection did not run again.
- **Gate measurements (release build, recorded in `docs/verification/`):** parser time per push on the corpus; frame time while streaming a long reply into a 150-row thread on the Mac and on an iPhone Simulator. Budget: no frame over 16 ms from our code on the Mac. (My call.)

## Records

One decision file at pull-request time (number from `Scripts/docs-index.sh --next`): the streaming markdown parser and per-message owner; amends D-236 (markdown) and notes D-237's per-token cost as removed for text. `docs/milestones.md` and the hill-climb defect table (17) are updated.

## Left to the builder

- The parser's internal state layout and the block id encoding.
- Whether inline `AttributedString`s are cached in the view layer or beside the document cache.
- The tick source in production (a display link or a clock task), given it is injected.
- Exact heading sizes, list indents and table padding within the LLA scale.
- How to split the work into pull requests. The parser target can land alone, before any view uses it.
