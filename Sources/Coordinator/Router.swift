import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Validates envelopes, routes allowlisted methods, and deduplicates repeated local mutations by
/// operationId. This is local idempotency only; it says nothing about upstream delivery.
public actor Router {
  public struct Context: Sendable {
    public var database: WorkspaceDatabase
    public var eventLog: EventLog
    public var diagnostics: DiagnosticsService
    public var sessions: SessionService
    public var servers: LocalServerService
    public var hub: HubSync
    public var projects: ProjectService
    public var startedAt: String
    public var paths: PlatformPaths
  }

  private let context: Context
  private var completedOperations: [String: ResponseEnvelope] = [:]
  private var operationOrder: [String] = []
  private let operationCacheLimit = 500
  private let logger = Log.logger("router")

  public init(context: Context) {
    self.context = context
  }

  public func dispatch(line: Data) async -> ResponseEnvelope {
    let command: ParsedCommand
    do {
      command = try parseCommand(line)
    } catch {
      let failure = WorkspaceError.from(error)
      let requestId =
        (try? JSONCoding.decoder.decode(JSONValue.self, from: line))?["requestId"]?.stringValue ?? "unknown"
      logger.warning(
        "rejected command \(failure.code.rawValue, privacy: .public) for request \(requestId, privacy: .public)"
      )
      return .failure(requestId, error: failure)
    }
    let requestId = command.envelope.requestId
    if let operationId = command.envelope.operationId, var previous = completedOperations[operationId] {
      previous.requestId = requestId
      return previous
    }
    var response: ResponseEnvelope
    do {
      response = .success(requestId, result: try await handle(command))
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.code == .internalError {
        logger.error(
          "command \(command.method.rawValue, privacy: .public) failed: \(failure.message, privacy: .public)")
        await context.diagnostics.recordError(
          scope: command.method.rawValue, code: failure.code.rawValue, message: failure.message)
      }
      response = .failure(requestId, error: failure)
    }
    if let operationId = command.envelope.operationId {
      completedOperations[operationId] = response
      operationOrder.append(operationId)
      if operationOrder.count > operationCacheLimit {
        let evicted = operationOrder.removeFirst()
        completedOperations[evicted] = nil
      }
    }
    return response
  }

  private func handle(_ command: ParsedCommand) async throws -> JSONValue {
    let db = context.database
    let events = context.eventLog
    let sessions = context.sessions
    let servers = context.servers
    switch command.method {
    case .systemPing:
      return try JSONValue(
        encoding: SystemPing.Result(
          epoch: events.epoch, sequence: await events.sequence,
          coordinator: CoordinatorIdentity(
            version: CoordinatorVersion.current, pid: ProcessInfo.processInfo.processIdentifier),
          startedAt: context.startedAt))
    case .diagnosticsRead:
      return try JSONValue(encoding: try await context.diagnostics.read())
    case .connectionList:
      let params = try command.params(for: ConnectionList.self)
      return try JSONValue(
        encoding: ConnectionList.Result(
          connections: try db.listConnections(includeDisabled: params.includeDisabled ?? false)))
    case .threadList:
      let params = try command.params(for: ThreadList.self)
      let filter = ThreadFilter(
        connectionId: params.connectionId, includeArchived: params.includeArchived ?? false,
        query: params.query)
      return try JSONValue(encoding: ThreadList.Result(threads: try db.listThreads(filter)))
    case .draftRead:
      let params = try command.params(for: DraftRead.self)
      return try JSONValue(encoding: DraftRead.Result(draft: try db.draft(threadId: params.threadId)))
    case .draftSave:
      let params = try command.params(for: DraftSave.self)
      guard try db.thread(id: params.threadId) != nil else {
        throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
      }
      return try JSONValue(
        encoding: DraftSave.Result(draft: try db.saveDraft(threadId: params.threadId, text: params.text)))
    case .eventsSnapshot:
      return try JSONValue(
        encoding: EventsSnapshot.Result(
          epoch: events.epoch, sequence: await events.sequence,
          connections: try db.listConnections(includeDisabled: true),
          threads: try db.listThreads(ThreadFilter(includeArchived: true)),
          activeTurns: try db.unresolvedTurns()))
    case .eventsReplay:
      let params = try command.params(for: EventsReplay.self)
      guard let replayed = await events.replay(epoch: params.epoch, afterSequence: params.afterSequence)
      else {
        throw WorkspaceError(
          .snapshotRequired, "Event position is no longer replayable; fetch a snapshot.",
          details: ["epoch": .string(events.epoch), "sequence": .number(Double(await events.sequence))])
      }
      return try JSONValue(encoding: EventsReplay.Result(events: replayed))
    case .connectionAdd:
      return try JSONValue(
        encoding: try await sessions.connectionAdd(try command.params(for: ConnectionAdd.self)))
    case .connectionInspect:
      return try JSONValue(
        encoding: try await sessions.connectionInspect(try command.params(for: ConnectionInspect.self)))
    case .connectionLogin:
      return try JSONValue(
        encoding: try await sessions.connectionLogin(try command.params(for: ConnectionLogin.self)))
    case .threadCreate:
      return try JSONValue(
        encoding: try await sessions.threadCreate(try command.params(for: ThreadCreate.self)))
    case .threadRead:
      return try JSONValue(encoding: try await sessions.threadRead(try command.params(for: ThreadRead.self)))
    case .threadUpdate:
      return try JSONValue(
        encoding: try await sessions.threadUpdate(try command.params(for: ThreadUpdate.self)))
    case .threadMarkRead:
      return try JSONValue(
        encoding: try await sessions.threadMarkRead(try command.params(for: ThreadMarkRead.self)))
    case .projectList:
      return try JSONValue(encoding: try await context.projects.list())
    case .projectCreate:
      return try JSONValue(
        encoding: try await context.projects.create(try command.params(for: ProjectCreate.self)))
    case .projectUpdate:
      return try JSONValue(
        encoding: try await context.projects.update(try command.params(for: ProjectUpdate.self)))
    case .projectRename:
      return try JSONValue(
        encoding: try await context.projects.rename(try command.params(for: ProjectRename.self)))
    case .projectDelete:
      return try JSONValue(
        encoding: try await context.projects.delete(try command.params(for: ProjectDelete.self)))
    case .threadReconcile:
      return try JSONValue(
        encoding: try await sessions.threadReconcile(try command.params(for: ThreadReconcile.self)))
    case .turnSend:
      return try JSONValue(
        encoding: try await sessions.turnSend(
          try command.params(for: TurnSend.self), operationId: command.envelope.operationId ?? ""))
    case .turnInterrupt:
      return try JSONValue(
        encoding: try await sessions.turnInterrupt(try command.params(for: TurnInterrupt.self)))
    case .turnAbandon:
      return try JSONValue(
        encoding: try await sessions.turnAbandon(try command.params(for: TurnAbandon.self)))
    case .credentialAdd:
      return try JSONValue(
        encoding: try await sessions.credentialAdd(try command.params(for: CredentialAdd.self)))
    case .requestRespond:
      return try JSONValue(
        encoding: try await sessions.requestRespond(try command.params(for: RequestRespond.self)))
    case .serverAdd:
      return try JSONValue(encoding: try await servers.add(try command.params(for: ServerAdd.self)))
    case .serverList:
      return try JSONValue(encoding: try await servers.list())
    case .serverStart:
      return try JSONValue(
        encoding: try await servers.start(id: try command.params(for: ServerStart.self).serverId))
    case .serverStatus:
      return try JSONValue(
        encoding: try await servers.status(id: try command.params(for: ServerStatus.self).serverId))
    case .serverInspect:
      return try JSONValue(
        encoding: try await servers.inspect(id: try command.params(for: ServerInspect.self).serverId))
    case .serverLogs:
      return try JSONValue(encoding: try await servers.logs(try command.params(for: ServerLogs.self)))
    case .serverStop:
      let params = try command.params(for: ServerStop.self)
      return try JSONValue(
        encoding: try await servers.stop(id: params.serverId, force: params.force ?? false))
    case .serverRestart:
      let params = try command.params(for: ServerRestart.self)
      return try JSONValue(
        encoding: try await servers.restart(id: params.serverId, force: params.force ?? false))
    case .workspaceActiveWork:
      return try JSONValue(encoding: try await sessions.activeWork())
    case .workspaceStopLocalWork:
      return try JSONValue(encoding: try await sessions.stopLocalWork())
    case .workspaceReconcile:
      let params = try command.params(for: WorkspaceReconcile.self)
      return try JSONValue(encoding: await sessions.reconcileAll(reason: params.reason ?? "request"))
    case .databaseStatus:
      return try JSONValue(encoding: try storeStatus())
    case .databaseBackup:
      let params = try command.params(for: DatabaseBackup.self)
      let path = params.path ?? defaultBackupPath()
      let summary = try context.database.export(to: path)
      return try JSONValue(encoding: DatabaseBackup.Result(path: summary.path, rows: summary.rows))
    case .databaseRestore:
      let params = try command.params(for: DatabaseRestore.self)
      // A restore rewrites the change log and its sequence; reused deviceSeqs would count as already
      // accepted at the hub and never be mirrored.
      guard try context.database.hubLink() == nil else {
        throw WorkspaceError(
          .protocolInvalid,
          "This Mac is joined to a hub; run `agent-workspace hub leave` before restoring, then join again.")
      }
      let summary = try context.database.restore(from: params.path, replace: params.replace)
      return try JSONValue(encoding: DatabaseBackup.Result(path: summary.path, rows: summary.rows))
    case .databaseImportSQLite:
      let params = try command.params(for: DatabaseImportSQLite.self)
      let summary = try SQLiteImporter.importFile(at: params.path, into: context.database)
      return try JSONValue(encoding: DatabaseImportSQLite.Result(rows: summary.rows))
    case .hubJoin:
      let params = try command.params(for: HubJoin.self)
      return try JSONValue(
        encoding: try await context.hub.join(
          url: params.url, code: params.code, deviceName: params.deviceName ?? HubSync.defaultDeviceName()))
    case .hubStatus:
      return try JSONValue(encoding: try await context.hub.status())
    case .hubLeave:
      try await context.hub.leave()
      return try JSONValue(encoding: try await context.hub.status())
    }
  }

  // MARK: - Store commands (M7)

  private var backupsDir: String { (context.paths.dataDir as NSString).appendingPathComponent("backups") }

  private func defaultBackupPath() -> String {
    let stamp = Timestamp.now().replacingOccurrences(of: ":", with: "-")
    return (backupsDir as NSString).appendingPathComponent("workspace-\(stamp).jsonl")
  }

  private func storeStatus() throws -> DatabaseStatus.Result {
    let endpoint = context.paths.postgres
    return DatabaseStatus.Result(
      endpoint: "postgresql:///\(endpoint.database)?host=\(endpoint.socketDir)&port=\(endpoint.port)",
      dataDir: endpoint.dataDir, migrations: try context.database.appliedMigrations(),
      rows: try context.database.tableCounts(), unsyncedChanges: try context.database.unsyncedChangeCount(),
      backupsDir: backupsDir)
  }
}
