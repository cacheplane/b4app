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
    content.stepIndent(row.depth)
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
    case .agent:
      // Opened, its children are drawn under it as rows of their own, then its result (`AgentOutputRow`).
      header
    case .step, .thought, .other:
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
      if case .agent = row.kind, row.opens {
        // The button's value says whether it is open, so the word is not spoken.
        Text(open ? "Hide" : "Show")
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.muted)
          .fixedSize()
          .accessibilityHidden(true)
      }
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

  /// A check when done, the working mark while running, an open circle while waiting, a danger cross
  /// when failed, a dash when declined or left unfinished; nothing otherwise, in the same box so the
  /// titles line up.
  @ViewBuilder private var mark: some View {
    Group {
      switch row.mark {
      case .done: symbol("checkmark", LLA.Color.muted)
      case .running: ThreadMark(state: .working)
      // Still while the turn waits for the user: the open circle of a plan's pending step.
      case .waiting: Circle().strokeBorder(LLA.Color.muted, lineWidth: 1).frame(width: 8, height: 8)
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

/// An opened agent's own result, after its children: drawn as a step's output is, under the agent's row
/// and at its level. With no result, what the call recorded instead: its whole detail.
struct AgentOutputRow: View {
  let row: DenseTranscript.StepRow

  var body: some View {
    let detail = ToolEvidence.detail(of: row.item)
    StepOutput(detail: detail, resultOnly: detail.output != .none)
      .padding(.leading, LLA.Metrics.mark + LLA.Space.s)
      .padding(.vertical, LLA.Space.s)
      .stepIndent(row.depth)
  }
}

extension View {
  /// Indents a step row's content `depth` levels, each under its thin rule. The rules run the row's whole
  /// height, so the rows of a run draw one unbroken line per level.
  fileprivate func stepIndent(_ depth: Int) -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, CGFloat(depth) * StepRowView.level)
      .background(alignment: .leading) {
        HStack(spacing: 0) {
          ForEach(0..<depth, id: \.self) { _ in
            Rectangle().fill(LLA.Color.rule).frame(width: 1)
              .padding(.leading, StepRowView.ruleInset)
              .padding(.trailing, StepRowView.ruleGap)
          }
        }
        .accessibilityHidden(true)
      }
  }
}

/// What an opened step draws: its working directory, input, output, exit code, changes and diffs, or
/// its payload when none of those was recorded. `resultOnly` draws the output text alone (or the words
/// for none): an agent's own output, whose input is already its row's title.
struct StepOutput: View {
  let detail: ToolEvidence.Detail
  var resultOnly = false

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      if resultOnly {
        result
      } else {
        full
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("step-output")
  }

  @ViewBuilder private var result: some View {
    switch detail.output {
    case .text(let output): StepOutputBlock(text: output)
    case .empty, .none: Text("No text output.").llaSmallMuted()
    }
  }

  @ViewBuilder private var full: some View {
    if let cwd = detail.cwd {
      Text(cwd).llaCodeMuted()
    }
    if let input = detail.input {
      Text("Input").llaCaption()
      StepOutputBlock(text: input)
    }
    switch detail.output {
    case .none: EmptyView()
    // A result with no text is still a result; say so rather than draw nothing.
    case .empty: Text("No text output.").llaSmallMuted()
    case .text(let output):
      if detail.input != nil { Text("Output").llaCaption() }
      StepOutputBlock(text: output)
    }
    if let exitCode = detail.exitCode {
      Text("Exit code \(exitCode)").llaSmallMuted()
    }
    ForEach(Array(detail.changes.enumerated()), id: \.offset) { _, change in
      Text(change.path).font(LLAFont.mono(12, weight: .semibold)).foregroundStyle(LLA.Color.ink)
      if let diff = change.diff {
        StepOutputBlock(text: diff)
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

/// A step's text, quiet: small code type on the raised surface, leading-aligned, a long line scrolling
/// sideways inside the block. Past `limit` lines the rest waits behind a link-style control.
struct StepOutputBlock: View {
  let text: String
  @State private var showAll = false
  @Environment(\.holdTranscript) private var holdTranscript
  @State private var memo = Memo()

  static let limit = 20

  /// The text cut at `limit` lines: what is drawn, how many lines there are, and the control's words when
  /// some are left out. A trailing newline ends a line and does not start one.
  struct Cut: Equatable {
    var shown: [String]
    var total: Int
    var control: String?
  }

  static func lines(of text: String, limit: Int = limit) -> Cut {
    var all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    if all.count > 1, all.last == "" { all.removeLast() }
    guard all.count > limit else { return Cut(shown: all, total: all.count, control: nil) }
    return Cut(shown: Array(all.prefix(limit)), total: all.count, control: "Show all \(all.count) lines")
  }

  /// The count of one text, kept across the parent's body evaluations.
  private final class Memo {
    var text: String?
    var cut = Cut(shown: [], total: 0, control: nil)
    func cut(of text: String) -> Cut {
      if self.text != text {
        self.text = text
        cut = StepOutputBlock.lines(of: text)
      }
      return cut
    }
  }

  var body: some View {
    let cut = memo.cut(of: text)
    let hidden = cut.control != nil && !showAll
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      ScrollView(.horizontal) {
        Text(hidden ? cut.shown.joined(separator: "\n") : text)
          .font(LLAFont.codeSmall)
          .foregroundStyle(LLA.Color.ink)
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: true)
          .padding(.horizontal, LLA.Space.m)
          .padding(.vertical, LLA.Space.s)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.surfaceRaised)
      )
      .clipShape(RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous))
      if cut.control != nil {
        Button {
          // As every toggle in the transcript does: the block grows under its row, which stays put.
          holdTranscript()
          showAll.toggle()
        } label: {
          Text(showAll ? "Show fewer lines" : (cut.control ?? ""))
            .font(LLAFont.small)
            .foregroundStyle(LLA.Color.muted)
            .underline()
            .frame(minHeight: LLA.Metrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

extension EnvironmentValues {
  /// Holds the transcript's view (`TranscriptFolds.hold()`) before a control inside a row changes the
  /// row's height; nothing outside a transcript.
  @Entry var holdTranscript: @MainActor () -> Void = {}
}
