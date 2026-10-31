import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// Codex adapter over `codex app-server` (spec section 7). Owns one app-server process, keeps the
/// set of threads resumed in the current process generation, and tracks pending server requests so
/// every one of them gets an explicit answer.
public actor CodexAdapter: AgentAdapter, LoginCapable {
  public nonisolated let kind = ConnectionKind.codex
  public nonisolated let connectionId: String
  /// Answer requests the app cannot present (permissions, elicitation, dynamic tools) with an explicit
  /// decline instead of leaving Codex waiting. Off only in tests that assert the raw request.
  public var autoDeclineUnsupported = true
  /// Stricter-than-configured policy for new threads. Nil in the app (D-012: the user's Codex
  /// configuration decides); the live approval test sets `on-request` + `workspace-write`.
  public var threadPolicy: CodexProtocol.ThreadPolicy?

  public func setThreadPolicy(_ policy: CodexProtocol.ThreadPolicy?) { threadPolicy = policy }

  private struct PendingRequest {
    var id: RpcId
    var method: CodexProtocol.ServerRequestMethod?
    var rawMethod: String
    var generation: Int
  }

  private let executablePath: String?
  private let environment: [String: String]
  private let clientVersion: String
  private var server: CodexAppServer?
  private var pumpTask: Task<Void, Never>?
  private let eventStream: AsyncStream<AdapterEvent>
  private let eventContinuation: AsyncStream<AdapterEvent>.Continuation
  private var loadedThreads: Set<String> = []
  private var loadedGeneration = 0
  private var pendingRequests: [String: PendingRequest] = [:]
  private var account: CodexAccount?
  private let logger = CodexLog.logger("codex.adapter")

  public init(
    connectionId: String, executablePath: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment, clientVersion: String = "0.0.0"
  ) {
    self.connectionId = connectionId
    self.executablePath = executablePath
    self.environment = environment
    self.clientVersion = clientVersion
    (eventStream, eventContinuation) = AsyncStream<AdapterEvent>.makeStream()
  }

  /// Convenience for a connection whose executable was already recorded.
  public init(connection: Connection, environment: [String: String], clientVersion: String) {
    self.init(
      connectionId: connection.id, executablePath: connection.target.isEmpty ? nil : connection.target,
      environment: environment, clientVersion: clientVersion)
  }

  // MARK: - Lifecycle

  private func ensureStarted() async throws -> CodexAppServer {
    if let server {
      try await server.ensureStarted()
      return server
    }
    guard let found = ExecutableLocator.find("codex", explicitPath: executablePath, environment: environment)
    else {
      throw WorkspaceError(.missingExecutable, "Codex CLI not found. \(CodexInspector.installGuidance)")
    }
    // `B4APP_CODEX_REQUEST_TIMEOUT` (seconds) shortens the RPC timeout; fixture tests of lost
    // acknowledgements use it so an unknown submission shows up in a second instead of thirty.
    let requestTimeout =
      environment["B4APP_CODEX_REQUEST_TIMEOUT"].flatMap(Double.init).map { Duration.seconds($0) }
      ?? .seconds(30)
    let server = CodexAppServer(
      options: CodexAppServer.Options(
        executablePath: found.path, environment: environment, clientVersion: clientVersion,
        requestTimeout: requestTimeout))
    self.server = server
    pumpTask = Task { [weak self] in
      for await inbound in server.inbound {
        guard let self else { return }
        await self.handle(inbound)
      }
      await self?.finishEvents()
    }
    try await server.ensureStarted()
    return server
  }

  private func finishEvents() { eventContinuation.finish() }

  private func handle(_ inbound: CodexAppServer.Inbound) async {
    switch inbound {
    case .message(let message, let generation):
      if loadedGeneration != generation {
        loadedGeneration = generation
        loadedThreads = []
      }
      if case .request(let id, let method, _) = message {
        let known = CodexProtocol.ServerRequestMethod(rawValue: method)
        let key = CodexEventTranslator.requestIdString(id)
        pendingRequests[key] = PendingRequest(
          id: id, method: known, rawMethod: method, generation: generation)
        for event in CodexEventTranslator.translate(
          message, connectionId: connectionId, generation: generation)
        {
          eventContinuation.yield(event)
        }
        if autoDeclineUnsupported, !(known?.answerable ?? false) {
          await autoDecline(key: key, nativeIds: ["requestId": key], generation: generation, method: method)
        }
        return
      }
      if case .notification("serverRequest/resolved", let params) = message {
        let requestId = params["requestId"]
        let key = requestId?.stringValue ?? requestId?.numberValue.map { String(Int($0)) } ?? ""
        pendingRequests[key] = nil
      }
      for event in CodexEventTranslator.translate(message, connectionId: connectionId, generation: generation)
      {
        eventContinuation.yield(event)
      }
    case .exited(let generation, let status, let stderrTail):
      loadedThreads = []
      pendingRequests = [:]
      let tail = stderrTail.split(separator: "\n").suffix(3).joined(separator: " | ")
      eventContinuation.yield(
        AdapterEvent.connectionChanged(
          connectionId: connectionId, status: .offline,
          authStatus: account == nil ? .unknown : .authenticated, transport: .disconnected,
          message: "codex app-server exited (\(status)).\(tail.isEmpty ? "" : " stderr: \(tail)")",
          adapterGeneration: generation))
    }
  }

  private func autoDecline(key: String, nativeIds: [String: String], generation: Int, method: String) async {
    guard let server, let pending = pendingRequests.removeValue(forKey: key) else { return }
    do {
      if let known = pending.method, let body = CodexProtocol.declineResponse(method: known) {
        try await server.respond(id: pending.id, result: body)
      } else {
        try await server.respondError(
          id: pending.id, code: -32601, message: "\(method) is not supported by Personal Agent Workspace.")
      }
    } catch {
      logger.warning(
        "auto-decline of \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
    eventContinuation.yield(
      AdapterEvent(
        kind: .runtimeRequestResolved, connectionId: connectionId, nativeIds: nativeIds,
        adapterGeneration: generation,
        payload: ["source": "auto_decline", "autoDeclined": true, "method": .string(method)]))
  }

  // MARK: - Account

  /// `account/read` through the app server. Nil means signed out. Only type, email, and plan are kept.
  public func accountStatus() async throws -> CodexAccount? {
    let server = try await ensureStarted()
    let result = try await server.request("account/read", CodexProtocol.accountReadParams())
    account = CodexAccount(accountReadResult: result)
    return account
  }

  /// Start the official ChatGPT sign-in. The caller opens `authUrl` in the system browser; completion
  /// arrives as a `connection.changed` event.
  public func startLogin() async throws -> LoginStart {
    let server = try await ensureStarted()
    let result = try await server.request("account/login/start", CodexProtocol.loginStartParams())
    guard let url = result["authUrl"]?.stringValue, let loginId = result["loginId"]?.stringValue else {
      throw WorkspaceError(.protocolInvalid, "account/login/start returned no authUrl.", details: result)
    }
    return LoginStart(authUrl: url, loginId: loginId)
  }

  // MARK: - AgentAdapter

  public func inspectConnection() async throws -> ConnectionInspection {
    var inspection = await CodexInspector.inspect(explicitPath: executablePath, environment: environment)
    guard inspection.status == .ready else { return inspection }
    do {
      let account = try await accountStatus()
      inspection.authStatus = account == nil ? .required : .authenticated
      inspection.nativeScope = account?.nativeScope
      inspection.message =
        account.map { "Signed in as \($0.email ?? $0.type) (\($0.planType ?? "plan unknown"))." }
        ?? "Codex is signed out. Sign in with ChatGPT to start a conversation."
      inspection.capabilities = Self.capabilities
    } catch {
      let failure = WorkspaceError.from(error)
      inspection.status = failure.code == .missingExecutable ? .error : .incompatible
      inspection.error = failure
      inspection.message = "codex app-server did not answer: \(failure.message)"
    }
    return inspection
  }

  static let capabilities: Capabilities = [
    .streaming: .supported, .nativeResume: .supported, .historyRetrieval: .supported,
    .explicitInterruption: .supported, .reconnect: .unverified, .permissionDecisions: .supported,
    .userQuestions: .supported, .modelSelection: .unverified,
  ]

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    let server = try await ensureStarted()
    let account = try await requireAccount()
    let result = try await server.request(
      "thread/start", CodexProtocol.threadStartParams(cwd: input.workingDirectory, policy: threadPolicy))
    guard let threadId = result["thread"]?["id"]?.stringValue else {
      throw WorkspaceError(.protocolInvalid, "thread/start returned no thread id.")
    }
    loadedThreads.insert(threadId)
    return NativeSessionRef(nativeSessionId: threadId, nativeScope: account.nativeScope)
  }

  private func requireAccount() async throws -> CodexAccount {
    if let account { return account }
    guard let fetched = try await accountStatus() else {
      throw WorkspaceError(.authRequired, "Codex is signed out. Sign in with ChatGPT first.")
    }
    return fetched
  }

  /// `thread/resume` once per process generation; a missing native thread is `native_session_missing`.
  private func ensureLoaded(
    _ ref: NativeSessionRef, cwd: String?, server: CodexAppServer
  ) async throws -> JSONValue? {
    if loadedThreads.contains(ref.nativeSessionId) { return nil }
    do {
      let result = try await server.request(
        "thread/resume", CodexProtocol.threadResumeParams(threadId: ref.nativeSessionId, cwd: cwd))
      loadedThreads.insert(ref.nativeSessionId)
      return result
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.details?["rpcCode"] != nil {
        throw WorkspaceError(
          .nativeSessionMissing,
          "Codex could not resume thread \(ref.nativeSessionId): \(failure.message). The cached transcript stays; start a new thread to continue.",
          details: failure.details)
      }
      throw failure
    }
  }

  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    let server = try await ensureStarted()
    loadedThreads.remove(ref.nativeSessionId)
    let resumed = try await ensureLoaded(ref, cwd: nil, server: server)
    let page = try await server.request(
      "thread/turns/list", CodexProtocol.turnsListParams(threadId: ref.nativeSessionId))
    let items = CodexEventTranslator.snapshotItems(turnsListResult: page)
    let status = resumed?["thread"]?["status"]?["type"]?.stringValue
    var activeTurn: ActiveTurnRef?
    if status == "active",
      let last = page["data"]?.arrayValue?.last, last["status"]?.stringValue == "inProgress",
      let id = last["id"]?.stringValue
    {
      activeTurn = ActiveTurnRef(nativeTurnId: id)
    }
    return SessionSnapshot(
      ref: ref, title: resumed?["thread"]?["name"]?.stringValue, items: items, activeTurn: activeTurn,
      pendingRequests: [], truncated: !(page["nextCursor"]?.isNull ?? true))
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    let server = try await ensureStarted()
    _ = try await ensureLoaded(ref, cwd: input.workingDirectory, server: server)
    let result: JSONValue
    do {
      result = try await server.request(
        "turn/start",
        CodexProtocol.turnStartParams(
          threadId: ref.nativeSessionId, text: input.text, cwd: input.workingDirectory))
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.details?["reason"]?.stringValue == "timeout" {
        throw WorkspaceError(
          .submissionUnknown, "Codex did not acknowledge the turn; it may still have started.",
          details: failure.details)
      }
      throw failure
    }
    guard let turnId = result["turn"]?["id"]?.stringValue else {
      throw WorkspaceError(.submissionUnknown, "turn/start returned no turn id.", details: result)
    }
    return SubmissionReceipt(nativeTurnId: turnId, acknowledged: true)
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    let server = try await ensureStarted()
    do {
      _ = try await server.request(
        "turn/interrupt",
        CodexProtocol.turnInterruptParams(threadId: ref.nativeSessionId, turnId: turn.nativeTurnId))
    } catch {
      throw WorkspaceError(
        .cancellationUnconfirmed, "Codex did not confirm the interrupt: \(WorkspaceError.from(error).message)"
      )
    }
    return StopReceipt(confirmed: true, outcome: nil)
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    guard let server else { throw WorkspaceError(.staleRuntimeRequest, "No Codex process is running.") }
    guard let pending = pendingRequests[ref.nativeRequestId], pending.generation == ref.adapterGeneration
    else {
      throw WorkspaceError(
        .staleRuntimeRequest,
        "Request \(ref.nativeRequestId) is no longer pending in the current Codex process.")
    }
    let body: JSONValue?
    switch (response, pending.method) {
    case (.decision(let decision), .some(let method)) where method.answerable && method != .userInput:
      body = CodexProtocol.approvalResponse(decision, legacy: method.isLegacy)
    case (.answers(let answers), .some(.userInput)):
      body = CodexProtocol.userInputResponse(answers)
    case (.decline, .some(let method)):
      body = CodexProtocol.declineResponse(method: method)
    case (.decline, .none):
      body = nil
    default:
      throw WorkspaceError(
        .protocolInvalid, "Response shape does not match request kind \(pending.rawMethod).")
    }
    if let body {
      try await server.respond(id: pending.id, result: body)
    } else {
      try await server.respondError(
        id: pending.id, code: -32601, message: "Declined by Personal Agent Workspace.")
    }
    pendingRequests[ref.nativeRequestId] = nil
  }

  public func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    let server = try await ensureStarted()
    _ = try await ensureLoaded(ref, cwd: nil, server: server)
    let read = try await server.request(
      "thread/read", CodexProtocol.threadReadParams(threadId: ref.nativeSessionId))
    if read["thread"]?["status"]?["type"]?.stringValue == "active" {
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
    let page = try await server.request(
      "thread/turns/list",
      ["threadId": .string(ref.nativeSessionId), "sortDirection": "desc", "limit": 1, "itemsView": "summary"])
    let last = page["data"]?.arrayValue?.first
    guard let turn, last?["id"]?.stringValue == turn.nativeTurnId else {
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
    switch last?["status"]?.stringValue {
    case "completed": return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(.completed))
    case "interrupted": return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(.cancelled))
    case "failed": return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(.failed))
    default: return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
  }

  public nonisolated func events() -> AsyncStream<AdapterEvent> { eventStream }

  public func dispose() async {
    await server?.close()
    server = nil
  }
}
