import SwiftUI
import WorkspaceProtocol

/// How a step of a turn's task list is drawn once the turn's state is applied.
enum TaskStepMark: Equatable, Sendable {
  case done, running, pending, unfinished, unknown

  /// The stored status, as an adapter wrote it or as `DenseTranscript.settled` rewrote it for a turn
  /// that is no longer running. Anything else is pending: a step is never read as done or under way
  /// unless something said so.
  init(status: String?) {
    switch status {
    case "completed": self = .done
    case "inProgress": self = .running
    case "stopped": self = .unfinished
    case "unknown": self = .unknown
    default: self = .pending
    }
  }

  /// The state VoiceOver reads after a step's text.
  var spoken: String {
    switch self {
    case .done: return "done"
    case .running: return "in progress"
    case .pending: return "not started"
    case .unfinished: return "unfinished"
    case .unknown: return "unknown"
    }
  }
}

/// What the row of a `taskList` item says: the words, decided without SwiftUI.
struct TaskListDisplay: Equatable, Sendable {
  struct Step: Equatable, Sendable {
    var text: String
    var mark: TaskStepMark
    var accessibilityLabel: String { "\(text), \(mark.spoken)" }
  }

  var header: String
  var accessibilityHeader: String
  var explanation: String?
  var steps: [Step]

  /// Nil unless the item is a task list with at least one step: an emptied list draws nothing.
  init?(item: DisplayItem) {
    guard item.type == TaskList.itemType, let stored = item.payload["steps"]?.arrayValue, !stored.isEmpty
    else { return nil }
    steps = stored.map {
      Step(text: $0["text"]?.stringValue ?? "", mark: TaskStepMark(status: $0["status"]?.stringValue))
    }
    let done = steps.filter { $0.mark == .done }.count
    header = "Plan · \(done) of \(steps.count)"
    accessibilityHeader = "Plan, \(done) of \(steps.count) done"
    explanation = item.payload["explanation"]?.stringValue
  }
}

/// A turn's plan or task list: how much is done, then each step with its mark. One row per turn,
/// whichever runtime keeps the list; its payload is replaced as the agent updates it.
struct TaskListRow: View {
  let display: TaskListDisplay

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text(display.header)
        .font(LLAFont.smallStrong)
        .foregroundStyle(LLA.Color.ink)
        .accessibilityLabel(display.accessibilityHeader)
        .accessibilityAddTraits(.isHeader)
      if let explanation = display.explanation {
        Text(explanation).llaSmallMuted().lineLimit(1).truncationMode(.tail)
      }
      ForEach(Array(display.steps.enumerated()), id: \.offset) { _, step in
        HStack(alignment: .firstTextBaseline, spacing: LLA.Space.s) {
          TaskStepMarkView(mark: step.mark)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + LLA.Metrics.mark / 3 }
            .accessibilityHidden(true)
          Text(step.text)
            .font(LLAFont.small)
            .foregroundStyle(step.mark == .running ? LLA.Color.ink : LLA.Color.muted)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.accessibilityLabel)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("task-list")
  }
}

/// A step's mark in the 12 pt box the thread marks use: a check, the working mark, an open circle, a
/// dash for a step its turn left unfinished, a dotted circle for one whose state is not known.
private struct TaskStepMarkView: View {
  let mark: TaskStepMark

  var body: some View {
    Group {
      switch mark {
      case .done:
        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(
          LLA.Color.muted)
      case .running:
        ThreadMark(state: .working)
      case .pending:
        Circle().strokeBorder(LLA.Color.muted, lineWidth: 1).frame(width: 8, height: 8)
      case .unfinished:
        Capsule().fill(LLA.Color.muted).frame(width: 8, height: 1.5)
      case .unknown:
        Circle().strokeBorder(LLA.Color.muted, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
          .frame(width: 8, height: 8)
      }
    }
    .frame(width: LLA.Metrics.mark, height: LLA.Metrics.mark)
  }
}
