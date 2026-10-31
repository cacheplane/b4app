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
    didSet { if composerText != oldValue, !restoringDraft { scheduleDraftSave() } }
  }
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

  public init(transportProvider: @escaping TransportProvider) {
    self.transportProvider = transportProvider
  }

  public var visibleThreads: [ConversationThread] { filtered(archived: false) }

  /// Archived threads under the same search and connection filter, shown when `showArchived` is on.
  public var archivedThreads: [ConversationThread] { filtered(archived: true) }

  private func filtered(archived: Bool) -> [ConversationThread] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    return threads.filter { $0.archived == archived }
      .filter { connectionFilter == nil || $0.connectionId == connectionFilter }
      .filter { query.isEmpty || $0.title.lowercased().contains(query) }
      .sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
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
    await loadDetail(id: id)
  }

  private func loadDetail(id: String) async {
    guard let client else { return }
    detailLoading = true
    defer { detailLoading = false }
    do {
      let read = try await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: id), options: RequestOptions(timeout: .seconds(60)))
      detail = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
      if let active = read.turns.last(where: { $0.status != .terminal }) {
        activeTurns[id] = active
      } else {
        activeTurns[id] = nil
      }
      let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: id)).draft
      restoringDraft = true
      composerText = draft?.text ?? ""
      restoringDraft = false
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
        threads.removeAll { $0.id == thread.id }
        threads.insert(thread, at: 0)
        if detail?.thread.id == thread.id { detail?.thread = thread }
      }
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
