import B4Adapter
import ClaudeAdapter
import CodexAdapter
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Owns adapters per connection, the turn lifecycle, the display projection, and runtime requests.
/// It is the only writer of turns, display items, and runtime requests (spec sections 6 and 10).
public actor SessionService {
  public typealias AdapterFactory =
    @Sendable (Connection, [String: String], String, any SecretStore) throws -> any AgentAdapter

  public struct Context: Sendable {
    public var database: WorkspaceDatabase
    public var eventLog: EventLog
    public var diagnostics: DiagnosticsService
    public var environment: [String: String]
    public var clientVersion: String
    public var secretStore: any SecretStore
    public var adapterFactory: AdapterFactory
    /// Managed B4 servers (M4); a managed route connection is usable only while its server is ready.
    public var servers: LocalServerService?
    /// Decides which project a new thread joins; shared with the router so their writes serialise.
    public var projects: ProjectService

    public init(
      database: WorkspaceDatabase, eventLog: EventLog, diagnostics: DiagnosticsService,
      environment: [String: String], clientVersion: String, secretStore: any SecretStore,
      adapterFactory: AdapterFactory? = nil, servers: LocalServerService? = nil,
      projects: ProjectService? = nil
    ) {
      self.database = database
      self.eventLog = eventLog
      self.diagnostics = diagnostics
      self.environment = environment
      self.clientVersion = clientVersion
      self.secretStore = secretStore
      self.adapterFactory = adapterFactory ?? SessionService.defaultAdapterFactory
      self.servers = servers
      self.projects = projects ?? ProjectService(database: database, eventLog: eventLog)
    }
  }

  /// One adapter per connection kind. B4 reads its endpoint secret from the credential store.
  public static let defaultAdapterFactory: AdapterFactory = { connection, environment, version, secrets in
    switch connection.kind {
    case .codex: return CodexAdapter(connection: connection, environment: environment, clientVersion: version)
    case .claude:
      return ClaudeAdapter(connection: connection, environment: environment, clientVersion: version)
    case .b4: return B4Adapter(connection: connection, secretStore: secrets, clientVersion: version)
    }
  }

  private let context: Context
  private var adapters: [String: any AgentAdapter] = [:]
  private var pumps: [String: Task<Void, Never>] = [:]
  private let logger = Log.logger("sessions")
  private var db: WorkspaceDatabase { context.database }

  public init(context: Context) {
    self.context = context
  }

  /// Coordinator start: no runtime process survived, so pending requests expire and non-terminal
  /// turns become `reconciling` with an unknown outcome until a viewer reconciles them.
  public func start() {
    if let servers = context.servers {
      pumps["managed-servers"] = Task { [weak self] in
        for await event in servers.events() {
          guard let self else { return }
          await self.project(event)
        }
      }
    }
    do {
      _ = try db.expireAllRuntimeRequests()
      for turn in try db.unresolvedTurns() where turn.status != .reconciling {
        _ = try db.updateTurn(id: turn.id) {
          $0.status = .reconciling
          if $0.submission == .acknowledged || $0.nativeTurnId != nil { $0.submission = .unknown }
        }
      }
    } catch {
      logger.error("startup reconciliation failed: \(String(describing: error), privacy: .public)")
    }
  }

  public func shutdown() async {
    for (id, pump) in pumps { pump.cancel(); pumps[id] = nil }
    for adapter in adapters.values { await adapter.dispose() }
    adapters = [:]
  }

  // MARK: - Adapters

  private func adapter(for connection: Connection) throws -> any AgentAdapter {
    if let existing = adapters[connection.id] { return existing }
    let adapter = try context.adapterFactory(
      connection, context.environment, context.clientVersion, context.secretStore)
    adapters[connection.id] = adapter
    let connectionId = connection.id
    pumps[connectionId] = Task { [weak self] in
      for await event in adapter.events() {
        guard let self else { return }
        await self.project(event)
      }
    }
    return adapter
  }

  private func connectionAndAdapter(id: String) throws -> (Connection, any AgentAdapter) {
    guard let connection = try db.connection(id: id) else {
      throw WorkspaceError(.notFound, "Connection \(id) does not exist.")
    }
    return (connection, try adapter(for: connection))
  }

  private func threadContext(id: String) throws -> (ConversationThread, Connection, any AgentAdapter) {
    guard let thread = try db.thread(id: id) else {
      throw WorkspaceError(.notFound, "Thread \(id) does not exist.")
    }
    let (connection, adapter) = try connectionAndAdapter(id: thread.connectionId)
    return (thread, connection, adapter)
  }

  // MARK: - Connections

  public func connectionAdd(_ params: ConnectionAdd.Params) async throws -> ConnectionAdd.Result {
    let executableName: String
    let defaultLabel: String
    switch params.kind {
    case .codex:
      executableName = "codex"
      defaultLabel = "Codex"
    case .claude:
      executableName = "claude"
      defaultLabel = "Claude Code"
    case .b4:
      return try await addB4Connection(params)
    }
    let located = ExecutableLocator.find(
      executableName, explicitPath: params.executablePath, environment: context.environment)
    let target = params.executablePath ?? located?.path ?? ""
    if let existing = try db.connections(kind: params.kind).first(where: { $0.target == target }) {
      return try await connectionInspect(ConnectionInspect.Params(connectionId: existing.id))
    }
    let connection = try db.insertConnection(
      Connection(
        id: UUID().uuidString.lowercased(), kind: params.kind, label: params.label ?? defaultLabel,
        target: target, status: .connecting))
    return try await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
  }

  /// Attach a B4 endpoint: base URL (HTTPS, or HTTP on loopback), exact route key, optional
  /// credential reference. A non-agent route is stored and inspected as `incompatible` (D-023).
  private func addB4Connection(_ params: ConnectionAdd.Params) async throws -> ConnectionAdd.Result {
    if let serverId = params.serverId { return try await addManagedConnection(params, serverId: serverId) }
    guard var url = params.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
      throw WorkspaceError(.protocolInvalid, "A B4 connection needs url, the endpoint base URL.")
    }
    let base = try B4HTTPClient.assertAllowedOrigin(url)
    while url.hasSuffix("/") { url.removeLast() }
    guard let routeText = params.route?.trimmingCharacters(in: .whitespacesAndNewlines),
      let route = B4RouteKey(routeText)
    else {
      throw WorkspaceError(
        .protocolInvalid, "A B4 connection needs route in the form /<path>#agent.",
        details: ["route": .string(params.route ?? "")])
    }
    if let reference = params.authReference {
      guard let ref = SecretRef(rawValue: reference) else {
        throw WorkspaceError(
          .protocolInvalid, "authReference must be a secret: reference returned by `credential add`.",
          details: ["authReference": .string(reference)])
      }
      guard try await context.secretStore.read(ref) != nil else {
        throw WorkspaceError(
          .notFound, "Credential \(reference) is not in the credential store.",
          details: ["authReference": .string(reference)])
      }
    }
    // Same endpoint, route, and credential: the same profile. A different credential is a different
    // account context and gets its own connection (spec 5.2).
    if let existing = try db.connections(kind: .b4).first(where: {
      $0.target == url && $0.routeKey == route.key && $0.authReference == params.authReference
    }) {
      return try await connectionInspect(ConnectionInspect.Params(connectionId: existing.id))
    }
    let mode: B4Mode = B4HTTPClient.isLoopback(base.host ?? "") ? .attachedLocal : .remote
    let connection = try db.insertConnection(
      Connection(
        id: UUID().uuidString.lowercased(), kind: .b4,
        label: params.label ?? "\(route.displayName) @ \(base.host ?? url)", target: url, routeKey: route.key,
        b4Mode: mode, authReference: params.authReference, status: .connecting))
    return try await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
  }

  /// A route connection on a managed server: the target is the server's loopback origin, which is
  /// stable for the life of the registration (D-027). The route must be one the inspection found.
  private func addManagedConnection(
    _ params: ConnectionAdd.Params, serverId: String
  ) async throws -> ConnectionAdd.Result {
    guard let servers = context.servers else {
      throw WorkspaceError.unsupported("managed servers", plannedFor: "M4")
    }
    if params.url != nil || params.authReference != nil {
      throw WorkspaceError(
        .protocolInvalid, "A managed route connection takes a server and a route, not a url or a credential.")
    }
    let server = try await servers.resolve(serverId)
    guard let routeText = params.route?.trimmingCharacters(in: .whitespacesAndNewlines),
      let route = B4RouteKey(routeText)
    else {
      throw WorkspaceError(
        .protocolInvalid, "A route connection needs route in the form /<path>#agent.",
        details: ["route": .string(params.route ?? "")])
    }
    guard server.routes.contains(where: { $0.key == route.key }) else {
      throw WorkspaceError(
        .notFound,
        "Server \(server.name) has no route \(route.key). Known: \(server.routes.map(\.key).joined(separator: ", ")). Run `agent-workspace server inspect \(server.name)` after adding routes.",
        details: ["route": .string(route.key), "serverId": .string(server.id)])
    }
    guard let port = server.requestedPort else {
      throw WorkspaceError(.internalError, "Server \(server.name) has no port.")
    }
    if let existing = try db.connections(localServerId: server.id).first(where: { $0.routeKey == route.key })
    {
      return try await connectionInspect(ConnectionInspect.Params(connectionId: existing.id))
    }
    let connection = try db.insertConnection(
      Connection(
        id: UUID().uuidString.lowercased(), kind: .b4,
        label: params.label ?? "\(route.displayName) @ \(server.name)", target: "http://127.0.0.1:\(port)",
        routeKey: route.key, b4Mode: .managedLocal, localServerId: server.id, status: .connecting))
    return try await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
  }

  /// A managed route connection is reachable only while its server is ready; nothing is auto-started.
  private func managedServerOutage(_ connection: Connection) async -> WorkspaceError? {
    guard connection.b4Mode == .managedLocal, let serverId = connection.localServerId,
      let servers = context.servers
    else { return nil }
    if await servers.isReady(id: serverId) { return nil }
    let name = (try? await servers.resolve(serverId))?.name ?? serverId
    return WorkspaceError(
      .endpointUnavailable, "Server \(name) is stopped. Run `agent-workspace server start \(name)`.",
      details: ["serverId": .string(serverId), "reason": "server_stopped"])
  }

  /// Store an endpoint secret and hand back its reference. The value is never logged or echoed.
  public func credentialAdd(_ params: CredentialAdd.Params) async throws -> CredentialAdd.Result {
    let label = params.label.trimmingCharacters(in: .whitespaces)
    guard !label.isEmpty else { throw WorkspaceError(.protocolInvalid, "A credential needs a label.") }
    guard !params.value.isEmpty else {
      throw WorkspaceError(.protocolInvalid, "The credential value is empty.")
    }
    let ref = SecretRef.make()
    try await context.secretStore.put(ref, value: params.value)
    return CredentialAdd.Result(reference: ref.rawValue, label: label)
  }

  public func connectionInspect(_ params: ConnectionInspect.Params) async throws -> ConnectionAdd.Result {
    let (connection, adapter) = try connectionAndAdapter(id: params.connectionId)
    let inspection: ConnectionInspection
    if let outage = await managedServerOutage(connection) {
      inspection = ConnectionInspection(
        status: .offline, authStatus: .notRequired, message: outage.message, error: outage)
    } else {
      inspection = try await adapter.inspectConnection()
    }
    let updated =
      try db.updateConnection(id: connection.id) {
        $0.status = inspection.status
        $0.authStatus = inspection.authStatus
        $0.capabilities = inspection.capabilities
        if let path = inspection.executablePath, $0.target.isEmpty { $0.target = path }
        // The identity the runtime presents now; nil (signed out, unreachable) keeps the last known one.
        if let scope = inspection.nativeScope, !scope.isEmpty { $0.nativeScope = scope }
      } ?? connection
    await context.eventLog.publish(
      AdapterEvent.connectionChanged(
        connectionId: connection.id, status: inspection.status, authStatus: inspection.authStatus,
        transport: .disconnected, message: inspection.message))
    return ConnectionAdd.Result(connection: updated, inspection: inspection)
  }

  public func connectionLogin(_ params: ConnectionLogin.Params) async throws -> ConnectionLogin.Result {
    let (_, adapter) = try connectionAndAdapter(id: params.connectionId)
    guard let capable = adapter as? any LoginCapable else {
      throw WorkspaceError.unsupported("login", plannedFor: "M3")
    }
    let login = try await capable.startLogin()
    _ = try db.updateConnection(id: params.connectionId) { $0.authStatus = .authenticating }
    return ConnectionLogin.Result(authUrl: login.authUrl, loginId: login.loginId)
  }

  // MARK: - Threads

  public func threadCreate(_ params: ThreadCreate.Params) async throws -> ThreadCreate.Result {
    let (connection, adapter) = try connectionAndAdapter(id: params.connectionId)
    if let outage = await managedServerOutage(connection) { throw outage }
    let input: NewSessionInput
    let threadContext: String?
    let defaultTitle: String
    if connection.kind == .b4 {
      // A B4 thread is bound to the connection's route, not a directory (spec 3.3, D-013 analog).
      input = NewSessionInput(routeKey: connection.routeKey)
      threadContext = connection.routeKey
      defaultTitle = connection.routeKey.flatMap(B4RouteKey.init)?.displayName ?? connection.label
    } else {
      guard let requested = params.workingDirectory, !requested.isEmpty else {
        throw WorkspaceError(
          .protocolInvalid, "A \(connection.kind.rawValue) thread needs a workingDirectory.")
      }
      var isDirectory: ObjCBool = false
      let directory = (requested as NSString).expandingTildeInPath
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw WorkspaceError(
          .protocolInvalid, "Working directory \(requested) does not exist.",
          details: ["workingDirectory": .string(requested)])
      }
      input = NewSessionInput(workingDirectory: directory)
      threadContext = directory
      defaultTitle = (directory as NSString).lastPathComponent
    }
    let ref = try await adapter.createSession(input)
    if !ref.nativeScope.isEmpty, connection.nativeScope != ref.nativeScope {
      _ = try db.updateConnection(id: connection.id) { $0.nativeScope = ref.nativeScope }
    }
    let title = params.title?.trimmingCharacters(in: .whitespaces)
    var newThread = ConversationThread(
      id: UUID().uuidString.lowercased(), connectionId: connection.id, nativeThreadId: ref.nativeSessionId,
      nativeScope: ref.nativeScope, title: (title?.isEmpty == false ? title : nil) ?? defaultTitle,
      context: threadContext)
    // The thread joins the project of its folder (created on first use); `context` stays as given.
    newThread.projectId = try await context.projects.projectId(forThread: newThread, connection: connection)
    let thread = try db.insertThread(newThread)
    await context.eventLog.publish(
      AdapterEvent(
        kind: .sessionCreated, connectionId: connection.id, threadId: thread.id,
        nativeIds: ["threadId": ref.nativeSessionId], payload: ["scope": .string(ref.nativeScope)]))
    await context.eventLog.publish(try AdapterEvent.threadUpdated(thread))
    return ThreadCreate.Result(thread: thread)
  }

  /// Mark a thread read up to `turnId`, or unread again with nil. The storage guard ignores a turn that
  /// is not a terminal turn of this thread or is older than the marker; viewers hear about a change only.
  public func threadMarkRead(_ params: ThreadMarkRead.Params) async throws -> ThreadMarkRead.Result {
    guard let before = try db.thread(id: params.threadId),
      let after = try db.markRead(threadId: params.threadId, turnId: params.turnId)
    else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
    if before.readTurnId != after.readTurnId {
      await context.eventLog.publish(try AdapterEvent.threadUpdated(after))
    }
    return ThreadMarkRead.Result(thread: after)
  }

  /// A plain read is cheap and offline-safe: it reconciles an unresolved turn and, when the cache
  /// is empty although turns were recorded (the cache was lost), loads native history once.
  public func threadRead(_ params: ThreadRead.Params) async throws -> ThreadRead.Result {
    guard var thread = try db.thread(id: params.threadId) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    if let reconciling = try db.activeTurn(threadId: thread.id), reconciling.status == .reconciling {
      await reconcile(reconciling, thread: thread)
    }
    if try db.displayItems(threadId: thread.id).isEmpty, !(try db.turns(threadId: thread.id)).isEmpty {
      thread = await loadHistory(thread)
    }
    return try readResult(thread)
  }

  /// Deliberate reconciliation (spec 10.1.4, 10.3): identity check, unresolved turn, native history
  /// merged without duplicates (D-031), continuity recorded. Nothing is re-sent.
  public func threadReconcile(_ params: ThreadReconcile.Params) async throws -> ThreadRead.Result {
    guard var thread = try db.thread(id: params.threadId) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    guard let connection = try db.connection(id: thread.connectionId) else {
      throw WorkspaceError(.notFound, "Connection \(thread.connectionId) does not exist.")
    }
    if Self.identityChanged(thread: thread, connection: connection) {
      thread = await setContinuity(thread, .identityChanged)
      return try readResult(thread)
    }
    if let active = try db.activeTurn(threadId: thread.id), active.status != .submitting {
      await reconcile(active, thread: thread)
    }
    thread = await loadHistory(thread)
    return try readResult(thread)
  }

  private func readResult(_ thread: ConversationThread) throws -> ThreadRead.Result {
    ThreadRead.Result(
      thread: try db.thread(id: thread.id) ?? thread, turns: try db.turns(threadId: thread.id),
      items: try db.displayItems(threadId: thread.id),
      requests: try db.pendingRuntimeRequests(threadId: thread.id))
  }

  /// A thread created under one native identity never continues under another (spec 5.1).
  static func identityChanged(thread: ConversationThread, connection: Connection) -> Bool {
    guard !thread.nativeScope.isEmpty, let scope = connection.nativeScope, !scope.isEmpty else {
      return false
    }
    return scope != thread.nativeScope
  }

  /// Record a continuity change and tell viewers; a no-op when nothing changed.
  @discardableResult
  private func setContinuity(
    _ thread: ConversationThread, _ state: ThreadContinuity
  ) async -> ConversationThread {
    guard thread.continuity != state,
      let updated = try? db.updateThread(id: thread.id, { $0.continuity = state })
    else { return thread }
    if let event = try? AdapterEvent.threadUpdated(updated) { await context.eventLog.publish(event) }
    return updated
  }

  /// Load native history through `loadSession` and merge it into the cache. A missing native
  /// session marks the thread `missing` only once a turn was recorded; a fresh thread has nothing to
  /// resume yet. Transport failures leave the cache and the continuity as they were.
  private func loadHistory(_ thread: ConversationThread) async -> ConversationThread {
    guard let (_, connection, adapter) = try? threadContext(id: thread.id) else { return thread }
    if await managedServerOutage(connection) != nil { return thread }
    if Self.identityChanged(thread: thread, connection: connection) {
      return await setContinuity(thread, .identityChanged)
    }
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    do {
      let snapshot = try await adapter.loadSession(ref)
      let merge = try db.mergeSnapshotItems(threadId: thread.id, items: snapshot.items)
      if merge.inserted + merge.updated + merge.removed > 0 {
        await context.eventLog.publish(
          AdapterEvent(
            kind: .reconciliationSnapshot, connectionId: connection.id, threadId: thread.id,
            nativeIds: ["threadId": thread.nativeThreadId],
            payload: [
              "inserted": .number(Double(merge.inserted)), "updated": .number(Double(merge.updated)),
              "removed": .number(Double(merge.removed)), "truncated": .bool(snapshot.truncated),
            ]))
      }
      return await setContinuity(thread, .available)
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.code == .nativeSessionMissing, !((try? db.turns(threadId: thread.id)) ?? []).isEmpty {
        return await setContinuity(thread, .missing)
      }
      logger.info(
        "history load for \(thread.id, privacy: .public) skipped: \(failure.code.rawValue, privacy: .public)")
      return thread
    }
  }

  /// Ask the runtime what became of a turn whose outcome is unknown. Never assumes success.
  private func reconcile(_ turn: Turn, thread: ConversationThread) async {
    guard let (_, connection, adapter) = try? threadContext(id: thread.id) else { return }
    // A stopped managed server cannot answer; the turn stays reconciling until it is back.
    if await managedServerOutage(connection) != nil { return }
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    let result: ReconcileResult
    do {
      result = try await adapter.reconcile(ref, turn: turn.nativeTurnId.map(ActiveTurnRef.init))
    } catch {
      if WorkspaceError.from(error).code == .nativeSessionMissing { await setContinuity(thread, .missing) }
      return
    }
    if case .parked? = result.activeTurnOutcome {
      // The runtime is waiting on a durable prompt the adapter re-opened; the turn is answerable again.
      if let updated = try? db.updateTurn(id: turn.id, { $0.status = .waitingForUser }) {
        await publishTurn(.turnStateChanged, updated, thread: thread, payload: ["source": "reconcile"])
      }
      return
    }
    guard case .known(let outcome)? = result.activeTurnOutcome else { return }
    if let updated = try? db.updateTurn(
      id: turn.id,
      {
        $0.status = .terminal
        $0.outcome = outcome
      })
    {
      await publishTurn(
        .turnFinished, updated, thread: thread,
        payload: ["outcome": .string(outcome.rawValue), "source": "reconcile"])
    }
  }

  public func threadUpdate(_ params: ThreadUpdate.Params) async throws -> ThreadCreate.Result {
    guard
      let thread = try db.updateThread(
        id: params.threadId,
        {
          if let title = params.title { $0.title = title }
          if let pinned = params.pinned { $0.pinned = pinned }
          if let archived = params.archived { $0.archived = archived }
        })
    else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
    await context.eventLog.publish(try AdapterEvent.threadUpdated(thread))
    return ThreadCreate.Result(thread: thread)
  }

  // MARK: - Turns

  public func turnSend(_ params: TurnSend.Params, operationId: String) async throws -> TurnSend.Result {
    let text = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw WorkspaceError(.protocolInvalid, "Turn text must not be empty.") }
    if let existing = try db.turn(operationId: operationId) { return TurnSend.Result(turn: existing) }
    let (thread, connection, adapter) = try threadContext(id: params.threadId)
    if let outage = await managedServerOutage(connection) { throw outage }
    try await assertContinuable(thread, connection: connection)
    try assertDirectoryFree(thread, connection: connection)
    if let active = try db.activeTurn(threadId: thread.id) {
      throw WorkspaceError(
        .protocolInvalid,
        "A turn is still \(active.status.rawValue) on this thread. Wait for it to finish or stop it first.",
        details: [
          "reason": "turn_active", "turnId": .string(active.id), "status": .string(active.status.rawValue),
        ])
    }
    var turn = try db.insertTurn(
      Turn(id: UUID().uuidString.lowercased(), threadId: thread.id, operationId: operationId))
    let userItem = try db.upsertDisplayItem(
      threadId: thread.id, turnId: turn.id, nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": .string(text)], provenance: .live)
    // Cleared, not deleted: the empty text syncs as an ordinary last-writer-wins update.
    try? db.clearDraft(threadId: thread.id)
    await context.eventLog.publish(
      AdapterEvent(
        kind: .messageCompleted, connectionId: connection.id, threadId: thread.id, turnId: turn.id,
        payload: ["displayItem": try JSONValue(encoding: userItem), "role": "user"]))
    await publishTurn(.turnStateChanged, turn, thread: thread)
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    do {
      let receipt = try await adapter.sendTurn(
        ref, input: TurnInput(operationId: operationId, text: text, workingDirectory: thread.context))
      turn =
        try db.updateTurn(id: turn.id) {
          if $0.nativeTurnId == nil { $0.nativeTurnId = receipt.nativeTurnId }
          if $0.status == .submitting {
            $0.status = .running
            $0.submission = receipt.acknowledged ? .acknowledged : .unknown
          }
        } ?? turn
      await publishTurn(.turnStateChanged, turn, thread: thread)
      return TurnSend.Result(turn: turn)
    } catch {
      var failure = WorkspaceError.from(error)
      failure.message = LogRedactor.redact(failure.message)
      let unknown = failure.code == .submissionUnknown
      if failure.code == .nativeSessionMissing { await setContinuity(thread, .missing) }
      // The runtime's own notifications may already have acknowledged or finished the turn while the
      // request's response was lost (a late ack). State the events established wins over the error.
      if let current = try db.turn(id: turn.id), current.status != .submitting {
        return TurnSend.Result(turn: current)
      }
      turn =
        try db.updateTurn(id: turn.id) {
          guard $0.status == .submitting else { return }
          if unknown {
            $0.status = .reconciling
            $0.submission = .unknown
          } else {
            $0.status = .terminal
            $0.outcome = .failed
          }
        } ?? turn
      await publishTurn(
        unknown ? .turnStateChanged : .turnFinished, turn, thread: thread,
        payload: [
          "outcome": unknown ? .null : "failed", "errorCode": .string(failure.code.rawValue),
          "error": ["message": .string(failure.message)],
        ])
      await noteTurnFailure(code: failure.code, message: failure.message, connection: connection)
      throw WorkspaceError(
        failure.code, failure.message,
        details: ["turnId": .string(turn.id), "cause": failure.details ?? .null])
    }
  }

  /// Spec 12 and A15: a failed turn that reveals an auth, allowance, or compatibility problem updates
  /// the connection's state and the diagnostics so the user gets a specific next action. Nothing is
  /// retried and no billing mode changes.
  private func noteTurnFailure(code: ErrorCode, message: String, connection: Connection) async {
    let scope = "\(connection.kind.rawValue):\(connection.label)"
    switch code {
    case .authRequired:
      if let updated = try? db.updateConnection(id: connection.id, { $0.authStatus = .required }) {
        await context.eventLog.publish(
          AdapterEvent.connectionChanged(
            connectionId: updated.id, status: updated.status, authStatus: .required, transport: .connected,
            message: "Sign-in expired or was revoked: \(message)"))
      }
      await context.diagnostics.recordError(scope: scope, code: code.rawValue, message: message)
    case .incompatibleVersion:
      if let updated = try? db.updateConnection(id: connection.id, { $0.status = .incompatible }) {
        await context.eventLog.publish(
          AdapterEvent.connectionChanged(
            connectionId: updated.id, status: .incompatible, authStatus: updated.authStatus,
            transport: .connected, message: message))
      }
      await context.diagnostics.recordError(scope: scope, code: code.rawValue, message: message)
    case .allowanceExceeded, .authModeConflict, .nativeSessionMissing, .identityChanged, .endpointUnavailable,
      .submissionUnknown:
      await context.diagnostics.recordError(scope: scope, code: code.rawValue, message: message)
    default:
      break
    }
  }

  /// Refuse a turn on a thread whose native session cannot be continued (spec 3.3, 5.1). The cached
  /// transcript stays; the remedy is a new thread.
  private func assertContinuable(_ thread: ConversationThread, connection: Connection) async throws {
    if Self.identityChanged(thread: thread, connection: connection) {
      await setContinuity(thread, .identityChanged)
      throw WorkspaceError(
        .identityChanged,
        "This thread belongs to \(thread.nativeScope); the connection is now \(connection.nativeScope ?? "another identity"). Start a new thread to continue with the current account or server.",
        details: [
          "threadScope": .string(thread.nativeScope),
          "connectionScope": .string(connection.nativeScope ?? ""),
        ])
    }
    switch thread.continuity {
    case .available: return
    case .identityChanged:
      // The connection presents the thread's identity again: continuity is back.
      await setContinuity(thread, .available)
    case .missing:
      throw WorkspaceError(
        .nativeSessionMissing,
        "The runtime no longer has this thread's native session. The cached transcript stays; start a new thread to continue.",
        details: ["reason": "missing", "threadId": .string(thread.id)])
    }
  }

  /// Spec 10.1.5: writable Codex and Claude runs in one canonical directory are serialized through
  /// this app, across connections, and the lock holds through waiting and unknown states (D-033).
  private func assertDirectoryFree(_ thread: ConversationThread, connection: Connection) throws {
    guard connection.kind != .b4, let directory = thread.context else { return }
    let canonical = Self.canonicalDirectory(directory)
    for entry in try db.activeHarnessTurns() where entry.thread.id != thread.id {
      guard let other = entry.thread.context, Self.canonicalDirectory(other) == canonical else { continue }
      throw WorkspaceError(
        .protocolInvalid,
        "Another thread (\(entry.thread.title.isEmpty ? entry.thread.id : entry.thread.title)) has a turn \(entry.turn.status.rawValue) in \(canonical). Wait for it, stop it, or resolve its outcome first; two agents must not write the same directory at once.",
        details: [
          "reason": "directory_locked", "threadId": .string(entry.thread.id),
          "turnId": .string(entry.turn.id),
          "status": .string(entry.turn.status.rawValue), "directory": .string(canonical),
        ])
    }
  }

  /// Symlinks resolved, `..` collapsed, no trailing slash: the identity of a working directory.
  static func canonicalDirectory(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    var resolved = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
    return resolved
  }

  /// Deliberate recovery (spec 10.1.4): the user gives up on a turn whose outcome the runtime never
  /// established. The turn ends `failed`, a system note says why, and nothing is sent anywhere.
  public func turnAbandon(_ params: TurnAbandon.Params) async throws -> TurnSend.Result {
    guard let thread = try db.thread(id: params.threadId) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    guard let active = try db.activeTurn(threadId: thread.id) else {
      throw WorkspaceError(.notFound, "No turn is active on this thread.")
    }
    guard active.status == .reconciling else {
      throw WorkspaceError(
        .protocolInvalid,
        "Turn \(active.id) is \(active.status.rawValue), not reconciling. Stop it instead; only an unknown outcome can be abandoned.",
        details: [
          "reason": "turn_active", "turnId": .string(active.id), "status": .string(active.status.rawValue),
        ])
    }
    for request in try db.pendingRuntimeRequests(threadId: thread.id) {
      _ = try db.transitionRuntimeRequest(id: request.id, to: .expired)
    }
    let note = try db.upsertDisplayItem(
      threadId: thread.id, turnId: active.id, nativeItemId: nil, role: .system, type: "turnAbandoned",
      payload: [
        "text":
          "The runtime never reported how this turn ended, and you chose to abandon it. The agent may or may not have acted on the request; nothing was re-sent.",
        "submission": .string(active.submission.rawValue),
      ], provenance: .live)
    await context.eventLog.publish(
      AdapterEvent(
        kind: .messageCompleted, connectionId: thread.connectionId, threadId: thread.id, turnId: active.id,
        payload: ["displayItem": try JSONValue(encoding: note), "role": "system"]))
    let turn =
      try db.updateTurn(id: active.id) {
        $0.status = .terminal
        $0.outcome = .failed
      } ?? active
    await publishTurn(
      .turnFinished, turn, thread: thread, payload: ["outcome": "failed", "source": "abandoned"])
    if let touched = try db.updateThread(id: thread.id, { _ in }) {
      await context.eventLog.publish(try AdapterEvent.threadUpdated(touched))
    }
    return TurnSend.Result(turn: turn)
  }

  public func turnInterrupt(_ params: TurnInterrupt.Params) async throws -> TurnSend.Result {
    let (thread, _, adapter) = try threadContext(id: params.threadId)
    guard let active = try db.activeTurn(threadId: thread.id) else {
      throw WorkspaceError(.notFound, "No turn is active on this thread.")
    }
    guard let nativeTurnId = active.nativeTurnId else {
      throw WorkspaceError(
        .cancellationUnconfirmed,
        "The turn has not been acknowledged by the runtime yet; try again in a moment.")
    }
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    let receipt = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: nativeTurnId))
    let turn =
      try db.updateTurn(id: active.id) {
        if $0.status != .terminal {
          $0.status = .stopping
          if let outcome = receipt.outcome {
            $0.status = .terminal
            $0.outcome = outcome
          }
        }
      } ?? active
    await publishTurn(turn.status == .terminal ? .turnFinished : .turnStateChanged, turn, thread: thread)
    return TurnSend.Result(turn: turn)
  }

  // MARK: - Lifecycle (spec 10.3)

  private func summary(_ turn: Turn) throws -> ActiveTurnSummary? {
    guard let thread = try db.thread(id: turn.threadId),
      let connection = try db.connection(id: thread.connectionId)
    else { return nil }
    let local = connection.kind != .b4 || connection.b4Mode == .managedLocal
    return ActiveTurnSummary(
      threadId: thread.id, threadTitle: thread.title, turnId: turn.id, status: turn.status,
      connectionId: connection.id, connectionLabel: connection.label, kind: connection.kind,
      b4Mode: connection.b4Mode, local: local)
  }

  /// Every non-terminal turn and every owned server that is up, for the Quit dialog (D-032).
  public func activeWork() async throws -> WorkspaceActiveWork.Result {
    let turns = try db.unresolvedTurns().compactMap(summary)
    var servers: [LocalServer] = []
    if let service = context.servers {
      servers = try await service.list().servers.filter { $0.health == .ready || $0.health == .starting }
    }
    return WorkspaceActiveWork.Result(turns: turns, servers: servers)
  }

  /// "Stop owned local work and quit": interrupt local turns, wait briefly for the runtime's word,
  /// force-stop owned servers. Attached and remote runs are detached, never cancelled.
  public func stopLocalWork() async throws -> WorkspaceStopLocalWork.Result {
    var result = WorkspaceStopLocalWork.Result()
    for entry in try db.unresolvedTurns().compactMap(summary) {
      guard entry.local else {
        result.detached.append(entry)
        continue
      }
      if entry.status == .running || entry.status == .waitingForUser || entry.status == .stopping {
        _ = try? await turnInterrupt(TurnInterrupt.Params(threadId: entry.threadId))
      }
      let deadline = ContinuousClock.now + .seconds(5)
      var settled = false
      while ContinuousClock.now < deadline {
        if (try? db.turn(id: entry.turnId))?.status == .terminal {
          settled = true
          break
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      var final = entry
      final.status = (try? db.turn(id: entry.turnId))?.status ?? entry.status
      if settled { result.stopped.append(final) } else { result.unconfirmed.append(final) }
    }
    if let service = context.servers {
      for server in try await service.list().servers
      where server.health == .ready || server.health == .starting {
        do {
          _ = try await service.stop(id: server.id, force: true)
          result.serversStopped.append(server.name)
        } catch {
          result.serverErrors.append("\(server.name): \(WorkspaceError.from(error).message)")
        }
      }
    }
    return result
  }

  /// Wake, reconnect, or an explicit request: reconcile every unresolved turn and re-check offline
  /// connections. Turns still `submitting` are mid-dispatch and left to their own path.
  public func reconcileAll(reason: String) async -> WorkspaceReconcile.Result {
    var reconciled = 0
    var unknown = 0
    var rechecked = 0
    for turn in (try? db.unresolvedTurns()) ?? [] where turn.status != .submitting {
      guard let thread = try? db.thread(id: turn.threadId) else { continue }
      await reconcile(turn, thread: thread)
      let after = (try? db.turn(id: turn.id))?.status ?? turn.status
      if after != turn.status { reconciled += 1 } else if after == .reconciling { unknown += 1 }
    }
    for connection in (try? db.listConnections()) ?? [] where connection.status == .offline {
      if (try? await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))) != nil {
        rechecked += 1
      }
    }
    logger.info(
      "reconcile (\(reason, privacy: .public)): \(reconciled) changed, \(unknown) unknown, \(rechecked) connections rechecked"
    )
    return WorkspaceReconcile.Result(
      reconciled: reconciled, stillUnknown: unknown, connectionsRechecked: rechecked)
  }

  // MARK: - Runtime requests

  public func requestRespond(_ params: RequestRespond.Params) async throws -> RequestRespond.Result {
    guard let request = try db.runtimeRequest(id: params.requestId) else {
      throw WorkspaceError(.notFound, "Runtime request \(params.requestId) does not exist.")
    }
    guard request.state == .pending else {
      throw WorkspaceError(
        .staleRuntimeRequest, "Runtime request \(request.id) is already \(request.state.rawValue).")
    }
    let (thread, connection, adapter) = try threadContext(id: request.threadId)
    let response: RuntimeResponse
    if params.decline == true {
      response = .decline(reason: "Declined by the user.")
    } else if let decision = params.decision {
      response = .decision(decision)
    } else if let answers = params.answers {
      response = .answers(answers)
    } else {
      response = .decline(reason: "Declined by the user.")
    }
    try await adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: request.nativeRequestId, kind: request.kind,
        adapterGeneration: request.adapterGeneration),
      response: response)
    guard try db.transitionRuntimeRequest(id: request.id, to: .resolved) else {
      throw WorkspaceError(.staleRuntimeRequest, "Runtime request \(request.id) was answered concurrently.")
    }
    let resolved = try db.runtimeRequest(id: request.id) ?? request
    await context.eventLog.publish(
      AdapterEvent(
        kind: .runtimeRequestResolved, connectionId: connection.id, threadId: thread.id,
        turnId: request.turnId,
        nativeIds: ["requestId": request.nativeRequestId], adapterGeneration: request.adapterGeneration,
        payload: ["source": "user", "runtimeRequest": try JSONValue(encoding: resolved)]))
    return RequestRespond.Result(request: resolved)
  }

  // MARK: - Projection of adapter events

  private func publishTurn(
    _ kind: EventKind, _ turn: Turn, thread: ConversationThread, payload: JSONValue = [:]
  ) async {
    var body = payload.objectValue ?? [:]
    body["turn"] = (try? JSONValue(encoding: turn)) ?? .null
    body["status"] = .string(turn.status.rawValue)
    if let outcome = turn.outcome { body["outcome"] = .string(outcome.rawValue) }
    await context.eventLog.publish(
      AdapterEvent(
        kind: kind, connectionId: thread.connectionId, threadId: thread.id, turnId: turn.id,
        nativeIds: turn.nativeTurnId.map { ["turnId": $0, "threadId": thread.nativeThreadId] } ?? [:],
        payload: .object(body)))
  }

  private func project(_ incoming: AdapterEvent) async {
    // D-035: the coordinator is the redaction boundary. Adapters forward what runtimes say (stderr
    // tails, error messages); nothing of that leaves here unmasked.
    let raw: AdapterEvent = {
      var copy = incoming
      copy.payload = LogRedactor.redactMessages(in: incoming.payload)
      return copy
    }()
    var event = raw
    var thread: ConversationThread?
    var turn: Turn?
    do {
      if let nativeThreadId = raw.nativeIds["threadId"] {
        thread = try db.thread(connectionId: raw.connectionId, nativeThreadId: nativeThreadId)
      }
      if let thread {
        if let nativeTurnId = raw.nativeIds["turnId"] {
          turn = try db.turn(threadId: thread.id, nativeTurnId: nativeTurnId)
        }
        if turn == nil { turn = try db.activeTurn(threadId: thread.id) }
      }
      event.threadId = thread?.id
      event.turnId = turn?.id
      switch raw.kind {
      case .connectionChanged:
        try await projectConnectionChanged(raw)
      case .turnAcknowledged:
        if let turn, let thread {
          let updated = try db.updateTurn(id: turn.id) {
            if $0.nativeTurnId == nil { $0.nativeTurnId = raw.nativeIds["turnId"] }
            if $0.status == .submitting {
              $0.status = .running
              $0.submission = .acknowledged
            }
          }
          if let updated { event.payload = merge(raw.payload, ["turn": try JSONValue(encoding: updated)]) }
          _ = thread
        }
      case .messageStarted, .messageCompleted, .toolStarted, .toolCompleted:
        guard let thread else { break }
        if let item = try projectItem(raw, thread: thread, turn: turn) {
          event.payload = merge(raw.payload, ["displayItem": try JSONValue(encoding: item)])
        } else {
          return
        }
      case .messageDelta:
        guard thread != nil else { return }
      case .turnFinished:
        guard let thread, let turn else { break }
        let outcome = raw.payload["outcome"]?.stringValue.flatMap(TurnOutcome.init(rawValue:))
        let updated = try db.updateTurn(id: turn.id) {
          if $0.nativeTurnId == nil { $0.nativeTurnId = raw.nativeIds["turnId"] }
          $0.status = .terminal
          $0.outcome = outcome
        }
        if let updated { event.payload = merge(raw.payload, ["turn": try JSONValue(encoding: updated)]) }
        if let touched = try db.updateThread(id: thread.id, { _ in }) {
          await context.eventLog.publish(try AdapterEvent.threadUpdated(touched))
        }
        if outcome == .failed,
          let code = raw.payload["errorCode"]?.stringValue.flatMap(ErrorCode.init(rawValue:)),
          let connection = try db.connection(id: thread.connectionId)
        {
          await noteTurnFailure(
            code: code, message: raw.payload["error"]?["message"]?.stringValue ?? code.rawValue,
            connection: connection)
        }
      case .turnStateChanged:
        guard let turn, turn.status != .terminal else { break }
        let status = raw.payload["status"]?.stringValue
        if status == TurnStatus.waitingForUser.rawValue || status == TurnStatus.running.rawValue,
          turn.status == .running || turn.status == .waitingForUser
        {
          let updated = try db.updateTurn(id: turn.id) {
            $0.status = TurnStatus(rawValue: status!) ?? $0.status
          }
          if let updated { event.payload = merge(raw.payload, ["turn": try JSONValue(encoding: updated)]) }
        }
      case .runtimeRequestOpened:
        guard let thread, let nativeRequestId = raw.nativeIds["requestId"] else { break }
        let kind = raw.payload["kind"]?.stringValue.flatMap(RuntimeRequestKind.init(rawValue:)) ?? .unknown
        let request = try db.insertRuntimeRequest(
          RuntimeRequest(
            id: UUID().uuidString.lowercased(), nativeRequestId: nativeRequestId, threadId: thread.id,
            turnId: turn?.id, adapterGeneration: raw.adapterGeneration, kind: kind, payload: raw.payload))
        if let turn, turn.status == .running || turn.status == .reconciling {
          _ = try db.updateTurn(id: turn.id) { $0.status = .waitingForUser }
        }
        event.payload = merge(raw.payload, ["runtimeRequest": try JSONValue(encoding: request)])
      case .runtimeRequestResolved:
        guard let thread, let nativeRequestId = raw.nativeIds["requestId"],
          let request = try db.runtimeRequest(
            threadId: thread.id, nativeRequestId: nativeRequestId, adapterGeneration: raw.adapterGeneration)
        else { break }
        _ = try db.transitionRuntimeRequest(id: request.id, to: .resolved)
        if let turn, turn.status == .waitingForUser,
          try db.pendingRuntimeRequests(threadId: thread.id).isEmpty
        {
          _ = try db.updateTurn(id: turn.id) { $0.status = .running }
        }
        if let resolved = try db.runtimeRequest(id: request.id) {
          event.payload = merge(raw.payload, ["runtimeRequest": try JSONValue(encoding: resolved)])
        }
      case .adapterError:
        await context.diagnostics.recordError(
          scope: raw.payload["scope"]?.stringValue ?? "adapter",
          code: raw.payload["errorCode"]?.stringValue ?? "internal",
          message: raw.payload["message"]?.stringValue ?? "adapter error")
      default:
        break
      }
    } catch {
      logger.error(
        "projection of \(raw.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
      )
      await context.diagnostics.recordError(
        scope: "projection", code: "internal", message: String(describing: error))
    }
    await context.eventLog.publish(event)
  }

  /// Store a started or completed item. Live user messages echoed by the runtime attach their native
  /// id to the item the composer already stored instead of duplicating it. Returns nil to drop.
  private func projectItem(
    _ raw: AdapterEvent, thread: ConversationThread, turn: Turn?
  ) throws -> DisplayItem? {
    guard let item = raw.payload["item"], let type = raw.payload["type"]?.stringValue else { return nil }
    let role = raw.payload["role"]?.stringValue.flatMap(DisplayItemRole.init(rawValue:)) ?? .tool
    let nativeItemId = raw.nativeIds["itemId"]
    if role == .user {
      guard raw.kind == .messageCompleted else { return nil }
      if let turn, let local = try db.unlinkedUserItem(threadId: thread.id, turnId: turn.id) {
        _ = try db.updateDisplayItem(id: local.id) { $0.nativeItemId = nativeItemId }
        return nil
      }
      if let nativeItemId,
        try db.displayItems(threadId: thread.id).contains(where: { $0.nativeItemId == nativeItemId })
      {
        return nil
      }
    }
    return try db.upsertDisplayItem(
      threadId: thread.id, turnId: turn?.id, nativeItemId: nativeItemId, role: role, type: type,
      payload: item,
      provenance: .live)
  }

  private func projectConnectionChanged(_ raw: AdapterEvent) async throws {
    let disconnected = raw.payload["transport"]?.stringValue == TransportStatus.disconnected.rawValue
    // A per-thread runtime (Claude: one process per session) reports exits with the native thread id.
    // Only that thread is affected; the connection itself stays as it was.
    if disconnected, let nativeThreadId = raw.nativeIds["threadId"] {
      guard let thread = try db.thread(connectionId: raw.connectionId, nativeThreadId: nativeThreadId) else {
        return
      }
      for request in try db.pendingRuntimeRequests(threadId: thread.id) {
        _ = try db.transitionRuntimeRequest(id: request.id, to: .expired)
        await context.eventLog.publish(
          AdapterEvent(
            kind: .runtimeRequestExpired, connectionId: raw.connectionId, threadId: thread.id,
            turnId: request.turnId, nativeIds: ["requestId": request.nativeRequestId],
            adapterGeneration: request.adapterGeneration,
            payload: ["runtimeRequest": try JSONValue(encoding: request), "reason": "runtime_exited"]))
      }
      if let turn = try db.activeTurn(threadId: thread.id),
        let updated = try db.updateTurn(
          id: turn.id,
          {
            $0.status = .reconciling
            $0.submission = .unknown
          })
      {
        await publishTurn(.turnStateChanged, updated, thread: thread, payload: ["reason": "runtime_exited"])
      }
      return
    }
    let status = raw.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:))
    let auth = raw.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:))
    _ = try db.updateConnection(id: raw.connectionId) {
      if let status { $0.status = status }
      if let auth { $0.authStatus = auth }
    }
    guard disconnected else { return }
    // The runtime process is gone: its pending requests can never be answered and running turns are
    // of unknown outcome until reconciled. Never assume success or cancellation.
    for request in try db.pendingRuntimeRequests(connectionId: raw.connectionId) {
      _ = try db.transitionRuntimeRequest(id: request.id, to: .expired)
      await context.eventLog.publish(
        AdapterEvent(
          kind: .runtimeRequestExpired, connectionId: raw.connectionId, threadId: request.threadId,
          turnId: request.turnId, nativeIds: ["requestId": request.nativeRequestId],
          adapterGeneration: request.adapterGeneration,
          payload: ["runtimeRequest": try JSONValue(encoding: request), "reason": "runtime_exited"]))
    }
    for turn in try db.unresolvedTurns(connectionId: raw.connectionId) {
      guard
        let updated = try db.updateTurn(
          id: turn.id,
          {
            $0.status = .reconciling
            $0.submission = .unknown
          }), let thread = try db.thread(id: turn.threadId)
      else { continue }
      await publishTurn(.turnStateChanged, updated, thread: thread, payload: ["reason": "runtime_exited"])
    }
  }

  private func merge(_ base: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
    .object((base.objectValue ?? [:]).merging(extra) { _, new in new })
  }
}
