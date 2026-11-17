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
    /// What a running turn is doing, where no steps line says it.
    case running(RunningLine)

    var id: String {
      switch self {
      case .item(let item): return item.id
      case .line(let line): return "steps-\(line.group)"
      case .note(let turn): return "note-\(turn.id)"
      case .running(let line): return "running-\(line.turn)"
      }
    }
  }

  /// A running turn's line (D-239): at normal density after the turn's last item, and at dense where
  /// the turn has nothing to fold and no reply yet. It is not a control.
  struct RunningLine: Equatable, Sendable {
    var turn: String
    /// The turn's status is waiting_for_user.
    var waiting: Bool
    /// The newest in-progress counted step's name.
    var name: String?

    /// "Waiting for you", else the name, else "Working": the words a dense steps line draws.
    var text: String { waiting ? "Waiting for you" : name ?? "Working" }
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
    case TaskList.itemType: return "Plan"
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

  /// The items a thread draws: a task list with no steps (a plan the agent emptied) is not one.
  private static func drawn(_ items: [DisplayItem]) -> [DisplayItem] {
    items.filter { $0.type != TaskList.itemType || !($0.payload["steps"]?.arrayValue ?? []).isEmpty }
  }

  /// `open` holds the groups whose lines are open.
  static func entries(items: [DisplayItem], turns: [Turn], open: Set<String>) -> [Entry] {
    let known = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = drawn(items).enumerated().sorted {
      ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset)
    }.map(\.element)

    // One pass: each item goes to a group. A turn's items are gathered where its first stands, and a
    // turnless item joins the group of the item before it; before any group it is drawn as it is.
    var groupOrder: [String] = []
    var members: [String: [DisplayItem]] = [:]
    var layoutOrder: [Entry?] = []  // a plain item, or nil where the next group goes
    for (item, key) in zip(ordered, groupKeys(ordered)) {
      guard let key else {
        layoutOrder.append(.item(item))
        continue
      }
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

  /// Normal density: every item in the order given, a step of an ended turn settled as at dense, and
  /// each turn's note, or a running turn's line, after that turn's last item (a turn with no items:
  /// after everything).
  static func plain(items stored: [DisplayItem], turns: [Turn]) -> [Entry] {
    let items = drawn(stored)
    let known = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let keys = groupKeys(items)
    var last: [String: Int] = [:]
    for (index, key) in keys.enumerated() {
      if let key { last[key] = index }
    }
    var result: [Entry] = []
    for (index, item) in items.enumerated() {
      guard let key = keys[index] else {
        result.append(.item(item))
        continue
      }
      result.append(.item(settled(item, in: known[key])))
      guard last[key] == index, let turn = known[key] else { continue }
      if hasNote(turn) { result.append(.note(turn)) }
      if let line = runningLine(of: turn, items: zip(items, keys).filter { $0.1 == key }.map(\.0)) {
        result.append(.running(line))
      }
    }
    for turn in turns where last[turn.id] == nil {
      if hasNote(turn) { result.append(.note(turn)) }
      if let line = runningLine(of: turn, items: []) { result.append(.running(line)) }
    }
    return result
  }

  /// The word a step's badge draws for its status. "In progress" and not "Running": a runtime opens
  /// a step when it names the tool, before its arguments are complete or a permission is answered.
  static func statusLabel(_ status: String) -> String {
    switch status {
    case "inProgress": return "In progress"
    case "completed": return "Completed"
    case "failed": return "Failed"
    case "declined": return "Declined"
    case "stopped": return "Unfinished"
    case "unknown": return "Unknown"
    default: return status
    }
  }

  /// How many rows a thread draws before "Show earlier": the transcript lays out every row it draws.
  static let page = 150

  /// The latest part of a thread's rows, and how many earlier ones it leaves out.
  struct Window: Equatable, Sendable {
    var hidden: Int
    var entries: [Entry]
  }

  /// The last `shown` entries, begun at a user's message when one stands within `page / 5` entries
  /// before the cut, so a turn is not begun in its middle when its start is near.
  static func window(_ entries: [Entry], shown: Int) -> Window {
    guard entries.count > shown, shown > 0 else { return Window(hidden: 0, entries: entries) }
    var start = entries.count - shown
    let reach = max(start - page / 5, 0)
    if let turnStart = entries[reach..<start + 1].lastIndex(where: { entry in
      if case .item(let item) = entry { return item.role == .user }
      return false
    }) {
      start = turnStart
    }
    return Window(hidden: start, entries: Array(entries[start...]))
  }

  /// The group each item belongs to, in the order given: its turn, a history group opened by a
  /// turnless user message, or the group of the item before it; nil before any group.
  private static func groupKeys(_ items: [DisplayItem]) -> [String?] {
    var current: String?
    return items.map { item in
      if let turnId = item.turnId {
        current = turnId
      } else if item.role == .user {
        current = "h-\(item.id)"
      }
      return current
    }
  }

  private static let runningStatuses: Set<TurnStatus> = [.submitting, .running, .waitingForUser, .stopping]

  /// The line of a turn that is running, named from its items; nil for any other turn.
  private static func runningLine(of turn: Turn, items: [DisplayItem]) -> RunningLine? {
    guard runningStatuses.contains(turn.status) else { return nil }
    return RunningLine(
      turn: turn.id, waiting: turn.status == .waitingForUser,
      name: runningName(of: items.filter(isCountedStep)))
  }

  private static func hasNote(_ turn: Turn) -> Bool {
    turn.status == .terminal && turn.outcome != .completed
  }

  /// One group: the user's messages, the line, what the turn shows, its system items, its note.
  private static func layout(key: String, items: [DisplayItem], turn: Turn?, isOpen: Bool) -> [Entry] {
    let running = turn.map { runningStatuses.contains($0.status) } ?? false
    let shown = items.map { settled($0, in: turn) }

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
      // A running turn's plan is drawn as its messages are: it says what the agent is doing.
      visible = rest.filter { isMessage($0) || $0.type == TaskList.itemType }
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
    // Nothing to fold and no reply yet: between the send and the turn's first item.
    if folded.isEmpty, visible.isEmpty, let turn, let line = runningLine(of: turn, items: []) {
      entries.append(.running(line))
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

  /// A step still in progress in a turn that is not running never reads as in progress: "stopped"
  /// (drawn "Unfinished") once the turn has ended, since nothing recorded says it finished, and
  /// "unknown" while the turn's outcome is unknown. The stored item is untouched.
  private static func settled(_ item: DisplayItem, in turn: Turn?) -> DisplayItem {
    if let turn, runningStatuses.contains(turn.status) { return item }
    let word = turn?.status == .reconciling ? "unknown" : "stopped"
    // A task list's own status is always completed; it is its steps that a turn can leave open.
    if item.type == TaskList.itemType, case .object(var members) = item.payload,
      let steps = members["steps"]?.arrayValue
    {
      members["steps"] = .array(
        steps.map { step in
          guard step["status"]?.stringValue == "inProgress", case .object(var fields) = step else {
            return step
          }
          fields["status"] = .string(word)
          return .object(fields)
        })
      var copy = item
      copy.payload = .object(members)
      return copy
    }
    guard item.role == .tool, item.payload["status"]?.stringValue == "inProgress",
      case .object(var members) = item.payload
    else { return item }
    members["status"] = .string(word)
    var copy = item
    copy.payload = .object(members)
    return copy
  }
}
