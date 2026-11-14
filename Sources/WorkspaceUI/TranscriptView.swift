import SwiftUI
import WorkspaceProtocol

/// Which turns' lines are open, by group key. Owned by the transcript as `@State`, so it is forgotten
/// with the view and never stored.
@Observable final class TranscriptFolds {
  var open: Set<String>
  /// From a toggle until the reader returns to the end, sends a message, or another thread is shown:
  /// the transcript neither pins its bottom edge nor follows the stream, so the opened line stays put.
  private(set) var holds = false

  init(open: Set<String> = []) { self.open = open }

  func toggle(_ group: String) {
    if open.contains(group) { open.remove(group) } else { open.insert(group) }
    holds = true
  }

  /// The bottom pin and the following come back.
  func release() {
    if holds { holds = false }
  }

  func reset() {
    if !open.isEmpty { open = [] }
    release()
  }
}

/// The content's height and whether its end is in view (within 8 pt of the viewport's). The height is
/// part of it so a toggle that leaves the content fitting the viewport still reports in.
private struct TranscriptEnd: Equatable {
  var height: CGFloat
  var reached: Bool

  init(_ geometry: ScrollGeometry) {
    height = geometry.contentSize.height
    reached = geometry.visibleRect.maxY >= geometry.contentSize.height - 8
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
      // text, a reload re-lays the lazy stack), keep the bottom edge in place; scrolling to "bottom" in
      // the same update reads the old layout and leaves the view past the new end.
      // While an opened turn holds the view, its top edge is kept instead, so the line the reader
      // pressed stays where it was as its steps are drawn under it and the stream goes on below.
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(folds.holds ? .top : .bottom, for: .sizeChanges)
      .onScrollGeometryChange(for: TranscriptEnd.self, of: TranscriptEnd.init) { _, end in
        if end.reached { folds.release() }
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

  /// Keeps the end in view as the thread grows, unless an opened turn holds the view.
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
  /// The transcript scrolls, so its stack is lazy. A test measuring the content outside a scroll view
  /// turns this off: a lazy stack there estimates the height of rows it has not laid out.
  var lazy = true

  var body: some View {
    Group {
      if lazy {
        LazyVStack(alignment: .leading, spacing: LLA.Space.l) { rows }
      } else {
        VStack(alignment: .leading, spacing: LLA.Space.l) { rows }
      }
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.vertical, LLA.Metrics.margin)
    .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var rows: some View {
    if detail.items.isEmpty && pending == nil {
      Text("No messages yet. Say something below.").llaMuted()
    }
    if dense {
      ForEach(DenseTranscript.entries(items: detail.items, turns: detail.turns, open: folds.open)) {
        entry in
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
          TurnNoteRow(turn: turn)
        }
      }
    } else {
      ForEach(detail.items) { item in
        TranscriptRow(item: item, liveText: item.nativeItemId.flatMap { detail.liveText[$0] })
          .id(item.id)
      }
      ForEach(detail.turns.filter { $0.status == .terminal && $0.outcome != .completed }) { turn in
        TurnNoteRow(turn: turn)
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
        if !segments.isEmpty {
          parts
          // A running step's name is free text ("swift test"), so a dot keeps the action word from
          // reading as its last word. Stacked, the action is on its own line and needs none.
          if !stacked { Text("·").foregroundStyle(LLA.Color.muted).fixedSize() }
        }
        // Stacked, the action word has the row's width to itself and wraps rather than overrun it.
        Text(line.action(open: open))
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
            in: .whitespacesAndNewlines)
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

/// Markdown rendered through Foundation's parser: no HTML, no scripts, links stay inert text.
struct MarkdownText: View {
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
  }
}

struct ToolCard: View {
  let item: DisplayItem

  var body: some View {
    CollapsibleCard(title: title, status: item.payload["status"]?.stringValue) {
      VStack(alignment: .leading, spacing: LLA.Space.s) {
        if let cwd = item.payload["cwd"]?.stringValue {
          Text(cwd).llaCodeMuted()
        }
        if let output = item.payload["aggregatedOutput"]?.stringValue ?? item.payload["output"]?.stringValue,
          !output.isEmpty
        {
          LLACodeBlock(output)
        }
        ForEach(Array((item.payload["changes"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, change in
          Text(change["path"]?.stringValue ?? "").font(LLAFont.mono(12, weight: .semibold)).foregroundStyle(
            LLA.Color.ink)
          if let diff = change["diff"]?.stringValue {
            LLACodeBlock(diff)
          }
        }
        if item.payload["aggregatedOutput"] == nil, item.payload["changes"] == nil {
          Text(String(describing: item.payload).prefix(2_000)).llaCodeMuted().textSelection(.enabled)
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
              if let status { LLABadge(status, tone: statusTone(status)) }
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

struct TurnNoteRow: View {
  let turn: Turn

  var text: String { turn.outcome == .cancelled ? "Turn stopped." : "Turn failed." }

  var body: some View {
    Text(text)
      .font(LLAFont.caption)
      .foregroundStyle(turn.outcome == .cancelled ? LLA.Color.muted : LLA.Color.danger)
  }
}
