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
    /// Decides which environment a new thread joins. The router must be given the same instance: its
    /// environment edits and this service's thread inserts serialise on that one actor.
    public var environments: EnvironmentService
    /// The waits between tries of a check that found its runtime unreachable (settings connections).
    public var checkRetryDelays: [Duration]
    /// How often deleted threads' runtime copies are retried (deleting threads); zero runs no sweep loop.
    public var threadDeleteSweep: Duration

    public init(
      database: WorkspaceDatabase, eventLog: EventLog, diagnostics: DiagnosticsService,
      environment: [String: String], clientVersion: String, secretStore: any SecretStore,
      environments: EnvironmentService, adapterFactory: AdapterFactory? = nil,
      servers: LocalServerService? = nil,
      checkRetryDelays: [Duration] = [.seconds(1), .seconds(3)], threadDeleteSweep: Duration = .zero
    ) {
      self.database = database
      self.eventLog = eventLog
      self.diagnostics = diagnostics
      self.environment = environment
      self.clientVersion = clientVersion
      self.secretStore = secretStore
      self.adapterFactory = adapterFactory ?? SessionService.defaultAdapterFactory
      self.servers = servers
      self.environments = environments
      self.checkRetryDelays = checkRetryDelays
      self.threadDeleteSweep = threadDeleteSweep
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

  let context: Context
  var adapters: [String: any AgentAdapter] = [:]
  var pumps: [String: Task<Void, Never>] = [:]
  /// Connections with a background check in progress (`inspectInBackground`).
  var runningChecks: Set<String> = []
  /// Set by `shutdown`; no adapter is made after it.
  var closing = false
  /// Runtime requests whose answer is with the adapter right now. `requestRespond` suspends on the
  /// adapter before it marks the request resolved, so without this a second answer (one from the Mac,
  /// one relayed from the phone) could reach the runtime too.
  private var answering: Set<String> = []
  /// The text each open message has streamed so far, by thread id and native item id. A runtime that is
  /// stopped mid-reply (Codex) never completes the item, so without this the reply is stored empty.
  private var streamed: [String: [String: String]] = [:]
  /// Deleted threads whose runtime copy is being deleted right now, so two sweeps never both try one.
  var deletingThreads: Set<String> = []
  let logger = Log.logger("sessions")
  var db: WorkspaceDatabase { context.database }

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
          await self.environment(event)
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
    startThreadDeleteSweep()
  }

  /// Dispose every adapter. `closing` is set before the first suspension, so no adapter (and no
  /// runtime) can be made once a shutdown has begun.
  ///
  /// The adapters are disposed side by side (each runtime may take a moment to exit), and forgotten
  /// before the first suspension, so a second call does nothing.
  public func shutdown() async {
    closing = true
    for (id, pump) in pumps { pump.cancel(); pumps[id] = nil }
    let disposing = Array(adapters.values)
    adapters = [:]
    await withTaskGroup(of: Void.self) { group in
      for adapter in disposing { group.addTask { await adapter.dispose() } }
    }
  }

  // MARK: - Adapters

  func adapter(for connection: Connection) throws -> any AgentAdapter {
    if closing { throw WorkspaceError(.signedOut, AccountManager.signedOutMessage) }
    if let existing = adapters[connection.id] { return existing }
    let adapter = try context.adapterFactory(
      connection, context.environment, context.clientVersion, context.secretStore)
    adapters[connection.id] = adapter
    let connectionId = connection.id
    pumps[connectionId] = Task { [weak self] in
      for await event in adapter.events() {
        guard let self else { return }
        await self.environment(event)
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
    guard let thread = try db.thread(id: id), thread.userDeletedAt == nil else {
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
    var managed = Connection(
      id: UUID().uuidString.lowercased(), kind: .b4,
      label: params.label ?? "\(route.displayName) @ \(server.name)", target: "http://127.0.0.1:\(port)",
      routeKey: route.key, b4Mode: .managedLocal, localServerId: server.id, status: .connecting)
    // The connection serves its server folder's environment, from its first change-log entry on.
    managed.environmentId = try await context.environments.environmentId(forConnection: managed)
    let connection = try db.insertConnection(managed)
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
    if params.background == true { return inspectInBackground(connection) }
    let inspection: ConnectionInspection
    if let outage = await managedServerOutage(connection) {
      inspection = ConnectionInspection(
        status: .offline, authStatus: .notRequired, message: outage.message, error: outage)
    } else {
      inspection = try await inspectRetrying(connection, adapter: adapter)
    }
    let updated =
      try db.updateConnection(id: connection.id) {
        $0.status = inspection.status
        $0.authStatus = inspection.authStatus
        $0.capabilities = inspection.capabilities
        $0.models = inspection.models
        if let path = inspection.executablePath, $0.target.isEmpty { $0.target = path }
        // The identity the runtime presents now; nil (signed out, unreachable) keeps the last known one.
        if let scope = inspection.nativeScope, !scope.isEmpty { $0.nativeScope = scope }
      } ?? connection
    await publishVisibleEvent(
      try AdapterEvent.connectionChanged(
        connectionId: connection.id, status: inspection.status, authStatus: inspection.authStatus,
        transport: .disconnected, message: inspection.message
      ).carrying(updated))
    if inspection.status == .ready, inspection.authStatus == .authenticated {
      await refreshUsage(connectionId: connection.id, adapter: adapter)
    }
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
    try await threadCreate(params, model: nil, permission: nil)
  }

  /// `threadCreate` with the thread's runtime choices, already validated (`threadStart`): they are stored
  /// on the new thread and the runtime's session starts with them.
  func threadCreate(
    _ params: ThreadCreate.Params, model: String?, permission: String?
  ) async throws -> ThreadCreate.Result {
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
      // The environment that owns its folder may already list other folders for the runtime to reach.
      let canonical = Self.canonicalDirectory(directory)
      let others = try db.environment(folderPath: canonical)?.folders.map(\.path).filter { $0 != canonical }
      input = NewSessionInput(
        workingDirectory: directory, model: model, permission: permission,
        additionalDirectories: Self.existingDirectories(others ?? []))
      threadContext = directory
      defaultTitle = (directory as NSString).lastPathComponent
    }
    let ref = try await adapter.createSession(input)
    if !ref.nativeScope.isEmpty, connection.nativeScope != ref.nativeScope {
      _ = try db.updateConnection(id: connection.id) { $0.nativeScope = ref.nativeScope }
    }
    let title = params.title?.trimmingCharacters(in: .whitespaces)
    let newThread = ConversationThread(
      id: params.threadId ?? UUID().uuidString.lowercased(), connectionId: connection.id,
      nativeThreadId: ref.nativeSessionId,
      nativeScope: ref.nativeScope, title: (title?.isEmpty == false ? title : nil) ?? defaultTitle,
      context: threadContext, model: model, permission: permission)
    // The thread joins the environment of its folder (created on first use) in one step with its insert, so
    // no environment edit can land in between; `context` stays as given.
    let thread = try await context.environments.insertThread(newThread, connection: connection)
    await publishVisibleEvent(
      AdapterEvent(
        kind: .sessionCreated, connectionId: connection.id, threadId: thread.id,
        nativeIds: ["threadId": ref.nativeSessionId], payload: ["scope": .string(ref.nativeScope)]))
    await publishVisibleEvent(try AdapterEvent.threadUpdated(thread))
    return ThreadCreate.Result(thread: thread)
  }

  /// Mark a thread read up to `turnId`, or unread again with nil. The storage guard ignores a turn that
  /// is not a terminal turn of this thread or is older than the marker; viewers hear about a change only.
  public func threadMarkRead(_ params: ThreadMarkRead.Params) async throws -> ThreadMarkRead.Result {
    guard let before = try db.thread(id: params.threadId),
      let after = try db.markRead(threadId: params.threadId, turnId: params.turnId)
    else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
    if before.readTurnId != after.readTurnId {
      await publishVisibleEvent(try AdapterEvent.threadUpdated(after))
    }
    return ThreadMarkRead.Result(thread: after)
  }

  /// A plain read is cheap and offline-safe: it reconciles an unresolved turn and, when the cache
  /// is empty although turns were recorded (the cache was lost), loads native history once.
  public func threadRead(_ params: ThreadRead.Params) async throws -> ThreadRead.Result {
    guard var thread = try db.thread(id: params.threadId), thread.userDeletedAt == nil else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    if let reconciling = try db.activeTurn(threadId: thread.id), reconciling.status == .reconciling {
      await reconcile(reconciling, thread: thread)
    }
    if try db.displayItems(threadId: thread.id).isEmpty, !(try db.turns(threadId: thread.id)).isEmpty {
      thread = (try? await loadHistory(thread)) ?? thread
    }
    return try readResult(thread)
  }

  /// Deliberate reconciliation (spec 10.1.4, 10.3): identity check, unresolved turn, native history
  /// merged without duplicates (D-031), continuity recorded. Nothing is re-sent.
  public func threadReconcile(_ params: ThreadReconcile.Params) async throws -> ThreadRead.Result {
    guard var thread = try db.thread(id: params.threadId), thread.userDeletedAt == nil else {
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
    thread = try await loadHistory(thread, surfaceRecovery: true)
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
    thread.identityChanged(on: connection)
  }

  /// Record a continuity change and tell viewers; a no-op when nothing changed.
  @discardableResult
  private func setContinuity(
    _ thread: ConversationThread, _ state: ThreadContinuity
  ) async -> ConversationThread {
    guard thread.continuity != state,
      let updated = try? db.updateThread(id: thread.id, { $0.continuity = state })
    else { return thread }
    if let event = try? AdapterEvent.threadUpdated(updated) { await publishVisibleEvent(event) }
    return updated
  }

  /// Load native history through `loadSession` and merge it into the cache. A missing native
  /// session marks the thread `missing` only once a turn was recorded; a fresh thread has nothing to
  /// resume yet. Transport failures leave the cache and the continuity as they were.
  private func loadHistory(
    _ thread: ConversationThread, surfaceRecovery: Bool = false
  ) async throws
    -> ConversationThread
  {
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
        await publishVisibleEvent(
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
      if failure.code == .protocolInvalid,
        failure.details?["reason"]?.stringValue == "native_session_archived"
      {
        // Older adapters marked every resume rejection as missing. The runtime has now confirmed
        // that this session exists, and an explicit check must show its real recovery instruction.
        let restored = await setContinuity(thread, .available)
        if surfaceRecovery { throw failure }
        return restored
      }
      if failure.code == .nativeSessionMissing, !((try? db.turns(threadId: thread.id)) ?? []).isEmpty {
        return await setContinuity(thread, .missing)
      }
      if surfaceRecovery { throw failure }
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
    guard let existing = try db.thread(id: params.threadId), existing.userDeletedAt == nil else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    if params.model != nil || params.permission != nil {
      guard let kind = try db.connection(id: existing.connectionId)?.kind else {
        throw WorkspaceError(.notFound, "Connection \(existing.connectionId) does not exist.")
      }
      try Self.validateRuntimeChoice(model: params.model, permission: params.permission, kind: kind)
    }
    guard
      let thread = try db.updateThread(
        id: params.threadId,
        {
          if let title = params.title { $0.title = title }
          if let pinned = params.pinned { $0.pinned = pinned }
          if let archived = params.archived { $0.archived = archived }
          if let model = params.model { $0.model = model }
          if let permission = params.permission { $0.permission = permission }
        })
    else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
    await publishVisibleEvent(try AdapterEvent.threadUpdated(thread))
    return ThreadCreate.Result(thread: thread)
  }

  /// A model or permission chosen for a thread of `kind`: none on B4 (`not_supported_for_b4`), and a
  /// permission must be one of the runtime's (`unknown_permission`). Any model id is taken; the runtime
  /// judges it.
  static func validateRuntimeChoice(model: String?, permission: String?, kind: ConnectionKind) throws {
    guard model != nil || permission != nil else { return }
    if kind == .b4 {
      throw WorkspaceError(
        .protocolInvalid, "A B4 thread has no model or permission to set.",
        details: ["reason": "not_supported_for_b4"])
    }
    if let permission, !RuntimeOptions.permissions(for: kind).contains(where: { $0.id == permission }) {
      throw WorkspaceError(
        .protocolInvalid, "\(permission) is not a permission option of this thread's runtime.",
        details: ["reason": "unknown_permission", "permission": .string(permission)])
    }
  }

  // MARK: - thread.start

  /// Create the thread (or reuse the one this id already names) and send its first turn, so a retry
  /// lands on the same thread and the same turn. The relay calls it with `requireEnvironment` (the phone
  /// always names an environment), the Mac's own app without.
  ///
  /// Refuses with `protocol_invalid` anything the Mac would not start itself: a text it cannot store
  /// (`invalid_text`), a thread id that is not a lowercase UUID (`invalid_thread_id`), no environment when
  /// one is required or an unknown one, an unknown connection, a Codex or Claude start with no folder or
  /// (given an environment) one outside the environment's folders, a B4 start with a folder, a remote B4
  /// connection when an environment is required, a local B4 connection that does not serve the given
  /// environment, a connection not ready for a conversation, a model or permission the runtime does not
  /// take (`validateRuntimeChoice`), or a thread id already used with another connection or folder.
  /// What `turnSend` refuses before inserting a turn (`assertCanStart`) is refused before the thread
  /// is made. A Codex or Claude thread with no environment given joins its folder's environment (made when none
  /// owns it) as it is inserted (D-048).
  public func threadStart(
    _ params: ThreadStart.Params, operationId: String, requireEnvironment: Bool
  ) async throws -> ThreadStart.Result {
    try Self.requireStorableText(params.text)
    // The caller mints the id; the thread row keeps it, so only the form this Mac mints is taken.
    guard Self.isLowercaseUUID(params.threadId) else {
      throw Self.refusal("The new thread's id is not valid.", reason: "invalid_thread_id")
    }
    // A retry of a start that already made its turn gets that answer, whatever changed since (the
    // connection may have gone offline): refusing it now would tell the caller the send never happened.
    if let turn = try db.turn(operationId: operationId) {
      guard turn.threadId == params.threadId, let thread = try db.thread(id: turn.threadId) else {
        throw Self.refusal(
          "This command already started a turn on another thread.", reason: "operation_reused")
      }
      return ThreadStart.Result(thread: thread, turn: turn)
    }
    guard !params.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkspaceError(.protocolInvalid, "Turn text must not be empty.")
    }
    let environment: WorkEnvironment?
    if let environmentId = params.environmentId {
      guard let found = try db.environment(id: environmentId) else {
        throw Self.refusal("This environment is not on this Mac.", reason: "environment_missing")
      }
      environment = found
    } else if requireEnvironment {
      throw Self.refusal(
        "A new thread from another device needs an environment.", reason: "environment_missing")
    } else {
      environment = nil
    }
    guard let connection = try db.connection(id: params.connectionId) else {
      throw Self.refusal("This connection is not on this Mac.", reason: "connection_missing")
    }
    let environmentFolders = Set(environment?.folders.map(\.path) ?? [])
    let requested = params.folder.flatMap { $0.isEmpty ? nil : $0 }
    let folder: String?
    switch connection.kind {
    case .codex, .claude:
      guard let requested else {
        throw Self.refusal(
          "A \(connection.kind.rawValue) thread needs one of the environment's folders.",
          reason: "folder_missing"
        )
      }
      let canonical = Self.canonicalDirectory(requested)
      guard environment == nil || environmentFolders.contains(canonical) else {
        throw Self.refusal(
          "That folder is not one of this environment's folders.", reason: "folder_outside_environment")
      }
      folder = canonical
    case .b4:
      let remote = connection.b4Mode == .remote
      if remote, requireEnvironment {
        throw Self.refusal(
          "A remote B4 connection cannot start a thread from another device.", reason: "remote_b4")
      }
      guard requested == nil else {
        throw Self.refusal(
          "A B4 thread is bound to its route and takes no folder.", reason: "folder_not_allowed")
      }
      // A local connection's synced environment and the coordinator's own resolution (its managed
      // server's folder) must both name the given environment. A remote thread has no environment (D-048).
      if let environment, !remote {
        guard connection.localServerId != nil, connection.environmentId == environment.id,
          let serverFolder = try await context.environments.serverFolder(of: connection),
          environmentFolders.contains(serverFolder)
        else {
          throw Self.refusal(
            "Connection \(connection.label) does not serve this environment.",
            reason: "connection_outside_environment")
        }
      }
      folder = nil
    }
    guard connection.enabled, connection.status == .ready else {
      throw Self.refusal(
        "Connection \(connection.label) is not ready for a conversation.", reason: "connection_not_ready")
    }
    try Self.validateRuntimeChoice(model: params.model, permission: params.permission, kind: connection.kind)
    // What `turnSend` would refuse before inserting the turn is refused before the thread is made, so a
    // refused start (and each retry) leaves no empty thread behind.
    try await assertCanStart(connection: connection.id)
    let thread: ConversationThread
    if let existing = try db.thread(id: params.threadId) {
      let sameFolder = folder == nil || existing.context.map(Self.canonicalDirectory) == folder
      guard existing.connectionId == connection.id, sameFolder else {
        throw Self.refusal(
          "Thread \(params.threadId) already exists with another connection or folder.",
          reason: "thread_mismatch")
      }
      thread = existing
    } else {
      thread = try await threadCreate(
        ThreadCreate.Params(
          connectionId: connection.id, workingDirectory: folder,
          title: ThreadTitle.fromFirstMessage(params.text), threadId: params.threadId),
        model: params.model, permission: params.permission
      ).thread
    }
    let turn = try await turnSend(
      TurnSend.Params(threadId: thread.id, text: params.text), operationId: operationId
    ).turn
    return ThreadStart.Result(thread: try db.thread(id: thread.id) ?? thread, turn: turn)
  }

  static func isLowercaseUUID(_ text: String) -> Bool {
    text.count == 36 && UUID(uuidString: text) != nil && text == text.lowercased()
  }

  /// A NUL cannot be stored, and the store refuses it only after the turn row exists, which would leave
  /// that turn `submitting` (see the Task 8 report); a text with one is refused before anything.
  static func requireStorableText(_ text: String) throws {
    guard !text.unicodeScalars.contains("\0") else {
      throw WorkspaceError(
        .protocolInvalid, "The message contains a character that cannot be sent.",
        details: ["reason": "invalid_text"])
    }
  }

  private static func refusal(_ message: String, reason: String) -> WorkspaceError {
    WorkspaceError(.protocolInvalid, message, details: ["reason": .string(reason)])
  }

  // MARK: - Turns

  public func turnSend(_ params: TurnSend.Params, operationId: String) async throws -> TurnSend.Result {
    let text = params.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw WorkspaceError(.protocolInvalid, "Turn text must not be empty.") }
    if let existing = try db.turn(operationId: operationId) { return TurnSend.Result(turn: existing) }
    let (thread, connection, adapter) = try threadContext(id: params.threadId)
    if let outage = await managedServerOutage(connection) { throw outage }
    try await assertContinuable(thread, connection: connection)
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
    await publishVisibleEvent(
      AdapterEvent(
        kind: .messageCompleted, connectionId: connection.id, threadId: thread.id, turnId: turn.id,
        payload: ["displayItem": try JSONValue(encoding: userItem), "role": "user"]))
    await publishTurn(.turnStateChanged, turn, thread: thread)
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    do {
      let receipt = try await adapter.sendTurn(
        ref,
        input: TurnInput(
          operationId: operationId, text: text, workingDirectory: thread.context, model: thread.model,
          permission: thread.permission,
          additionalDirectories: try additionalDirectories(for: thread)))
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
        await publishVisibleEvent(
          AdapterEvent.connectionChanged(
            connectionId: updated.id, status: updated.status, authStatus: .required, transport: .connected,
            message: "Sign-in expired or was revoked: \(message)"))
      }
      await context.diagnostics.recordError(scope: scope, code: code.rawValue, message: message)
    case .incompatibleVersion:
      if let updated = try? db.updateConnection(id: connection.id, { $0.status = .incompatible }) {
        await publishVisibleEvent(
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

  /// The refusals `turnSend` makes before inserting a turn that can be judged before the thread exists:
  /// the connection's adapter and a managed server that is not ready. A remote `thread.start` asks first,
  /// so a start that would be refused makes no thread. A thread's own active turn is `turnSend`'s to
  /// refuse.
  public func assertCanStart(connection connectionId: String) async throws {
    let (connection, _) = try connectionAndAdapter(id: connectionId)
    if let outage = await managedServerOutage(connection) { throw outage }
  }

  /// The environment's other folders, for the runtime to reach beside the thread's own: the canonical paths
  /// of its environment's folders, oldest first, without the thread's working directory or any folder no
  /// longer on disk. Empty for a thread with no environment or no directory (B4).
  func additionalDirectories(for thread: ConversationThread) throws -> [String] {
    guard let environmentId = thread.environmentId, let context = thread.context, !context.isEmpty,
      try db.connection(id: thread.connectionId)?.kind != .b4,
      let environment = try db.environment(id: environmentId)
    else { return [] }
    let own = Self.canonicalDirectory(context)
    return Self.existingDirectories(environment.folders.map(\.path).filter { $0 != own })
  }

  /// The paths that are directories on disk now: an environment folder deleted or unmounted since it was
  /// added is not handed to a runtime.
  static func existingDirectories(_ paths: [String]) -> [String] {
    paths.filter { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
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
    // The runtime never ended the turn; whatever streamed is of unknown standing and is not stored.
    streamed[thread.id] = nil
    let note = try db.upsertDisplayItem(
      threadId: thread.id, turnId: active.id, nativeItemId: nil, role: .system, type: "turnAbandoned",
      payload: [
        "text":
          "The runtime never reported how this turn ended, and you chose to abandon it. The agent may or may not have acted on the request; nothing was re-sent.",
        "submission": .string(active.submission.rawValue),
      ], provenance: .live)
    await publishVisibleEvent(
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
      await publishVisibleEvent(try AdapterEvent.threadUpdated(touched))
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

  /// Log-out's first step (sign-in plan, Task 10): interrupt every running turn of a local runtime
  /// (Codex, Claude, a managed B4 server) side by side, and wait until `deadline` for those runtimes to
  /// confirm. Remote and attached B4 runs are left running on their server: the log-out detaches from
  /// them, as a quit does, and never cancels them implicitly. Returns the interrupted turns whose end was
  /// not confirmed in time; they reconcile at the account's next sign-in.
  func interruptLocalTurns(until deadline: ContinuousClock.Instant) async -> [ActiveTurnSummary] {
    let entries = ((try? db.unresolvedTurns()) ?? []).compactMap { try? summary($0) }.filter {
      $0.local && ($0.status == .running || $0.status == .waitingForUser || $0.status == .stopping)
    }
    await withTaskGroup(of: Void.self) { group in
      for entry in entries {
        group.addTask { _ = try? await self.turnInterrupt(TurnInterrupt.Params(threadId: entry.threadId)) }
      }
    }
    var open = entries
    while !open.isEmpty, ContinuousClock.now < deadline {
      open = open.filter { (try? db.turn(id: $0.turnId))?.status != .terminal }
      if open.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return open
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
    // First answer wins at the runtime: checked and claimed with no suspension point in between.
    guard answering.insert(request.id).inserted else {
      throw WorkspaceError(.staleRuntimeRequest, "Runtime request \(request.id) is already being answered.")
    }
    defer { answering.remove(request.id) }
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
    await publishVisibleEvent(
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
    await publishVisibleEvent(
      AdapterEvent(
        kind: kind, connectionId: thread.connectionId, threadId: thread.id, turnId: turn.id,
        nativeIds: turn.nativeTurnId.map { ["turnId": $0, "threadId": thread.nativeThreadId] } ?? [:],
        payload: .object(body)))
  }

  /// A captured thread may predate another device's deletion. Decide visibility at publication,
  /// holding the row lease through EventLog.publish so deletion cannot commit between them.
  private func publishVisibleEvent(_ event: AdapterEvent) async {
    do {
      try await publishVisibleEnvelope(event, database: db, eventLog: context.eventLog)
    } catch {
      logger.error("event publication failed: \(String(describing: error), privacy: .public)")
      await context.diagnostics.recordError(
        scope: "event_publication", code: "internal", message: String(describing: error))
    }
  }

  private func environment(_ incoming: AdapterEvent) async {
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
        try await environmentConnectionChanged(raw)
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
        var raw = raw
        if raw.kind == .messageCompleted, let native = raw.nativeIds["itemId"],
          let text = streamed[thread.id]?.removeValue(forKey: native)
        {
          raw.payload = Self.withStreamedText(raw.payload, text)
        }
        if let item = try environmentItem(raw, thread: thread, turn: turn) {
          event.payload = merge(raw.payload, ["displayItem": try JSONValue(encoding: item)])
        } else {
          return
        }
      case .messageDelta:
        guard let thread else { return }
        if let native = raw.nativeIds["itemId"], let delta = raw.payload["delta"]?.stringValue {
          streamed[thread.id, default: [:]][native, default: ""] += delta
        }
      case .turnFinished:
        guard let thread, let turn else { break }
        try await completeStreamedItems(thread: thread)
        let outcome = raw.payload["outcome"]?.stringValue.flatMap(TurnOutcome.init(rawValue:))
        let updated = try db.updateTurn(id: turn.id) {
          if $0.nativeTurnId == nil { $0.nativeTurnId = raw.nativeIds["turnId"] }
          $0.status = .terminal
          $0.outcome = outcome
        }
        if let updated { event.payload = merge(raw.payload, ["turn": try JSONValue(encoding: updated)]) }
        if let touched = try db.updateThread(id: thread.id, { _ in }), touched.userDeletedAt == nil {
          await publishVisibleEvent(try AdapterEvent.threadUpdated(touched))
        }
        if outcome == .failed,
          let code = raw.payload["errorCode"]?.stringValue.flatMap(ErrorCode.init(rawValue:)),
          let connection = try db.connection(id: thread.connectionId)
        {
          await noteTurnFailure(
            code: code, message: raw.payload["error"]?["message"]?.stringValue ?? code.rawValue,
            connection: connection)
        }
        // Last, and never fatal: a failed count must not skip the failure handling above.
        try? recordTokens(raw, turn: turn, connectionId: thread.connectionId)
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
      case .usageChanged:
        try storeUsage(raw)
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
    // A deleted thread's rows still follow its runtime, but nothing about it reaches a client.
    if thread?.userDeletedAt != nil { return }
    await publishVisibleEvent(event)
  }

  /// A completion that carries no text keeps what the item streamed (a runtime may complete a stopped
  /// reply empty); one with text is the runtime's final word and is kept as it is.
  private static func withStreamedText(_ payload: JSONValue, _ text: String) -> JSONValue {
    guard !text.isEmpty, var item = payload["item"]?.objectValue,
      (item["text"]?.stringValue ?? "").isEmpty
    else { return payload }
    item["text"] = .string(text)
    var body = payload.objectValue ?? [:]
    body["item"] = .object(item)
    return .object(body)
  }

  /// The turn ended with messages the runtime never completed (a stopped reply): store the text each
  /// streamed and announce the item as completed, before the turn's end, so a client that clears its
  /// live text when the turn finishes still shows the reply.
  private func completeStreamedItems(thread: ConversationThread) async throws {
    guard let open = streamed.removeValue(forKey: thread.id), open.contains(where: { !$0.value.isEmpty })
    else { return }
    for item in try db.displayItems(threadId: thread.id) {
      guard let native = item.nativeItemId, let text = open[native], !text.isEmpty,
        (item.payload["text"]?.stringValue ?? "").isEmpty
      else { continue }
      guard
        let stored = try db.updateDisplayItem(
          id: item.id,
          {
            var payload = $0.payload.objectValue ?? [:]
            payload["text"] = .string(text)
            $0.payload = .object(payload)
          })
      else { continue }
      await publishVisibleEvent(
        AdapterEvent(
          kind: .messageCompleted, connectionId: thread.connectionId, threadId: thread.id,
          turnId: stored.turnId,
          nativeIds: ["threadId": thread.nativeThreadId, "itemId": native],
          payload: ["displayItem": try JSONValue(encoding: stored), "role": .string(stored.role.rawValue)]))
    }
  }

  /// Store a started or completed item. Live user messages echoed by the runtime attach their native
  /// id to the item the composer already stored instead of duplicating it. Returns nil to drop.
  private func environmentItem(
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

  private func environmentConnectionChanged(_ raw: AdapterEvent) async throws {
    let disconnected = raw.payload["transport"]?.stringValue == TransportStatus.disconnected.rawValue
    // A per-thread runtime (Claude: one process per session) reports exits with the native thread id.
    // Only that thread is affected; the connection itself stays as it was.
    if disconnected, let nativeThreadId = raw.nativeIds["threadId"] {
      guard let thread = try db.thread(connectionId: raw.connectionId, nativeThreadId: nativeThreadId) else {
        return
      }
      for request in try db.pendingRuntimeRequests(threadId: thread.id) {
        _ = try db.transitionRuntimeRequest(id: request.id, to: .expired)
        await publishVisibleEvent(
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
      await publishVisibleEvent(
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

/// The synchronous callback runs in the event-log actor turn while storage holds the row lease.
private func publishVisibleEnvelope(
  _ event: AdapterEvent, database: WorkspaceDatabase, eventLog: isolated EventLog
) throws {
  if let threadId = event.threadId {
    try database.withVisibleThread(id: threadId) { eventLog.publish(event) }
  } else {
    eventLog.publish(event)
  }
}
