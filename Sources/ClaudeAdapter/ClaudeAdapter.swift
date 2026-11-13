import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import os

/// Claude Code adapter over the CLI's stream-json protocol (spec section 8, decision D-002). One
/// `claude` process per native session (D-015); every control request gets exactly one answer.
public actor ClaudeAdapter: AgentAdapter, LoginCapable, CommandListing {
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

  /// The model, permission mode, and extra directories a session's process runs with.
  private struct Settings: Equatable {
    var model: String?
    var permission: String?
    var directories: [String]
  }

  private let executablePath: String?
  private let environment: [String: String]
  private let clientVersion: String
  private var sessions: [String: ClaudeSession] = [:]
  /// Per live session, what its process was launched with or last switched to.
  private var applied: [String: Settings] = [:]
  /// Set by `dispose()`, for good: no `claude` process is started after it.
  private var disposed = false
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
    if disposed { throw Self.disposedError }
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
      inspection.models = RuntimeOptions.claudeModels
    } else {
      scope = nil
    }
    return inspection
  }

  /// Start Claude Code in an empty folder, read the commands its handshake reports, and close it.
  /// No message is sent, so no transcript is written and nothing is inferred; the session-start
  /// hooks the owner configured do run.
  public func readCommands() async throws -> [RuntimeCommand] {
    let path = try locate()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "b4app-claude-commands-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = ClaudeSession(
      options: ClaudeSession.Options(
        executablePath: path, environment: environment, workingDirectory: folder.path,
        sessionId: UUID().uuidString.lowercased(), resume: false, clientVersion: clientVersion))
    do {
      try await session.start()
    } catch {
      await session.close()
      throw error
    }
    let commands = await session.commands
    await session.close()
    return commands
  }

  static let capabilities: Capabilities = [
    .streaming: .supported, .nativeResume: .supported, .historyRetrieval: .supported,
    .explicitInterruption: .supported, .reconnect: .unverified, .permissionDecisions: .supported,
    .userQuestions: .supported, .modelSelection: .supported,
  ]

  // MARK: - Sessions

  /// A permission id Claude Code knows, else nil: a value synced from another device reaches the
  /// adapter unvalidated, and an unknown one leaves Claude Code's own setting in place.
  static func permissionMode(_ id: String?) -> String? {
    guard let id, RuntimeOptions.permissions(for: .claude).contains(where: { $0.id == id }) else {
      return nil
    }
    return id
  }

  private func startSession(
    id: String, workingDirectory: String, resume: Bool, settings: Settings
  ) async throws -> ClaudeSession {
    let path = try locate()
    generation += 1
    let session = ClaudeSession(
      options: ClaudeSession.Options(
        executablePath: path, environment: environment, workingDirectory: workingDirectory, sessionId: id,
        resume: resume, clientVersion: clientVersion, model: settings.model,
        permissionMode: settings.permission, addDirectories: settings.directories))
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
    // A dispose while this session was starting owns the adapter now: the process does not outlive it.
    if disposed {
      await session.close()
      throw Self.disposedError
    }
    sessions[id] = session
    applied[id] = settings
    // What this session can run; the coordinator keeps the list on the connection.
    let commands = await session.commands
    if !commands.isEmpty {
      eventContinuation.yield(
        AdapterEvent(
          kind: .commandsChanged, connectionId: connectionId, adapterGeneration: generation,
          payload: ["commands": (try? JSONValue(encoding: commands)) ?? []]))
    }
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
      applied[id] = nil
      trackers[id] = nil
      pumps[id] = nil
    }
  }

  /// Stop the session's process and start it again on the same conversation (`--resume`) with new
  /// launch flags. A deliberate stop between turns: its exit is not reported as the runtime exiting.
  private func restart(id: String, workingDirectory: String, settings: Settings) async throws -> ClaudeSession
  {
    let old = sessions.removeValue(forKey: id)
    let pump = pumps.removeValue(forKey: id)
    trackers[id] = nil
    applied[id] = nil
    pendingRequests = pendingRequests.filter { $0.value.sessionId != id }
    await old?.close()
    // The old process's last frames and its exit are handled (and dropped) before the new one registers.
    await pump?.value
    return try await startSession(
      id: id, workingDirectory: workingDirectory, resume: true, settings: settings)
  }

  /// Run a control request that changes a live session; Claude Code refusing it fails the turn.
  private func change(_ control: String, _ request: () async throws -> Void) async throws {
    do {
      try await request()
    } catch {
      let failure = WorkspaceError.from(error)
      // A refusal (`control_response` error); a timeout or an exit keeps its own code.
      guard failure.code == .internalError else { throw failure }
      throw WorkspaceError(
        .unsupportedCapability, "Claude Code refused \(control): \(failure.message)",
        details: ["control": .string(control)])
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
    let settings = Settings(
      model: input.model, permission: Self.permissionMode(input.permission),
      directories: input.additionalDirectories)
    _ = try await startSession(id: id, workingDirectory: directory, resume: false, settings: settings)
    return NativeSessionRef(nativeSessionId: id, nativeScope: scope)
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    let id = ref.nativeSessionId
    let directory = input.workingDirectory ?? NSHomeDirectory()
    let wanted = Settings(
      model: input.model, permission: Self.permissionMode(input.permission),
      directories: input.additionalDirectories)
    let session: ClaudeSession
    if let live = sessions[id], await live.isRunning, let current = applied[id] {
      // `--add-dir` is a launch flag, and no control request clears a model or permission back to
      // Claude Code's own setting: either takes a restart, so a live process runs as a fresh launch would.
      // Nor does Claude Code switch a live process into `bypassPermissions` unless it launched in it.
      let cleared =
        (wanted.model == nil && current.model != nil)
        || (wanted.permission == nil && current.permission != nil)
      let bypassing = wanted.permission == "bypassPermissions" && current.permission != "bypassPermissions"
      if cleared || bypassing || Set(wanted.directories) != Set(current.directories) {
        session = try await restart(id: id, workingDirectory: directory, settings: wanted)
      } else {
        if let model = wanted.model, model != current.model {
          try await change("set_model") { try await live.setModel(model) }
          applied[id]?.model = model
        }
        if let mode = wanted.permission, mode != current.permission {
          try await change("set_permission_mode") { try await live.setPermissionMode(mode) }
          applied[id]?.permission = mode
        }
        session = live
      }
    } else {
      session = try await startSession(id: id, workingDirectory: directory, resume: true, settings: wanted)
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

  /// Claude Code has no delete command; like the Claude desktop app (`find … -exec rm`), remove the
  /// session's transcript (`<sessionId>.jsonl`) and its subagent folder (`<sessionId>/`) from every
  /// project folder that holds one. Nothing else is touched: not the project folders, not other
  /// sessions. Already gone only when the projects root lists and no folder holds the transcript.
  public func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion {
    let id = ref.nativeSessionId
    guard id.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else {
      throw WorkspaceError(.protocolInvalid, "Refusing to delete a Claude Code session with an unsafe id.")
    }
    if let session = sessions[id] { await session.close() }
    if projectsDirectory == nil { _ = try? await ensureAccount() }
    let root = projectsDirectory ?? Self.projectsRoot(environment: environment)
    let fm = FileManager.default
    let projects: [String]
    do {
      projects = try fm.contentsOfDirectory(atPath: root)
    } catch {
      throw WorkspaceError(
        .endpointUnavailable,
        "Could not read Claude Code's projects folder \(root): \(error.localizedDescription)")
    }
    let standardRoot = URL(fileURLWithPath: root).standardizedFileURL.path
    var removed = false
    for project in projects {
      let folder = (root as NSString).appendingPathComponent(project)
      let file = (folder as NSString).appendingPathComponent("\(id).jsonl")
      guard fm.fileExists(atPath: file) else { continue }
      guard URL(fileURLWithPath: folder).deletingLastPathComponent().standardizedFileURL.path == standardRoot
      else {
        throw WorkspaceError(.protocolInvalid, "Refusing to delete a Claude Code transcript outside \(root).")
      }
      try fm.removeItem(atPath: file)
      let subagents = (folder as NSString).appendingPathComponent(id)
      var isDirectory: ObjCBool = false
      if fm.fileExists(atPath: subagents, isDirectory: &isDirectory), isDirectory.boolValue {
        try fm.removeItem(atPath: subagents)
      }
      removed = true
    }
    return removed ? .deleted : .alreadyGone
  }

  /// Where Claude Code keeps transcripts when its auth status has not said: `$CLAUDE_CONFIG_DIR/projects`,
  /// else `~/.claude/projects`.
  static func projectsRoot(environment: [String: String]) -> String {
    if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
      return (config as NSString).appendingPathComponent("projects")
    }
    let home = environment["HOME"] ?? NSHomeDirectory()
    return (home as NSString).appendingPathComponent(".claude/projects")
  }

  public nonisolated func events() -> AsyncStream<AdapterEvent> { eventStream }

  static let disposedError = WorkspaceError(
    .endpointUnavailable, "This Claude connection was shut down; no Claude Code process is started again.")

  /// Final: every session's process stops, and every later call refuses instead of starting one.
  public func dispose() async {
    disposed = true
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
