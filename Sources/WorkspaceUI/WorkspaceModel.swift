import Foundation
import Observation
import WorkspaceClient
import WorkspaceProtocol

public enum LinkState: Sendable, Equatable {
  case connecting, ready, unavailable
}

/// What the sidebar dot says about a thread (spec 3.1: idle, running, waiting, reconnecting, error).
public enum ThreadRowState: String, Sendable, Equatable, CaseIterable {
  case idle, running, waiting, stopping, unknown, reconnecting, error

  public var label: String {
    switch self {
    case .idle: return "Idle"
    case .running: return "Running"
    case .waiting: return "Waiting for you"
    case .stopping: return "Stopping"
    case .unknown: return "Outcome unknown"
    case .reconnecting: return "Runtime offline"
    case .error: return "Connection error"
    }
  }
}

public enum Surface: String, CaseIterable, Identifiable, Sendable {
  case threads, connections, servers, diagnostics

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .threads: return "Threads"
    case .connections: return "Connections"
    case .servers: return "Local servers"
    case .diagnostics: return "Diagnostics"
    }
  }

  public var systemImage: String {
    switch self {
    case .threads: return "bubble.left.and.bubble.right"
    case .connections: return "point.3.connected.trianglepath.dotted"
    case .servers: return "server.rack"
    case .diagnostics: return "stethoscope"
    }
  }
}

/// The open thread: cached rows from `thread.read` patched by live events.
public struct ThreadDetail: Sendable, Equatable {
  public var thread: ConversationThread
  public var turns: [Turn]
  public var items: [DisplayItem]
  public var requests: [RuntimeRequest]
  /// Streaming assistant text by native item id, cleared when the item completes.
  public var liveText: [String: String] = [:]

  public var activeTurn: Turn? { turns.last { $0.status != .terminal } }

  mutating func upsert(_ item: DisplayItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
      items.sort { $0.sequence < $1.sequence }
    }
  }

  mutating func upsert(_ turn: Turn) {
    if let index = turns.firstIndex(where: { $0.id == turn.id }) {
      turns[index] = turn
    } else {
      turns.append(turn)
      turns.sort { $0.createdAt < $1.createdAt }
    }
  }
}

/// Renderer-side projection of coordinator state: snapshot first, then live events, resnapshot on
/// desync. Views never talk to the client directly.
@Observable
public final class WorkspaceModel {
  public typealias TransportProvider = @Sendable () async throws -> any WorkspaceTransport

  public private(set) var link: LinkState = .connecting
  public private(set) var linkMessage: String?
  public private(set) var connections: [Connection] = []
  public private(set) var threads: [ConversationThread] = []
  public private(set) var diagnostics: DiagnosticsReport?
  public private(set) var diagnosticsError: String?
  public private(set) var diagnosticsLoading = false
  public private(set) var servers: [LocalServer] = []
  /// Latest redacted log tail per server id, replaced on each poll.
  public private(set) var serverLogs: [String: ServerLogs.Result] = [:]
  /// A stop or restart the coordinator refused because a turn is running; the view confirms force.
  public var pendingForceStop: (serverId: String, restart: Bool, threadIds: [String])?
  public private(set) var detail: ThreadDetail?
  public private(set) var detailLoading = false
  public private(set) var busy = false
  /// Every non-terminal turn by thread id, from the snapshot and then from turn events, so the
  /// sidebar shows per-thread state without opening each thread (spec 3.1).
  public private(set) var activeTurns: [String: Turn] = [:]
  public var lastError: String? {
    didSet { if lastError == nil { lastFailure = nil } }
  }
  /// The typed error behind `lastError`, when the failure came from the coordinator.
  public private(set) var lastFailure: WorkspaceError?
  public var composerText = "" {
    didSet {
      if composerText != oldValue, !restoringDraft {
        lastComposerChange = now()
        scheduleDraftSave()
      }
    }
  }
  /// Every project with its folders, loaded with the threads and refreshed on `project.changed`.
  public private(set) var projects: [Project] = []
  public var projectFilter: ProjectFilter = .all
  public var surface: Surface = .threads
  public var selectedThreadId: String?
  public var searchText = ""
  public var connectionFilter: String?
  public var showArchived = false
  public var showNewThread = false
  /// Draft writes are debounced; the pending one is flushed by `persistDraftNow()`.
  public private(set) var draftSaveTask: Task<Void, Never>?
  private var restoringDraft = false
  public static var draftSaveDelay: Duration = .milliseconds(600)
  /// A burst of events about one thread becomes one `thread.read` this long after the first.
  public static var refetchDelay: Duration = .milliseconds(200)
  /// A draft that changed elsewhere replaces the composer only when it has not been typed in for this long.
  public static var remoteDraftIdle: TimeInterval = 2
  /// The clock for relative times ("Replied 3m ago") and the composer idle rule; tests replace it.
  public var now: @Sendable () -> Date = { Date() }
  /// Set after `connection.login`; the view opens it in the system browser and clears it.
  public var pendingLoginURL: URL?

  /// How the coordinator is hosted, in the app's words (M6): a LaunchAgent that needs approval, or
  /// nothing. The app sets these; the UI only shows them. The action runs when its title is shown.
  public var hostNote: String?
  public var hostActionTitle: String?
  public var hostAction: (@MainActor () async -> Void)?
  /// The coordinator version this app was built with; a running coordinator that reports another
  /// version is an upgrade left behind, and `restartCoordinator` (set by the app) replaces it.
  public var expectedCoordinatorVersion: String?
  public var restartCoordinator: (@MainActor () async -> Void)?

  public var versionMismatch: String? {
    guard let expected = expectedCoordinatorVersion, let running = diagnostics?.coordinator.version,
      running != expected
    else { return nil }
    return "The running coordinator is \(running); this app is \(expected)."
  }

  private let transportProvider: TransportProvider
  private var client: WorkspaceClient?
  private var connectTask: Task<Void, Never>?
  @ObservationIgnored private var lastComposerChange = Date.distantPast
  /// Threads with a `thread.read` already scheduled; further events inside the window join it.
  @ObservationIgnored private var refetchTasks: [String: Task<Void, Never>] = [:]
  /// `"<threadId>/<turnId>"` for every `thread.markRead` sent, so a turn is marked at most once.
  @ObservationIgnored private var markedRead: Set<String> = []
  /// Threads the owner marked unread while open; they stay unread until the thread is opened again
  /// or a new reply finishes.
  @ObservationIgnored private var unreadHold: Set<String> = []

  public init(transportProvider: @escaping TransportProvider) {
    self.transportProvider = transportProvider
  }

  /// The list under the search, connection, and project filters: pinned first, then needs input,
  /// unread reply, working, and quiet, newest activity first inside each (`Attention.ordered`).
  public var orderedThreads: [ConversationThread] {
    Attention.ordered(filtered(archived: projectFilter == .archived, project: projectFilter))
  }

  /// Pinned threads of `orderedThreads`.
  public var pinnedThreads: [ConversationThread] { orderedThreads.filter(\.pinned) }

  /// The unpinned threads of `orderedThreads` grouped by project (the Mac sidebar).
  public var projectSections: [ProjectSection] {
    ProjectSection.build(threads: orderedThreads.filter { !$0.pinned }, projects: projects)
  }

  /// Unarchived threads under the search, connection, and project filters, in attention order.
  public var visibleThreads: [ConversationThread] {
    Attention.ordered(filtered(archived: false, project: projectFilter == .archived ? .all : projectFilter))
  }

  /// Archived threads under the search and connection filters, shown when `showArchived` is on.
  public var archivedThreads: [ConversationThread] {
    Attention.ordered(filtered(archived: true, project: .all))
  }

  public func band(of thread: ConversationThread) -> AttentionBand { Attention.band(of: thread) }

  /// A thread belongs under "Other" when it has no project or its project is not known.
  private func isOther(_ thread: ConversationThread) -> Bool {
    guard let projectId = thread.projectId else { return true }
    return !projects.contains { $0.id == projectId }
  }

  private func filtered(archived: Bool, project: ProjectFilter) -> [ConversationThread] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    return threads.filter { $0.archived == archived }
      .filter { connectionFilter == nil || $0.connectionId == connectionFilter }
      .filter { query.isEmpty || $0.title.lowercased().contains(query) }
      .filter {
        switch project {
        case .all, .archived: return true
        case .project(let id): return $0.projectId == id
        case .other: return isOther($0)
        }
      }
  }

  /// One line under a thread's title saying why it sits where it does. Needs-input threads name the
  /// request kind when the thread is open (the list's `activity` only counts requests).
  public func reasonLine(for thread: ConversationThread) -> String {
    switch Attention.band(of: thread) {
    case .needsInput:
      let pending = detail.flatMap { $0.thread.id == thread.id ? $0.requests : nil }?
        .filter { $0.state == .pending }.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      switch pending?.kind {
      case .commandApproval?, .fileChangeApproval?, .toolPermission?: return "Waiting for your approval"
      case .userQuestion?, .elicitation?: return "Has a question for you"
      case .unknown?, nil: return "Waiting for your input"
      }
    case .unread:
      let when = relative(thread.activity?.lastActivityAt)
      let word: String
      switch thread.activity?.latestTurnOutcome {
      case .failed?: word = "Failed"
      case .cancelled?: word = "Stopped"
      case .completed?, nil: word = "Replied"
      }
      return when.isEmpty ? word : "\(word) \(when)"
    case .working:
      return "Working"
    case .quiet:
      return thread.activity?.latestTurnId == nil ? "No messages yet" : "Read"
    }
  }

  private func relative(_ timestamp: String?) -> String {
    guard let timestamp, let date = Self.date(from: timestamp) else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now())
  }

  private static func date(from timestamp: String) -> Date? {
    if let date = Timestamp.date(from: timestamp) { return date }
    return ISO8601DateFormatter().date(from: timestamp)
  }

  /// Sidebar state for one thread: the connection's availability wins over an idle thread, and a
  /// non-terminal turn wins over both (spec 3.1 indicators).
  public func threadState(_ thread: ConversationThread) -> ThreadRowState {
    if let turn = activeTurns[thread.id] {
      switch turn.status {
      case .submitting, .running: return .running
      case .waitingForUser: return .waiting
      case .stopping: return .stopping
      case .reconciling: return .unknown
      case .terminal: break
      }
    }
    switch connection(id: thread.connectionId)?.status {
    case .offline?, .connecting?: return .reconnecting
    case .error?, .incompatible?: return .error
    default: return .idle
    }
  }

  public func connection(id: String) -> Connection? { connections.first { $0.id == id } }

  /// Connections that can start a thread right now.
  public var conversationReadyConnections: [Connection] {
    connections.filter { $0.enabled && $0.status == .ready }
  }

  public func connect() {
    connectTask?.cancel()
    link = .connecting
    linkMessage = nil
    connectTask = Task { [transportProvider] in
      do {
        let transport = try await transportProvider()
        let client = WorkspaceClient(transport: transport)
        self.client = client
        _ = try await client.ready()
        try await refreshSnapshot()
        link = .ready
        await observe(client)
      } catch {
        link = .unavailable
        linkMessage = Self.describe(error)
      }
    }
  }

  public func disconnect() async {
    connectTask?.cancel()
    await client?.close()
    client = nil
    link = .unavailable
  }

  public func refreshSnapshot() async throws {
    guard let client else { return }
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    connections = snapshot.connections
    threads = snapshot.threads
    activeTurns = Dictionary(
      snapshot.activeTurns.map { ($0.threadId, $0) }, uniquingKeysWith: { _, new in new })
    servers = (try? await client.request(ServerList.self, EmptyParams()).servers) ?? []
    await refreshProjects()
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    if let id = selectedThreadId, detail != nil { await loadDetail(id: id) }
  }

  public func refreshDiagnostics() async {
    guard let client else {
      diagnosticsError = "Coordinator is not connected."
      return
    }
    diagnosticsLoading = true
    defer { diagnosticsLoading = false }
    do {
      diagnostics = try await client.request(
        DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
      diagnosticsError = nil
    } catch {
      diagnosticsError = Self.describe(error)
    }
  }

  // MARK: - Managed servers

  public func server(id: String) -> LocalServer? { servers.first { $0.id == id } }

  /// The route connection on a managed server, when one exists.
  public func connection(serverId: String, route: String) -> Connection? {
    connections.first { $0.localServerId == serverId && $0.routeKey == route }
  }

  private static let serverOperation: Duration = .seconds(150)

  public func addServer(
    projectPath: String, name: String?, mode: LocalServerLaunchMode, envFilePath: String?, port: Int?
  ) async {
    _ = await perform {
      let result = try await $0.request(
        ServerAdd.self,
        ServerAdd.Params(
          projectPath: projectPath, name: name, launchMode: mode, envFilePath: envFilePath, port: port),
        options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func startServer(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ServerStart.self, ServerRef(serverId: id), options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func inspectServer(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ServerInspect.self, ServerRef(serverId: id), options: Self.mutation(timeout: Self.serverOperation))
      self.merge(result.server)
      return result.server
    }
  }

  public func stopServer(id: String, force: Bool = false) async {
    await lifecycle(ServerStop.self, id: id, force: force, restart: false)
  }

  public func restartServer(id: String, force: Bool = false) async {
    await lifecycle(ServerRestart.self, id: id, force: force, restart: true)
  }

  private func lifecycle<C: WorkspaceCommand>(_ command: C.Type, id: String, force: Bool, restart: Bool) async
  where C.Params == ServerLifecycleParams, C.Result == ServerAdd.Result {
    guard let client else {
      lastError = "Coordinator is not connected."
      return
    }
    busy = true
    defer { busy = false }
    do {
      let result = try await client.request(
        command, ServerLifecycleParams(serverId: id, force: force ? true : nil),
        options: Self.mutation(timeout: Self.serverOperation))
      merge(result.server)
      lastError = nil
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.details?["reason"]?.stringValue == "turn_active" {
        pendingForceStop = (
          id, restart, failure.details?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
      } else {
        lastError = Self.describe(error)
      }
    }
  }

  public func refreshServerLogs(id: String, lines: Int = 200) async {
    guard let client else { return }
    let previous = serverLogs[id]
    guard
      let result = try? await client.request(
        ServerLogs.self, ServerLogs.Params(serverId: id, lines: lines, afterOffset: previous?.offset))
    else { return }
    if var previous, result.offset >= previous.offset, !result.truncated {
      previous.lines = Array((previous.lines + result.lines).suffix(lines))
      previous.offset = result.offset
      serverLogs[id] = previous
    } else {
      serverLogs[id] = result
    }
  }

  public func connectRoute(serverId: String, route: String) async {
    await addConnection(kind: .b4, route: route, serverId: serverId)
  }

  private func merge(_ server: LocalServer) {
    if let index = servers.firstIndex(where: { $0.id == server.id }) {
      servers[index] = server
    } else {
      servers.append(server)
    }
  }

  // MARK: - Connections

  @discardableResult
  public func addConnection(
    kind: ConnectionKind, label: String? = nil, executablePath: String? = nil, url: String? = nil,
    route: String? = nil, authReference: String? = nil, serverId: String? = nil
  ) async
    -> Connection?
  {
    await perform {
      let result = try await $0.request(
        ConnectionAdd.self,
        ConnectionAdd.Params(
          kind: kind, label: label, executablePath: executablePath, url: url, route: route,
          authReference: authReference, serverId: serverId),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      if result.connection.status != .ready, let message = result.inspection.message {
        self.lastError = message
      }
      return result.connection
    }
  }

  public func inspectConnection(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionInspect.self, ConnectionInspect.Params(connectionId: id),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      return result.connection
    }
  }

  public func login(connectionId: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionLogin.self, ConnectionLogin.Params(connectionId: connectionId), options: Self.mutation())
      self.pendingLoginURL = URL(string: result.authUrl)
      return result
    }
  }

  // MARK: - Threads

  public func createThread(connectionId: String, directory: String?, title: String?) async {
    let created: ConversationThread? = await perform {
      try await $0.request(
        ThreadCreate.self,
        ThreadCreate.Params(connectionId: connectionId, workingDirectory: directory, title: title),
        options: Self.mutation(timeout: .seconds(60))
      ).thread
    }
    if let created {
      threads.removeAll { $0.id == created.id }
      threads.insert(created, at: 0)
      await openThread(id: created.id)
    }
  }

  public func openThread(id: String) async {
    if let current = detail, current.thread.id != id { await saveDraft(threadId: current.thread.id) }
    selectedThreadId = id
    surface = .threads
    unreadHold.remove(id)
    await loadDetail(id: id)
    await markReadIfNeeded(threadId: id)
  }

  private func loadDetail(id: String) async {
    guard let client else { return }
    detailLoading = true
    defer { detailLoading = false }
    do {
      let read = try await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: id), options: RequestOptions(timeout: .seconds(60)))
      // The saved draft is restored only when switching threads, and before the detail is published
      // so the composer is live only once it is settled. A refresh of the open thread (snapshot,
      // wake, a connection change) keeps whatever is being typed: restoring from disk there would
      // overwrite it, and the save already scheduled would then persist the overwrite.
      if detail?.thread.id != id {
        let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: id)).draft
        restoringDraft = true
        composerText = draft?.text ?? ""
        restoringDraft = false
      }
      detail = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
      store(read.thread)
      if let active = read.turns.last(where: { $0.status != .terminal }) {
        activeTurns[id] = active
      } else {
        activeTurns[id] = nil
      }
      lastError = nil
    } catch {
      lastError = Self.describe(error)
    }
  }

  public func saveDraft(threadId: String) async {
    guard let client else { return }
    let text = composerText
    _ = try? await client.request(
      DraftSave.self, DraftSave.Params(threadId: threadId, text: text), options: Self.mutation())
  }

  /// Save the open thread's draft shortly after typing stops, so a crash or Quit keeps the text.
  private func scheduleDraftSave() {
    draftSaveTask?.cancel()
    guard let threadId = detail?.thread.id else { return }
    draftSaveTask = Task { [weak self] in
      try? await Task.sleep(for: Self.draftSaveDelay)
      guard !Task.isCancelled, let self, self.detail?.thread.id == threadId else { return }
      await self.saveDraft(threadId: threadId)
      self.draftSaveTask = nil
    }
  }

  /// Flush the pending draft write now (app termination, window close).
  public func persistDraftNow() async {
    draftSaveTask?.cancel()
    draftSaveTask = nil
    guard let threadId = detail?.thread.id else { return }
    await saveDraft(threadId: threadId)
  }

  /// Deliberate reconciliation of one thread: unresolved turn, native history, continuity.
  public func reconcileThread(id: String) async {
    let read: ThreadRead.Result? = await perform {
      try await $0.request(
        ThreadReconcile.self, ThreadReconcile.Params(threadId: id),
        options: Self.mutation(timeout: .seconds(60)))
    }
    guard let read else { return }
    threads.removeAll { $0.id == read.thread.id }
    threads.insert(read.thread, at: 0)
    if detail?.thread.id == id {
      detail = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
    }
    activeTurns[id] = read.turns.last { $0.status != .terminal }
  }

  public func updateThread(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async
  {
    _ = await perform {
      try await $0.request(
        ThreadUpdate.self,
        ThreadUpdate.Params(threadId: id, title: title, pinned: pinned, archived: archived),
        options: Self.mutation()
      ).thread
    }
  }

  // MARK: - Projects

  public func refreshProjects() async {
    guard let client, let list = try? await client.request(ProjectList.self, EmptyParams()) else { return }
    projects = list.projects
  }

  @discardableResult
  public func createProject(name: String, folders: [String]) async -> Project? {
    let created: Project? = await perform {
      try await $0.request(
        ProjectCreate.self, ProjectCreate.Params(name: name, folders: folders), options: Self.mutation()
      ).project
    }
    if let created { merge(created) }
    return created
  }

  /// Rename a project; the empty string restores the folder-name display.
  public func renameProject(id: String, name: String) async {
    let renamed: Project? = await perform {
      try await $0.request(
        ProjectRename.self, ProjectRename.Params(projectId: id, name: name), options: Self.mutation()
      ).project
    }
    if let renamed { merge(renamed) }
  }

  public func addFolder(projectId: String, path: String) async {
    let updated: Project? = await perform {
      try await $0.request(
        ProjectUpdate.self, ProjectUpdate.Params(projectId: projectId, addFolders: [path]),
        options: Self.mutation()
      ).project
    }
    if let updated { merge(updated) }
    // Threads whose folder moved arrive as `thread.updated`; the list follows `project.changed`.
  }

  public func deleteProject(id: String) async {
    let deleted: String? = await perform {
      try await $0.request(ProjectDelete.self, ProjectDelete.Params(projectId: id), options: Self.mutation())
        .projectId
    }
    guard let deleted else { return }
    projects.removeAll { $0.id == deleted }
    if projectFilter == .project(deleted) { projectFilter = .all }
  }

  private func merge(_ project: Project) {
    if let index = projects.firstIndex(where: { $0.id == project.id }) {
      projects[index] = project
    } else {
      projects.append(project)
    }
  }

  // MARK: - Read state

  /// Mark the thread unread again (spec: context menu on the Mac, swipe on the phone).
  public func markUnread(id: String) async {
    let previous = threads.first { $0.id == id }?.readTurnId
    unreadHold.insert(id)
    markedRead = markedRead.filter { !$0.hasPrefix("\(id)/") }
    setReadTurn(threadId: id, turnId: nil)
    let result: ConversationThread? = await perform {
      try await $0.request(
        ThreadMarkRead.self, ThreadMarkRead.Params(threadId: id, turnId: nil), options: Self.mutation()
      ).thread
    }
    if let result {
      store(result)
    } else {
      unreadHold.remove(id)
      setReadTurn(threadId: id, turnId: previous)
    }
  }

  /// When the open thread's latest turn is finished and is not the one marked read, mark it read:
  /// once per (thread, turn) for the life of the model. Nothing is sent for a turn still running.
  private func markReadIfNeeded(threadId: String) async {
    guard let detail, detail.thread.id == threadId, !unreadHold.contains(threadId) else { return }
    guard let latest = detail.turns.max(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }),
      latest.status == .terminal
    else { return }
    let readTurnId = threads.first { $0.id == threadId }?.readTurnId ?? detail.thread.readTurnId
    guard readTurnId != latest.id, markedRead.insert("\(threadId)/\(latest.id)").inserted else { return }
    guard let client else {
      markedRead.remove("\(threadId)/\(latest.id)")
      return
    }
    setReadTurn(threadId: threadId, turnId: latest.id)
    do {
      let result = try await client.request(
        ThreadMarkRead.self, ThreadMarkRead.Params(threadId: threadId, turnId: latest.id),
        options: Self.mutation())
      store(result.thread)
    } catch {
      // Not sent after all: the dot comes back and a later open may try again.
      markedRead.remove("\(threadId)/\(latest.id)")
      if threads.first(where: { $0.id == threadId })?.readTurnId == latest.id {
        setReadTurn(threadId: threadId, turnId: readTurnId)
      }
    }
  }

  /// Set the read marker on the list row and the open detail at once, so the row's band changes
  /// before the coordinator has answered.
  private func setReadTurn(threadId: String, turnId: String?) {
    if let index = threads.firstIndex(where: { $0.id == threadId }) { threads[index].readTurnId = turnId }
    if detail?.thread.id == threadId { detail?.thread.readTurnId = turnId }
  }

  /// Put a fresher copy of a thread into the list (and the open detail), keeping the `activity` and
  /// owner name an event payload may lack.
  private func store(_ thread: ConversationThread) {
    var fresh = thread
    if let index = threads.firstIndex(where: { $0.id == thread.id }) {
      fresh.activity = fresh.activity ?? threads[index].activity
      fresh.ownerDeviceName = fresh.ownerDeviceName ?? threads[index].ownerDeviceName
      threads[index] = fresh
    } else {
      threads.append(fresh)
    }
    if detail?.thread.id == thread.id { detail?.thread = fresh }
  }

  // MARK: - Keeping rows current

  /// Re-read one thread shortly after an event about it, so its `activity` (and the open thread's
  /// turns and requests) are current. The first event opens a window; the rest join its one read.
  private func scheduleRefetch(threadId: String) {
    guard refetchTasks[threadId] == nil else { return }
    refetchTasks[threadId] = Task { [weak self] in
      try? await Task.sleep(for: Self.refetchDelay)
      guard !Task.isCancelled, let self else { return }
      self.refetchTasks[threadId] = nil
      await self.refetch(threadId: threadId)
    }
  }

  private func refetch(threadId: String) async {
    guard let client,
      let read = try? await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: threadId), options: RequestOptions(timeout: .seconds(60))
      )
    else { return }
    if var current = detail, current.thread.id == threadId {
      current.turns = read.turns
      current.items = read.items
      current.requests = read.requests
      detail = current
      activeTurns[threadId] = read.turns.last { $0.status != .terminal }
    }
    store(read.thread)
    await markReadIfNeeded(threadId: threadId)
  }

  /// A draft changed on another device shows in the open composer, but only when nothing has been
  /// typed for `remoteDraftIdle` seconds: a focused composer keeps what is being typed.
  private func reloadRemoteDraftIfIdle(threadId: String) {
    guard now().timeIntervalSince(lastComposerChange) >= Self.remoteDraftIdle, let client else { return }
    let stamp = lastComposerChange
    Task {
      guard
        let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: threadId)).draft,
        detail?.thread.id == threadId, lastComposerChange == stamp, composerText != draft.text
      else { return }
      restoringDraft = true
      composerText = draft.text
      restoringDraft = false
    }
  }

  // MARK: - Turns and requests

  public func send() async {
    guard let detail else { return }
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    composerText = ""
    let sent: Turn? = await perform {
      try await $0.request(
        TurnSend.self, TurnSend.Params(threadId: detail.thread.id, text: text),
        options: Self.mutation(timeout: .seconds(90))
      ).turn
    }
    if sent == nil, composerText.isEmpty, self.detail?.activeTurn != nil {
      composerText = text
    }
  }

  public func stop() async {
    guard let detail else { return }
    _ = await perform {
      try await $0.request(
        TurnInterrupt.self, TurnInterrupt.Params(threadId: detail.thread.id), options: Self.mutation()
      ).turn
    }
  }

  // MARK: - Lifecycle (spec 10.3)

  /// What the coordinator is running now, for the Quit choice. Nil when the coordinator is unreachable.
  public func activeWork() async -> WorkspaceActiveWork.Result? {
    guard let client else { return nil }
    return try? await client.request(
      WorkspaceActiveWork.self, EmptyParams(), options: RequestOptions(timeout: .seconds(10)))
  }

  /// Stop owned local work (local turns, owned servers); remote runs are detached, not cancelled.
  public func stopLocalWork() async -> WorkspaceStopLocalWork.Result? {
    await perform {
      try await $0.request(
        WorkspaceStopLocalWork.self, EmptyParams(), options: Self.mutation(timeout: .seconds(90)))
    }
  }

  /// After the Mac wakes or the link comes back: fresh snapshot, then ask every runtime about every
  /// unresolved turn. Nothing is re-sent.
  public func reconcileAfter(_ reason: String) async {
    try? await refreshSnapshot()
    guard let client else { return }
    _ = try? await client.request(
      WorkspaceReconcile.self, WorkspaceReconcile.Params(reason: reason),
      options: Self.mutation(timeout: .seconds(120)))
    if let id = selectedThreadId, detail != nil { await loadDetail(id: id) }
  }

  /// The next action for the last failure, in the context of the open thread's connection.
  public var remediation: Remediation? {
    guard let failure = lastFailure else { return nil }
    let connection = detail.flatMap { self.connection(id: $0.thread.connectionId) }
    return Remediation.for(failure, connection: connection)
  }

  /// Carry out a remediation's action. Each one is an ordinary command the user could issue by hand.
  public func perform(_ action: Remediation.Action) async {
    switch action {
    case .none: break
    case .signIn(let connectionId): await login(connectionId: connectionId)
    case .openConnections: surface = .connections
    case .openServers: surface = .servers
    case .newThread: showNewThread = true
    case .checkAgain: if let id = detail?.thread.id { await reconcileThread(id: id) }
    case .abandonTurn: if let id = detail?.thread.id { await abandonTurn(threadId: id) }
    case .openThread(let threadId): await openThread(id: threadId)
    }
    if case .none = action { return }
    lastError = nil
  }

  /// Deliberate recovery for an outcome-unknown turn (spec 10.1.4). Nothing is re-sent.
  public func abandonTurn(threadId: String) async {
    _ = await perform {
      try await $0.request(
        TurnAbandon.self, TurnInterrupt.Params(threadId: threadId), options: Self.mutation()
      )
      .turn
    }
  }

  public func respond(requestId: String, decision: RuntimeDecision) async {
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, decision: decision),
        options: Self.mutation()
      ).request
    }
  }

  public func answer(requestId: String, answers: [String: [String]]) async {
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, answers: answers),
        options: Self.mutation()
      ).request
    }
  }

  // MARK: - Internals

  private static func mutation(timeout: Duration = .seconds(30)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: timeout)
  }

  private func perform<T: Sendable>(_ body: (WorkspaceClient) async throws -> T) async -> T? {
    guard let client else {
      lastError = "Coordinator is not connected."
      return nil
    }
    busy = true
    defer { busy = false }
    do {
      let value = try await body(client)
      lastError = nil
      return value
    } catch {
      lastFailure = WorkspaceError.from(error)
      lastError = Self.describe(error)
      return nil
    }
  }

  private func merge(_ connection: Connection) {
    if let index = connections.firstIndex(where: { $0.id == connection.id }) {
      connections[index] = connection
    } else {
      connections.append(connection)
    }
  }

  private func observe(_ client: WorkspaceClient) async {
    let events = await client.events()
    let desync = await client.desync()
    let desyncTask = Task { @MainActor in
      for await _ in desync { await self.reconcileAfter("reconnect") }
    }
    for await envelope in events { apply(envelope.event) }
    desyncTask.cancel()
    if link == .ready {
      link = .unavailable
      linkMessage = "Coordinator connection closed."
    }
  }

  private func apply(_ event: AdapterEvent) {
    switch event.kind {
    case .threadUpdated:
      if let thread = try? event.payload["thread"]?.decode(ConversationThread.self) {
        store(thread)
        if detail?.thread.id == thread.id { reloadRemoteDraftIfIdle(threadId: thread.id) }
        scheduleRefetch(threadId: thread.id)
      }
    case .projectChanged:
      Task { await refreshProjects() }
    case .serverChanged:
      if let server = try? event.payload["server"]?.decode(LocalServer.self) { merge(server) }
    case .connectionChanged:
      // A connection this client has not seen (added by the CLI or another window): refetch.
      if !connections.contains(where: { $0.id == event.connectionId }) {
        Task { try? await refreshSnapshot() }
      }
      if let index = connections.firstIndex(where: { $0.id == event.connectionId }) {
        if let status = event.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:)) {
          connections[index].status = status
        }
        if let auth = event.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:)) {
          connections[index].authStatus = auth
        }
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let threadId = event.threadId, let turn = try? event.payload["turn"]?.decode(Turn.self) {
        activeTurns[threadId] = turn.status == .terminal ? nil : turn
      }
      applyToDetail(event)
      if let threadId = event.threadId {
        scheduleRefetch(threadId: threadId)
        if event.kind == .turnFinished, detail?.thread.id == threadId {
          unreadHold.remove(threadId)
          Task { await markReadIfNeeded(threadId: threadId) }
        }
      }
    case .runtimeRequestOpened, .runtimeRequestResolved, .runtimeRequestExpired:
      applyToDetail(event)
      if let threadId = event.threadId { scheduleRefetch(threadId: threadId) }
    default:
      applyToDetail(event)
    }
  }

  private func applyToDetail(_ event: AdapterEvent) {
    guard var current = detail, event.threadId == current.thread.id else { return }
    switch event.kind {
    case .messageDelta:
      if let itemId = event.nativeIds["itemId"], let delta = event.payload["delta"]?.stringValue {
        current.liveText[itemId, default: ""] += delta
      }
    case .messageStarted, .messageCompleted, .toolStarted, .toolCompleted:
      if let item = try? event.payload["displayItem"]?.decode(DisplayItem.self) {
        current.upsert(item)
        if event.kind == .messageCompleted || event.kind == .toolCompleted, let nativeId = item.nativeItemId {
          current.liveText[nativeId] = nil
        }
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let turn = try? event.payload["turn"]?.decode(Turn.self) { current.upsert(turn) }
      if event.kind == .turnFinished { current.liveText = [:] }
    case .runtimeRequestOpened:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self),
        request.state == .pending, !current.requests.contains(where: { $0.id == request.id })
      {
        current.requests.append(request)
      }
    case .runtimeRequestResolved, .runtimeRequestExpired:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self) {
        current.requests.removeAll { $0.id == request.id }
      } else if let nativeId = event.nativeIds["requestId"] {
        current.requests.removeAll {
          $0.nativeRequestId == nativeId && $0.adapterGeneration == event.adapterGeneration
        }
      }
    case .adapterError:
      lastError = event.payload["message"]?.stringValue
    default:
      break
    }
    detail = current
  }

  static func describe(_ error: any Error) -> String {
    let failure = WorkspaceError.from(error)
    return "\(failure.message) [\(failure.code.rawValue)]"
  }
}
