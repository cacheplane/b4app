import Foundation
import WorkspaceProtocol
import WorkspaceStorage

/// Environments: the groups a thread belongs to by its working folder (design spec "Environments"). It decides
/// which environment a new thread joins, derives automatic environments, runs the one-time backfill, and
/// applies the Mac's environment commands. An actor, so check-then-write sequences (find a folder's
/// environment, else create it) never interleave. Every change that touches an environment publishes
/// `environment.changed`, and every thread whose `environmentId` moved publishes `thread.updated`.
///
/// A thread's folder is canonicalised only to look the environment up; `threads.context` is never rewritten.
public actor EnvironmentService {
  private let db: WorkspaceDatabase
  private let eventLog: EventLog

  public init(database: WorkspaceDatabase, eventLog: EventLog) {
    self.db = database
    self.eventLog = eventLog
  }

  // MARK: - Resolution

  /// The canonical folder a thread's environment is keyed by: a harness thread's working directory, a
  /// local B4 thread's managed server environment directory (through `connection.localServerId`), and nil
  /// for a remote B4 thread or anything without a folder. A folder that no longer exists is still
  /// canonicalised (nothing here touches the disk).
  func folder(forThread thread: ConversationThread, connection: Connection) throws -> String? {
    switch connection.kind {
    case .codex, .claude:
      guard let context = thread.context, !context.isEmpty else { return nil }
      return SessionService.canonicalDirectory(context)
    case .b4:
      return try serverFolder(of: connection)
    }
  }

  /// The canonical environment directory of the managed server a local B4 connection runs on; nil for any
  /// other connection, or when the server row is gone.
  func serverFolder(of connection: Connection) throws -> String? {
    guard connection.kind == .b4, let serverId = connection.localServerId,
      let server = try db.localServer(id: serverId), !server.projectPath.isEmpty
    else { return nil }
    return SessionService.canonicalDirectory(server.projectPath)
  }

  /// The environment a local B4 connection serves: the environment of its managed server's folder, created
  /// (automatic, empty name) when none owns it. Nil for a Codex or Claude connection, a remote or
  /// attached B4 connection, and one whose server is gone.
  public func environmentId(forConnection connection: Connection) async throws -> String? {
    guard let folder = try serverFolder(of: connection) else { return nil }
    return try await ensureEnvironment(folder: folder).id
  }

  /// The environment a new thread joins, created (automatic, empty name) when its folder has none; nil for a
  /// thread with no folder, which is every remote B4 thread.
  public func environmentId(
    forThread thread: ConversationThread, connection: Connection
  ) async throws -> String? {
    guard let folder = try folder(forThread: thread, connection: connection) else { return nil }
    return try await ensureEnvironment(folder: folder).id
  }

  /// Insert a new thread in the environment of its folder (created automatically when none owns it) and return
  /// it with `environmentId` set. Resolving the environment and inserting the row happen in one section with no
  /// suspension point, so (actor isolation) no environment command can run between them: the environment cannot
  /// be emptied and deleted under the insert, and a folder move cannot miss the not-yet-inserted
  /// thread. Events are published only after the row is committed.
  public func insertThread(
    _ thread: ConversationThread, connection: Connection
  ) async throws
    -> ConversationThread
  {
    let (inserted, createdEnvironment) = try insertResolving(thread, connection: connection)
    if let createdEnvironment {
      await eventLog.publish(.environmentChanged(environmentId: createdEnvironment.id))
    }
    return inserted
  }

  /// Synchronous on purpose: see `insertThread`.
  private func insertResolving(
    _ thread: ConversationThread, connection: Connection
  ) throws
    -> (thread: ConversationThread, createdEnvironment: WorkEnvironment?)
  {
    var thread = thread
    var created: WorkEnvironment?
    if let folder = try folder(forThread: thread, connection: connection) {
      let (environment, wasCreated) = try ensure(folder: folder)
      thread.environmentId = environment.id
      if wasCreated { created = environment }
    }
    return (try db.insertThread(thread), created)
  }

  /// The environment that owns `folder` (any spelling), creating an automatic one when none does.
  @discardableResult
  public func ensureEnvironment(folder: String) async throws -> WorkEnvironment {
    let (environment, created) = try ensure(folder: SessionService.canonicalDirectory(folder))
    if created { await eventLog.publish(.environmentChanged(environmentId: environment.id)) }
    return environment
  }

  private func ensure(folder canonical: String) throws -> (environment: WorkEnvironment, created: Bool) {
    if let existing = try db.environment(folderPath: canonical) { return (existing, false) }
    let environment = try db.insertEnvironment(WorkEnvironment(id: Self.newId()), folders: [canonical])
    return (environment, true)
  }

  /// Give every thread with no environment the environment of its folder. Idempotent: it looks only at threads
  /// with `environmentId IS NULL`, so a second run (or the next coordinator start) assigns nothing new; a
  /// remote B4 thread has no folder and stays unassigned, and is cheaply re-examined each time. Returns
  /// how many threads it assigned. It publishes nothing: it runs before any client connects.
  @discardableResult
  public func backfill() throws -> Int {
    let unassigned = try db.listThreads(ThreadFilter(includeArchived: true)).filter {
      $0.environmentId == nil
    }
    guard !unassigned.isEmpty else { return 0 }
    let connections = Dictionary(
      uniqueKeysWithValues: try db.listConnections(includeDisabled: true).map { ($0.id, $0) })
    var byEnvironment: [String: [String]] = [:]
    for thread in unassigned {
      guard let connection = connections[thread.connectionId],
        let folder = try folder(forThread: thread, connection: connection)
      else { continue }
      byEnvironment[try ensure(folder: folder).environment.id, default: []].append(thread.id)
    }
    for (environmentId, threadIds) in byEnvironment {
      try db.setThreadEnvironment(threadIds: threadIds, environmentId: environmentId)
    }
    return byEnvironment.values.reduce(0) { $0 + $1.count }
  }

  /// Give every local B4 connection with no environment the environment of its server's folder, once after
  /// migration 0005. Idempotent like `backfill()`: it looks only at connections with
  /// `environmentId IS NULL`, and a connection with no server folder stays unassigned. The writes land in
  /// the change log (the hub has not heard of the column yet). Returns how many it assigned.
  @discardableResult
  public func backfillConnections() async throws -> Int {
    try await alignConnections(onlyUnassigned: true)
  }

  /// Point every local B4 connection at the environment that now owns its server's folder; returns how many
  /// moved. Called after any edit that moves folders, since a folder's move or an environment's deletion can
  /// change which environment a connection's folder is in.
  @discardableResult
  private func alignConnections(onlyUnassigned: Bool = false) async throws -> Int {
    var moved = 0
    for connection in try db.listConnections(includeDisabled: true)
    where connection.kind == .b4 && connection.localServerId != nil
      && (!onlyUnassigned || connection.environmentId == nil)
    {
      guard let environmentId = try await environmentId(forConnection: connection),
        environmentId != connection.environmentId
      else { continue }
      try db.setConnectionEnvironment(id: connection.id, environmentId: environmentId)
      moved += 1
    }
    return moved
  }

  // MARK: - Commands

  public func list() throws -> EnvironmentList.Result {
    EnvironmentList.Result(environments: try db.listEnvironments())
  }

  /// A create that names its `environmentId` (the phone's, over the relay) runs once: when that manual
  /// environment exists already, it is the answer, as it stands, so a resend after a lost reply makes no
  /// second environment.
  public func create(_ params: EnvironmentCreate.Params) async throws -> EnvironmentCreate.Result {
    let id = try params.environmentId.map { id in
      guard SessionService.isLowercaseUUID(id) else {
        throw WorkspaceError(
          .protocolInvalid, "The new environment's id is not valid.",
          details: ["reason": "invalid_environment_id"])
      }
      return id
    }
    if let id, let existing = try db.environment(id: id) {
      guard existing.manual else {
        throw WorkspaceError(
          .protocolInvalid, "Environment \(id) already exists.", details: ["reason": "operation_reused"])
      }
      return EnvironmentCreate.Result(environment: existing)
    }
    let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let folders = try validatedFolders(params.folders, into: nil)
    guard !folders.isEmpty else {
      throw WorkspaceError(.protocolInvalid, "An environment needs at least one folder.")
    }
    let threadsByFolder = try threadIdsByFolder()
    let placing = folders.map { FolderPlacement(path: $0, threadIds: threadsByFolder[$0] ?? []) }
    let edit = try db.createManualEnvironment(
      WorkEnvironment(id: id ?? Self.newId(), name: name, manual: true), placing: placing)
    try await alignConnections()
    await publish(edit, threadIds: placing.flatMap(\.threadIds))
    return EnvironmentCreate.Result(environment: try require(edit.environment))
  }

  public func update(_ params: EnvironmentUpdate.Params) async throws -> EnvironmentUpdate.Result {
    guard let environment = try db.environment(id: params.environmentId) else {
      throw WorkspaceError(.notFound, "Environment \(params.environmentId) does not exist.")
    }
    // Validate every folder first; nothing changes when any of them is bad. The edit itself is one
    // transaction (folders, threads, and rename together).
    let adds = try validatedFolders(params.addFolders ?? [], into: environment).filter { path in
      !environment.folders.contains { $0.path == path }
    }
    var removes: [String] = []
    for raw in params.removeFolders ?? [] {
      let path = SessionService.canonicalDirectory(raw)
      guard environment.folders.contains(where: { $0.path == path }) else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(raw) is not in environment \(environment.displayName).",
          details: ["folder": .string(raw)])
      }
      guard !adds.contains(path) else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(raw) cannot be added and removed in one update.",
          details: ["folder": .string(raw)])
      }
      if !removes.contains(path) { removes.append(path) }
    }
    if !removes.isEmpty, !environment.manual, adds.isEmpty {
      throw WorkspaceError(
        .protocolInvalid,
        "Environment \(environment.displayName) is automatic; add a folder first or create an environment instead."
      )
    }
    let threadsByFolder = try threadIdsByFolder()
    let placing = adds.map { FolderPlacement(path: $0, threadIds: threadsByFolder[$0] ?? []) }
    let releasing = removes.map { path -> FolderRelease in
      let threadIds = threadsByFolder[path] ?? []
      return FolderRelease(
        path: path, threadIds: threadIds,
        replacement: threadIds.isEmpty ? nil : WorkEnvironment(id: Self.newId()))
    }
    let name = params.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let edit = try db.updateEnvironment(
      id: environment.id, name: name, placing: placing, releasing: releasing)
    try await alignConnections()
    await publish(edit, threadIds: placing.flatMap(\.threadIds) + releasing.flatMap(\.threadIds))
    return EnvironmentUpdate.Result(environment: try require(edit.environment))
  }

  /// The rename the phone also does. The empty string restores the folder-name display.
  public func rename(_ params: EnvironmentRename.Params) async throws -> EnvironmentRename.Result {
    let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let renamed = try db.renameEnvironment(id: params.environmentId, name: name) else {
      throw WorkspaceError(.notFound, "Environment \(params.environmentId) does not exist.")
    }
    await eventLog.publish(.environmentChanged(environmentId: renamed.id))
    return EnvironmentRename.Result(environment: renamed)
  }

  /// Delete a manual environment. Each of its folders that threads work in returns to a new automatic
  /// environment, and those threads follow; folders no thread uses are dropped (they get an environment again
  /// the next time a thread uses them).
  public func delete(_ params: EnvironmentDelete.Params) async throws -> EnvironmentDelete.Result {
    guard let environment = try db.environment(id: params.environmentId) else {
      throw WorkspaceError(.notFound, "Environment \(params.environmentId) does not exist.")
    }
    guard environment.manual else {
      throw WorkspaceError(
        .protocolInvalid,
        "Environment \(environment.displayName) is automatic; only manual environments can be deleted.")
    }
    let threadsByFolder = try threadIdsByFolder()
    let releasing = environment.folders.compactMap { folder -> FolderRelease? in
      let threadIds = threadsByFolder[folder.path] ?? []
      return threadIds.isEmpty
        ? nil
        : FolderRelease(
          path: folder.path, threadIds: threadIds, replacement: WorkEnvironment(id: Self.newId()))
    }
    // Threads that pointed here with no folder behind them become unassigned; tell viewers too.
    let orphaned = try db.listThreads(ThreadFilter(includeArchived: true, environmentId: environment.id)).map(
      \.id)
    let edit = try db.deleteManualEnvironment(id: environment.id, releasing: releasing)
    try await alignConnections()
    await publish(edit, threadIds: orphaned + releasing.flatMap(\.threadIds))
    return EnvironmentDelete.Result(environmentId: environment.id)
  }

  // MARK: - Helpers

  private static func newId() -> String { UUID().uuidString.lowercased() }

  private func require(_ environment: WorkEnvironment?) throws -> WorkEnvironment {
    guard let environment else { throw WorkspaceError(.internalError, "The edited environment disappeared.") }
    return environment
  }

  /// Canonical, de-duplicated, existing folders. A folder another manual environment owns is refused (move
  /// it by removing it there first); one an automatic environment owns is fair game.
  private func validatedFolders(_ raw: [String], into target: WorkEnvironment?) throws -> [String] {
    var folders: [String] = []
    for path in raw {
      guard !path.isEmpty else { throw WorkspaceError(.protocolInvalid, "A folder path must not be empty.") }
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(
          atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(path) does not exist.", details: ["folder": .string(path)])
      }
      let canonical = SessionService.canonicalDirectory(path)
      if let owner = try db.environment(folderPath: canonical), owner.manual, owner.id != target?.id {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(path) already belongs to environment \(owner.displayName).",
          details: ["folder": .string(path), "environmentId": .string(owner.id)])
      }
      if !folders.contains(canonical) { folders.append(canonical) }
    }
    return folders
  }

  /// Thread ids by the canonical folder they work in, archived threads included.
  private func threadIdsByFolder() throws -> [String: [String]] {
    let connections = Dictionary(
      uniqueKeysWithValues: try db.listConnections(includeDisabled: true).map { ($0.id, $0) })
    var result: [String: [String]] = [:]
    for thread in try db.listThreads(ThreadFilter(includeArchived: true)) {
      guard let connection = connections[thread.connectionId],
        let folder = try folder(forThread: thread, connection: connection)
      else { continue }
      result[folder, default: []].append(thread.id)
    }
    return result
  }

  private func publish(_ edit: EnvironmentEditResult, threadIds: [String]) async {
    var seenEnvironments = Set<String>()
    for environmentId in edit.changedEnvironmentIds where seenEnvironments.insert(environmentId).inserted {
      await eventLog.publish(.environmentChanged(environmentId: environmentId))
    }
    var seen = Set<String>()
    for id in threadIds where seen.insert(id).inserted {
      if let thread = try? db.thread(id: id), let event = try? AdapterEvent.threadUpdated(thread) {
        await eventLog.publish(event)
      }
    }
  }
}
