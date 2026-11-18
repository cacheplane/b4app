import WorkspaceProtocol

#if DEBUG
  import Synchronization
#endif

/// What a thread draws, in order. No SwiftUI: the views only draw it, so the Mac and
/// the phone read a thread the same way.
enum DenseTranscript {
  enum Entry: Equatable, Identifiable, Sendable {
    /// Drawn by `TranscriptRow`: a user's message, a reply, a plan row or a system item.
    case item(DisplayItem)
    /// The turn's line.
    case line(ActivityLine)
    /// One row of an opened turn's work, drawn by `StepRowView`.
    case step(StepRow)
    /// "Turn failed.", "Turn stopped." or, with no outcome recorded, "Turn ended."
    case note(Turn)
    /// An opened agent's own result, after its children: the call's output, drawn as a step's is.
    case output(StepRow)

    var id: String {
      switch self {
      case .item(let item): return item.id
      case .line(let line): return "steps-\(line.group)"
      case .step(let row): return row.id
      case .note(let turn): return "note-\(turn.id)"
      case .output(let row): return "output-\(row.id)"
      }
    }
  }

  /// A turn's line: what it did, or is doing, how long, and the word that shows or hides its work. A
  /// running turn always has one; an ended turn has one when something folds.
  struct ActivityLine: Equatable, Sendable {
    enum State: Equatable, Sendable {
      case running, waiting, stopping
      /// Ended, of unknown outcome, or a history group.
      case ended
    }

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
    var state: State
    /// Running only: the newest in-progress counted step's name.
    var runningName: String?
    /// The turn's `createdAt` while it has not ended: the clock counts from it.
    var startedAt: String?
    /// Seconds, once the turn has ended and its end is known.
    var duration: Int?

    /// Waiting: "Waiting for you"; stopping: "Stopping"; running: the name, else "Working".
    /// Ended: "4 steps" / "1 step", or nil when nothing is counted.
    var text: String? {
      switch state {
      case .waiting: return "Waiting for you"
      case .stopping: return "Stopping"
      case .running: return runningName ?? "Working"
      case .ended:
        guard counted > 0 else { return nil }
        return counted == 1 ? "1 step" : "\(counted) steps"
      }
    }

    var failedText: String? { failed > 0 ? "\(failed) failed" : nil }
    var declinedText: String? { declined > 0 ? "\(declined) declined" : nil }

    /// The turn's duration, written after an ended line's count.
    var durationText: String? {
      guard state == .ended, counted > 0, let duration else { return nil }
      return ActivityTime.duration(duration)
    }

    /// There is something to show.
    var canOpen: Bool { !folded.isEmpty }

    /// The working mark is drawn: the turn is running or stopping, not waiting for the owner.
    var marked: Bool { state == .running || state == .stopping }

    /// "Show" / "Hide"; "Show working" / "Hide working" when `text` is nil; nil when nothing folds.
    func action(open: Bool) -> String? {
      guard canOpen else { return nil }
      let verb = open ? "Hide" : "Show"
      return text == nil ? "\(verb) working" : verb
    }

    /// text, failedText, declinedText, durationText and the action, joined by ", ".
    func spoken(open: Bool) -> String {
      [text, failedText, declinedText, durationText, action(open: open)].compactMap { $0 }
        .joined(separator: ", ")
    }
  }

  /// The longest name the running line draws.
  static let nameLimit = 120

  /// The title a tool item's step row draws.
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

  #if DEBUG
    /// Calls of `entries` by thread id, for the test that a streamed token does not run
    /// the grouping again. Keyed by thread so tests running beside it do not move its count.
    private static let projectionCalls = Mutex<[String: Int]>([:])

    static func projections(of thread: String) -> Int { projectionCalls.withLock { $0[thread] ?? 0 } }

    private static func countProjection(_ items: [DisplayItem]) {
      guard let thread = items.first?.threadId else { return }
      projectionCalls.withLock { $0[thread, default: 0] += 1 }
    }
  #endif

  /// `open` holds the groups whose lines are open and the ids of the step rows that are open; an agent's
  /// row draws its children only while its id is there.
  static func entries(items: [DisplayItem], turns: [Turn], open: Set<String>) -> [Entry] {
    #if DEBUG
      countProjection(items)
    #endif
    let known = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = drawn(items).enumerated().sorted {
      ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset)
    }.map(\.element)
    // A sub-agent's items stand under the call that started it, never at their turn's level: from here
    // on the groups, their answers, counts and running names see only the top level.
    let tree = Tree(ordered)
    let topLevel = ordered.filter { !tree.isChild($0) }
    let rows = Rows(tree: tree, open: open)

    // One pass: each item goes to a group. A turn's items are gathered where its first stands, and a
    // turnless item joins the group of the item before it; before any group it is drawn as it is.
    var groupOrder: [String] = []
    var members: [String: [DisplayItem]] = [:]
    var layoutOrder: [Entry?] = []  // a plain item, or nil where the next group goes
    for (item, key) in zip(topLevel, groupKeys(topLevel)) {
      guard let key else {
        // No line stands above it, so its work is a row of its own; a turnless step never runs.
        if isWork(item) {
          layoutOrder += rows.entries(for: item, turn: nil).map(Optional.some)
        } else {
          layoutOrder.append(.item(item))
        }
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
        result += layout(
          key: key, items: members[key] ?? [], turn: known[key], isOpen: open.contains(key), rows: rows)
      }
    }

    let drawn = Set(groupOrder)
    // A turn with no items here: a running one (begun on another device, its message not here yet)
    // has its line from the moment it exists; a failed or stopped one, its note.
    for turn in turns where !drawn.contains(turn.id) {
      if runningStatuses.contains(turn.status) {
        result.append(.line(activityLine(key: turn.id, folded: [], turn: turn, tree: tree)))
      }
      if hasNote(turn) { result.append(.note(turn)) }
    }
    return result
  }

  /// The word a step row is spoken with for its status: "Running, swift test, 24 seconds".
  static func statusLabel(_ status: String) -> String {
    switch status {
    case "inProgress": return "Running"
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

  private static func hasNote(_ turn: Turn) -> Bool {
    turn.status == .terminal && turn.outcome != .completed
  }

  /// One group: the user's messages, the line, what the turn shows, its system items, its note.
  private static func layout(
    key: String, items: [DisplayItem], turn: Turn?, isOpen: Bool, rows: Rows
  ) -> [Entry] {
    let running = turn.map { runningStatuses.contains($0.status) } ?? false
    let shown = items.map { settled($0, in: turn) }

    let users = shown.filter { $0.role == .user }
    let systems = shown.filter { $0.role == .system }
    let rest = shown.filter { $0.role != .user && $0.role != .system }
    // A sub-agent's item whose call is not here (`Tree` left it at the top level) is still folded work:
    // never the answer and never drawn after the line.
    func isSubAgents(_ item: DisplayItem) -> Bool { item.payload["parentNativeItemId"]?.stringValue != nil }
    func isMessage(_ item: DisplayItem) -> Bool {
      item.role == .assistant && item.type == "agentMessage" && !isSubAgents(item)
    }
    // A message with no text is never the answer: it would stand after the line as an empty row.
    func hasText(_ item: DisplayItem) -> Bool {
      !(item.payload["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The messages the closed group draws after its line.
    var visible: [DisplayItem]
    if running {
      // A running turn's plan is drawn as its messages are: it says what the agent is doing.
      visible = rest.filter { isMessage($0) || ($0.type == TaskList.itemType && !isSubAgents($0)) }
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
    // A running turn always has its line: it is the one place that says the turn is working. An ended
    // one has it when something folds.
    if running || !folded.isEmpty {
      entries.append(.line(activityLine(key: key, folded: folded, turn: turn, tree: rows.tree)))
    }
    if isOpen && !folded.isEmpty {
      // Opened, the work is drawn row by row where it stands; what the closed group shows is unchanged.
      entries += rest.flatMap { item in
        shownIds.contains(item.id) ? [.item(item)] : rows.entries(for: item, turn: turn)
      }
    } else {
      entries += visible.map(Entry.item)
    }
    entries += systems.map(Entry.item)
    if let turn, hasNote(turn) { entries.append(.note(turn)) }
    return entries
  }

  /// The line of one group.
  private static func activityLine(
    key: String, folded: [DisplayItem], turn: Turn?, tree: Tree
  ) -> ActivityLine {
    let steps = folded.filter(isCountedStep)
    let state: ActivityLine.State
    switch turn?.status {
    case .submitting?, .running?: state = .running
    case .waitingForUser?: state = .waiting
    case .stopping?: state = .stopping
    default: state = .ended
    }
    return ActivityLine(
      group: key, folded: folded, counted: steps.count,
      failed: steps.filter { $0.payload["status"]?.stringValue == "failed" }.count,
      declined: steps.filter { $0.payload["status"]?.stringValue == "declined" }.count,
      state: state, runningName: state == .running ? runningName(of: steps, tree: tree) : nil,
      startedAt: state == .ended ? nil : turn?.createdAt,
      duration: state == .ended ? duration(of: turn) : nil)
  }

  /// How long a terminal turn took: `updatedAt` less `createdAt`. `updatedAt` is when the turn ended
  /// because `SessionService` does not touch a terminal turn but for a second `turnFinished`, the one way
  /// a duration reads long. A turn whose outcome is unknown, or a history group, has none.
  private static func duration(of turn: Turn?) -> Int? {
    guard let turn, turn.status == .terminal,
      let seconds = ActivityTime.seconds(from: turn.createdAt, to: turn.updatedAt)
    else { return nil }
    return max(seconds, 0)
  }

  /// The newest in-progress step's name: B4's label, else an agent's title, else the step's title (a B4
  /// call whose input is not a string: its name alone); first line, trimmed, cut.
  private static func runningName(of steps: [DisplayItem], tree: Tree) -> String? {
    guard let step = steps.last(where: { $0.payload["status"]?.stringValue == "inProgress" }) else {
      return nil
    }
    let label = step.payload["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let source: String
    if let label, !label.isEmpty {
      source = label
    } else if isAgent(step, children: tree.children(of: step)) {
      source = agentTitle(of: step)
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

// MARK: step rows

extension DenseTranscript {
  /// One row of an opened turn: a mark, a title and a time on one line, which opens to the step's
  /// output; an interim message or a plan drawn as it is.
  struct StepRow: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
      /// A counted step.
      case step
      /// A sub-agent's call and how many counted steps it holds.
      case agent(steps: Int)
      /// Reasoning: "Thought", which opens to its text.
      case thought
      /// An interim message, drawn as its text.
      case message
      /// A task list, drawn as `TaskListRow`.
      case plan
      /// Any other working row: a step row that is not counted.
      case other
    }

    enum Mark: Equatable, Sendable {
      case done, running, failed, declined, unfinished, none
      /// In progress in a turn waiting for the user: still, with no clock, as the turn's line is.
      case waiting
    }

    /// Settled: a step of a turn that is no longer running never reads as in progress.
    var item: DisplayItem
    /// How far in the row is drawn, 1 to 4.
    var depth: Int
    var kind: Kind
    var mark: Mark
    var title: String
    /// A running step's `createdAt`: its clock counts from it. Only a counted step or an agent has one.
    var startedAt: String?
    /// Seconds, once the step's end is known.
    var duration: Int?
    /// It has something to draw when pressed: a step's output, a thought's text, an agent's steps.
    var opens: Bool

    var id: String { item.id }

    /// The state in words, for a row that has a status: "Running", "Waiting", "Completed", "Unfinished".
    var state: String? {
      if mark == .waiting { return "Waiting" }
      switch kind {
      case .step, .agent, .other: return item.payload["status"]?.stringValue.map(DenseTranscript.statusLabel)
      case .thought, .message, .plan: return nil
      }
    }

    /// The state, the title and the duration: "Completed, swift test, 8 seconds". A running step's
    /// clock speaks its own time after it.
    var spoken: String {
      [state, title, duration.map(ActivityTime.words)].compactMap { $0 }.joined(separator: ", ")
    }
  }

  /// A tool or a reasoning item: drawn as a step row, never by `TranscriptRow`.
  static func isWork(_ item: DisplayItem) -> Bool {
    item.role == .tool || (item.role == .assistant && item.type != "agentMessage")
  }

  /// A call that starts a sub-agent: Claude Code's `Task` (`Agent` since 2.1) and Codex's
  /// `collabAgentToolCall`.
  private static func startsAgent(_ item: DisplayItem) -> Bool {
    switch item.type {
    case "collabAgentToolCall": return true
    case "toolUse": return ["Task", "Agent"].contains(item.payload["name"]?.stringValue)
    default: return false
    }
  }

  /// An item drawn as a sub-agent's row: one with children, or a call that starts a sub-agent.
  static func isAgent(_ item: DisplayItem, children: [DisplayItem]) -> Bool {
    !children.isEmpty || startsAgent(item)
  }

  /// "Agent: <text>": the call's `input.description`, else the first line of its prompt (Codex's
  /// `prompt`, or `input.prompt`), trimmed and cut at `nameLimit`; "Agent" without one.
  static func agentTitle(of item: DisplayItem) -> String {
    func firstLine(_ value: JSONValue?) -> String {
      let text = value?.stringValue ?? ""
      let first = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
      return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let sources = [
      item.payload["input"]?["description"], item.payload["prompt"], item.payload["input"]?["prompt"],
    ]
    guard let name = sources.lazy.map(firstLine).first(where: { !$0.isEmpty }) else { return "Agent" }
    return "Agent: " + (name.count > nameLimit ? String(name.prefix(nameLimit - 1)) + "…" : name)
  }

  /// The detail has something to draw: an input, an output, an exit code, changes, or the payload.
  private static func shows(_ detail: ToolEvidence.Detail) -> Bool {
    detail.input != nil || detail.output != .none || detail.exitCode != nil || !detail.changes.isEmpty
      || detail.raw != nil
  }

  /// Which items a sub-agent made, in a thread: an item whose `parentNativeItemId` names another item's
  /// `nativeItemId` is that item's child. Made once a projection. An item whose parents lead back to
  /// itself (a malformed field) is no child, so every child is reached from a top-level item.
  struct Tree {
    /// By the parent's item id, in sequence order.
    private var byParent: [String: [DisplayItem]] = [:]
    private var childIds: Set<String> = []

    /// `ordered`: the thread's items in sequence order.
    init(_ ordered: [DisplayItem]) {
      var byNative: [String: DisplayItem] = [:]
      for item in ordered {
        if let native = item.nativeItemId, byNative[native] == nil { byNative[native] = item }
      }
      guard !byNative.isEmpty else { return }
      func named(by item: DisplayItem) -> DisplayItem? {
        item.payload["parentNativeItemId"]?.stringValue.flatMap { byNative[$0] }
      }
      for item in ordered {
        guard let parent = named(by: item) else { continue }
        // Up the parents until one has none, one is seen twice, or the item itself comes back.
        var seen: Set<String> = []
        var ancestor: DisplayItem? = parent
        var cycles = false
        while let current = ancestor, seen.insert(current.id).inserted {
          if current.id == item.id {
            cycles = true
            break
          }
          ancestor = named(by: current)
        }
        guard !cycles else { continue }
        byParent[parent.id, default: []].append(item)
        childIds.insert(item.id)
      }
    }

    func isChild(_ item: DisplayItem) -> Bool { childIds.contains(item.id) }
    func children(of item: DisplayItem) -> [DisplayItem] { byParent[item.id] ?? [] }
  }

  /// Makes a work item's rows: its own and, while it is an agent whose id is open, its children's one
  /// level in, each made the same way, then the agent's own result.
  struct Rows {
    let tree: Tree
    let open: Set<String>

    /// A child settles with the turn of the row it stands under, whatever turn it names.
    func entries(for item: DisplayItem, turn: Turn?, depth: Int = 1) -> [Entry] {
      let children = tree.children(of: item)
      let row = stepRow(settled(item, in: turn), in: turn?.status, depth: depth, children: children)
      guard case .agent = row.kind, open.contains(row.id) else { return [.step(row)] }
      var result: [Entry] = [.step(row)]
      for child in children { result += entries(for: child, turn: turn, depth: depth + 1) }
      // Its result; with none, what else the call recorded, only when it has no children to show: a
      // sub-agent's prompt is never drawn under its steps.
      let detail = ToolEvidence.detail(of: row.item)
      if detail.output != .none || (children.isEmpty && shows(detail)) { result.append(.output(row)) }
      return result
    }
  }

  /// The row of one settled item of a turn in `status` (nil: no turn, or one the list does not know).
  /// `children`: the items a sub-agent it started made.
  static func stepRow(
    _ item: DisplayItem, in status: TurnStatus?, depth: Int = 1, children: [DisplayItem] = []
  ) -> StepRow {
    let kind: StepRow.Kind
    if isAgent(item, children: children) {
      kind = .agent(steps: children.filter(isCountedStep).count)
    } else if item.role == .assistant {
      kind = item.type == "agentMessage" ? .message : .thought
    } else if item.type == TaskList.itemType {
      kind = .plan
    } else {
      kind = isCountedStep(item) ? .step : .other
    }
    let mark: StepRow.Mark
    switch (kind, item.payload["status"]?.stringValue) {
    case (.thought, _), (.message, _), (.plan, _): mark = .none
    case (_, "completed"?): mark = .done
    case (_, "inProgress"?): mark = status == .waitingForUser ? .waiting : .running
    case (_, "failed"?): mark = .failed
    case (_, "declined"?): mark = .declined
    case (_, "stopped"?), (_, "unknown"?): mark = .unfinished
    default: mark = .none
    }
    let title: String
    let opens: Bool
    switch kind {
    case .thought:
      title = "Thought"
      opens = !thoughtText(of: item).isEmpty
    case .message:
      title = item.payload["text"]?.stringValue ?? ""
      opens = false
    case .plan:
      title = DenseTranscript.title(of: item)
      opens = false
    case .agent(let steps):
      let count = steps == 0 ? "" : steps == 1 ? " · 1 step" : " · \(steps) steps"
      title = agentTitle(of: item) + count
      opens = !children.isEmpty || shows(ToolEvidence.detail(of: item))
    case .step, .other:
      title = DenseTranscript.title(of: item)
      opens = shows(ToolEvidence.detail(of: item))
    }
    return StepRow(
      item: item, depth: min(max(depth, 1), 4), kind: kind, mark: mark, title: title,
      startedAt: mark == .running && kind != .other ? item.createdAt : nil,
      duration: duration(of: item, kind: kind, mark: mark), opens: opens)
  }

  /// Seconds from the item's creation to its `endedAt`: only a step or an agent that is not running or
  /// waiting has one, and a step with no end (or one that does not parse) has none.
  private static func duration(of item: DisplayItem, kind: StepRow.Kind, mark: StepRow.Mark) -> Int? {
    switch kind {
    case .step, .agent: break
    case .other, .thought, .message, .plan: return nil
    }
    guard mark != .running, mark != .waiting,
      let endedAt = item.payload["endedAt"]?.stringValue,
      let seconds = ActivityTime.seconds(from: item.createdAt, to: endedAt)
    else { return nil }
    return max(seconds, 0)
  }

  /// A reasoning item's text: its text, else its summary, else its content, one part a line.
  static func thoughtText(of item: DisplayItem) -> String {
    if let text = item.payload["text"]?.stringValue, !text.isEmpty { return text }
    let summary = item.payload["summary"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if !summary.isEmpty { return summary.joined(separator: "\n") }
    return item.payload["content"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "\n") ?? ""
  }

  /// The entries in runs drawn as one child of the column: a step row or an agent's result joins the
  /// line, step row or result before it, so an opened turn's rows stand close under its line. Every
  /// entry is in one run, in order.
  static func runs(_ entries: [Entry]) -> [[Entry]] {
    var runs: [[Entry]] = []
    for entry in entries {
      let joins: Bool
      switch entry {
      case .step, .output: joins = true
      case .item, .line, .note: joins = false
      }
      if joins, let last = runs.last?.last {
        switch last {
        case .line, .step, .output:
          runs[runs.count - 1].append(entry)
          continue
        case .item, .note: break
        }
      }
      runs.append([entry])
    }
    return runs
  }
}
