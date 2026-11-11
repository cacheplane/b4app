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
/// - `environment.create`, `environment.update`, and `environment.delete` run through `EnvironmentService`, exactly as
///   the Mac's own sheets do, so a folder the phone names is validated here, on the Mac it is on. A
///   create is idempotent by the phone's `environmentId`; an edit is not resent by the phone.
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
  private let environments: EnvironmentService
  private let db: WorkspaceDatabase
  private let diagnostics: DiagnosticsService
  private let gate: ScopeGate?
  private let logger = Log.logger("relay")
  /// By command id (the turn's operationId).
  private var inFlight: [String: Running] = [:]
  /// The latest `thread.start` per thread id it names; the next one for that id waits for it.
  private var threadStarts: [String: Task<RelayMessage, Never>] = [:]

  /// `gate` is the account scope's: a command runs only while the scope is open, and the scope's
  /// close waits (bounded) for the ones running.
  public init(
    sessions: SessionService, environments: EnvironmentService, database: WorkspaceDatabase,
    diagnostics: DiagnosticsService, gate: ScopeGate? = nil
  ) {
    self.sessions = sessions
    self.environments = environments
    self.db = database
    self.diagnostics = diagnostics
    self.gate = gate
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
    case .turnInterrupt, .requestRespond, .turnLookup, .environmentCreate, .environmentUpdate,
      .environmentDelete:
      return await reply(id: id, method: method, params: params)
    }
  }

  private func reply(id: String, method: RelayMethod, params: JSONValue) async -> RelayMessage {
    do {
      try gate?.enter()
      defer { gate?.leave() }
      return .reply(id: id, result: try await run(id: id, method: method, params: params))
    } catch {
      let failure = WorkspaceError.from(error)
      let (sanitized, replaced) = Self.wireError(failure)
      var wire = sanitized
      wire.details = blockingTurnRenamed(wire.details, commandId: id, method: method)
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

  /// Refusal reasons whose `details.turnId` names the turn in the way, not one this command made.
  static let blockingReasons: Set<String> = ["turn_active"]

  /// The phone reads `details.turnId` as "this send's turn exists, so it was accepted". A refusal made
  /// before this command's turn existed names another turn there (the one in the way); at this boundary
  /// that id moves to `details.blockingTurnId`. It moves when the reason is one of `blockingReasons`, and,
  /// for `turn.send` and `thread.start`, whenever the named turn is not this command's own (its
  /// operationId is not the command id). `SessionService` and the local `Router` keep `turnId`.
  private func blockingTurnRenamed(
    _ details: JSONValue?, commandId: String, method: RelayMethod
  ) -> JSONValue? {
    guard case .object(var object)? = details, let turnId = object["turnId"] else { return details }
    let blocking: Bool
    if let reason = object["reason"]?.stringValue, Self.blockingReasons.contains(reason) {
      blocking = true
    } else if method == .turnSend || method == .threadStart, let id = turnId.stringValue,
      let turn = try? db.turn(id: id)
    {
      blocking = turn.operationId != commandId
    } else {
      blocking = false
    }
    guard blocking else { return details }
    object["turnId"] = nil
    object["blockingTurnId"] = turnId
    return .object(object)
  }

  private func run(id: String, method: RelayMethod, params: JSONValue) async throws -> JSONValue {
    switch method {
    case .turnSend:
      let send = try decode(TurnSend.self, params)
      try SessionService.requireStorableText(send.text)
      return try JSONValue(encoding: try await sessions.turnSend(send, operationId: id))
    case .turnInterrupt:
      return try JSONValue(encoding: try await sessions.turnInterrupt(try decode(TurnInterrupt.self, params)))
    case .requestRespond:
      return try JSONValue(
        encoding: try await sessions.requestRespond(try decode(RequestRespond.self, params)))
    case .threadStart:
      // The phone always names an environment; only the Mac's own app may start without one.
      return try JSONValue(
        encoding: try await sessions.threadStart(
          try decode(ThreadStart.self, params), operationId: id, requireEnvironment: true))
    case .turnLookup:
      return try JSONValue(encoding: try turnLookup(try decode(TurnLookup.self, params)))
    case .environmentCreate:
      return try JSONValue(
        encoding: try await environments.create(try decode(EnvironmentCreate.self, params)))
    case .environmentUpdate:
      return try JSONValue(
        encoding: try await environments.update(try decode(EnvironmentUpdate.self, params)))
    case .environmentDelete:
      return try JSONValue(
        encoding: try await environments.delete(try decode(EnvironmentDelete.self, params)))
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
}
