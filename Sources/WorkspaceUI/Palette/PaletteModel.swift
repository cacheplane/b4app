import Foundation
import Observation
import SwiftUI
import WorkspaceProtocol

/// What the palette is open for. Find searches the workspace; Commands lists what can be done.
public nonisolated enum PalettePurpose: Sendable, Equatable {
  case find, commands

  var title: String { self == .find ? "Find" : "Commands" }
}

extension WorkspaceModel {
  /// Open the palette for `purpose`, or move an open one to it.
  public func presentPalette(_ purpose: PalettePurpose) {
    palettePurpose = purpose
    paletteRequest += 1
    showSearch = true
  }

  /// Close the palette and put the cursor back where writing happens: the open thread's composer, or
  /// the new-thread draft. The drafts themselves were never touched.
  func dismissPalette() {
    guard showSearch else { return }
    showSearch = false
    #if os(macOS)
      if selectedThreadId == nil { newThreadFocusRequest += 1 } else { composerFocusRequest += 1 }
    #endif
  }
}

/// Thread titles as lists show them, and the clamp the keyboard-driven lists share.
enum ThreadSearch {
  static func shownTitle(_ thread: ConversationThread) -> String {
    thread.title.isEmpty ? "Untitled" : thread.title
  }

  /// Move a highlight by `delta`, staying inside `0..<count`.
  static func step(_ index: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + delta, 0), count - 1)
  }
}

// MARK: - Rows

/// One selectable row. Its `id` is the identity of what it stands for, so a selection survives the
/// list changing around it.
struct PaletteItem: Identifiable, Equatable {
  enum Kind: Equatable {
    case thread(String)
    case command(CommandID, CommandTarget)
    case choice(CommandChoice)
    /// A runtime's command, as the text that goes in the draft ("/compact ").
    case runtime(String)
  }

  var id: String
  var kind: Kind
  var title: String
  /// Matched character offsets in `title`.
  var matched: Set<Int> = []
  var secondary: String?
  /// State or current value, at the trailing edge.
  var trailing: String?
  var shortcut: String?
  /// A thread's state mark; other rows carry a symbol.
  var state: ThreadState?
  var acknowledged = false
  var symbol: String?
  /// The Commands row leads with a typed slash.
  var isSlash = false
  var isActLevel = false
  var isDestructive = false
  var isCode = false
  var isCurrent = false
  var availability: CommandAvailability = .available
  /// What Return does, in words.
  var primary: String
  /// The footer's line while this row is selected: where it goes or when it takes effect.
  var context: String = ""
  /// A thread row can show its actions.
  var hasActions = false

  var isAvailable: Bool { availability == .available }

  /// Everything the row says, for VoiceOver.
  var spoken: String {
    var parts = [title]
    if let secondary, !secondary.isEmpty { parts.append(secondary) }
    if let trailing, !trailing.isEmpty { parts.append(trailing) }
    if isCurrent { parts.append("Current") }
    if let reason = availability.reason { parts.append("Unavailable: \(reason)") }
    return parts.joined(separator: ", ")
  }
}

struct PaletteSection: Identifiable, Equatable {
  var title: String?
  var items: [PaletteItem]
  var id: String { title ?? "" }
}

/// A level of the palette: the list it opened on, a thread's actions, or a command's argument.
enum PalettePage: Hashable {
  case root(PalettePurpose)
  case actions(CommandTarget)
  case choices(CommandID, CommandTarget)
  case text(CommandID, CommandTarget)
}

// MARK: - Results

/// The rows for a page and a query, from the model as it is now. Pure reads; nothing here waits.
struct PaletteResults {
  let model: WorkspaceModel
  /// The most rows a typed query lists.
  static let limit = 50

  /// Thread titles prepared for matching, kept between keystrokes while the list is unchanged.
  struct Index {
    var threads: [ConversationThread] = []
    /// Live threads in attention order, then archived ones; `titles` and `also` are in this order.
    var ordered: [ConversationThread] = []
    var titles: [FuzzyMatch.Text] = []
    var also: [[FuzzyMatch.Text]] = []
  }

  func index(_ previous: Index) -> Index {
    guard previous.threads != model.threads else { return previous }
    let ordered =
      Attention.ordered(model.threads.filter { !$0.archived })
      + Attention.ordered(model.threads.filter(\.archived))
    return Index(
      threads: model.threads, ordered: ordered,
      titles: ordered.map { FuzzyMatch.Text(ThreadSearch.shownTitle($0)) },
      also: ordered.map { thread in
        [model.environmentName(for: thread), model.connection(id: thread.connectionId)?.label]
          .compactMap { $0 }.map(FuzzyMatch.Text.init)
      })
  }

  // MARK: Rows

  func threadItem(_ thread: ConversationThread, matched: Set<Int> = []) -> PaletteItem {
    let state = model.state(of: thread)
    let connection = model.connection(id: thread.connectionId)
    let place = model.environmentName(for: thread) ?? "No folder"
    let unknown = model.activeTurns[thread.id]?.status == .reconciling
    let reason = model.reasonLine(for: thread)
    let trailing: String? =
      thread.archived
      ? "Archived"
      : unknown ? "Outcome unknown" : ["Read", "No messages yet"].contains(reason) ? nil : reason
    var context = [place, connection?.label ?? "Unknown connection"]
    if let connection, connection.kind != .b4 {
      context.append(ComposerPickerRow.modelName(thread.model, in: connection))
    }
    return PaletteItem(
      id: "thread:\(thread.id)", kind: .thread(thread.id), title: ThreadSearch.shownTitle(thread),
      matched: matched, secondary: "\(place) \u{00B7} \(connection?.label ?? "Unknown connection")",
      trailing: trailing, state: state, acknowledged: model.isAcknowledged(thread),
      isActLevel: state.isActLevel,
      primary: state == .approve || state == .reply ? "Review request" : "Open thread",
      context: context.joined(separator: " \u{00B7} "), hasActions: true)
  }

  /// A command row. `naming` adds the target's name as the secondary line, where the list mixes
  /// targets (a typed Find).
  func commandItem(
    _ id: CommandID, _ target: CommandTarget, matched: Set<Int> = [], naming: Bool = false,
    text: String? = nil
  ) -> PaletteItem {
    let definition = CommandCatalog.definition(id)
    var secondary = model.detail(of: id, target: target)
    if secondary == nil, naming, let threadId = target.threadId, let thread = model.thread(id: threadId) {
      secondary = ThreadSearch.shownTitle(thread)
    }
    if secondary == nil, naming, target == .draft { secondary = "New thread" }
    var context = ""
    switch target {
    case .thread(let threadId):
      context = model.thread(id: threadId).map { "Applies to \(ThreadSearch.shownTitle($0))" } ?? ""
    case .draft: context = "Applies to the new thread"
    case .settings, .connection: context = "Opens Settings"
    case .environment: context = "Prepares a new-thread draft"
    case .workspace: context = ""
    }
    if id == .useAsMessage { context = model.messageDestination }
    return PaletteItem(
      id: "command:\(id.rawValue):\(target)", kind: .command(id, target),
      title: model.title(of: id, target: target), matched: matched, secondary: secondary,
      trailing: model.currentValue(of: id, target: target), shortcut: definition.shortcutLabel,
      symbol: id == .commands ? nil : definition.symbol, isSlash: id == .commands,
      isDestructive: id == .threadAbandon,
      availability: model.availability(of: id, target: target, text: text),
      primary: model.primaryLabel(of: id, target: target), context: context)
  }

  /// A runtime's own command. The palette never sends: Return puts it in the draft, where the
  /// rest of the message is typed and sent as any other.
  func runtimeItem(
    _ command: RuntimeCommand, _ connection: Connection, matched: Set<Int> = []
  )
    -> PaletteItem
  {
    let text = "/\(command.name) "
    return PaletteItem(
      id: "runtime:\(connection.id):\(command.name)", kind: .runtime(text), title: "/\(command.name)",
      matched: matched, secondary: command.description.isEmpty ? nil : command.description,
      trailing: command.argumentHint, symbol: "terminal", isCode: true,
      availability: model.availability(of: .useAsMessage, target: .workspace, text: text),
      primary: "Add to draft", context: "\(connection.label) runs it when you send the message")
  }

  /// The runtime commands of the open thread, or of the new-thread draft.
  private var runtime: (connection: Connection, commands: [RuntimeCommand])? {
    model.runtimeCommands(for: openTarget ?? .draft)
  }

  func choiceItem(
    _ choice: CommandChoice, _ id: CommandID, _ target: CommandTarget, matched: Set<Int> = []
  )
    -> PaletteItem
  {
    PaletteItem(
      id: "choice:\(choice.id)", kind: .choice(choice), title: choice.title, matched: matched,
      secondary: choice.detail, symbol: CommandCatalog.definition(id).symbol, isCode: choice.isCode,
      isCurrent: choice.isCurrent,
      primary: choice.isCurrent && id != .threadNewWithRuntime
        ? "Keep \(choice.title)" : "Use \(choice.title)",
      context: model.effectNote(of: id, target: target))
  }

  /// The thread the commands speak for: the selected one, while it is in the list.
  private var openTarget: CommandTarget? {
    model.selectedThreadId.flatMap(model.thread(id:)).map { .thread($0.id) }
  }

  /// Every command row that is not a thread: environments, connections, settings pages, the open
  /// thread's or the draft's commands, and the workspace's.
  private func commandCandidates(includeDestinations: Bool) -> [(CommandID, CommandTarget)] {
    var list: [(CommandID, CommandTarget)] = []
    if let openTarget {
      list += model.commands(for: openTarget).filter { $0 != .threadOpen }.map { ($0, openTarget) }
    } else {
      list += model.commands(for: .draft).map { ($0, .draft) }
    }
    list += model.commands(for: .workspace).map { ($0, .workspace) }
    list += SettingsPage.allCases.map { (.openSettings, .settings($0)) }
    if includeDestinations {
      list += model.environments.map { (.environmentNewThread, .environment($0.id)) }
      list += model.connections.map { (.connectionOpen, .connection($0.id)) }
    }
    return list
  }

  // MARK: Pages

  func sections(for page: PalettePage, query: String, index: Index) -> [PaletteSection] {
    let terms = FuzzyMatch.terms(query)
    switch page {
    case .root(.find):
      return terms.isEmpty ? findStart() : [PaletteSection(items: find(terms, query: query, index: index))]
    case .root(.commands):
      return terms.isEmpty
        ? commandsStart()
        : [PaletteSection(items: rankedCommands(terms))]
    case .actions(let target):
      let all = model.commands(for: target).map { ($0, target) }
      return [
        PaletteSection(
          items: terms.isEmpty ? all.map { commandItem($0.0, $0.1) } : ranked(all, terms, naming: false))
      ]
    case .choices(let id, let target):
      let choices = model.choices(for: id, target: target)
      guard !terms.isEmpty else { return [PaletteSection(items: choices.map { choiceItem($0, id, target) })] }
      let hits: [(PaletteItem, Int)] = choices.compactMap { choice in
        FuzzyMatch.match(terms, title: FuzzyMatch.Text(choice.title)).map {
          (choiceItem(choice, id, target, matched: $0.positions), $0.score)
        }
      }
      return [PaletteSection(items: stable(hits))]
    case .text:
      return []
    }
  }

  /// Nothing typed: a short list of what needs the owner, where they were, and two common actions.
  private func findStart() -> [PaletteSection] {
    let live = Attention.ordered(model.threads.filter { !$0.archived })
    let needs = live.filter {
      model.state(of: $0).isActLevel || model.activeTurns[$0.id]?.status == .reconciling
    }.prefix(4)
    let recent = live.filter { thread in !needs.contains { $0.id == thread.id } }
      .sorted {
        ($0.activity?.lastActivityAt ?? $0.createdAt) > ($1.activity?.lastActivityAt ?? $1.createdAt)
      }
      .prefix(3)
    var sections: [PaletteSection] = []
    if !needs.isEmpty {
      sections.append(PaletteSection(title: "Needs you", items: needs.map { threadItem($0) }))
    }
    if !recent.isEmpty {
      sections.append(PaletteSection(title: "Recent", items: recent.map { threadItem($0) }))
    }
    sections.append(
      PaletteSection(
        title: "Suggested",
        items: [commandItem(.newThread, .workspace), commandItem(.commands, .workspace)]))
    return sections
  }

  private func commandsStart() -> [PaletteSection] {
    var sections: [PaletteSection] = []
    if let openTarget, let thread = openTarget.threadId.flatMap(model.thread(id:)) {
      sections.append(
        PaletteSection(
          title: ThreadSearch.shownTitle(thread),
          items: model.commands(for: openTarget).filter { $0 != .threadOpen }.map {
            commandItem($0, openTarget)
          }))
    } else {
      sections.append(
        PaletteSection(
          title: "New thread", items: model.commands(for: .draft).map { commandItem($0, .draft) }))
    }
    sections.append(
      PaletteSection(
        title: "Workspace",
        items: model.commands(for: .workspace).map { commandItem($0, .workspace) }
          + SettingsPage.allCases.map { commandItem(.openSettings, .settings($0)) }))
    if let runtime {
      sections.append(
        PaletteSection(
          title: runtime.connection.label,
          items: runtime.commands.map { runtimeItem($0, runtime.connection) }))
    }
    return sections
  }

  /// A typed Commands query: the app's commands and the runtime's in one list, the plainest match
  /// first, an app command before a runtime's that matches as well.
  private func rankedCommands(_ terms: [[FuzzyMatch.Unit]]) -> [PaletteItem] {
    var hits: [(PaletteItem, Int)] = commandCandidates(includeDestinations: false).compactMap { id, target in
      match(terms, id, target).map {
        (commandItem(id, target, matched: $0.positions, naming: true), $0.score * 2)
      }
    }
    if let runtime {
      for command in runtime.commands {
        let also = ([command.description] + (command.aliases ?? [])).map(FuzzyMatch.Text.init)
        guard let hit = FuzzyMatch.match(terms, title: FuzzyMatch.Text("/\(command.name)"), also: also)
        else { continue }
        hits.append((runtimeItem(command, runtime.connection, matched: hit.positions), hit.score * 2 - 1))
      }
    }
    return Array(stable(hits).prefix(Self.limit))
  }

  /// A typed Find: threads and everything else in one list, the plainest match first. Among equal
  /// matches threads keep attention order (archived last) and come before commands.
  private func find(_ terms: [[FuzzyMatch.Unit]], query: String, index: Index) -> [PaletteItem] {
    enum Candidate {
      case thread(Int)
      case command(CommandID, CommandTarget, Set<Int>)
    }
    // Score everything first; only the rows that will be listed are built, since a row reads its
    // thread's state, place, and reply time.
    var hits: [(Candidate, Int)] = []
    for offset in index.ordered.indices {
      guard
        let hit = FuzzyMatch.match(
          terms, title: index.titles[offset], also: index.also[offset], positions: false)
      else { continue }
      // An archived thread ranks just under a live one that matches as well.
      hits.append((.thread(offset), hit.score * 2 - (index.ordered[offset].archived ? 1 : 0)))
    }
    for (id, target) in commandCandidates(includeDestinations: true) {
      guard let hit = match(terms, id, target) else { continue }
      hits.append((.command(id, target, hit.positions), hit.score * 2 - 1))
    }
    var items: [PaletteItem] = stable(hits).prefix(Self.limit).map { candidate in
      switch candidate {
      case .thread(let offset):
        threadItem(
          index.ordered[offset],
          matched: FuzzyMatch.match(terms, title: index.titles[offset], also: index.also[offset])?.positions
            ?? [])
      case .command(let id, let target, let positions):
        commandItem(id, target, matched: positions, naming: true)
      }
    }
    // Nothing found, or little: the text can still become a message, never sent from here.
    if items.count < 3 {
      items.append(commandItem(.useAsMessage, .workspace, text: query))
    }
    return items
  }

  private func match(
    _ terms: [[FuzzyMatch.Unit]], _ id: CommandID, _ target: CommandTarget
  ) -> FuzzyMatch.Hit? {
    let definition = CommandCatalog.definition(id)
    var also = definition.aliases
    if let detail = model.detail(of: id, target: target) { also.append(detail) }
    if let slash = definition.slash { also.append(slash) }
    return FuzzyMatch.match(
      terms, title: FuzzyMatch.Text(model.title(of: id, target: target)), also: also.map(FuzzyMatch.Text.init)
    )
  }

  private func ranked(
    _ candidates: [(CommandID, CommandTarget)], _ terms: [[FuzzyMatch.Unit]], naming: Bool = true
  ) -> [PaletteItem] {
    stable(
      candidates.compactMap { id, target in
        match(terms, id, target).map {
          (commandItem(id, target, matched: $0.positions, naming: naming), $0.score)
        }
      })
  }

  /// Highest score first; equal scores keep the order they came in.
  private func stable<Row>(_ hits: [(Row, Int)]) -> [Row] {
    hits.enumerated().sorted { lhs, rhs in
      lhs.element.1 != rhs.element.1 ? lhs.element.1 > rhs.element.1 : lhs.offset < rhs.offset
    }.map(\.element.0)
  }
}

extension WorkspaceModel {
  /// Where "Use as message" puts the text, in the footer's words.
  var messageDestination: String {
    if let thread = selectedThreadId.flatMap(thread(id:)) {
      return "Draft for \(ThreadSearch.shownTitle(thread))"
    }
    let draft = newThreadDraft
    let place =
      draft.chosenFolder.map(ComposerPickerRow.folderName) ?? draft.environment?.displayName ?? "No folder"
    return ["New thread", place, draft.connection?.label].compactMap { $0 }.joined(separator: " \u{00B7} ")
  }
}

// MARK: - State

/// The palette while it is open: its pages, each page's own query and selection, and how the last
/// command ended. The views draw this and send it keys; it never touches a draft.
@Observable
final class PaletteModel {
  struct Frame: Equatable {
    var page: PalettePage
    var query = ""
    /// The selected row's `id`; nil selects the first row.
    var selection: String?
  }

  enum Feedback: Equatable {
    /// Asked; no answer yet. Shown only once the answer is slow.
    case requested(String)
    case failed(String)
    case unknown(String)
  }

  /// How a change of page moved, for the transition.
  enum Direction { case forward, back }

  let workspace: WorkspaceModel
  private(set) var stack: [Frame]
  private(set) var feedback: Feedback?
  private(set) var direction = Direction.forward
  /// Set while a command is out: Return does nothing until it answers.
  private(set) var running = false
  /// The account the palette opened under.
  @ObservationIgnored private let generation: Int
  @ObservationIgnored private var index = PaletteResults.Index()
  /// The rows for the page and text they were built for, until something they read changes.
  @ObservationIgnored private var cached: (frame: Frame, sections: [PaletteSection])?
  /// Bumped when the cached rows go stale, so whatever drew them draws again.
  private var revision = 0
  /// How long an answer may take before "requested" shows.
  @ObservationIgnored var requestedDelay: Duration = .milliseconds(150)
  /// Called once a command completed and the palette should go away.
  @ObservationIgnored var onFinish: (String) -> Void = { _ in }

  init(workspace: WorkspaceModel, purpose: PalettePurpose) {
    self.workspace = workspace
    stack = [Frame(page: .root(purpose))]
    generation = workspace.accountGeneration
  }

  var frame: Frame { stack[stack.count - 1] }
  var page: PalettePage { frame.page }
  var query: String { frame.query }
  var depth: Int { stack.count }

  var purpose: PalettePurpose {
    if case .root(let purpose) = stack[0].page { return purpose }
    return .find
  }

  /// The rows, built once per page, text, and state of the workspace: a view reads them several
  /// times a pass (the list, the selection, the footer), and a keystroke should cost one build.
  var sections: [PaletteSection] {
    _ = revision
    let frame = Frame(page: page, query: query)
    if let cached, cached.frame == frame { return cached.sections }
    let results = PaletteResults(model: workspace)
    let built = withObservationTracking {
      index = results.index(index)
      return results.sections(for: page, query: query, index: index)
    } onChange: { [weak self] in
      // The workspace is only ever changed on the main actor, and this runs inside that change: the
      // rows are stale from this instant, not from a later hop.
      MainActor.assumeIsolated {
        self?.cached = nil
        self?.revision += 1
      }
    }
    cached = (frame, built)
    return built
  }

  var items: [PaletteItem] { sections.flatMap(\.items) }

  /// The selected row: the remembered one while it is still listed, else the first.
  var selected: PaletteItem? {
    let items = self.items
    return items.first { $0.id == frame.selection } ?? items.first
  }

  /// The scope and the path, as chips before the field.
  var crumbs: [String] {
    var crumbs: [String] = []
    if case .root(.commands) = stack[0].page { crumbs.append("Commands") }
    for frame in stack.dropFirst() {
      switch frame.page {
      case .actions(let target):
        crumbs.append(targetName(target))
      case .choices(let id, let target), .text(let id, let target):
        if !crumbs.contains(targetName(target)), target != .workspace { crumbs.append(targetName(target)) }
        crumbs.append(argumentName(id))
      case .root: break
      }
    }
    return crumbs
  }

  private func targetName(_ target: CommandTarget) -> String {
    switch target {
    case .thread(let id): return workspace.thread(id: id).map(ThreadSearch.shownTitle) ?? "Thread"
    case .draft: return "New thread"
    case .environment(let id):
      return workspace.environments.first { $0.id == id }?.displayName ?? "Environment"
    case .connection(let id): return workspace.connection(id: id)?.label ?? "Connection"
    case .settings(let page): return page.title
    case .workspace: return "Workspace"
    }
  }

  private func argumentName(_ id: CommandID) -> String {
    switch id {
    case .threadModel: return "Model"
    case .threadPermission, .draftPermission: return "Permissions"
    case .threadNewWithRuntime, .draftRuntime: return "Runtime"
    case .draftEnvironment: return "Environment"
    case .threadRename: return "Rename"
    default: return CommandCatalog.plain(CommandCatalog.definition(id).title)
    }
  }

  /// Find's prompt, which the title bar's resting control shows too.
  static let findPrompt = "Search threads, environments, and commands"

  var placeholder: String {
    switch page {
    case .root(.find): return Self.findPrompt
    case .root(.commands): return "Run a command"
    case .actions: return "Filter actions"
    case .choices: return "Filter"
    case .text: return "Title"
    }
  }

  /// What Return does now, in words, and whether it can.
  var primaryLabel: String {
    if case .failed = feedback { return "Try again" }
    if case .text(let id, let target) = page { return workspace.primaryLabel(of: id, target: target) }
    return selected?.primary ?? "Open"
  }

  var primaryEnabled: Bool {
    guard !running else { return false }
    if case .text = page { return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return selected?.isAvailable ?? false
  }

  /// The footer's line: how the last command ended, why the selected row cannot run, or where it goes.
  var context: String {
    switch feedback {
    case .requested(let text), .failed(let text), .unknown(let text): return text
    case nil: break
    }
    if case .text = page { return "The title is local to this app. The runtime's history is not changed." }
    guard let selected else { return "" }
    return selected.availability.reason ?? selected.context
  }

  var canShowActions: Bool { !running && (selected?.hasActions ?? false) }

  // MARK: Input

  func setQuery(_ text: String) {
    guard text != query else { return }
    // ">" or "/" as the first character of Find is the way into Commands; anywhere else it is text.
    if case .root(.find) = page, stack.count == 1, text == ">" || text == "/" {
      direction = .forward
      stack = [Frame(page: .root(.commands))]
      feedback = nil
      return
    }
    stack[stack.count - 1].query = text
    if case .text = page {} else { stack[stack.count - 1].selection = nil }
    if !running { feedback = nil }
  }

  func select(_ id: String) {
    guard !running, frame.selection != id else { return }
    stack[stack.count - 1].selection = id
    feedback = nil
  }

  /// Move the selection by rows. Returns the row to scroll to.
  @discardableResult func move(by delta: Int) -> String? {
    let items = self.items
    guard !running, !items.isEmpty else { return nil }
    let current = items.firstIndex { $0.id == selected?.id } ?? 0
    let next = items[ThreadSearch.step(current, by: delta, count: items.count)]
    select(next.id)
    return next.id
  }

  /// Move to another purpose (⌘K or ⇧⌘P while open).
  func show(_ purpose: PalettePurpose) {
    guard !running else { return }
    direction = .forward
    stack = [Frame(page: .root(purpose))]
    feedback = nil
  }

  private func push(_ page: PalettePage, query: String = "") {
    direction = .forward
    feedback = nil
    stack.append(Frame(page: page, query: query))
  }

  /// One level back. False when there is none left, and the palette should close.
  @discardableResult func back() -> Bool {
    guard !running else { return true }
    feedback = nil
    direction = .back
    if stack.count > 1 {
      stack.removeLast()
      return true
    }
    if case .root(.commands) = page, workspace.palettePurpose == .find {
      stack = [Frame(page: .root(.find))]
      return true
    }
    return false
  }

  /// Backspace in an empty field: up a level, or out of the Commands scope. False when the key
  /// should do what it always does.
  func deleteBackward() -> Bool {
    guard query.isEmpty, !running else { return false }
    if case .text = page { return false }
    if stack.count > 1 { return back() }
    if case .root(.commands) = page {
      direction = .back
      stack = [Frame(page: .root(.find))]
      return true
    }
    return false
  }

  func showActions() {
    guard canShowActions, let selected, case .thread(let id) = selected.kind else { return }
    push(.actions(.thread(id)))
  }

  /// Return: the selected row's primary action, or the text argument.
  func activate() async {
    guard !running else { return }
    if case .text(let id, let target) = page {
      guard primaryEnabled else { return }
      await run(id, target, argument: query)
      return
    }
    guard let selected, selected.isAvailable else { return }
    switch selected.kind {
    case .thread(let id):
      await run(.threadOpen, .thread(id), argument: nil)
    case .choice(let choice):
      guard case .choices(let id, let target) = page else { return }
      await run(id, target, argument: choice.value)
    case .runtime(let text):
      await run(.useAsMessage, .workspace, argument: text)
    case .command(let id, let target):
      switch CommandCatalog.definition(id).argument {
      case .choice:
        push(.choices(id, target))
      case .text:
        let title = target.threadId.flatMap(workspace.thread(id:))?.title ?? ""
        push(.text(id, target), query: title)
      case .none:
        if id == .commands {
          show(.commands)
        } else {
          await run(id, target, argument: id == .useAsMessage ? stack[0].query : nil)
        }
      }
    }
  }

  private func run(_ id: CommandID, _ target: CommandTarget, argument: String?) async {
    running = true
    feedback = nil
    let doing = CommandCatalog.plain(workspace.title(of: id, target: target))
    let slow = Task { [requestedDelay] in
      try? await Task.sleep(for: requestedDelay)
      if !Task.isCancelled, running { feedback = .requested("\(doing)\u{2026}") }
    }
    let outcome = await workspace.run(id, target: target, argument: argument, generation: generation)
    slow.cancel()
    running = false
    switch outcome {
    case .completed(let spoken):
      feedback = nil
      onFinish(spoken)
    case .failed(let reason):
      feedback = .failed(reason)
    case .unknown(let reason):
      feedback = .unknown(reason)
    }
  }
}
