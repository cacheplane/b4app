import WorkspaceProtocol

/// What a thread draws at dense density, in order. No SwiftUI: the views only draw it, so the Mac and
/// the phone read a thread the same way.
enum DenseTranscript {
  enum Entry: Equatable, Identifiable, Sendable {
    /// Drawn by `TranscriptRow`, as at normal density.
    case item(DisplayItem)
    /// The turn's line.
    case line(StepsLine)
    /// "Turn failed." / "Turn stopped."
    case note(Turn)

    var id: String {
      switch self {
      case .item(let item): return item.id
      case .line(let line): return "steps-\(line.group)"
      case .note(let turn): return "note-\(turn.id)"
      }
    }
  }

  struct StepsLine: Equatable, Sendable {
    /// The turn id, or "h-<user item id>" for a history group.
    var group: String
    /// What the closed line hides, in sequence order.
    var folded: [DisplayItem]
    /// Counted steps, whatever their status.
    var counted: Int
    /// Counted steps whose status is "failed".
    var failed: Int
    /// Counted steps whose status is "declined".
    var declined: Int
    var running: Bool
    /// Running, and the turn's status is waiting_for_user.
    var waiting: Bool
    /// Running only: the newest in-progress counted step's name.
    var runningName: String?

    /// Running: "Waiting for you", else the name, else "Working".
    /// Ended: "4 steps" / "1 step", or nil when nothing is counted.
    var text: String? {
      if running {
        if waiting { return "Waiting for you" }
        return runningName ?? "Working"
      }
      guard counted > 0 else { return nil }
      return counted == 1 ? "1 step" : "\(counted) steps"
    }

    var failedText: String? { failed > 0 ? "\(failed) failed" : nil }
    var declinedText: String? { declined > 0 ? "\(declined) declined" : nil }

    /// "Show" / "Hide"; "Show working" / "Hide working" when `text` is nil.
    func action(open: Bool) -> String {
      let verb = open ? "Hide" : "Show"
      return text == nil ? "\(verb) working" : verb
    }

    /// text, failedText, declinedText and the action, joined by ", ".
    func spoken(open: Bool) -> String {
      [text, failedText, declinedText, action(open: open)].compactMap { $0 }.joined(separator: ", ")
    }
  }

  /// The longest name the running line draws.
  static let nameLimit = 120

  /// The title a tool item's card draws.
  static func title(of item: DisplayItem) -> String {
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

  private static let toolTypes: Set<String> = [
    "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageView",
    "toolCall", "toolUse", "collabAgentToolCall", "imageGeneration",
  ]

  /// Claude Code tools that keep a plan, a task list or the conversation, rather than act.
  private static let workingToolNames: Set<String> = [
    "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ExitPlanMode", "AskUserQuestion",
  ]

  /// A counted step is a tool call, by type; plan and capability items are working, not steps.
  static func isCountedStep(_ item: DisplayItem) -> Bool {
    guard item.role == .tool, toolTypes.contains(item.type) else { return false }
    if item.type == "toolUse", let name = item.payload["name"]?.stringValue, workingToolNames.contains(name) {
      return false
    }
    return true
  }

  /// `open` holds the groups whose lines are open.
  static func entries(items: [DisplayItem], turns: [Turn], open: Set<String>) -> [Entry] {
    let known = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = items.enumerated().sorted {
      ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset)
    }.map(\.element)

    // One pass: each item goes to a group. A turn's items are gathered where its first stands, and a
    // turnless item joins the group of the item before it; before any group it is drawn as it is.
    var groupOrder: [String] = []
    var members: [String: [DisplayItem]] = [:]
    var layoutOrder: [Entry?] = []  // a plain item, or nil where the next group goes
    var current: String?
    for item in ordered {
      let key: String?
      if let turnId = item.turnId {
        key = turnId
      } else if item.role == .user {
        key = "h-\(item.id)"
      } else {
        key = current
      }
      guard let key else {
        layoutOrder.append(.item(item))
        continue
      }
      current = key
      if members[key] == nil {
        groupOrder.append(key)
        layoutOrder.append(nil)
      }
      members[key, default: []].append(item)
    }
    var result: [Entry] = []
    var nextGroup = groupOrder.makeIterator()
    for slot in layoutOrder {
      if let slot {
        result.append(slot)
      } else if let key = nextGroup.next() {
        result += layout(key: key, items: members[key] ?? [], turn: known[key], isOpen: open.contains(key))
      }
    }

    let drawn = Set(groupOrder)
    for turn in turns where !drawn.contains(turn.id) && hasNote(turn) {
      result.append(.note(turn))
    }
    return result
  }

  private static let runningStatuses: Set<TurnStatus> = [.submitting, .running, .waitingForUser, .stopping]

  private static func hasNote(_ turn: Turn) -> Bool {
    turn.status == .terminal && turn.outcome != .completed
  }

  /// One group: the user's messages, the line, what the turn shows, its system items, its note.
  private static func layout(key: String, items: [DisplayItem], turn: Turn?, isOpen: Bool) -> [Entry] {
    let running = turn.map { runningStatuses.contains($0.status) } ?? false
    // A turn that is not running never shows a running step, except one whose outcome is unknown.
    let stopsSteps = !running && turn?.status != .reconciling
    let shown = stopsSteps ? items.map(stopped) : items

    let users = shown.filter { $0.role == .user }
    let systems = shown.filter { $0.role == .system }
    let rest = shown.filter { $0.role != .user && $0.role != .system }
    func isMessage(_ item: DisplayItem) -> Bool { item.role == .assistant && item.type == "agentMessage" }
    // A message with no text is never the answer: it would stand after the line as an empty row.
    func hasText(_ item: DisplayItem) -> Bool {
      !(item.payload["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The messages the closed group draws after its line.
    var visible: [DisplayItem]
    if running {
      visible = rest.filter(isMessage)
    } else if let last = rest.last(where: { isMessage($0) && hasText($0) }),
      !rest.drop(while: { $0.id != last.id }).contains(where: isCountedStep)
    {
      visible = [last]
    } else {
      visible = []
    }
    let shownIds = Set(visible.map(\.id))
    let folded = rest.filter { !shownIds.contains($0.id) }

    var entries: [Entry] = users.map(Entry.item)
    if !folded.isEmpty {
      let steps = folded.filter(isCountedStep)
      entries.append(
        .line(
          StepsLine(
            group: key, folded: folded, counted: steps.count,
            failed: steps.filter { $0.payload["status"]?.stringValue == "failed" }.count,
            declined: steps.filter { $0.payload["status"]?.stringValue == "declined" }.count,
            running: running, waiting: running && turn?.status == .waitingForUser,
            runningName: running ? runningName(of: steps) : nil)))
    }
    entries += (isOpen && !folded.isEmpty ? rest : visible).map(Entry.item)
    entries += systems.map(Entry.item)
    if let turn, hasNote(turn) { entries.append(.note(turn)) }
    return entries
  }

  /// The newest in-progress step's name: B4's label, else the card's title (a B4 call whose input is
  /// not a string: its name alone); first line, trimmed, cut.
  private static func runningName(of steps: [DisplayItem]) -> String? {
    guard let step = steps.last(where: { $0.payload["status"]?.stringValue == "inProgress" }) else {
      return nil
    }
    let label = step.payload["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let source: String
    if let label, !label.isEmpty {
      source = label
    } else if step.type == "toolCall", let input = step.payload["input"], !input.isNull,
      input.stringValue == nil
    {
      source = step.payload["name"]?.stringValue ?? "Tool"
    } else {
      source = title(of: step)
    }
    let firstLine =
      source.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let name = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    guard name.count > nameLimit else { return name }
    return String(name.prefix(nameLimit - 1)) + "…"
  }

  /// A step still in progress in a turn that has ended reads "stopped"; the stored item is untouched.
  private static func stopped(_ item: DisplayItem) -> DisplayItem {
    guard item.role == .tool, item.payload["status"]?.stringValue == "inProgress",
      case .object(var members) = item.payload
    else { return item }
    members["status"] = .string("stopped")
    var copy = item
    copy.payload = .object(members)
    return copy
  }
}
