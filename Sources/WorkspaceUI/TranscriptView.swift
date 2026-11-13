import SwiftUI
import WorkspaceProtocol

/// Cached items plus live streaming text. Agent output is rendered as text, never executed.
struct TranscriptView: View {
  let detail: ThreadDetail
  /// The phone's message still on its way to the Mac, shown after the items with its state, until its
  /// turn's own message arrives (M8c). Always nil on the Mac.
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: LLA.Space.l) {
          if detail.items.isEmpty && pending == nil {
            Text("No messages yet. Say something below.").llaMuted()
          }
          ForEach(detail.items) { item in
            TranscriptRow(item: item, liveText: item.nativeItemId.flatMap { detail.liveText[$0] })
              .id(item.id)
          }
          ForEach(detail.turns.filter { $0.status == .terminal && $0.outcome != .completed }) { turn in
            TurnNoteRow(turn: turn)
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
        .padding(.horizontal, LLA.Metrics.margin)
        .padding(.vertical, LLA.Metrics.margin)
        .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier("transcript")
      #if os(iOS)
        // Dragging the transcript down puts the keyboard away, as in Messages.
        .scrollDismissesKeyboard(.interactively)
      #endif
      // A thread opens at its latest message. When the content shrinks (a Stop drops a reply's live
      // text, a reload re-lays the lazy stack), keep the bottom edge in place; scrolling to "bottom" in
      // the same update reads the old layout and leaves the view past the new end.
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(.bottom, for: .sizeChanges)
      .onChange(of: detail.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
      .onChange(of: detail.turns.filter { $0.status == .terminal }.count) { _, _ in
        proxy.scrollTo("bottom", anchor: .bottom)
      }
      .onChange(of: pending?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
      .onChange(of: detail.liveText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
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

  var body: some View {
    Text(turn.outcome == .cancelled ? "Turn stopped." : "Turn failed.")
      .font(LLAFont.caption)
      .foregroundStyle(turn.outcome == .cancelled ? LLA.Color.muted : LLA.Color.danger)
  }
}
