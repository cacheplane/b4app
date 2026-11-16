import SwiftUI
import WorkspaceProtocol

/// Which turns' lines are open, by group key. Owned by the transcript as `@State`, so it is forgotten
/// with the view and never stored.
@Observable final class TranscriptFolds {
  var open: Set<String>
  /// From a toggle until the reader returns to the end, sends a message, or another thread is shown:
  /// the transcript neither pins its bottom edge nor follows the stream, so the opened line stays put.
  private(set) var holds = false

  /// How many of the thread's latest rows are drawn; "Show earlier" adds a page.
  private(set) var shown = DenseTranscript.page
  /// The row that stood first when "Show earlier" was pressed: it is kept at the top of the view as
  /// the earlier rows are drawn above it.
  private(set) var kept: String?

  init(open: Set<String> = []) { self.open = open }

  /// The reader asked for earlier rows: a page more, and the view is theirs until they return to the end.
  func showEarlier(keeping first: String?) {
    kept = first
    shown += DenseTranscript.page
    holds = true
  }

  func toggle(_ group: String) {
    if open.contains(group) { open.remove(group) } else { open.insert(group) }
    holds = true
  }

  /// The reader scrolled back from the end: the same hold as opening a turn, so neither the stream nor
  /// a turn's end moves what they are reading.
  func hold() {
    if !holds { holds = true }
  }

  /// The bottom pin and the following come back.
  func release() {
    if holds { holds = false }
  }

  func reset() {
    if !open.isEmpty { open = [] }
    if shown != DenseTranscript.page { shown = DenseTranscript.page }
    kept = nil
    release()
  }
}

/// The content's height, where the viewport's top edge stands in it, and whether its end is in view
/// (within 8 pt of the viewport's). The height is part of it so a toggle that leaves the content
/// fitting the viewport still reports in.
struct TranscriptEnd: Equatable {
  var height: CGFloat
  var top: CGFloat
  var reached: Bool
  /// The end marker is out of view: more than the transcript's bottom padding lies below the viewport.
  /// Following the stream rests the view with that padding below it, so nearer than this is the end.
  var away: Bool

  init(height: CGFloat, top: CGFloat, reached: Bool, away: Bool) {
    self.height = height
    self.top = top
    self.reached = reached
    self.away = away
  }

  init(_ geometry: ScrollGeometry) {
    height = geometry.contentSize.height
    top = geometry.visibleRect.minY
    let below = geometry.contentSize.height - geometry.visibleRect.maxY
    reached = below <= 8
    away = below > LLA.Metrics.margin + 8
  }

  /// What a change of geometry says about the reader. The end in view: following. The viewport's top
  /// edge moved up over content of the same height, the end marker out of view: the reader went back (a
  /// wheel, a drag, Page Up, the scroller). Content growing under a still viewport, the view being
  /// taken down to the end, and a layout pass that resizes the content and moves the view with it are
  /// none of these: the top edge stays or moves down, or the height changed in the same step.
  enum Intent: Equatable { case following, reading, unchanged }

  static func intent(from old: TranscriptEnd, to new: TranscriptEnd) -> Intent {
    if new.reached { return .following }
    return new.away && new.top < old.top - 0.5 && abs(new.height - old.height) <= 0.5
      ? .reading : .unchanged
  }
}

/// Cached items plus live streaming text. Agent output is rendered as text, never executed.
struct TranscriptView: View {
  let detail: ThreadDetail
  /// The phone's message still on its way to the Mac, shown after the items with its state, until its
  /// turn's own message arrives (M8c). Always nil on the Mac.
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil
  /// Dense draws each turn as the message, one line for the work, and the answer.
  var dense = false
  @State private var folds: TranscriptFolds

  init(
    detail: ThreadDetail, pending: PendingSend? = nil, pendingStatus: String? = nil, dense: Bool = false,
    folds: TranscriptFolds = TranscriptFolds()
  ) {
    self.detail = detail
    self.pending = pending
    self.pendingStatus = pendingStatus
    self.dense = dense
    _folds = State(initialValue: folds)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        TranscriptContent(
          detail: detail, pending: pending, pendingStatus: pendingStatus, dense: dense, folds: folds)
      }
      .accessibilityIdentifier("transcript")
      #if os(iOS)
        // Dragging the transcript down puts the keyboard away, as in Messages.
        .scrollDismissesKeyboard(.interactively)
      #endif
      // A thread opens at its latest message. When the content shrinks (a Stop drops a reply's live
      // text, a reload draws fewer rows), keep the bottom edge in place; scrolling to "bottom" in
      // the same update reads the old layout and leaves the view past the new end.
      // While an opened turn holds the view, its top edge is kept instead, so the line the reader
      // pressed stays where it was as its steps are drawn under it and the stream goes on below.
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(folds.holds ? .top : .bottom, for: .sizeChanges)
      .onScrollGeometryChange(for: TranscriptEnd.self, of: TranscriptEnd.init) { old, end in
        switch TranscriptEnd.intent(from: old, to: end) {
        case .following: folds.release()
        case .reading: folds.hold()
        case .unchanged: break
        }
      }
      // While the view is held, the latest content is out of sight below: one press goes back to it
      // and follows the stream again.
      .overlay(alignment: .bottom) {
        if folds.holds {
          Button("Jump to latest") {
            folds.release()
            proxy.scrollTo("bottom", anchor: .bottom)
          }
          .buttonStyle(.llaSecondary)
          // The pill's fill is close to the page's: a rule keeps its edge visible over the transcript.
          .overlay(Capsule().stroke(LLA.Color.rule, lineWidth: 1))
          .llaPopoverShadow()
          .padding(.bottom, LLA.Space.m)
          .accessibilityIdentifier("jump-to-latest")
          .accessibilityHint("Scrolls to the end of the thread and follows new output")
        }
      }
      // Earlier rows were drawn above: the row that stood first stays at the top of the view.
      .onChange(of: folds.shown) { _, _ in
        if let kept = folds.kept { proxy.scrollTo(kept, anchor: .top) }
      }
      .onChange(of: detail.items.count) { _, _ in follow(proxy) }
      .onChange(of: detail.turns.filter { $0.status == .terminal }.count) { _, _ in follow(proxy) }
      .onChange(of: detail.liveText) { _, _ in follow(proxy) }
      // Normal density has no lines to hold open, so a switch lets go and normal scrolls as it always has.
      .onChange(of: dense) { _, _ in folds.reset() }
      // The reader sent something: back to the end, as today.
      .onChange(of: pending?.id) { _, _ in
        folds.release()
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .onChange(of: detail.turns.count) { old, new in
        guard new > old, folds.holds else { return }
        folds.release()
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      // The same view shows the next thread. If a turn held this one, a `follow` that ran first in this
      // update saw the hold and did nothing, so the next thread is taken to its end here.
      .onChange(of: detail.thread.id) { _, _ in
        let held = folds.holds
        folds.reset()
        if held { proxy.scrollTo("bottom", anchor: .bottom) }
      }
    }
  }

  /// Keeps the end in view as the thread grows, unless an opened turn or a reader who scrolled back
  /// holds the view.
  private func follow(_ proxy: ScrollViewProxy) {
    guard !folds.holds else { return }
    proxy.scrollTo("bottom", anchor: .bottom)
  }
}

/// The transcript's rows, without the scroll view around them (so a test can measure them).
struct TranscriptContent: View {
  let detail: ThreadDetail
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil
  var dense = false
  let folds: TranscriptFolds
  var body: some View {
    // Not a lazy stack. A lazy stack sizes rows it has not laid out by estimate, and with the bottom
    // edge pinned it kept that estimate: a thread whose first reply was several windows tall opened
    // partway up it with the later messages never laid out, and a short thread could stop following
    // its stream. Every drawn row is laid out, and `DenseTranscript.window` bounds how many there are.
    VStack(alignment: .leading, spacing: LLA.Space.l) { rows }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Metrics.margin)
      .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
      .frame(maxWidth: .infinity)
  }

  /// Dense folds each turn's work into a line; normal draws every item. Both settle an ended turn's
  /// open steps and put its note with it.
  private var window: DenseTranscript.Window {
    DenseTranscript.window(
      dense
        ? DenseTranscript.entries(items: detail.items, turns: detail.turns, open: folds.open)
        : DenseTranscript.plain(items: detail.items, turns: detail.turns),
      shown: folds.shown)
  }

  @ViewBuilder private var rows: some View {
    if detail.items.isEmpty && pending == nil {
      Text("No messages yet. Say something below.").llaMuted()
    }
    let window = window
    if window.hidden > 0 {
      Button("Show earlier") { folds.showEarlier(keeping: window.entries.first?.id) }
        .buttonStyle(.llaLink)
        .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row)
        .accessibilityLabel("Show earlier, \(window.hidden) more")
        .accessibilityIdentifier("show-earlier")
    }
    ForEach(window.entries) { entry in
      switch entry {
      case .item(let item):
        TranscriptRow(item: item, liveText: item.nativeItemId.flatMap { detail.liveText[$0] })
          .id(item.id)
      case .line(let line):
        StepsLineRow(line: line, open: folds.open.contains(line.group)) {
          folds.toggle(line.group)
        }
        .id(entry.id)
      case .note(let turn):
        TurnNoteRow(turn: turn).id(entry.id)
      case .running(let line):
        RunningLineRow(line: line).id(entry.id)
      }
    }
    if let pending {
      PendingMessageRow(send: pending, status: pendingStatus).id("pending-\(pending.id)")
    }
    if let turn = detail.activeTurn, turn.status == .reconciling {
      HStack(alignment: .top, spacing: LLA.Space.s) {
        LLAStateDot(state: .unknown).padding(.top, 2)
        Text(
          "The runtime stopped before this turn finished. Its outcome is unknown; check again below, or abandon the turn to continue."
        )
        .llaSmall().fixedSize(horizontal: false, vertical: true)
      }
    }
    Color.clear.frame(height: 1).id("bottom")
  }
}

/// A turn's line: what the turn did, or is doing, and the word that shows or hides it. One muted line,
/// cut at its tail; at accessibility sizes it wraps under the action word.
struct StepsLineRow: View {
  let line: DenseTranscript.StepsLine
  let open: Bool
  let toggle: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  /// The line read as one element: "4 steps, 1 failed, Show".
  var label: String { line.spoken(open: open) }

  var body: some View {
    Button {
      withAnimation(.none) { toggle() }
    } label: {
      let stacked = typeSize.isAccessibilitySize
      let layout =
        stacked
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
        : AnyLayout(HStackLayout(spacing: LLA.Space.xs))
      layout {
        if !segments.isEmpty { parts }
        // A running step's name is free text ("swift test"), so a dot keeps the action word from
        // reading as its last word. It is part of the action's text, not a view of its own: a third
        // view in the row kept a lazy stack from settling when the transcript had one.
        // Stacked, the action word has the row's width to itself and wraps rather than overrun it.
        Text(segments.isEmpty || stacked ? line.action(open: open) : "· \(line.action(open: open))")
          .foregroundStyle(LLA.Color.muted)
          .lineLimit(stacked ? nil : 1)
          .fixedSize(horizontal: !stacked, vertical: true)
      }
      .font(LLAFont.small)
      .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityIdentifier("steps-line")
  }

  /// A run of the line drawn in one colour.
  struct Segment: Equatable {
    enum Tone: Equatable { case muted, danger }
    var text: String
    var tone: Tone
  }

  /// The text, "N failed" (danger, and only it) and "N declined", with a muted ", " between the parts
  /// that are present. The action word is not part of it.
  var segments: [Segment] {
    var segments: [Segment] = []
    func add(_ text: String?, _ tone: Segment.Tone) {
      guard let text else { return }
      if !segments.isEmpty { segments.append(Segment(text: ", ", tone: .muted)) }
      segments.append(Segment(text: text, tone: tone))
    }
    add(line.text, .muted)
    add(line.failedText, .danger)
    add(line.declinedText, .muted)
    return segments
  }

  private func styled(_ segment: Segment) -> Text {
    Text(segment.text).foregroundStyle(segment.tone == .danger ? LLA.Color.danger : LLA.Color.muted)
  }

  /// The segments. On one line the text is the only part that shrinks, cut at its tail; stacked they
  /// are one text that wraps as a whole, so no part is squeezed by the ones beside it.
  @ViewBuilder private var parts: some View {
    if typeSize.isAccessibilitySize {
      segments.dropFirst().reduce(styled(segments[0])) { Text("\($0)\(styled($1))") }
        .fixedSize(horizontal: false, vertical: true)
    } else {
      HStack(spacing: 0) {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
          if index == 0, line.text != nil {
            styled(segment).lineLimit(1).truncationMode(.tail)
          } else {
            styled(segment).fixedSize()
          }
        }
      }
    }
  }
}

/// The phone's own message before the Mac has it: the user's bubble as the transcript draws it, with
/// "Sending…", "Not confirmed: …", or "Didn't reach your Mac" under it.
struct PendingMessageRow: View {
  let send: PendingSend
  let status: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: LLA.Space.xs) {
      HStack {
        Spacer(minLength: 60)
        Text(send.text)
          .llaBody()
          .textSelection(.enabled)
          .padding(.horizontal, LLA.Space.l)
          .padding(.vertical, LLA.Space.m)
          .background(
            RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.surface)
          )
          .opacity(send.state == .sending ? 0.7 : 1)
      }
      if let status {
        HStack(spacing: LLA.Space.xs) {
          if send.state == .sending { ProgressView().controlSize(.mini).accessibilityHidden(true) }
          Text(status)
            .font(LLAFont.caption)
            .foregroundStyle(send.state == .sending ? LLA.Color.muted : LLA.Color.danger)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pending-message")
  }
}

struct TranscriptRow: View {
  let item: DisplayItem
  let liveText: String?

  var body: some View {
    switch item.role {
    case .user:
      HStack {
        Spacer(minLength: 60)
        Text(item.payload["text"]?.stringValue ?? "")
          .llaBody()
          .textSelection(.enabled)
          .padding(.horizontal, LLA.Space.l)
          .padding(.vertical, LLA.Space.m)
          .background(
            RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.surface))
      }
    case .assistant:
      if item.type == "agentMessage" {
        // Trimmed: a reply's trailing blank lines otherwise widen the gap to the next item unevenly.
        MarkdownText(
          text: (liveText ?? item.payload["text"]?.stringValue ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines),
          streaming: liveText != nil
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        CollapsibleCard(
          title: item.type == "reasoning" || item.type == "thinking" ? "Reasoning" : item.type.capitalized,
          status: nil
        ) {
          Text(reasoningText).llaSmallMuted().textSelection(.enabled).fixedSize(
            horizontal: false, vertical: true)
        }
      }
    case .tool:
      ToolCard(item: item)
    case .system:
      Text(item.type).llaCaption()
    }
  }

  private var reasoningText: String {
    if let text = item.payload["text"]?.stringValue, !text.isEmpty { return text }
    let summary = item.payload["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if !summary.isEmpty { return summary.joined(separator: "\n") }
    return item.payload["text"]?.stringValue ?? item.payload["content"]?.arrayValue?.compactMap(\.stringValue)
      .joined(separator: "\n") ?? ""
  }
}

/// A reply: prose through Foundation's parser (no HTML, no scripts, links stay inert text) and each
/// fenced block as code. A reply with no fence is one text, as it always was.
struct MarkdownText: View {
  let text: String
  /// The reply is still arriving: an open fence may yet close, so it offers no Copy.
  var streaming = false

  var body: some View {
    let blocks = MarkdownBlocks.split(text)
    if blocks.contains(where: { if case .code = $0 { true } else { false } }) {
      VStack(alignment: .leading, spacing: LLA.Space.m) {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          switch block {
          case .prose(let prose): MarkdownProse(text: prose)
          case .code(let language, let code, let closed):
            CodeFence(language: language, code: code, copyable: closed || !streaming)
          }
        }
      }
    } else {
      MarkdownProse(text: text)
    }
  }
}

/// Inline Markdown, whitespace kept. Equatable so a block whose text did not change is not parsed
/// again as the reply's last block streams.
struct MarkdownProse: View, Equatable {
  let text: String

  var body: some View {
    Group {
      if let attributed = try? AttributedString(
        markdown: text,
        options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      {
        Text(attributed)
      } else {
        Text(text)
      }
    }
    .llaBody()
    .lineSpacing(4)
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A fenced block: its language, Copy, and the code at its full height, scrolling sideways inside the
/// block when a line is wider than the column. Copy takes the code exactly, without fence or language.
struct CodeFence: View, Equatable {
  let language: String?
  let code: String
  let copyable: Bool
  @State private var copied = false

  nonisolated static func == (lhs: CodeFence, rhs: CodeFence) -> Bool {
    lhs.language == rhs.language && lhs.code == rhs.code && lhs.copyable == rhs.copyable
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: LLA.Space.s) {
        Text(language ?? "code").font(LLAFont.caption).foregroundStyle(LLA.Color.codeFg.opacity(0.7))
        Spacer()
        if copyable {
          Button(copied ? "Copied" : "Copy") {
            Clipboard.copy(code)
            copied = true
            Task {
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          }
          .buttonStyle(.plain)
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.codeFg)
          .frame(minHeight: LLA.Metrics.row)
          .contentShape(Rectangle())
          .accessibilityLabel(copied ? "Copied" : "Copy code")
          .accessibilityIdentifier("copy-code")
        }
      }
      .padding(.horizontal, LLA.Space.m)
      .frame(minHeight: max(LLA.Metrics.row, 32))
      ScrollView(.horizontal) {
        Text(code.isEmpty ? " " : code)
          .font(LLAFont.codeSmall)
          .foregroundStyle(LLA.Color.codeFg)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding([.horizontal, .bottom], LLA.Space.m)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).fill(LLA.Color.codeBg))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
  }
}

/// The system pasteboard, for a Copy the reader pressed.
enum Clipboard {
  @MainActor static func copy(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}

struct ToolCard: View {
  let item: DisplayItem

  var body: some View {
    CollapsibleCard(title: title, status: item.payload["status"]?.stringValue) {
      let detail = ToolEvidence.detail(of: item)
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        if let cwd = detail.cwd {
          Text(cwd).llaCodeMuted()
        }
        if let input = detail.input {
          Text("Input").llaCaption()
          LLACodeBlock(input)
        }
        switch detail.output {
        case .none: EmptyView()
        // A result with no text is still a result; say so rather than draw nothing.
        case .empty: Text("No text output.").llaSmallMuted()
        case .text(let output):
          if detail.input != nil { Text("Output").llaCaption() }
          LLACodeBlock(output)
        }
        if let exitCode = detail.exitCode {
          Text("Exit code \(exitCode)").llaSmallMuted()
        }
        ForEach(Array(detail.changes.enumerated()), id: \.offset) { _, change in
          Text(change.path).font(LLAFont.mono(12, weight: .semibold)).foregroundStyle(LLA.Color.ink)
          if let diff = change.diff {
            LLACodeBlock(diff)
          }
        }
        if let raw = detail.raw {
          Text(raw).llaCodeMuted().textSelection(.enabled)
          if detail.rawCut {
            Text("Cut at \(ToolEvidence.rawLimit) characters.").llaSmallMuted()
          }
        }
      }
    }
  }

  private var title: String { DenseTranscript.title(of: item) }
}

/// A bordered row with a mono title that opens to its detail. No icon; the title says what it is.
struct CollapsibleCard<Content: View>: View {
  let title: String
  let status: String?
  @ViewBuilder let content: () -> Content
  @State private var expanded = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    LLACard(fill: .bg, padding: LLA.Space.m) {
      VStack(alignment: .leading, spacing: 0) {
        Button {
          withAnimation(.none) { expanded.toggle() }
        } label: {
          // At accessibility sizes the title takes the full width and wraps; the badge and the
          // Show/Hide word go under it rather than squeezing it to an ellipsis.
          let stacked = typeSize.isAccessibilitySize
          let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
            : AnyLayout(HStackLayout(spacing: LLA.Space.s))
          layout {
            Text(title).llaCode().lineLimit(stacked ? 4 : 1).truncationMode(.middle)
            if !stacked { Spacer() }
            HStack(spacing: LLA.Space.s) {
              if let status { LLABadge(DenseTranscript.statusLabel(status), tone: statusTone(status)) }
              Text(expanded ? "Hide" : "Show").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
            }
          }
          // The target reaches over the card's padding, so the whole closed card is the button: at
          // least 44 pt tall on the phone without making the card itself taller.
          .frame(
            maxWidth: .infinity, minHeight: max(LLA.Metrics.row - 2 * LLA.Space.m, 0), alignment: .leading
          )
          .contentShape(Rectangle().inset(by: -LLA.Space.m))
        }
        .buttonStyle(.plain)
        if expanded {
          content().padding(.top, LLA.Space.m)
        }
      }
    }
  }

  private func statusTone(_ status: String) -> LLABadge.Tone {
    switch status {
    case "completed": return .neutral
    case "failed", "declined": return .danger
    case "inProgress": return .accent
    default: return .muted
    }
  }
}

/// What a running turn is doing (D-239): the working mark and one muted line, cut at its tail, the
/// height of a steps line. A turn waiting for an answer has the words alone: the request below it is
/// what asks. It is read as its text and is not a control.
struct RunningLineRow: View {
  let line: DenseTranscript.RunningLine

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      if !line.waiting { ThreadMark(state: .working).accessibilityHidden(true) }
      Text(line.text)
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.muted)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(line.text)
    .accessibilityIdentifier("running-line")
  }
}

struct TurnNoteRow: View {
  let turn: Turn

  var text: String { turn.outcome == .cancelled ? "Turn stopped." : "Turn failed." }

  var body: some View {
    Text(text)
      .font(LLAFont.caption)
      .foregroundStyle(turn.outcome == .cancelled ? LLA.Color.muted : LLA.Color.danger)
  }
}
