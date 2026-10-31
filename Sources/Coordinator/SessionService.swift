import CodexAdapter
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Owns adapters per connection, the turn lifecycle, the display projection, and runtime requests.
/// It is the only writer of turns, display items, and runtime requests (spec sections 6 and 10).
public actor SessionService {
  public typealias AdapterFactory =
    @Sendable (Connection, [String: String], String) throws -> any AgentAdapter

  public struct Context: Sendable {
    public var database: WorkspaceDatabase
    public var eventLog: EventLog
    public var diagnostics: DiagnosticsService
    public var environment: [String: String]
    public var clientVersion: String
    public var adapterFactory: AdapterFactory

    public init(
      database: WorkspaceDatabase, eventLog: EventLog, diagnostics: DiagnosticsService,
      environment: [String: String], clientVersion: String, adapterFactory: AdapterFactory? = nil
    ) {
      self.database = database
      self.eventLog = eventLog
      self.diagnostics = diagnostics
      self.environment = environment
      self.clientVersion = clientVersion
      self.adapterFactory = adapterFactory ?? SessionService.defaultAdapterFactory
    }
  }

  /// Codex is the only runtime with a conversation adapter in M1; the others throw `unsupported_capability`.
  public static let defaultAdapterFactory: AdapterFactory = { connection, environment, version in
    switch connection.kind {
    case .codex: return CodexAdapter(connection: connection, environment: environment, clientVersion: version)
    case .claude: throw WorkspaceError.unsupported("claude.conversation", plannedFor: "M2")
    case .b4: throw WorkspaceError.unsupported("b4.conversation", plannedFor: "M3")
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
    let adapter = try context.adapterFactory(connection, context.environment, context.clientVersion)
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
    guard params.kind == .codex else {
      throw WorkspaceError.unsupported(
        "\(params.kind.rawValue).connection", plannedFor: params.kind == .claude ? "M2" : "M3")
    }
    let located = ExecutableLocator.find(
      "codex", explicitPath: params.executablePath, environment: context.environment)
    let target = params.executablePath ?? located?.path ?? ""
    if let existing = try db.connections(kind: .codex).first(where: { $0.target == target }) {
      return try await connectionInspect(ConnectionInspect.Params(connectionId: existing.id))
    }
    let connection = try db.insertConnection(
      Connection(
        id: UUID().uuidString.lowercased(), kind: .codex, label: params.label ?? "Codex", target: target,
        status: .connecting))
    return try await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
  }

  public func connectionInspect(_ params: ConnectionInspect.Params) async throws -> ConnectionAdd.Result {
    let (connection, adapter) = try connectionAndAdapter(id: params.connectionId)
    let inspection = try await adapter.inspectConnection()
    let updated =
      try db.updateConnection(id: connection.id) {
        $0.status = inspection.status
        $0.authStatus = inspection.authStatus
        $0.capabilities = inspection.capabilities
        if let path = inspection.executablePath, $0.target.isEmpty { $0.target = path }
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
    var isDirectory: ObjCBool = false
    let directory = (params.workingDirectory as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw WorkspaceError(
        .protocolInvalid, "Working directory \(params.workingDirectory) does not exist.",
        details: ["workingDirectory": .string(params.workingDirectory)])
    }
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: directory))
    let title = params.title?.trimmingCharacters(in: .whitespaces)
    let thread = try db.insertThread(
      ConversationThread(
        id: UUID().uuidString.lowercased(), connectionId: connection.id, nativeThreadId: ref.nativeSessionId,
        nativeScope: ref.nativeScope,
        title: (title?.isEmpty == false ? title : nil) ?? (directory as NSString).lastPathComponent,
        context: directory))
    await context.eventLog.publish(
      AdapterEvent(
        kind: .sessionCreated, connectionId: connection.id, threadId: thread.id,
        nativeIds: ["threadId": ref.nativeSessionId], payload: ["scope": .string(ref.nativeScope)]))
    await context.eventLog.publish(try AdapterEvent.threadUpdated(thread))
    return ThreadCreate.Result(thread: thread)
  }

  public func threadRead(_ params: ThreadRead.Params) async throws -> ThreadRead.Result {
    guard let thread = try db.thread(id: params.threadId) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    if let reconciling = try db.activeTurn(threadId: thread.id), reconciling.status == .reconciling {
      await reconcile(reconciling, thread: thread)
    }
    return ThreadRead.Result(
      thread: thread, turns: try db.turns(threadId: thread.id),
      items: try db.displayItems(threadId: thread.id),
      requests: try db.pendingRuntimeRequests(threadId: thread.id))
  }

  /// Ask the runtime what became of a turn whose outcome is unknown. Never assumes success.
  private func reconcile(_ turn: Turn, thread: ConversationThread) async {
    guard let (_, _, adapter) = try? threadContext(id: thread.id) else { return }
    let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
    guard let result = try? await adapter.reconcile(ref, turn: turn.nativeTurnId.map(ActiveTurnRef.init)),
      case .known(let outcome)? = result.activeTurnOutcome
    else { return }
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
    try? db.deleteDraft(threadId: thread.id)
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
      let failure = WorkspaceError.from(error)
      let unknown = failure.code == .submissionUnknown
      turn =
        try db.updateTurn(id: turn.id) {
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
      throw WorkspaceError(
        failure.code, failure.message,
        details: ["turnId": .string(turn.id), "cause": failure.details ?? .null])
    }
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

  private func project(_ raw: AdapterEvent) async {
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
        if let turn, turn.status == .running {
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
          scope: "codex", code: raw.payload["errorCode"]?.stringValue ?? "internal",
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
    let status = raw.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:))
    let auth = raw.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:))
    _ = try db.updateConnection(id: raw.connectionId) {
      if let status { $0.status = status }
      if let auth { $0.authStatus = auth }
    }
    guard raw.payload["transport"]?.stringValue == TransportStatus.disconnected.rawValue else { return }
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
