import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// Runs a command relayed from the hub through the same `SessionService` call the `Router` makes for the
/// local app, and answers with a `reply`. It writes nothing itself: `SessionService` stays the only
/// writer of turns, display items, and runtime requests, so the Mac app sees a relayed command through
/// its ordinary events. Errors keep their code and details, `details.turnId` included: a reply error
/// that carries one means the turn exists and its outcome arrives through sync. A message that could
/// carry store, process, or path text is replaced at this boundary (see `wireError`).
///
/// - A command past its deadline, judged on the hub's clock (`hubNow`, never `Date()`), runs nothing.
/// - `turn.send` and `thread.start` run once per command id: a resend while the first is still running
///   awaits it and returns its reply; after it ends, `SessionService`'s durable lookup by operationId
///   (the command id) answers the resend with the same turn.
/// - `thread.start`s naming the same thread id run one after another, so only one creates the thread.
public actor RelayExecutor {
  /// The message of every error whose own text must stay on this Mac.
  static let couldNotRun = "Your Mac could not run this."

  /// A `turn.send` or `thread.start` still running.
  private struct Running {
    var method: RelayMethod
    /// The thread the command names, when its params name one.
    var threadId: String?
    var task: Task<RelayMessage, Never>
  }

  private let sessions: SessionService
  private let projects: ProjectService
  private let db: WorkspaceDatabase
  private let diagnostics: DiagnosticsService
  private let logger = Log.logger("relay")
  /// By command id (the turn's operationId).
  private var inFlight: [String: Running] = [:]
  /// The latest `thread.start` per thread id it names; the next one for that id waits for it.
  private var threadStarts: [String: Task<RelayMessage, Never>] = [:]

  public init(
    sessions: SessionService, projects: ProjectService, database: WorkspaceDatabase,
    diagnostics: DiagnosticsService
  ) {
    self.sessions = sessions
    self.projects = projects
    self.db = database
    self.diagnostics = diagnostics
  }

  /// Run one relayed command. `deadline` is the hub's stamp and `hubNow` the hub's clock as this Mac
  /// estimates it at receipt; the reply carries `id`.
  public func execute(
    id: String, method: RelayMethod, params: JSONValue, deadline: Date, hubNow: Date
  ) async -> RelayMessage {
    guard hubNow <= deadline else {
      return .reply(
        id: id, error: RelayWireError(.commandExpired, "The command reached this Mac after its deadline."))
    }
    switch method {
    case .turnSend, .threadStart:
      if let running = inFlight[id] {
        guard running.method == method else {
          return .reply(
            id: id,
            error: RelayWireError(
              .protocolInvalid, "This command id is already running as another command.",
              details: ["reason": "operation_reused"]))
        }
        return await running.task.value
      }
      let threadId = params["threadId"]?.stringValue
      // Only `thread.start` creates a thread, so only it waits for an earlier start of the same id.
      let previous = method == .threadStart ? threadId.flatMap { threadStarts[$0] } : nil
      let task = Task {
        if let previous { _ = await previous.value }
        return await self.reply(id: id, method: method, params: params)
      }
      inFlight[id] = Running(method: method, threadId: threadId, task: task)
      if method == .threadStart, let threadId { threadStarts[threadId] = task }
      let reply = await task.value
      inFlight[id] = nil
      if let threadId, threadStarts[threadId] == task { threadStarts[threadId] = nil }
      return reply
    case .turnInterrupt, .requestRespond, .turnLookup:
      return await reply(id: id, method: method, params: params)
    }
  }

  private func reply(id: String, method: RelayMethod, params: JSONValue) async -> RelayMessage {
    do {
      return .reply(id: id, result: try await run(id: id, method: method, params: params))
    } catch {
      let failure = WorkspaceError.from(error)
      let (wire, replaced) = Self.wireError(failure)
      if replaced {
        // The full text stays on this Mac: the log (private) and Diagnostics, as the `Router` records it.
        logger.error(
          "relayed \(method.rawValue, privacy: .public) failed with \(failure.code.rawValue, privacy: .public): \(failure.message, privacy: .private)"
        )
        await diagnostics.recordError(
          scope: "relay:\(method.rawValue)", code: failure.code.rawValue, message: failure.message)
      }
      return .reply(id: id, error: wire)
    }
  }

  /// The error as it may leave this Mac, and whether its message was replaced. The code and details are
  /// kept, so `reason` and `turnId` survive. The message becomes `couldNotRun` when it may carry text
  /// that must not reach the hub or the phone:
  /// - any `internal_error` (its message is often `String(describing:)` of a foreign error), whose
  ///   details are dropped too except `turnId`;
  /// - a store failure: the message contains "PostgreSQL:" (the store's prefix, which may be followed by
  ///   SQL, `DETAIL: Key (…)=(…)` or `Failing row contains (…)` with row values), whatever its code;
  /// - a process launch failure: the message contains "Could not start " (the prefix `StreamingProcess`,
  ///   `ManagedProcess`, and the launcher put before the executable path), whatever its code.
  static func wireError(_ failure: WorkspaceError) -> (error: RelayWireError, replaced: Bool) {
    let isInternal = failure.code == .internalError
    guard
      isInternal || failure.message.contains("PostgreSQL:") || failure.message.contains("Could not start ")
    else {
      return (
        RelayWireError(code: failure.code.rawValue, message: failure.message, details: failure.details), false
      )
    }
    var details = failure.details
    if isInternal { details = failure.details?["turnId"].map { .object(["turnId": $0]) } }
    return (RelayWireError(code: failure.code.rawValue, message: couldNotRun, details: details), true)
  }

  private func run(id: String, method: RelayMethod, params: JSONValue) async throws -> JSONValue {
    switch method {
    case .turnSend:
      return try JSONValue(
        encoding: try await sessions.turnSend(try decode(TurnSend.self, params), operationId: id))
    case .turnInterrupt:
      return try JSONValue(encoding: try await sessions.turnInterrupt(try decode(TurnInterrupt.self, params)))
    case .requestRespond:
      return try JSONValue(
        encoding: try await sessions.requestRespond(try decode(RequestRespond.self, params)))
    case .threadStart:
      return try JSONValue(
        encoding: try await threadStart(try decode(ThreadStart.self, params), operationId: id))
    case .turnLookup:
      return try JSONValue(encoding: try turnLookup(try decode(TurnLookup.self, params)))
    }
  }

  // MARK: - turn.lookup

  /// `in_flight` while this Mac is still running that send on that thread, `found` once a turn of the
  /// thread has that operationId, otherwise `none`. A command is dropped after its deadline, so `none`
  /// after the deadline is final.
  private func turnLookup(_ params: TurnLookup.Params) throws -> TurnLookup.Result {
    if let running = inFlight[params.operationId], running.threadId == params.threadId {
      return TurnLookup.Result(state: .inFlight)
    }
    if let turn = try db.turn(operationId: params.operationId), turn.threadId == params.threadId {
      return TurnLookup.Result(state: .found, turn: turn)
    }
    return TurnLookup.Result(state: .none)
  }

  // MARK: - thread.start

  /// Create the thread (or reuse the one this id already names) and send its first turn, so a retry
  /// lands on the same thread and the same turn. Refuses with `protocol_invalid` anything the Mac would
  /// not start itself: an unknown project, a Codex or Claude folder that is not one of the project's
  /// folders, a B4 connection that does not serve the project, a remote B4 connection, a connection not
  /// ready for a conversation, or a thread id already used with another connection or folder.
  private func threadStart(
    _ params: ThreadStart.Params, operationId: String
  ) async throws -> ThreadStart.Result {
    // A retry of a start that already made its turn gets that answer, whatever changed since (the
    // connection may have gone offline): refusing it now would tell the phone the send never happened.
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
    guard let project = try db.project(id: params.projectId) else {
      throw Self.refusal("This project is not on this Mac.", reason: "project_missing")
    }
    guard let connection = try db.connection(id: params.connectionId) else {
      throw Self.refusal("This connection is not on this Mac.", reason: "connection_missing")
    }
    let projectFolders = Set(project.folders.map(\.path))
    let requested = params.folder.flatMap { $0.isEmpty ? nil : $0 }
    let folder: String?
    switch connection.kind {
    case .codex, .claude:
      guard let requested else {
        throw Self.refusal(
          "A \(connection.kind.rawValue) thread needs one of the project's folders.", reason: "folder_missing"
        )
      }
      let canonical = SessionService.canonicalDirectory(requested)
      guard projectFolders.contains(canonical) else {
        throw Self.refusal(
          "That folder is not one of this project's folders.", reason: "folder_outside_project")
      }
      folder = canonical
    case .b4:
      if connection.b4Mode == .remote {
        throw Self.refusal(
          "A remote B4 connection cannot start a thread from another device.", reason: "remote_b4")
      }
      guard requested == nil else {
        throw Self.refusal(
          "A B4 thread is bound to its route and takes no folder.", reason: "folder_not_allowed")
      }
      // The connection's synced project and the coordinator's own resolution (its managed server's
      // folder) must both name this project.
      guard connection.localServerId != nil, connection.projectId == project.id,
        let serverFolder = try await projects.serverFolder(of: connection),
        projectFolders.contains(serverFolder)
      else {
        throw Self.refusal(
          "Connection \(connection.label) does not serve this project.", reason: "connection_outside_project")
      }
      folder = nil
    }
    guard connection.enabled, connection.status == .ready else {
      throw Self.refusal(
        "Connection \(connection.label) is not ready for a conversation.", reason: "connection_not_ready")
    }
    let thread: ConversationThread
    if let existing = try db.thread(id: params.threadId) {
      let sameFolder = folder == nil || existing.context.map(SessionService.canonicalDirectory) == folder
      guard existing.connectionId == connection.id, sameFolder else {
        throw Self.refusal(
          "Thread \(params.threadId) already exists with another connection or folder.",
          reason: "thread_mismatch")
      }
      thread = existing
    } else {
      thread = try await sessions.threadCreate(
        ThreadCreate.Params(connectionId: connection.id, workingDirectory: folder, threadId: params.threadId)
      ).thread
    }
    let turn = try await sessions.turnSend(
      TurnSend.Params(threadId: thread.id, text: params.text), operationId: operationId
    ).turn
    return ThreadStart.Result(thread: try db.thread(id: thread.id) ?? thread, turn: turn)
  }

  // MARK: - Helpers

  private func decode<C: WorkspaceCommand>(_ command: C.Type, _ params: JSONValue) throws -> C.Params {
    do {
      return try params.decode(C.Params.self)
    } catch {
      throw WorkspaceError(
        .protocolInvalid, "Invalid params for \"\(C.method.rawValue)\".",
        details: ["method": .string(C.method.rawValue)])
    }
  }

  private static func refusal(_ message: String, reason: String) -> WorkspaceError {
    WorkspaceError(.protocolInvalid, message, details: ["reason": .string(reason)])
  }
}
