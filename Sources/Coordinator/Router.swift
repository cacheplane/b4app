import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Validates envelopes, routes allowlisted methods, and deduplicates repeated local mutations by
/// operationId. This is local idempotency only; it says nothing about upstream delivery.
///
/// Every method that reads or writes the store runs on the signed-in account's scope, resolved per
/// command (`needsAccount`); with nobody signed in it answers `signed_out` before its params are read.
/// `system.*`, `diagnostics.read`, `events.replay` (the shared event log, which carries
/// `account.changed`), and the relay-only methods need no account; `hub.join` signs in when nobody is.
/// `account.*` is routed to the account manager without an account; the commands that act on the
/// signed-in one answer `signed_out` themselves, and `account.logout` and `account.delete` (like
/// `hub.leave`) run outside the scope's gate, since closing the scope waits for what is inside it.
public actor Router {
  public struct Context: Sendable {
    public var eventLog: EventLog
    public var diagnostics: DiagnosticsService
    public var accounts: AccountManager
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
    if let operationId = command.envelope.operationId, var previous = completedOperations[operationId],
      command.method != .hubPair
    {
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
    // A pairing code is a credential: it is answered once, to the caller who asked, and never kept. A
    // `signed_out` answer is not kept either: the same operation succeeds once someone signs in.
    if let operationId = command.envelope.operationId, command.method != .hubPair,
      response.error?.code != .signedOut
    {
      completedOperations[operationId] = response
      operationOrder.append(operationId)
      if operationOrder.count > operationCacheLimit {
        let evicted = operationOrder.removeFirst()
        completedOperations[evicted] = nil
      }
    }
    return response
  }

  /// Whether `method` reads or writes an account's store, and so needs someone signed in. Exhaustive on
  /// purpose: a new method has to be put in one group or the other.
  static func needsAccount(_ method: WorkspaceProtocol.Method) -> Bool {
    switch method {
    case .systemPing, .diagnosticsRead, .eventsReplay, .hubJoin, .threadStart, .turnLookup, .accountStatus,
      .accountPasskeyBegin, .accountPasskeyFinish, .accountAppleStart, .accountAppleFinish,
      .accountCompleteProfile, .accountLogout, .accountIdentities, .accountAddPasskeyBegin,
      .accountAddPasskeyFinish, .accountRemoveIdentity, .accountDelete, .accountDismissNotice,
      .accountAppleLinkStart, .accountAppleLinkFinish:
      return false
    case .connectionList, .threadList, .draftRead, .draftSave, .eventsSnapshot, .connectionAdd,
      .connectionInspect, .connectionLogin, .threadCreate, .threadRead, .threadUpdate, .threadReconcile,
      .turnSend, .turnInterrupt, .turnAbandon, .requestRespond, .credentialAdd, .serverAdd, .serverList,
      .serverStart, .serverStatus, .serverLogs, .serverRestart, .serverStop, .serverInspect,
      .workspaceActiveWork, .workspaceStopLocalWork, .workspaceReconcile, .databaseStatus, .databaseBackup,
      .databaseRestore, .databaseImportSQLite, .hubStatus, .hubLeave, .hubPair, .hubPairStatus,
      .settingsRead, .settingsUpdate, .projectList, .projectCreate, .projectUpdate, .projectRename,
      .projectDelete, .threadMarkRead, .usageRead, .connectionUpdate, .credentialRemove, .threadDelete:
      return true
    }
  }

  private func handle(_ command: ParsedCommand) async throws -> JSONValue {
    if Self.needsAccount(command.method) {
      // `hub leave` signs out, which closes the scope and waits for the commands inside it: it runs
      // through the account manager, outside the scope's gate.
      if command.method == .hubLeave { return try JSONValue(encoding: try await context.accounts.leave()) }
      let scope = try context.accounts.scope()
      // Admitted, or `signed_out` once the scope has begun closing; the close waits for what is inside.
      try scope.enter()
      defer { scope.leave() }
      return try await handle(command, in: scope)
    }
    let events = context.eventLog
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
    case .eventsReplay:
      let params = try command.params(for: EventsReplay.self)
      guard let replayed = await events.replay(epoch: params.epoch, afterSequence: params.afterSequence)
      else {
        throw WorkspaceError(
          .snapshotRequired, "Event position is no longer replayable; fetch a snapshot.",
          details: ["epoch": .string(events.epoch), "sequence": .number(Double(await events.sequence))])
      }
      return try JSONValue(encoding: EventsReplay.Result(events: replayed))
    case .threadStart, .turnLookup:
      throw WorkspaceError(.unsupportedCapability, "Only relayed from the hub.")
    case .hubJoin:
      let params = try command.params(for: HubJoin.self)
      return try JSONValue(
        encoding: try await context.accounts.join(
          url: params.url, code: params.code, deviceName: params.deviceName ?? HubSync.defaultDeviceName()))
    case .accountStatus:
      return try JSONValue(encoding: await context.accounts.status())
    case .accountPasskeyBegin:
      return try JSONValue(encoding: try await context.accounts.passkeyBegin())
    case .accountPasskeyFinish:
      return try JSONValue(
        encoding: try await context.accounts.passkeyFinish(try command.params(for: AccountPasskeyFinish.self))
      )
    case .accountAppleStart:
      return try JSONValue(encoding: try await context.accounts.appleStart())
    case .accountAppleFinish:
      return try JSONValue(
        encoding: try await context.accounts.appleFinish(try command.params(for: AccountAppleFinish.self)))
    case .accountCompleteProfile:
      return try JSONValue(
        encoding: try await context.accounts.completeProfile(
          try command.params(for: AccountCompleteProfile.self)))
    case .accountLogout:
      let params = try command.params(for: AccountLogout.self)
      return try JSONValue(encoding: try await context.accounts.logout(stopWork: params.stopWork))
    case .accountIdentities:
      return try JSONValue(encoding: try await context.accounts.identities())
    case .accountAddPasskeyBegin:
      return try JSONValue(encoding: try await context.accounts.addPasskeyBegin())
    case .accountAddPasskeyFinish:
      return try JSONValue(
        encoding: try await context.accounts.addPasskeyFinish(
          try command.params(for: AccountAddPasskeyFinish.self)))
    case .accountRemoveIdentity:
      return try JSONValue(
        encoding: try await context.accounts.removeIdentity(
          try command.params(for: AccountRemoveIdentity.self)))
    case .accountDelete:
      return try JSONValue(encoding: try await context.accounts.deleteAccount())
    case .accountDismissNotice:
      return try JSONValue(encoding: try await context.accounts.dismissNotice())
    case .accountAppleLinkStart:
      return try JSONValue(encoding: try await context.accounts.appleLinkStart())
    case .accountAppleLinkFinish:
      return try JSONValue(
        encoding: try await context.accounts.appleLinkFinish(
          try command.params(for: AccountAppleLinkFinish.self)))
    default:
      throw WorkspaceError(.internalError, "\(command.method.rawValue) needs an account.")
    }
  }

  /// A method that reads or writes the store, on the signed-in account's scope.
  private func handle(_ command: ParsedCommand, in scope: AccountScope) async throws -> JSONValue {
    let db = scope.database
    let events = context.eventLog
    let sessions = scope.sessions
    let servers = scope.servers
    switch command.method {
    case .systemPing, .diagnosticsRead, .eventsReplay, .hubJoin, .threadStart, .turnLookup, .accountStatus,
      .accountPasskeyBegin, .accountPasskeyFinish, .accountAppleStart, .accountAppleFinish,
      .accountCompleteProfile, .accountLogout, .accountIdentities, .accountAddPasskeyBegin,
      .accountAddPasskeyFinish, .accountRemoveIdentity, .accountDelete, .accountDismissNotice,
      .accountAppleLinkStart, .accountAppleLinkFinish:
      throw WorkspaceError(.internalError, "\(command.method.rawValue) needs no account.")
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
      // A caller-chosen thread id is for `thread.start` through the relay only.
      var params = try command.params(for: ThreadCreate.self)
      params.threadId = nil
      return try JSONValue(encoding: try await sessions.threadCreate(params))
    case .threadRead:
      return try JSONValue(encoding: try await sessions.threadRead(try command.params(for: ThreadRead.self)))
    case .threadUpdate:
      return try JSONValue(
        encoding: try await sessions.threadUpdate(try command.params(for: ThreadUpdate.self)))
    case .threadMarkRead:
      return try JSONValue(
        encoding: try await sessions.threadMarkRead(try command.params(for: ThreadMarkRead.self)))
    case .projectList:
      return try JSONValue(encoding: try await scope.projects.list())
    case .projectCreate:
      return try JSONValue(
        encoding: try await scope.projects.create(try command.params(for: ProjectCreate.self)))
    case .projectUpdate:
      return try JSONValue(
        encoding: try await scope.projects.update(try command.params(for: ProjectUpdate.self)))
    case .projectRename:
      return try JSONValue(
        encoding: try await scope.projects.rename(try command.params(for: ProjectRename.self)))
    case .projectDelete:
      return try JSONValue(
        encoding: try await scope.projects.delete(try command.params(for: ProjectDelete.self)))
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
      return try JSONValue(encoding: try storeStatus(scope.database))
    case .databaseBackup:
      let params = try command.params(for: DatabaseBackup.self)
      let path = params.path ?? defaultBackupPath()
      let summary = try db.export(to: path)
      return try JSONValue(encoding: DatabaseBackup.Result(path: summary.path, rows: summary.rows))
    case .databaseRestore:
      let params = try command.params(for: DatabaseRestore.self)
      // A restore rewrites the change log and its sequence; reused deviceSeqs would count as already
      // accepted at the hub and never be mirrored.
      guard try db.hubLink() == nil else {
        throw WorkspaceError(
          .protocolInvalid,
          "This account syncs with a hub, so its store cannot be restored from a backup: the hub would "
            + "ignore the restored changes. Restore into an account that has not joined a hub.")
      }
      let summary = try db.restore(from: params.path, replace: params.replace)
      return try JSONValue(encoding: DatabaseBackup.Result(path: summary.path, rows: summary.rows))
    case .databaseImportSQLite:
      let params = try command.params(for: DatabaseImportSQLite.self)
      let summary = try SQLiteImporter.importFile(at: params.path, into: db)
      return try JSONValue(encoding: DatabaseImportSQLite.Result(rows: summary.rows))
    case .hubStatus:
      var status = try await scope.hub.status()
      status.notice = await context.accounts.notice(for: scope)
      return try JSONValue(encoding: status)
    case .hubLeave:
      throw WorkspaceError(.internalError, "hub.leave runs through the account manager.")
    case .usageRead:
      return try JSONValue(encoding: try await sessions.usageRead())
    case .threadDelete:
      return try JSONValue(
        encoding: try await sessions.threadDelete(try command.params(for: ThreadDelete.self)))
    case .credentialRemove:
      return try JSONValue(
        encoding: try await sessions.credentialRemove(try command.params(for: CredentialRemove.self)))
    case .connectionUpdate:
      return try JSONValue(
        encoding: try await sessions.connectionUpdate(try command.params(for: ConnectionUpdate.self)))
    case .hubPair:
      return try JSONValue(encoding: try await scope.hub.pair())
    case .hubPairStatus:
      return try JSONValue(encoding: await scope.hub.pairStatus())
    case .settingsRead:
      return try JSONValue(encoding: try await scope.hub.settings())
    case .settingsUpdate:
      return try JSONValue(
        encoding: try await scope.hub.updateSettings(try command.params(for: SettingsUpdate.self)))
    }
  }

  // MARK: - Store commands (M7)

  private var backupsDir: String { (context.paths.dataDir as NSString).appendingPathComponent("backups") }

  private func defaultBackupPath() -> String {
    let stamp = Timestamp.now().replacingOccurrences(of: ":", with: "-")
    return (backupsDir as NSString).appendingPathComponent("workspace-\(stamp).jsonl")
  }

  private func storeStatus(_ database: WorkspaceDatabase) throws -> DatabaseStatus.Result {
    let endpoint = database.endpoint
    return DatabaseStatus.Result(
      endpoint: "postgresql:///\(endpoint.database)?host=\(endpoint.socketDir)&port=\(endpoint.port)",
      dataDir: context.paths.postgres.dataDir, migrations: try database.appliedMigrations(),
      rows: try database.tableCounts(), unsyncedChanges: try database.unsyncedChangeCount(),
      backupsDir: backupsDir)
  }
}
