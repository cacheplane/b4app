import SwiftUI
import WorkspaceProtocol

/// One row of an opened turn, indented under a thin rule: a mark, the title and the time on one muted
/// line, which a step opens to its output and a thought to its text. An interim message is drawn as its
/// text and a plan as its row. At accessibility sizes the title wraps and the time goes under it.
struct StepRowView: View {
  let row: DenseTranscript.StepRow
  let streams: MessageStreamStore
  let open: Bool
  let toggle: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  /// From the column's edge to a level's rule, and from the rule to the row (the approved mockup's).
  static let ruleInset: CGFloat = 6
  static let ruleGap: CGFloat = 14

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, CGFloat(row.depth) * Self.level)
      // The rules run the row's whole height, so the rows of a run draw one unbroken line per level.
      .background(alignment: .leading) {
        HStack(spacing: 0) {
          ForEach(0..<row.depth, id: \.self) { _ in
            Rectangle().fill(LLA.Color.rule).frame(width: 1)
              .padding(.leading, Self.ruleInset)
              .padding(.trailing, Self.ruleGap)
          }
        }
        .accessibilityHidden(true)
      }
  }

  /// The width of one level: the inset, the rule and the gap.
  static let level = ruleInset + 1 + ruleGap

  @ViewBuilder private var content: some View {
    switch row.kind {
    case .message:
      MarkdownText(document: streams.document(for: row.item), streaming: false)
        .padding(.vertical, LLA.Space.s)
    case .plan:
      if let display = TaskListDisplay(item: row.item) {
        TaskListRow(display: display).padding(.vertical, LLA.Space.s)
      }
    case .step, .agent, .thought, .other:
      VStack(alignment: .leading, spacing: 0) {
        header
        if open && row.opens {
          output
            .padding(.leading, LLA.Metrics.mark + LLA.Space.s)
            .padding(.bottom, LLA.Space.s)
        }
      }
    }
  }

  // MARK: the row

  @ViewBuilder private var header: some View {
    Group {
      if row.opens {
        Button {
          withAnimation(.none) { toggle() }
        } label: {
          line
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
      } else {
        line
      }
    }
    // The row's children are its words and its clock, so the clock speaks the time it shows.
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("step-row")
  }

  private var line: some View {
    let stacked = typeSize.isAccessibilitySize
    let layout =
      stacked
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: LLA.Space.xs))
      : AnyLayout(HStackLayout(spacing: LLA.Space.s))
    return layout {
      HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: LLA.Space.s) {
        mark
        title
      }
      .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
      time
    }
    .padding(.vertical, LLA.Space.xs)
    .frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var title: some View {
    let stacked = typeSize.isAccessibilitySize
    return Text(row.title)
      .font(Self.isMono(row.item) ? LLAFont.codeSmall : LLAFont.small)
      .foregroundStyle(row.mark == .failed ? LLA.Color.danger : LLA.Color.muted)
      .lineLimit(stacked ? nil : 1)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: stacked)
      .accessibilityLabel(row.spoken)
  }

  /// The title is a command or a path: a command, or a tool use that names one.
  static func isMono(_ item: DisplayItem) -> Bool {
    switch item.type {
    case "commandExecution": return true
    case "toolUse":
      return item.payload["command"]?.stringValue != nil || item.payload["path"]?.stringValue != nil
    default: return false
    }
  }

  @ViewBuilder private var time: some View {
    if let start = row.startedAt {
      ActivityClock(start: start).font(LLAFont.small).fixedSize()
    } else if let duration = row.duration {
      Text(ActivityTime.duration(duration))
        .font(LLAFont.small)
        .monospacedDigit()
        .foregroundStyle(LLA.Color.muted)
        .fixedSize()
        .accessibilityHidden(true)
    }
  }

  /// A check when done, the working mark while running, a danger cross when failed, a dash when
  /// declined or left unfinished; nothing otherwise, in the same box so the titles line up.
  @ViewBuilder private var mark: some View {
    Group {
      switch row.mark {
      case .done: symbol("checkmark", LLA.Color.muted)
      case .running: ThreadMark(state: .working)
      case .failed: symbol("xmark", LLA.Color.danger)
      case .declined, .unfinished: symbol("minus", LLA.Color.muted)
      case .none: Color.clear
      }
    }
    .frame(width: LLA.Metrics.mark, height: LLA.Metrics.mark)
    .accessibilityHidden(true)
  }

  private func symbol(_ name: String, _ color: Color) -> some View {
    Image(systemName: name).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
  }

  // MARK: opened

  @ViewBuilder private var output: some View {
    if row.kind == .thought {
      Text(DenseTranscript.thoughtText(of: row.item)).llaSmallMuted().textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      StepOutput(detail: ToolEvidence.detail(of: row.item))
    }
  }
}

/// What an opened step draws: its working directory, input, output, exit code, changes and diffs, or
/// its payload when none of those was recorded.
struct StepOutput: View {
  let detail: ToolEvidence.Detail

  var body: some View {
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
