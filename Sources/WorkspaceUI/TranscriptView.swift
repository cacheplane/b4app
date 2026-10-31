import SwiftUI
import WorkspaceProtocol

/// Cached items plus live streaming text. Agent output is rendered as text, never executed.
struct TranscriptView: View {
  let detail: ThreadDetail

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if detail.items.isEmpty {
            Text("No messages yet. Say something below.").foregroundStyle(.secondary)
          }
          ForEach(detail.items) { item in
            TranscriptRow(item: item, liveText: item.nativeItemId.flatMap { detail.liveText[$0] })
              .id(item.id)
          }
          ForEach(detail.turns.filter { $0.status == .terminal && $0.outcome != .completed }) { turn in
            TurnNoteRow(turn: turn)
          }
          if let turn = detail.activeTurn, turn.status == .reconciling {
            Label(
              "The runtime stopped before this turn finished. Its outcome is unknown; reopen the thread to reconcile or start a new thread.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.callout).foregroundStyle(.orange)
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
          .textSelection(.enabled)
          .padding(10)
          .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
      }
    case .assistant:
      if item.type == "agentMessage" {
        MarkdownText(text: liveText ?? item.payload["text"]?.stringValue ?? "")
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        CollapsibleCard(title: item.type == "reasoning" ? "Reasoning" : item.type.capitalized, status: nil) {
          Text(reasoningText).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    case .tool:
      ToolCard(item: item)
    case .system:
      Text(item.type).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var reasoningText: String {
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
    if let attributed = try? AttributedString(
      markdown: text,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      Text(attributed).textSelection(.enabled)
    } else {
      Text(text).textSelection(.enabled)
    }
  }
}

struct ToolCard: View {
  let item: DisplayItem

  var body: some View {
    CollapsibleCard(title: title, status: item.payload["status"]?.stringValue) {
      VStack(alignment: .leading, spacing: 6) {
        if let cwd = item.payload["cwd"]?.stringValue {
          Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        if let output = item.payload["aggregatedOutput"]?.stringValue, !output.isEmpty {
          ScrollView(.horizontal) {
            Text(output).font(.caption.monospaced()).textSelection(.enabled)
          }
          .frame(maxHeight: 240)
        }
        ForEach(Array((item.payload["changes"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, change in
          Text(change["path"]?.stringValue ?? "").font(.caption.bold())
          if let diff = change["diff"]?.stringValue {
            ScrollView(.horizontal) { Text(diff).font(.caption.monospaced()).textSelection(.enabled) }
              .frame(maxHeight: 240)
          }
        }
        if item.payload["aggregatedOutput"] == nil, item.payload["changes"] == nil {
          Text(String(describing: item.payload).prefix(2_000)).font(.caption.monospaced()).textSelection(
            .enabled)
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
    default: return item.type
    }
  }
}

struct CollapsibleCard<Content: View>: View {
  let title: String
  let status: String?
  @ViewBuilder let content: () -> Content
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      content().padding(.top, 6)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "terminal").foregroundStyle(.secondary)
        Text(title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
        Spacer()
        if let status { Text(status).font(.caption).foregroundStyle(statusColor(status)) }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "completed": return .green
    case "failed", "declined": return .red
    case "inProgress": return .orange
    default: return .secondary
    }
  }
}

struct TurnNoteRow: View {
  let turn: Turn

  var body: some View {
    Label(
      turn.outcome == .cancelled ? "Turn stopped." : "Turn failed.",
      systemImage: turn.outcome == .cancelled ? "stop.circle" : "xmark.octagon"
    )
    .font(.caption).foregroundStyle(turn.outcome == .cancelled ? Color.secondary : Color.red)
  }
}
