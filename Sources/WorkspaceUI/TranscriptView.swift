import SwiftUI
import WorkspaceProtocol

/// Cached items plus live streaming text. Agent output is rendered as text, never executed.
struct TranscriptView: View {
  let detail: ThreadDetail

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: LLA.Space.l) {
          if detail.items.isEmpty {
            Text("No messages yet. Say something below.").llaMuted()
          }
          ForEach(detail.items) { item in
            TranscriptRow(item: item, liveText: item.nativeItemId.flatMap { detail.liveText[$0] })
              .id(item.id)
          }
          ForEach(detail.turns.filter { $0.status == .terminal && $0.outcome != .completed }) { turn in
            TurnNoteRow(turn: turn)
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
        .padding(.horizontal, LLA.Space.xl)
        .padding(.vertical, LLA.Space.xl)
        .frame(maxWidth: LLA.Metrics.column, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .onChange(of: detail.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
      .onChange(of: detail.liveText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
    }
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
        MarkdownText(text: liveText ?? item.payload["text"]?.stringValue ?? "")
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

  private var title: String {
    switch item.type {
    case "commandExecution": return item.payload["command"]?.stringValue ?? "Command"
    case "fileChange":
      let count = item.payload["changes"]?.arrayValue?.count ?? 0
      return "File change (\(count) file\(count == 1 ? "" : "s"))"
    case "mcpToolCall":
      return
        "\(item.payload["server"]?.stringValue ?? "mcp") / \(item.payload["tool"]?.stringValue ?? "tool")"
    case "webSearch": return "Web search"
    case "toolUse":
      let name = item.payload["name"]?.stringValue ?? "Tool"
      if let command = item.payload["command"]?.stringValue { return "\(name): \(command)" }
      if let path = item.payload["path"]?.stringValue { return "\(name): \(path)" }
      return name
    case "toolCall":
      let name = item.payload["name"]?.stringValue ?? "Tool"
      if let input = item.payload["input"], !input.isNull {
        let preview = input.stringValue ?? String(describing: input)
        return "\(name): \(preview.prefix(80))"
      }
      return name
    default: return item.type
    }
  }
}

/// A bordered row with a mono title that opens to its detail. No icon; the title says what it is.
struct CollapsibleCard<Content: View>: View {
  let title: String
  let status: String?
  @ViewBuilder let content: () -> Content
  @State private var expanded = false

  var body: some View {
    LLACard(fill: .bg, padding: LLA.Space.m) {
      VStack(alignment: .leading, spacing: 0) {
        Button {
          withAnimation(.none) { expanded.toggle() }
        } label: {
          HStack(spacing: LLA.Space.s) {
            Text(title).llaCode().lineLimit(1).truncationMode(.middle)
            Spacer()
            if let status { LLABadge(status, tone: statusTone(status)) }
            Text(expanded ? "Hide" : "Show").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
          }
          .contentShape(Rectangle())
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
