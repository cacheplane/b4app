import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import os

/// B4 Agent Protocol adapter for an attached local server or a remote HTTPS endpoint (spec section
/// 9). One actor per connection; one streaming task per thread with an active turn. No child
/// process: the owner runs the server, so `dispose` only drops streams and never cancels a run.
public actor B4Adapter: AgentAdapter {
  public nonisolated let kind = ConnectionKind.b4
  public nonisolated let connectionId: String
  public nonisolated let baseURL: String
  public nonisolated let routeKey: String

  private struct Run {
    var translator: B4TurnTranslator
    var task: Task<Void, Never>?
    var cancel: (@Sendable () -> Void)?
    var consuming: Bool { task != nil }
  }

  private struct PendingInterrupt {
    var threadId: String
    var grant: String?
    var allowAlways: Bool
    var generation: Int
  }

  /// What the server says about a turn whose stream this coordinator is not consuming.
  private enum Resolution {
    case running(B4HTTPClient.StreamHandle)
    case parked([(id: String, value: JSONValue, grant: String?)])
    case outcome(TurnOutcome, reason: String)
    case notRecorded
    case unknown
  }

  private let client: B4HTTPClient?
  private let clientError: WorkspaceError?
  private let route: B4RouteKey?
  private let authConfigured: Bool
  private let clientVersion: String
  private var runs: [String: Run] = [:]
  private var pending: [String: PendingInterrupt] = [:]
  private var generation = 1
  private let eventStream: AsyncStream<AdapterEvent>
  private let eventContinuation: AsyncStream<AdapterEvent>.Continuation
  private let logger = Logger(subsystem: "com.cacheplane.b4app", category: "b4.adapter")

  public init(
    connectionId: String, baseURL: String, routeKey: String,
    authorization: @escaping B4HTTPClient.AuthorizationProvider = { nil }, authConfigured: Bool = false,
    session: URLSession? = nil, clientVersion: String = "0.0.0"
  ) {
    self.connectionId = connectionId
    self.baseURL = baseURL
    self.routeKey = routeKey
    self.route = B4RouteKey(routeKey)
    self.authConfigured = authConfigured
    self.clientVersion = clientVersion
    do {
      client = try B4HTTPClient(baseURL: baseURL, authorizationProvider: authorization, session: session)
      clientError = nil
    } catch {
      client = nil
      clientError = WorkspaceError.from(error)
    }
    (eventStream, eventContinuation) = AsyncStream<AdapterEvent>.makeStream()
  }

  /// The coordinator's constructor: the secret is read from the credential store on first use and
  /// becomes a bearer header (D-022).
  public init(connection: Connection, secretStore: any SecretStore, clientVersion: String) {
    let reference = connection.authReference
    self.init(
      connectionId: connection.id, baseURL: connection.target, routeKey: connection.routeKey ?? "",
      authorization: {
        guard let reference else { return nil }
        guard let ref = SecretRef(rawValue: reference) else {
          throw WorkspaceError(
            .authRequired, "The connection's credential reference \(reference) is not valid.",
            details: ["reference": .string(reference)])
        }
        guard let value = try await secretStore.read(ref) else {
          throw WorkspaceError(
            .authRequired,
            "Credential \(reference) is not in the credential store. Run `agent-workspace credential add` and update the connection.",
            details: ["reference": .string(reference)])
        }
        return B4HTTPClient.authorizationHeader(secret: value)
      }, authConfigured: reference != nil, clientVersion: clientVersion)
  }

  static let capabilities: Capabilities = [
    .streaming: .supported, .nativeResume: .supported, .historyRetrieval: .supported,
    .explicitInterruption: .supported, .reconnect: .supported, .permissionDecisions: .supported,
    .userQuestions: .unsupported, .modelSelection: .unsupported,
  ]

  // MARK: - Guards

  private func requireClient() throws -> B4HTTPClient {
    guard let client else {
      throw clientError ?? WorkspaceError(.protocolInvalid, "Invalid B4 base URL: \(baseURL)")
    }
    return client
  }

  private func requireAgentRoute() throws -> B4RouteKey {
    guard let route else {
      throw WorkspaceError(
        .protocolInvalid, "\"\(routeKey)\" is not a B4 route key. Expected /<path>#agent.",
        details: ["route": .string(routeKey)])
    }
    guard route.isAgent else {
      throw WorkspaceError(
        .unsupportedCapability,
        "Route \(route.key) is a \(route.kind) route. Conversations support standard agent routes only (D-023).",
        details: ["route": .string(route.key), "kind": .string(route.kind)])
    }
    return route
  }

  // MARK: - AgentAdapter

  public func inspectConnection() async throws -> ConnectionInspection {
    guard let client else {
      let failure = clientError ?? WorkspaceError(.protocolInvalid, "Invalid B4 base URL.")
      return ConnectionInspection(
        status: .error, authStatus: .unknown, message: failure.message, error: failure)
    }
    var inspection = await B4Inspector.inspect(client: client, authConfigured: authConfigured)
    inspection.version = nil
    do {
      _ = try requireAgentRoute()
    } catch {
      let failure = WorkspaceError.from(error)
      if inspection.status == .ready || failure.code == .protocolInvalid {
        inspection.status = failure.code == .protocolInvalid ? .error : .incompatible
        inspection.error = failure
        inspection.message = failure.message
      }
      return inspection
    }
    if inspection.status == .ready { inspection.capabilities = Self.capabilities }
    return inspection
  }

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    let client = try requireClient()
    let route = try requireAgentRoute()
    let (status, body) = try await client.json(
      "POST", "/threads", body: B4Protocol.threadCreateBody(route: route.key, clientVersion: clientVersion))
    guard status == 200 else {
      throw report(B4Protocol.error(status: status, body: body, operation: "thread creation"))
    }
    guard let id = body?["thread_id"]?.stringValue else {
      throw WorkspaceError(
        .incompatibleVersion, "POST /threads did not return a thread_id; this is not a compatible B4 server.")
    }
    return NativeSessionRef(nativeSessionId: id, nativeScope: client.origin)
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    let client = try requireClient()
    let route = try requireAgentRoute()
    let threadId = ref.nativeSessionId
    if let run = runs[threadId], run.translator.isActive {
      throw WorkspaceError(
        .protocolInvalid, "A turn is still active on this thread.", details: ["reason": "turn_active"])
    }
    let ordinal = await turnCount(threadId: threadId)
    let turnId = ordinal.map { "turn-\($0 + 1)" } ?? "run-\(UUID().uuidString.lowercased())"
    let handle: B4HTTPClient.StreamHandle
    do {
      handle = try await client.stream(
        "POST", "/threads/\(threadId)/runs/stream",
        body: B4Protocol.runBody(route: route.key, text: input.text))
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.details?["timeout"]?.boolValue == true {
        throw WorkspaceError(
          .submissionUnknown,
          "The B4 server did not answer the run request in time; it may still have started. Reopen the thread to reconcile.",
          details: failure.details)
      }
      throw failure
    }
    guard handle.status == 200 else {
      let body = await handle.collectJSON()
      throw report(B4Protocol.error(status: handle.status, body: body, operation: "turn start"))
    }
    guard handle.isEventStream else {
      handle.cancel()
      throw WorkspaceError(
        .incompatibleVersion,
        "runs/stream did not answer with an event stream (\(handle.contentType ?? "no content type")).")
    }
    let translator = B4TurnTranslator(
      connectionId: connectionId, threadId: threadId, turnId: turnId, generation: generation)
    start(threadId: threadId, translator: translator, handle: handle)
    return SubmissionReceipt(nativeTurnId: turnId, acknowledged: true)
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    let client = try requireClient()
    let threadId = ref.nativeSessionId
    if let run = runs[threadId], run.translator.phase == .parked {
      // Stop on a parked turn: the only way to end it is to answer its prompt, so decline it. The
      // route then finishes on its own and the stream reports the real outcome.
      guard let (interruptId, prompt) = pending.first(where: { $0.value.threadId == threadId }) else {
        throw WorkspaceError(
          .cancellationUnconfirmed, "The turn is parked but its prompt is no longer known.")
      }
      try await resume(
        threadId: threadId, interruptId: interruptId, decision: .cancelled, grant: prompt.grant)
      return StopReceipt(confirmed: true, outcome: nil)
    }
    let status: Int
    let body: JSONValue?
    do {
      (status, body) = try await client.json("POST", "/threads/\(threadId)/cancel")
    } catch {
      throw WorkspaceError(
        .cancellationUnconfirmed,
        "Could not reach the B4 server to cancel: \(WorkspaceError.from(error).message)")
    }
    switch (status, B4Protocol.errorCode(body)) {
    case (200, _):
      return StopReceipt(confirmed: true, outcome: nil)
    case (409, "no_run_in_flight"):
      // Nothing is running: the stream already decided, or no stream is being consumed here.
      if runs[threadId]?.consuming == true { return StopReceipt(confirmed: true, outcome: nil) }
      switch try await resolve(threadId: threadId, turnId: turn.nativeTurnId) {
      case .outcome(let outcome, _):
        runs[threadId] = nil
        return StopReceipt(confirmed: true, outcome: outcome)
      case .notRecorded:
        runs[threadId] = nil
        return StopReceipt(confirmed: true, outcome: .failed)
      case .running(let handle):
        handle.cancel()
        return StopReceipt(confirmed: false, outcome: nil)
      case .parked, .unknown:
        return StopReceipt(confirmed: true, outcome: nil)
      }
    default:
      let failure = B4Protocol.error(status: status, body: body, operation: "cancel")
      if failure.code == .nativeSessionMissing { throw failure }
      throw WorkspaceError(.cancellationUnconfirmed, failure.message, details: failure.details)
    }
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    guard let prompt = pending[ref.nativeRequestId], prompt.generation == ref.adapterGeneration else {
      throw WorkspaceError(
        .staleRuntimeRequest, "Request \(ref.nativeRequestId) is no longer pending on the B4 server.")
    }
    let decision: B4Protocol.ResumeDecision
    switch response {
    case .decision(let choice): decision = B4Protocol.resumeDecision(choice, allowAlways: prompt.allowAlways)
    case .decline: decision = .cancelled
    case .answers:
      throw WorkspaceError(.protocolInvalid, "A B4 permission prompt takes a decision, not answers.")
    }
    try await resume(
      threadId: prompt.threadId, interruptId: ref.nativeRequestId, decision: decision, grant: prompt.grant)
  }

  public func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    let threadId = ref.nativeSessionId
    if let run = runs[threadId], run.consuming {
      // The stream may already have delivered its terminal frame while the pump's bookkeeping is
      // still behind; the translator knows the outcome, so report it instead of "unknown".
      if case .finished(let outcome) = run.translator.phase,
        turn?.nativeTurnId ?? run.translator.turnId == run.translator.turnId
      {
        return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(outcome))
      }
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
    guard let turn else { return ReconcileResult(snapshot: nil, activeTurnOutcome: nil) }
    switch try await resolve(threadId: threadId, turnId: turn.nativeTurnId) {
    case .running(let handle):
      generation += 1
      var translator =
        runs[threadId]?.translator
        ?? B4TurnTranslator(
          connectionId: connectionId, threadId: threadId, turnId: turn.nativeTurnId, generation: generation)
      translator.generation = generation
      translator.reattaching = true
      start(threadId: threadId, translator: translator, handle: handle)
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    case .parked(let prompts):
      reopen(prompts, threadId: threadId, turnId: turn.nativeTurnId)
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .parked)
    case .outcome(let outcome, _):
      runs[threadId] = nil
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(outcome))
    case .notRecorded:
      reportNotRecorded(threadId: threadId, turnId: turn.nativeTurnId)
      runs[threadId] = nil
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .known(.failed))
    case .unknown:
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
  }

  /// Returns once every stream being consumed has ended and been handled. A test seam: `turn.finished`
  /// is emitted from inside the stream, a moment before its end clears the run. Waits for nothing else.
  func streamsSettled() async {
    var awaited: Set<Task<Void, Never>> = []
    while let task = runs.values.compactMap(\.task).first(where: { !awaited.contains($0) }) {
      awaited.insert(task)
      await task.value
    }
  }

  /// History from the latest checkpoint (`GET /threads/:id/state`), best effort and read-only.
  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    let client = try requireClient()
    let threadId = ref.nativeSessionId
    let (status, thread) = try await client.json("GET", "/threads/\(threadId)")
    guard status == 200 else {
      throw B4Protocol.error(status: status, body: thread, operation: "thread read")
    }
    var items: [SnapshotItem] = []
    let (stateStatus, state) = try await client.json("GET", "/threads/\(threadId)/state")
    if stateStatus == 200, let values = state?["values"] {
      items = B4Protocol.snapshotItems(stateValues: values)
    } else if stateStatus != 404 {
      throw B4Protocol.error(status: stateStatus, body: state, operation: "state read")
    }
    var pendingRefs: [RuntimeRequestRef] = []
    if thread?["status"]?.stringValue == "interrupted" {
      for prompt in try await pendingInterrupts(threadId: threadId) {
        pendingRefs.append(
          RuntimeRequestRef(
            nativeRequestId: prompt.id, kind: B4Protocol.requestKind(prompt.value["kind"]?.stringValue),
            adapterGeneration: generation))
      }
    }
    return SessionSnapshot(
      ref: ref, title: nil, items: items, activeTurn: nil, pendingRequests: pendingRefs, truncated: false)
  }

  public nonisolated func events() -> AsyncStream<AdapterEvent> { eventStream }

  /// Drops local streams only. Runs keep going on the server (spec section 6: never an implicit cancel).
  public func dispose() async {
    for (id, run) in runs {
      run.task?.cancel()
      run.cancel?()
      runs[id] = nil
    }
  }

  // MARK: - Streams

  private func start(threadId: String, translator: B4TurnTranslator, handle: B4HTTPClient.StreamHandle) {
    runs[threadId] = Run(translator: translator, task: nil, cancel: handle.cancel)
    runs[threadId]?.task = Task { [weak self] in
      await self?.consume(threadId: threadId, handle: handle)
    }
  }

  private func consume(threadId: String, handle: B4HTTPClient.StreamHandle) async {
    var parser = SSEParser()
    var clean = false
    do {
      for try await chunk in handle.bytes {
        for sse in parser.push(chunk) { apply(B4StreamEvent(sse), threadId: threadId) }
        if Task.isCancelled { return }
      }
      if let rest = parser.flush() { apply(B4StreamEvent(rest), threadId: threadId) }
      clean = true
    } catch {
      logger.info(
        "stream for \(threadId, privacy: .public) ended: \(String(describing: error), privacy: .public)")
    }
    if Task.isCancelled { return }
    await streamEnded(threadId: threadId, clean: clean)
  }

  private func apply(_ incoming: B4StreamEvent, threadId: String) {
    guard var run = runs[threadId] else { return }
    let events = run.translator.translate(incoming)
    runs[threadId] = run
    for event in events {
      if event.kind == .runtimeRequestOpened, let id = event.nativeIds["requestId"] {
        pending[id] = PendingInterrupt(
          threadId: threadId, grant: event.payload["request"]?["grant"]?.stringValue,
          allowAlways: event.payload["request"]?["allowAlways"]?.boolValue ?? true,
          generation: event.adapterGeneration)
      }
      eventContinuation.yield(event)
    }
  }

  private func streamEnded(threadId: String, clean: Bool) async {
    guard var run = runs[threadId] else { return }
    run.task = nil
    run.cancel = nil
    runs[threadId] = run
    switch run.translator.phase {
    case .finished:
      runs[threadId] = nil
    case .parked:
      break
    case .ended:
      await settle(threadId: threadId, turnId: run.translator.turnId)
    case .streaming:
      await reattach(threadId: threadId)
    }
  }

  /// The response ended without a terminal event while the turn is open. Reattach a bounded number
  /// of times; the prompt is never resent (spec M3 exit gate).
  private func reattach(threadId: String) async {
    guard let client else { return }
    for attempt in 1...3 {
      try? await Task.sleep(for: .milliseconds(250 * attempt))
      guard runs[threadId] != nil else { return }
      do {
        let handle = try await client.stream("GET", "/threads/\(threadId)/runs/stream")
        if handle.status == 200, handle.isEventStream {
          runs[threadId]?.translator.reattaching = true
          runs[threadId]?.cancel = handle.cancel
          runs[threadId]?.task = Task { [weak self] in await self?.consume(threadId: threadId, handle: handle)
          }
          return
        }
        let body = await handle.collectJSON()
        logger.warning(
          "reattach to \(threadId, privacy: .public) answered \(handle.status, privacy: .public): \(B4Protocol.errorMessage(body) ?? "", privacy: .public)"
        )
        if handle.status == 404 || handle.status == 409 { break }
      } catch {
        logger.info(
          "reattach attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)"
        )
      }
    }
    if let run = runs[threadId] {
      eventContinuation.yield(run.translator.transportLost())
      runs[threadId] = nil
    }
  }

  /// A reattach found nothing live, so ask the server what became of the turn and emit the answer.
  private func settle(threadId: String, turnId: String) async {
    do {
      switch try await resolve(threadId: threadId, turnId: turnId) {
      case .running(let handle):
        runs[threadId]?.translator.reattaching = true
        runs[threadId]?.cancel = handle.cancel
        runs[threadId]?.task = Task { [weak self] in await self?.consume(threadId: threadId, handle: handle) }
      case .parked(let prompts):
        reopen(prompts, threadId: threadId, turnId: turnId)
      case .outcome(let outcome, let reason):
        finish(threadId: threadId, outcome: outcome, source: reason)
      case .notRecorded:
        reportNotRecorded(threadId: threadId, turnId: turnId)
        finish(threadId: threadId, outcome: .failed, source: "not_recorded")
      case .unknown:
        if let run = runs[threadId] {
          eventContinuation.yield(run.translator.transportLost())
          runs[threadId] = nil
        }
      }
    } catch {
      if let run = runs[threadId] {
        eventContinuation.yield(run.translator.transportLost())
        runs[threadId] = nil
      }
    }
  }

  private func finish(threadId: String, outcome: TurnOutcome, source: String) {
    guard var run = runs[threadId] else { return }
    for event in run.translator.finish(outcome, source: source) { eventContinuation.yield(event) }
    runs[threadId] = nil
  }

  private func reopen(
    _ prompts: [(id: String, value: JSONValue, grant: String?)], threadId: String, turnId: String
  ) {
    generation += 1
    var translator =
      runs[threadId]?.translator
      ?? B4TurnTranslator(
        connectionId: connectionId, threadId: threadId, turnId: turnId, generation: generation)
    translator.generation = generation
    translator.reattaching = false
    for prompt in prompts {
      let events = translator.reopen(interruptId: prompt.id, value: prompt.value, grant: prompt.grant)
      pending[prompt.id] = PendingInterrupt(
        threadId: threadId, grant: prompt.grant, allowAlways: prompt.value["allowAlways"]?.boolValue ?? true,
        generation: generation)
      for event in events { eventContinuation.yield(event) }
    }
    runs[threadId] = Run(translator: translator, task: nil, cancel: nil)
  }

  private func reportNotRecorded(threadId: String, turnId: String) {
    eventContinuation.yield(
      AdapterEvent(
        kind: .adapterError, connectionId: connectionId, nativeIds: ["threadId": threadId, "turnId": turnId],
        adapterGeneration: generation,
        payload: [
          "errorCode": .string(ErrorCode.submissionUnknown.rawValue),
          "message":
            "The B4 server has no record of this turn, so it was marked failed and was not resubmitted. Send it again if you still want it.",
        ]))
  }

  @discardableResult
  private func report(_ failure: WorkspaceError) -> WorkspaceError {
    switch failure.code {
    case .authRequired:
      eventContinuation.yield(
        AdapterEvent.connectionChanged(
          connectionId: connectionId, status: .ready, authStatus: .error, transport: .connected,
          message: failure.message, adapterGeneration: generation))
    case .incompatibleVersion:
      eventContinuation.yield(
        AdapterEvent.connectionChanged(
          connectionId: connectionId, status: .incompatible,
          authStatus: authConfigured ? .unknown : .notRequired,
          transport: .connected, message: failure.message, adapterGeneration: generation))
    default:
      break
    }
    return failure
  }

  private func resume(
    threadId: String, interruptId: String, decision: B4Protocol.ResumeDecision, grant: String?
  ) async throws {
    let client = try requireClient()
    let route = try requireAgentRoute()
    let handle = try await client.stream(
      "POST", "/threads/\(threadId)/resume",
      body: B4Protocol.resumeBody(
        route: route.key, interruptId: interruptId, decision: decision, grant: grant))
    guard handle.status == 200 else {
      let body = await handle.collectJSON()
      let failure = B4Protocol.error(status: handle.status, body: body, operation: "resume")
      if failure.code == .staleRuntimeRequest { pending[interruptId] = nil }
      throw report(failure)
    }
    pending[interruptId] = nil
    var translator =
      runs[threadId]?.translator
      ?? B4TurnTranslator(
        connectionId: connectionId, threadId: threadId, turnId: "resume", generation: generation)
    translator.beginResume()
    start(threadId: threadId, translator: translator, handle: handle)
  }

  // MARK: - Server reads

  private func turnCount(threadId: String) async -> Int? {
    guard let client, let (status, body) = try? await client.json("GET", "/threads/\(threadId)/turns"),
      status == 200, let turns = B4Protocol.turnList(body)
    else { return nil }
    return turns.count
  }

  private func pendingInterrupts(
    threadId: String
  ) async throws -> [(id: String, value: JSONValue, grant: String?)] {
    let client = try requireClient()
    let (status, body) = try await client.json("GET", "/threads/\(threadId)/pending_interrupts")
    guard status == 200 else {
      throw B4Protocol.error(status: status, body: body, operation: "pending interrupts")
    }
    return (body?["interrupts"]?.arrayValue ?? []).compactMap { entry in
      guard let id = entry["interruptId"]?.stringValue else { return nil }
      return (id, entry["value"] ?? .null, entry["grant"]?.stringValue)
    }
  }

  private static func ordinal(of turnId: String) -> Int? {
    turnId.hasPrefix("turn-") ? Int(turnId.dropFirst(5)) : nil
  }

  /// Ask the server what became of a turn: status row, pending prompts, and the turn list (D-019).
  private func resolve(threadId: String, turnId: String) async throws -> Resolution {
    let client = try requireClient()
    let (status, thread) = try await client.json("GET", "/threads/\(threadId)")
    guard status == 200 else {
      throw B4Protocol.error(status: status, body: thread, operation: "thread read")
    }
    let threadStatus = thread?["status"]?.stringValue ?? "idle"
    if threadStatus == "busy" {
      let handle = try await client.stream("GET", "/threads/\(threadId)/runs/stream")
      if handle.status == 200, handle.isEventStream {
        // The first frame says whether a run is live; the server sends it immediately.
        var parser = SSEParser()
        var live: Bool?
        var consumed: [[UInt8]] = []
        var iterator = handle.bytes.makeAsyncIterator()
        while live == nil, let chunk = try await iterator.next() {
          consumed.append(chunk)
          for sse in parser.push(chunk) where live == nil {
            if case .state(_, let isLive, _) = B4StreamEvent(sse) { live = isLive }
          }
        }
        if live == true {
          // Hand the consumer the whole stream, including the bytes read while probing; the
          // translator ignores a live `state` frame.
          let (rest, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
          for chunk in consumed { continuation.yield(chunk) }
          Task {
            do {
              while let chunk = try await iterator.next() { continuation.yield(chunk) }
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
          return .running(
            B4HTTPClient.StreamHandle(
              status: 200, contentType: handle.contentType, bytes: rest, cancel: handle.cancel))
        }
        handle.cancel()
      } else {
        _ = await handle.collectJSON()
      }
    }
    if threadStatus == "interrupted" {
      let prompts = try await pendingInterrupts(threadId: threadId)
      if !prompts.isEmpty { return .parked(prompts) }
    }
    let (turnsStatus, body) = try await client.json("GET", "/threads/\(threadId)/turns")
    guard turnsStatus == 200, let turns = B4Protocol.turnList(body) else {
      if threadStatus == "interrupted" { return .outcome(.cancelled, reason: "cancelled") }
      return .unknown
    }
    guard let ordinal = Self.ordinal(of: turnId) else {
      if threadStatus == "interrupted" { return .outcome(.cancelled, reason: "cancelled") }
      if threadStatus == "busy" { return .outcome(.failed, reason: "run_lost") }
      return .unknown
    }
    guard turns.indices.contains(ordinal - 1) else { return .notRecorded }
    let recorded = turns[ordinal - 1]["status"]?.stringValue
    if let outcome = B4Protocol.turnOutcome(turnStatus: recorded) {
      return .outcome(outcome, reason: "reconcile")
    }
    switch threadStatus {
    case "interrupted": return .outcome(.cancelled, reason: "cancelled")
    case "busy": return .outcome(.failed, reason: "run_lost")
    default: return .unknown
    }
  }
}
