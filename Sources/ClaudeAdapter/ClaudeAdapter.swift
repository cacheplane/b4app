import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import os

/// Claude Code adapter over the CLI's stream-json protocol (spec section 8, decision D-002). One
/// `claude` process per native session (D-015); every control request gets exactly one answer.
public actor ClaudeAdapter: AgentAdapter, LoginCapable {
  public nonisolated let kind = ConnectionKind.claude
  public nonisolated let connectionId: String
  public var autoDeclineUnsupported = true

  private struct PendingRequest {
    var sessionId: String
    var subtype: String
    var toolName: String?
    var toolUseId: String
    var input: JSONValue
    var generation: Int
  }

  private enum Ack: Sendable { case acknowledged, exited(String), timedOut }

  private let executablePath: String?
  private let environment: [String: String]
  private let clientVersion: String
  private var sessions: [String: ClaudeSession] = [:]
  private var trackers: [String: ClaudeTurnTracker] = [:]
  private var pumps: [String: Task<Void, Never>] = [:]
  private var pendingRequests: [String: PendingRequest] = [:]
  private var ackWaiters: [String: CheckedContinuation<Ack, Never>] = [:]
  private var generation = 0
  private var scope: String?
  private var projectsDirectory: String?
  private let eventStream: AsyncStream<AdapterEvent>
  private let eventContinuation: AsyncStream<AdapterEvent>.Continuation
  private let logger = Logger(subsystem: "com.cacheplane.b4app", category: "claude.adapter")

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

  public init(connection: Connection, environment: [String: String], clientVersion: String) {
    self.init(
      connectionId: connection.id, executablePath: connection.target.isEmpty ? nil : connection.target,
      environment: environment, clientVersion: clientVersion)
  }

  // MARK: - Executable and account

  private func locate() throws -> String {
    guard let found = ExecutableLocator.find("claude", explicitPath: executablePath, environment: environment)
    else {
      throw WorkspaceError(.missingExecutable, "Claude Code not found. \(ClaudeInspector.installGuidance)")
    }
    return found.path
  }

  /// Read `claude auth status --json` through the session executable and environment. Throws when
  /// the Mac is signed out or an inherited API key would switch billing mode.
  @discardableResult
  private func ensureAccount() async throws -> String {
    if let scope { return scope }
    let path = try locate()
    let read = await ClaudeAuth.readStatus(executable: path, environment: environment)
    guard let status = read.status else {
      throw WorkspaceError(
        .incompatibleVersion, "`claude auth status --json` did not return the expected shape.")
    }
    let assessment = ClaudeAuth.assess(status, environment: environment)
    if let error = assessment.error {
      throw WorkspaceError(error.code, assessment.message, details: error.details)
    }
    projectsDirectory = status.projectsDirectory
    scope = assessment.nativeScope ?? status.email ?? "claude"
    return scope!
  }

  public func inspectConnection() async throws -> ConnectionInspection {
    var inspection = await ClaudeInspector.inspect(explicitPath: executablePath, environment: environment)
    if inspection.status == .ready, inspection.authStatus == .authenticated {
      scope = inspection.nativeScope
      inspection.capabilities = Self.capabilities
    } else {
      scope = nil
    }
    return inspection
  }

  static let capabilities: Capabilities = [
    .streaming: .supported, .nativeResume: .supported, .historyRetrieval: .supported,
    .explicitInterruption: .supported, .reconnect: .unverified, .permissionDecisions: .supported,
    .userQuestions: .supported, .modelSelection: .unverified,
  ]

  // MARK: - Sessions

  private func startSession(id: String, workingDirectory: String, resume: Bool) async throws -> ClaudeSession
  {
    let path = try locate()
    generation += 1
    let session = ClaudeSession(
      options: ClaudeSession.Options(
        executablePath: path, environment: environment, workingDirectory: workingDirectory, sessionId: id,
        resume: resume, clientVersion: clientVersion))
    do {
      try await session.start()
    } catch {
      let failure = WorkspaceError.from(error)
      let stderr = failure.details?["stderr"]?.stringValue ?? ""
      if resume, stderr.contains("No conversation found") {
        throw WorkspaceError(
          .nativeSessionMissing,
          "Claude Code has no transcript for session \(id). The cached transcript stays; start a new thread to continue.",
          details: failure.details)
      }
      throw failure
    }
    sessions[id] = session
    trackers[id] = ClaudeTurnTracker(connectionId: connectionId, sessionId: id, generation: generation)
    pumps[id] = Task { [weak self] in
      for await inbound in session.inbound {
        guard let self else { return }
        await self.handle(inbound, sessionId: id)
      }
    }
    return session
  }

  private func handle(_ inbound: ClaudeSession.Inbound, sessionId id: String) async {
    guard var tracker = trackers[id] else { return }
    switch inbound {
    case .frame(let frame):
      let events = tracker.translate(frame)
      trackers[id] = tracker
      switch frame {
      case .systemInit, .assistant, .streamEvent, .result:
        ackWaiters.removeValue(forKey: id)?.resume(returning: .acknowledged)
      default:
        break
      }
      for event in events { eventContinuation.yield(event) }
      if case .controlRequest(let request) = frame {
        let (_, answerable) = ClaudeTurnTracker.requestKind(
          subtype: request.subtype, toolName: request.toolName)
        pendingRequests[request.requestId] = PendingRequest(
          sessionId: id, subtype: request.subtype, toolName: request.toolName,
          toolUseId: request.toolUseId ?? "", input: request.input, generation: tracker.generation)
        if autoDeclineUnsupported, !answerable {
          await autoDecline(requestId: request.requestId, sessionId: id, generation: tracker.generation)
        }
      }
      if case .controlCancel(let requestId) = frame { pendingRequests[requestId] = nil }
    case .exited(let status, let tail):
      let events = tracker.processExited(status: String(describing: status))
      for event in events { eventContinuation.yield(event) }
      ackWaiters.removeValue(forKey: id)?.resume(returning: .exited(tail))
      pendingRequests = pendingRequests.filter { $0.value.sessionId != id }
      sessions[id] = nil
      trackers[id] = nil
      pumps[id] = nil
    }
  }

  private func autoDecline(requestId: String, sessionId: String, generation: Int) async {
    guard let pending = pendingRequests.removeValue(forKey: requestId), let session = sessions[sessionId]
    else {
      return
    }
    do {
      if pending.subtype == "elicitation" {
        try await session.send(try ClaudeStream.elicitationDecline(requestId: requestId))
      } else {
        try await session.send(
          try ClaudeStream.controlErrorResponse(
            requestId: requestId, message: "\(pending.subtype) is not supported by Personal Agent Workspace.")
        )
      }
    } catch {
      logger.warning(
        "auto-decline of \(pending.subtype, privacy: .public) failed: \(String(describing: error), privacy: .public)"
      )
    }
    eventContinuation.yield(
      AdapterEvent(
        kind: .runtimeRequestResolved, connectionId: connectionId,
        nativeIds: ["threadId": sessionId, "requestId": requestId], adapterGeneration: generation,
        payload: ["source": "auto_decline", "autoDeclined": true, "method": .string(pending.subtype)]))
  }

  // MARK: - AgentAdapter

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    let scope = try await ensureAccount()
    let directory = input.workingDirectory ?? NSHomeDirectory()
    let id = UUID().uuidString.lowercased()
    _ = try await startSession(id: id, workingDirectory: directory, resume: false)
    return NativeSessionRef(nativeSessionId: id, nativeScope: scope)
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    let id = ref.nativeSessionId
    let session: ClaudeSession
    if let live = sessions[id], await live.isRunning {
      session = live
    } else {
      session = try await startSession(
        id: id, workingDirectory: input.workingDirectory ?? NSHomeDirectory(), resume: true)
    }
    let turnUuid = UUID().uuidString.lowercased()
    trackers[id]?.beginTurn(uuid: turnUuid)
    try await session.send(try ClaudeStream.userMessage(text: input.text, uuid: turnUuid))
    let ack: Ack = await withCheckedContinuation { continuation in
      ackWaiters[id] = continuation
      Task {
        try? await Task.sleep(for: .seconds(30))
        self.ackWaiters.removeValue(forKey: id)?.resume(returning: .timedOut)
      }
    }
    switch ack {
    case .acknowledged:
      return SubmissionReceipt(nativeTurnId: turnUuid, acknowledged: true)
    case .exited(let tail):
      throw WorkspaceError(
        .endpointUnavailable,
        "claude exited before accepting the turn.\(tail.isEmpty ? "" : " \(tail.suffix(300))")",
        details: ["turnUuid": .string(turnUuid)])
    case .timedOut:
      throw WorkspaceError(
        .submissionUnknown,
        "Claude Code did not acknowledge the turn within 30 s; it may still have started.",
        details: ["turnUuid": .string(turnUuid)])
    }
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    guard let session = sessions[ref.nativeSessionId] else {
      throw WorkspaceError(.cancellationUnconfirmed, "No Claude process is running for this thread.")
    }
    trackers[ref.nativeSessionId]?.markInterruptRequested()
    do {
      _ = try await session.control("interrupt", ["cancel_queued": true], timeout: .seconds(15))
    } catch {
      throw WorkspaceError(
        .cancellationUnconfirmed,
        "Claude Code did not confirm the interrupt: \(WorkspaceError.from(error).message)")
    }
    return StopReceipt(confirmed: true, outcome: nil)
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    guard let pending = pendingRequests[ref.nativeRequestId], pending.generation == ref.adapterGeneration,
      let session = sessions[pending.sessionId]
    else {
      throw WorkspaceError(
        .staleRuntimeRequest,
        "Request \(ref.nativeRequestId) is no longer pending in the current Claude process.")
    }
    let line: Data
    switch (pending.subtype, pending.toolName, response) {
    case ("can_use_tool", "AskUserQuestion", .answers(let answers)):
      let questions = pending.input["questions"]?.arrayValue ?? []
      var native: [String: JSONValue] = [:]
      for (key, values) in answers {
        guard key.hasPrefix("q"), let index = Int(key.dropFirst()), questions.indices.contains(index),
          let text = questions[index]["question"]?.stringValue
        else { continue }
        native[text] = .string(values.joined(separator: ", "))
      }
      line = try ClaudeStream.permissionResponse(
        requestId: ref.nativeRequestId, toolUseId: pending.toolUseId,
        decision: ClaudeStream.askUserQuestionAnswer(questions: .array(questions), answers: native))
    case ("can_use_tool", "AskUserQuestion", .decline(let reason)),
      ("can_use_tool", _, .decline(let reason)):
      line = try ClaudeStream.permissionResponse(
        requestId: ref.nativeRequestId, toolUseId: pending.toolUseId,
        decision: .deny(message: reason, interrupt: false))
    case ("can_use_tool", let tool, .decision(let decision)) where tool != "AskUserQuestion":
      switch decision {
      case .allowOnce, .allowAlways:
        line = try ClaudeStream.permissionResponse(
          requestId: ref.nativeRequestId, toolUseId: pending.toolUseId,
          decision: .allow(updatedInput: pending.input))
      case .deny:
        line = try ClaudeStream.permissionResponse(
          requestId: ref.nativeRequestId, toolUseId: pending.toolUseId,
          decision: .deny(message: "User declined", interrupt: false))
      }
    case ("elicitation", _, .decline):
      line = try ClaudeStream.elicitationDecline(requestId: ref.nativeRequestId)
    case (_, _, .decline):
      line = try ClaudeStream.controlErrorResponse(
        requestId: ref.nativeRequestId, message: "Declined by Personal Agent Workspace.")
    default:
      throw WorkspaceError(
        .protocolInvalid,
        "Response shape does not match request \(pending.subtype) (\(pending.toolName ?? "-")).")
    }
    try await session.send(line)
    pendingRequests[ref.nativeRequestId] = nil
  }

  /// A turn with no live process cannot still be running under this coordinator (D-016).
  public func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    if let session = sessions[ref.nativeSessionId], await session.isRunning {
      return ReconcileResult(snapshot: nil, activeTurnOutcome: .unknown)
    }
    return ReconcileResult(snapshot: nil, activeTurnOutcome: turn == nil ? nil : .known(.failed))
  }

  /// History from the transcript Claude Code writes under `projectsDirectory` (D-017).
  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await ensureAccount()
    guard let root = projectsDirectory,
      let file = Self.transcript(sessionId: ref.nativeSessionId, under: root)
    else {
      throw WorkspaceError(
        .nativeSessionMissing, "No Claude Code transcript found for session \(ref.nativeSessionId).")
    }
    let text = try String(contentsOfFile: file, encoding: .utf8)
    let items = ClaudeTurnTracker.snapshotItems(transcriptLines: text.split(separator: "\n").map(String.init))
    return SessionSnapshot(
      ref: ref, title: nil, items: items, activeTurn: nil, pendingRequests: [], truncated: false)
  }

  static func transcript(sessionId: String, under root: String) -> String? {
    let fm = FileManager.default
    guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return nil }
    for project in projects {
      let candidate = (root as NSString).appendingPathComponent("\(project)/\(sessionId).jsonl")
      if fm.fileExists(atPath: candidate) { return candidate }
    }
    return nil
  }

  public nonisolated func events() -> AsyncStream<AdapterEvent> { eventStream }

  public func dispose() async {
    for session in sessions.values { await session.close() }
  }

  // MARK: - LoginCapable

  /// Runs `claude auth login --claudeai` and returns the URL it prints. The CLI opens the browser
  /// itself; when it exits the adapter re-reads auth status and publishes `connection.changed`.
  public func startLogin() async throws -> LoginStart {
    let path = try locate()
    let child = try StreamingProcess.start(
      executable: path, arguments: ["auth", "login", "--claudeai"],
      environment: ClaudeStream.childEnvironment(from: environment, clientVersion: clientVersion))
    let url: String? = await withTaskGroup(of: String?.self) { group in
      group.addTask {
        var buffer = ""
        for await chunk in child.stdout {
          buffer += String(decoding: chunk, as: UTF8.self)
          if let range = buffer.range(of: "https://") {
            let rest = buffer[range.lowerBound...]
            let end = rest.firstIndex(where: { $0.isWhitespace }) ?? rest.endIndex
            return String(rest[..<end])
          }
        }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(15))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    Task { [weak self] in
      _ = await child.waitForExit()
      await self?.loginFinished()
    }
    guard let url else {
      if !child.isRunning { child.terminate() }
      throw WorkspaceError(
        .endpointUnavailable,
        "Claude Code did not print a sign-in URL. Run `claude auth login` in a terminal, then re-check the connection.",
        details: ["stderr": .string(child.recentStderr())])
    }
    return LoginStart(authUrl: url, loginId: "claude-login-\(child.processIdentifier)")
  }

  private func loginFinished() async {
    scope = nil
    let status: AuthStatus
    let message: String
    if (try? await ensureAccount()) != nil {
      status = .authenticated
      message = "Signed in to Claude Code as \(scope ?? "unknown")."
    } else {
      status = .required
      message = "Claude Code sign-in did not complete."
    }
    eventContinuation.yield(
      AdapterEvent.connectionChanged(
        connectionId: connectionId, status: .ready, authStatus: status, transport: .disconnected,
        message: message,
        adapterGeneration: generation))
  }
}
