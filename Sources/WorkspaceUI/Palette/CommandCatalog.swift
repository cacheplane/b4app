import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

// MARK: - The catalog

/// A command's stable name. Menus, shortcuts, the palette, and the composer's `/` list all refer to a
/// command by this, never by its title.
public nonisolated struct CommandID: RawRepresentable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  init(_ rawValue: String) { self.rawValue = rawValue }

  public static let find = CommandID("workspace.find")
  public static let commands = CommandID("workspace.commands")
  public static let newThread = CommandID("workspace.newThread")
  public static let showArchived = CommandID("workspace.showArchived")
  public static let useAsMessage = CommandID("workspace.useAsMessage")
  public static let openSettings = CommandID("settings.open")
  public static let environmentNewThread = CommandID("environment.newThread")
  public static let connectionOpen = CommandID("connection.open")
  public static let threadOpen = CommandID("thread.open")
  public static let threadRename = CommandID("thread.rename")
  public static let threadPin = CommandID("thread.pin")
  public static let threadArchive = CommandID("thread.archive")
  public static let threadMarkUnread = CommandID("thread.markUnread")
  public static let threadModel = CommandID("thread.model")
  public static let threadPermission = CommandID("thread.permission")
  public static let threadNewWithRuntime = CommandID("thread.newWithRuntime")
  public static let threadStop = CommandID("thread.stop")
  public static let threadCheckAgain = CommandID("thread.checkAgain")
  public static let threadAbandon = CommandID("thread.abandon")
  public static let draftEnvironment = CommandID("draft.environment")
  public static let draftRuntime = CommandID("draft.runtime")
  public static let draftPermission = CommandID("draft.permission")
}

/// What a command acts on, by identity: captured when a row becomes concrete, checked again when the
/// command runs.
public nonisolated enum CommandTarget: Hashable, Sendable {
  case workspace
  case thread(String)
  case environment(String)
  case connection(String)
  case settings(SettingsPage)
  /// The new-thread draft.
  case draft

  var threadId: String? {
    if case .thread(let id) = self { return id }
    return nil
  }
}

/// What a command still needs before it can run.
public nonisolated enum CommandArgument: Sendable, Equatable {
  case none
  /// One of a short list (`WorkspaceModel.choices`).
  case choice
  /// A line of text.
  case text
}

public nonisolated enum CommandAvailability: Sendable, Equatable {
  case available
  /// Why it cannot run now, in words the palette shows as they are.
  case unavailable(String)

  public var reason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

/// How a command ended. A command that was sent and not answered is `unknown`: never reported as
/// done, and never as failed.
public nonisolated enum CommandOutcome: Sendable, Equatable {
  /// Done; the words are spoken to VoiceOver.
  case completed(String)
  case failed(String)
  case unknown(String)
}

/// One value a `choice` command can take.
public nonisolated struct CommandChoice: Identifiable, Sendable, Equatable {
  public var id: String
  public var title: String
  /// What `run` receives as its argument.
  public var value: String
  public var isCurrent: Bool
  public var detail: String?
  /// A technical value (a model id) is set in the mono face.
  public var isCode = false
}

public struct CommandDefinition: Identifiable {
  public let id: CommandID
  /// The title when nothing about the target changes it (`WorkspaceModel.title(of:target:)`).
  public let title: String
  /// Other words that find it. An alias typed whole ranks with the title.
  public let aliases: [String]
  public let symbol: String
  /// Its name after `/` in the composer, when it is offered there.
  public let slash: String?
  public let slashAliases: [String]
  public let shortcut: KeyboardShortcut?
  /// The shortcut as the palette prints it.
  public let shortcutLabel: String?
  public let argument: CommandArgument

  init(
    _ id: CommandID, _ title: String, symbol: String, aliases: [String] = [], slash: String? = nil,
    slashAliases: [String] = [], shortcut: KeyboardShortcut? = nil, shortcutLabel: String? = nil,
    argument: CommandArgument = .none
  ) {
    self.id = id
    self.title = title
    self.aliases = aliases
    self.symbol = symbol
    self.slash = slash
    self.slashAliases = slashAliases
    self.shortcut = shortcut
    self.shortcutLabel = shortcutLabel
    self.argument = argument
  }
}

/// Every command the app offers, declared once.
public enum CommandCatalog {
  public static let all: [CommandDefinition] = [
    CommandDefinition(
      .find, "Find", symbol: "magnifyingglass", aliases: ["search", "go to"],
      shortcut: KeyboardShortcut("k"), shortcutLabel: "\u{2318}K"),
    CommandDefinition(
      .commands, "Commands", symbol: "slash.circle", aliases: ["actions", "command palette"],
      shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]), shortcutLabel: "\u{21E7}\u{2318}P"),
    CommandDefinition(
      .newThread, "New thread", symbol: "square.and.pencil", aliases: ["compose", "start", "new chat"],
      slash: "new", shortcut: KeyboardShortcut("n"), shortcutLabel: "\u{2318}N"),
    CommandDefinition(
      .showArchived, "Show archived threads", symbol: "archivebox", aliases: ["archive", "hidden"]),
    CommandDefinition(.useAsMessage, "Use as message", symbol: "text.bubble", aliases: ["send", "ask"]),
    CommandDefinition(.openSettings, "Settings", symbol: "gearshape", aliases: ["settings", "preferences"]),
    CommandDefinition(.environmentNewThread, "New thread here", symbol: "folder", aliases: ["environment"]),
    CommandDefinition(
      .connectionOpen, "Open connection", symbol: "link", aliases: ["connection", "runtime"]),
    CommandDefinition(.threadOpen, "Open thread", symbol: "arrow.right", aliases: ["go", "show"]),
    CommandDefinition(
      .threadRename, "Rename\u{2026}", symbol: "pencil", aliases: ["title", "name"], argument: .text),
    CommandDefinition(.threadPin, "Pin", symbol: "pin", aliases: ["unpin", "favorite"], slash: "pin"),
    CommandDefinition(
      .threadArchive, "Archive", symbol: "archivebox", aliases: ["unarchive", "hide"], slash: "archive"),
    CommandDefinition(
      .threadMarkUnread, "Mark as unread", symbol: "circle", aliases: ["unread"], slash: "unread"),
    CommandDefinition(
      .threadModel, "Choose model\u{2026}", symbol: "cube", aliases: ["model", "switch model"],
      slash: "model", argument: .choice),
    CommandDefinition(
      .threadPermission, "Choose permissions\u{2026}", symbol: "shield",
      aliases: ["permissions", "permission", "mode", "approvals", "sandbox"], slash: "permissions",
      slashAliases: ["permission", "perm", "mode", "approvals"], argument: .choice),
    CommandDefinition(
      .threadNewWithRuntime, "New thread with another runtime\u{2026}", symbol: "square.and.pencil",
      aliases: ["switch runtime", "codex", "claude", "connection"], argument: .choice),
    CommandDefinition(.threadStop, "Stop turn", symbol: "stop", aliases: ["interrupt", "cancel"]),
    CommandDefinition(
      .threadCheckAgain, "Check again", symbol: "arrow.clockwise", aliases: ["reconcile", "retry", "turn"]),
    CommandDefinition(
      .threadAbandon, "Abandon turn", symbol: "xmark.circle", aliases: ["give up", "unknown"]),
    CommandDefinition(
      .draftEnvironment, "Choose where it starts\u{2026}", symbol: "folder",
      aliases: ["environment", "folder", "place"], slash: "environment", slashAliases: ["env", "folder"],
      argument: .choice),
    CommandDefinition(
      .draftRuntime, "Choose runtime and model\u{2026}", symbol: "cube",
      aliases: ["model", "runtime", "codex", "claude"], slash: "model", slashAliases: ["runtime"],
      argument: .choice),
    CommandDefinition(
      .draftPermission, "Choose permissions\u{2026}", symbol: "shield",
      aliases: ["permissions", "permission", "mode", "approvals"], slash: "permissions",
      slashAliases: ["permission", "perm", "mode", "approvals"], argument: .choice),
  ]

  private static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  public static func definition(_ id: CommandID) -> CommandDefinition {
    // Every id is declared above; an unknown one is a programming error caught by the catalog test.
    byId[id] ?? CommandDefinition(id, id.rawValue, symbol: "questionmark")
  }

  /// A title without its trailing ellipsis, for the primary-action label.
  static func plain(_ title: String) -> String {
    title.hasSuffix("\u{2026}") ? String(title.dropLast()) : title
  }
}

// MARK: - What the model says about a command

extension WorkspaceModel {
  func thread(id: String) -> ConversationThread? { threads.first { $0.id == id } }

  /// The thread whose turn the detail shows, when it is the one named.
  private func openTurn(of threadId: String) -> Turn? {
    if let detail, detail.thread.id == threadId { return detail.activeTurn }
    return activeTurns[threadId]
  }

  /// A turn whose outcome is unknown, or a thread whose native session cannot continue.
  func needsRecovery(_ thread: ConversationThread) -> Bool {
    openTurn(of: thread.id)?.status == .reconciling || thread.continuity != .available
  }

  /// The commands that apply to a target, in the order a list shows them. A command that could apply
  /// but cannot run now is listed (`availability` says why); one that never applies is left out.
  public func commands(for target: CommandTarget) -> [CommandID] {
    switch target {
    case .workspace:
      #if os(macOS)
        return [.newThread, .showArchived]
      #else
        return [.newThread]
      #endif
    case .settings: return [.openSettings]
    case .environment: return [.environmentNewThread]
    case .connection: return [.connectionOpen]
    case .draft:
      return newThreadDraft.connection?.kind == .b4
        ? [.draftEnvironment, .draftRuntime] : [.draftEnvironment, .draftRuntime, .draftPermission]
    case .thread(let id):
      guard let thread = thread(id: id) else { return [] }
      var list: [CommandID] = [.threadOpen, .threadRename, .threadPin, .threadArchive, .threadMarkUnread]
      if let kind = connection(id: thread.connectionId)?.kind, kind != .b4 {
        list += [.threadModel, .threadPermission]
      }
      list.append(.threadNewWithRuntime)
      let turn = openTurn(of: id)
      if let turn, turn.status != .reconciling { list.append(.threadStop) }
      if needsRecovery(thread) { list.append(.threadCheckAgain) }
      if turn?.status == .reconciling { list.append(.threadAbandon) }
      return list
    }
  }

  /// The commands the composer's `/` offers for a target.
  public func slashCommands(for target: CommandTarget) -> [CommandID] {
    let offered = (commands(for: target) + (target == .draft ? [] : [.newThread]))
      .filter { CommandCatalog.definition($0).slash != nil }
    // Settings first: they are what a slash is most often typed for.
    return offered.filter { CommandCatalog.definition($0).argument == .choice }
      + offered.filter { CommandCatalog.definition($0).argument != .choice }
  }

  public func title(of id: CommandID, target: CommandTarget) -> String {
    let thread = target.threadId.flatMap(thread(id:))
    switch (id, target) {
    case (.threadOpen, _):
      let state = thread.map(Attention.state(of:))
      return state == .approve || state == .reply ? "Review request" : "Open thread"
    case (.threadPin, _): return thread?.pinned == true ? "Unpin" : "Pin"
    case (.threadArchive, _): return thread?.archived == true ? "Unarchive" : "Archive"
    case (.showArchived, _):
      return viewSettings.showArchived ? "Hide archived threads" : "Show archived threads"
    case (.openSettings, .settings(let page)): return page.title
    case (.environmentNewThread, .environment(let environmentId)):
      return environments.first { $0.id == environmentId }?.displayName ?? "Environment"
    case (.connectionOpen, .connection(let connectionId)):
      return connection(id: connectionId).map(startLabel(for:)) ?? "Connection"
    default: return CommandCatalog.definition(id).title
    }
  }

  /// What Return does for this row, named concretely.
  public func primaryLabel(of id: CommandID, target: CommandTarget) -> String {
    switch (id, target) {
    case (.threadModel, _): return "Choose model"
    case (.threadPermission, _), (.draftPermission, _): return "Choose permissions"
    case (.threadNewWithRuntime, _), (.draftRuntime, _): return "Choose runtime"
    case (.draftEnvironment, _): return "Choose where it starts"
    case (.threadRename, _): return "Rename"
    case (.openSettings, .settings(let page)): return "Open \(page.title)"
    case (.connectionOpen, _): return "Open connection"
    case (.environmentNewThread, _): return "New thread in \(title(of: id, target: target))"
    default: return CommandCatalog.plain(title(of: id, target: target))
    }
  }

  /// One short line that tells a row from its neighbours or says what it does and does not do.
  public func detail(of id: CommandID, target: CommandTarget) -> String? {
    switch (id, target) {
    case (.threadArchive, .thread(let threadId)):
      let archived = thread(id: threadId)?.archived ?? false
      return !archived && openTurn(of: threadId) != nil ? "The running turn continues" : nil
    case (.threadNewWithRuntime, .thread(let threadId)):
      let label = thread(id: threadId).flatMap { connection(id: $0.connectionId)?.label }
      return label.map { "This thread stays on \($0)" }
    case (.threadCheckAgain, _): return "Asks the runtime what happened. Nothing is re-sent."
    case (.threadAbandon, _): return "Gives up on the unknown outcome. Nothing is re-sent."
    case (.useAsMessage, _): return "Puts the search text in the draft; nothing is sent"
    case (.openSettings, _): return "Settings"
    case (.environmentNewThread, .environment(let environmentId)):
      let folders = environments.first { $0.id == environmentId }?.folders ?? []
      return folders.count > 1 ? "Environment \u{00B7} \(folders.count) folders" : "Environment"
    case (.connectionOpen, .connection(let connectionId)):
      guard let connection = connection(id: connectionId) else { return "Connection" }
      let kind = connection.kind == .b4 ? "B4 agent" : "Connection"
      return connection.status == .ready ? kind : "\(kind) \u{00B7} \(connection.status.rawValue)"
    default: return nil
    }
  }

  /// The commands the target's runtime runs from a message, and the connection that runs them: the
  /// thread's, or the one a new thread would start on. A runtime command that shares a name with one
  /// of the app's is left out; the app's answers to that name.
  func runtimeCommands(for target: CommandTarget) -> (connection: Connection, commands: [RuntimeCommand])? {
    let found: Connection?
    switch target {
    case .thread(let id): found = thread(id: id).flatMap { connection(id: $0.connectionId) }
    case .draft: found = newThreadDraft.connection
    default: found = nil
    }
    guard let found, let listed = found.commands, !listed.isEmpty else { return nil }
    var taken = Set<String>()
    for id in slashCommands(for: target) {
      let definition = CommandCatalog.definition(id)
      if let slash = definition.slash { taken.insert(slash) }
      taken.formUnion(definition.slashAliases)
    }
    let commands = listed.filter { !taken.contains($0.name) }
    return commands.isEmpty ? nil : (found, commands)
  }

  /// The value a setting has now, for the trailing edge of its row.
  public func currentValue(of id: CommandID, target: CommandTarget) -> String? {
    switch (id, target) {
    case (.threadModel, .thread(let threadId)):
      guard let thread = thread(id: threadId), let connection = connection(id: thread.connectionId)
      else { return nil }
      return ComposerPickerRow.modelName(thread.model, in: connection)
    case (.threadPermission, .thread(let threadId)):
      guard let thread = thread(id: threadId), let kind = connection(id: thread.connectionId)?.kind
      else { return nil }
      return RuntimeOptions.permissionLabel(thread.permission, kind: kind)
    case (.draftEnvironment, _):
      let draft = newThreadDraft
      if let chosen = draft.chosenFolder { return ComposerPickerRow.folderName(chosen) }
      return draft.environment?.displayName ?? "No folder"
    case (.draftRuntime, _):
      guard let connection = newThreadDraft.connection else { return nil }
      if connection.kind == .b4 { return startLabel(for: connection) }
      return
        "\(connection.label) \u{00B7} \(ComposerPickerRow.modelName(newThreadDraft.model, in: connection))"
    case (.draftPermission, _):
      guard let kind = newThreadDraft.connection?.kind, kind != .b4 else { return nil }
      return RuntimeOptions.permissionLabel(newThreadDraft.permission, kind: kind)
    default: return nil
    }
  }

  /// Whether a command can run now, and if not, why. `text` is the argument it would run with, where
  /// the answer depends on it.
  public func availability(
    of id: CommandID, target: CommandTarget, text: String? = nil
  ) -> CommandAvailability {
    if case .thread(let threadId) = target, thread(id: threadId) == nil {
      return .unavailable("This thread is no longer here.")
    }
    let thread = target.threadId.flatMap(thread(id:))
    switch id {
    case .find, .commands, .openSettings, .connectionOpen, .threadOpen, .showArchived,
      .draftEnvironment, .draftRuntime, .draftPermission:
      return .available
    case .newThread, .threadNewWithRuntime:
      return newThreadEntryReason.map(CommandAvailability.unavailable) ?? .available
    case .environmentNewThread:
      guard case .environment(let environmentId) = target,
        let environment = startEnvironments.first(where: { $0.id == environmentId })
      else { return .unavailable("A thread cannot be started in this environment from here.") }
      if let reason = startBlockedReason(for: environment) { return .unavailable(reason) }
      if startConnections(for: environment).isEmpty {
        return .unavailable("No ready connection can start a thread in this environment.")
      }
      return .available
    case .useAsMessage:
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .unavailable("Type the message first.")
      }
      let existing = selectedThreadId == nil ? newThreadDraft.text : composerText
      return existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .available : .unavailable("There is already a draft here. It is never overwritten.")
    default: break
    }
    guard link == .ready else { return .unavailable("The coordinator is not connected.") }
    guard let thread else { return .available }
    switch id {
    case .threadMarkUnread:
      return canMarkUnread(thread)
        ? .available : .unavailable("Only a reply you have read can be marked unread.")
    case .threadModel, .threadPermission:
      guard let connection = connection(id: thread.connectionId) else {
        return .unavailable("This thread's connection is gone.")
      }
      return connection.kind == .b4 ? .unavailable("A B4 agent's route decides this.") : .available
    case .threadStop:
      guard let turn = openTurn(of: thread.id) else { return .unavailable("No turn is running.") }
      guard detail?.thread.id == thread.id else {
        return .unavailable("Open the thread to stop its turn.")
      }
      if let reason = controlsDisabledReason(for: thread) { return .unavailable(reason) }
      if turn.nativeTurnId == nil { return .unavailable("The turn has not started yet.") }
      if turn.status == .stopping || !canStop(thread) { return .unavailable("The turn is already stopping.") }
      return .available
    case .threadCheckAgain, .threadAbandon:
      if let reason = controlsDisabledReason(for: thread) { return .unavailable(reason) }
      return busy ? .unavailable("Another request is still out.") : .available
    default:
      return .available
    }
  }

  /// When a setting's change takes effect, in words under the choices.
  public func effectNote(of id: CommandID, target: CommandTarget) -> String {
    switch (id, target) {
    case (.threadModel, .thread(let threadId)), (.threadPermission, .thread(let threadId)):
      if openTurn(of: threadId) != nil { return "A turn is running. The change applies to the next turn." }
      return relaysThroughHub
        ? "Applies from the next turn, once your Mac has it" : "Applies from the next turn"
    case (.threadNewWithRuntime, .thread(let threadId)):
      guard let thread = thread(id: threadId) else { return "" }
      let label = connection(id: thread.connectionId)?.label ?? "its runtime"
      return "\(ThreadSearch.shownTitle(thread)) keeps \(label) and its folder"
    case (.draftEnvironment, _), (.draftRuntime, _), (.draftPermission, _):
      return "Applies to the new thread"
    default: return ""
    }
  }

  // MARK: Choices

  static let choiceSeparator = "\u{1F}"

  /// The values a `choice` command offers now, the current one marked. These are the composer
  /// pickers' own lists (`PickerMenus`), so the palette can never offer what a picker would not.
  public func choices(for id: CommandID, target: CommandTarget) -> [CommandChoice] {
    switch (id, target) {
    case (.threadModel, .thread(let threadId)):
      guard let thread = thread(id: threadId), let connection = connection(id: thread.connectionId)
      else { return [] }
      return PickerMenus.models(connection, chosen: thread.model, isChosenConnection: true, forThread: true)
        .map { choice($0, isCode: connection.kind == .codex && $0.value != nil) }
    case (.threadPermission, .thread(let threadId)):
      guard let thread = thread(id: threadId), let kind = connection(id: thread.connectionId)?.kind
      else { return [] }
      return PickerMenus.permissions(kind: kind, chosen: thread.permission, forThread: true).map {
        choice($0)
      }
    case (.draftPermission, _):
      guard let kind = newThreadDraft.connection?.kind else { return [] }
      return PickerMenus.permissions(kind: kind, chosen: newThreadDraft.permission, forThread: false)
        .map { choice($0) }
    case (.draftRuntime, _):
      let draft = newThreadDraft
      return runtimeChoices(draft.connections, chosenConnection: draft.connectionId, chosenModel: draft.model)
    case (.threadNewWithRuntime, .thread(let threadId)):
      guard let thread = thread(id: threadId) else { return [] }
      let environment = thread.environmentId.flatMap { id in startEnvironments.first { $0.id == id } }
      let offered =
        environment.map { startConnections(for: $0) + remoteB4Connections }
        ?? startConnectionsWithoutEnvironment
      return runtimeChoices(offered, chosenConnection: nil, chosenModel: nil)
    case (.draftEnvironment, _):
      let draft = newThreadDraft
      var list: [CommandChoice] = []
      for environment in draft.environments {
        let folders = environment.folders.count > 1 ? environment.folders.map(\.path) : [nil]
        for folder in folders {
          let name = folder.map { "\(environment.displayName) \u{00B7} \(ComposerPickerRow.folderName($0))" }
          let value = [environment.id, folder ?? ""].joined(separator: Self.choiceSeparator)
          list.append(
            CommandChoice(
              id: value, title: name ?? environment.displayName, value: value,
              isCurrent: draft.chosenFolder == nil && draft.environmentId == environment.id
                && (folder == nil || draft.folder == folder)))
        }
      }
      list.append(CommandChoice(id: "", title: "No folder", value: "", isCurrent: draft.isNoFolder))
      return list
    default: return []
    }
  }

  private func choice(_ item: PickerChoice, isCode: Bool = false) -> CommandChoice {
    CommandChoice(
      id: item.value ?? "", title: item.title, value: item.value ?? "", isCurrent: item.selected,
      isCode: isCode)
  }

  /// One row per Codex or Claude model, then the B4 agents, in the runtime menu's order.
  private func runtimeChoices(
    _ offered: [Connection], chosenConnection: String?, chosenModel: String?
  ) -> [CommandChoice] {
    let sections = PickerMenus.runtimeSections(offered)
    var list: [CommandChoice] = []
    for connection in sections.harness {
      let selected = chosenConnection == connection.id
      let models = PickerMenus.models(
        connection, chosen: selected ? chosenModel : nil, isChosenConnection: selected, forThread: false)
      for model in models {
        let value = [connection.id, model.value ?? ""].joined(separator: Self.choiceSeparator)
        list.append(
          CommandChoice(
            id: value, title: "\(connection.label) \u{00B7} \(model.title)", value: value,
            isCurrent: model.selected))
      }
    }
    for agent in sections.local + sections.remote {
      let value = [agent.id, ""].joined(separator: Self.choiceSeparator)
      list.append(
        CommandChoice(
          id: value, title: startLabel(for: agent), value: value, isCurrent: chosenConnection == agent.id,
          detail: agent.b4Mode == .remote ? "Remote B4" : "B4 agent"))
    }
    return list
  }

  // MARK: Running

  /// Run a command on the target it was offered for. The account, the target, and the command's
  /// availability are checked again here, since any of them may have changed while the palette was open.
  public func run(
    _ id: CommandID, target: CommandTarget, argument: String? = nil, generation: Int? = nil
  ) async -> CommandOutcome {
    if let generation, generation != accountGeneration {
      return .failed("The account changed. Nothing was done.")
    }
    if let reason = availability(of: id, target: target, text: argument).reason { return .failed(reason) }
    switch (id, target) {
    case (.find, _):
      presentPalette(.find)
      return .completed("Find")
    case (.commands, _):
      presentPalette(.commands)
      return .completed("Commands")
    case (.newThread, _):
      await openNewThread()
      return .completed("New thread")
    case (.showArchived, _):
      // The account's view setting (D-208), as the view options' own toggle sets it.
      await setShowArchived(!viewSettings.showArchived)
      return settled(viewSettings.showArchived ? "Archived threads shown" : "Archived threads hidden")
    case (.openSettings, .settings(let page)):
      openSettings(page)
      return .completed("\(page.title) settings")
    case (.connectionOpen, _):
      openSettings(.connections)
      return .completed("Connections settings")
    case (.environmentNewThread, .environment(let environmentId)):
      await openNewThread(environmentId: environmentId)
      return .completed("New thread in \(title(of: id, target: target))")
    case (.useAsMessage, _):
      let text = argument ?? ""
      if selectedThreadId == nil {
        newThreadDraft.text = text
        newThreadFocusRequest += 1
      } else {
        composerText = text
      }
      return .completed("Moved to the draft. Nothing was sent.")
    case (.draftEnvironment, _):
      let parts = (argument ?? "").components(separatedBy: Self.choiceSeparator)
      if parts.count == 2, !parts[0].isEmpty {
        if parts[1].isEmpty {
          newThreadDraft.selectEnvironment(parts[0])
        } else {
          newThreadDraft.selectFolder(parts[1], in: parts[0])
        }
      } else {
        newThreadDraft.selectNoFolder()
      }
      return .completed("Starts in \(currentValue(of: id, target: target) ?? "No folder")")
    case (.draftRuntime, _):
      let parts = (argument ?? "").components(separatedBy: Self.choiceSeparator)
      guard parts.count == 2 else { return .failed("That runtime is no longer offered.") }
      newThreadDraft.selectRuntime(connectionId: parts[0], model: parts[1].isEmpty ? nil : parts[1])
      guard newThreadDraft.connectionId == parts[0] else {
        return .failed("That runtime is no longer offered.")
      }
      return .completed(currentValue(of: id, target: target) ?? "Runtime chosen")
    case (.draftPermission, _):
      newThreadDraft.selectPermission(argument.flatMap { $0.isEmpty ? nil : $0 })
      return .completed(currentValue(of: id, target: target) ?? "Permissions chosen")
    case (_, .thread(let threadId)):
      return await run(id, threadId: threadId, argument: argument)
    default:
      return .failed("This command does not apply here.")
    }
  }

  private func run(_ id: CommandID, threadId: String, argument: String?) async -> CommandOutcome {
    guard let thread = thread(id: threadId) else { return .failed("This thread is no longer here.") }
    switch id {
    case .threadOpen:
      selectedThreadId = threadId
      showDetailColumn()
      await openThread(id: threadId)
      return .completed("Opened \(ThreadSearch.shownTitle(thread))")
    case .threadRename:
      let title = (argument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return .failed("A title cannot be empty.") }
      return await update(ThreadUpdate.Params(threadId: threadId, title: title), done: "Renamed")
    case .threadPin:
      return await update(
        ThreadUpdate.Params(threadId: threadId, pinned: !thread.pinned),
        done: thread.pinned ? "Unpinned" : "Pinned")
    case .threadArchive:
      return await update(
        ThreadUpdate.Params(threadId: threadId, archived: !thread.archived),
        done: thread.archived ? "Unarchived" : "Archived")
    case .threadMarkUnread:
      await markUnread(id: threadId)
      return settled("Marked as unread")
    case .threadModel:
      guard let model = argument, !model.isEmpty else { return .completed("Model unchanged") }
      guard model != thread.model else { return .completed("Model unchanged") }
      await setThreadRuntime(threadId: threadId, model: model, permission: nil)
      return settled("Model changed for the next turn")
    case .threadPermission:
      guard let permission = argument, !permission.isEmpty, permission != thread.permission else {
        return .completed("Permissions unchanged")
      }
      await setThreadRuntime(threadId: threadId, model: nil, permission: permission)
      return settled("Permissions changed for the next turn")
    case .threadNewWithRuntime:
      let parts = (argument ?? "").components(separatedBy: Self.choiceSeparator)
      guard parts.count == 2 else { return .failed("That runtime is no longer offered.") }
      await openNewThread(environmentId: thread.environmentId)
      newThreadDraft.refreshChoices()
      newThreadDraft.selectRuntime(connectionId: parts[0], model: parts[1].isEmpty ? nil : parts[1])
      guard newThreadDraft.connectionId == parts[0] else {
        return .failed("That runtime cannot start a thread there. The new-thread draft is open.")
      }
      return .completed("New thread on \(currentValue(of: .draftRuntime, target: .draft) ?? "the runtime")")
    case .threadStop:
      await stop()
      // A stop is a request: the turn's own state says when it has stopped.
      return relaysThroughHub ? .completed("Stop sent to your Mac") : settled("Stop requested")
    case .threadCheckAgain:
      await reconcileThread(id: threadId)
      return settled("Checked")
    case .threadAbandon:
      await abandonTurn(threadId: threadId)
      return settled("Turn abandoned. Nothing was re-sent.")
    default:
      return .failed("This command does not apply to a thread.")
    }
  }

  /// A thread update whose answer is kept, so the row is right before any event arrives.
  private func update(_ params: ThreadUpdate.Params, done: String) async -> CommandOutcome {
    let updated: ConversationThread? = await perform {
      try await $0.request(ThreadUpdate.self, params, options: Self.mutation()).thread
    }
    if let updated { store(updated) }
    return settled(done)
  }

  /// How the call that just returned ended. Every caller goes through `perform`, which clears the
  /// last failure on success and sets it on a refusal.
  private func settled(_ done: String) -> CommandOutcome {
    guard let failure = lastFailure else { return .completed(done) }
    if SendRules.mayHaveArrived(failure) {
      return .unknown("Not confirmed: your Mac did not answer. Check before trying again.")
    }
    return .failed(SendRules.reason(failure, now: now()))
  }
}
