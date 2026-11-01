import Foundation
import WorkspaceProtocol
import WorkspaceStorage

/// Projects: the groups a thread belongs to by its working folder (design spec "Projects"). It decides
/// which project a new thread joins, derives automatic projects, runs the one-time backfill, and
/// applies the Mac's project commands. An actor, so check-then-write sequences (find a folder's
/// project, else create it) never interleave. Every change that touches a project publishes
/// `project.changed`, and every thread whose `projectId` moved publishes `thread.updated`.
///
/// A thread's folder is canonicalised only to look the project up; `threads.context` is never rewritten.
public actor ProjectService {
  private let db: WorkspaceDatabase
  private let eventLog: EventLog

  public init(database: WorkspaceDatabase, eventLog: EventLog) {
    self.db = database
    self.eventLog = eventLog
  }

  // MARK: - Resolution

  /// The canonical folder a thread's project is keyed by: a harness thread's working directory, a
  /// local B4 thread's managed server project directory (through `connection.localServerId`), and nil
  /// for a remote B4 thread or anything without a folder. A folder that no longer exists is still
  /// canonicalised (nothing here touches the disk).
  func folder(forThread thread: ConversationThread, connection: Connection) throws -> String? {
    switch connection.kind {
    case .codex, .claude:
      guard let context = thread.context, !context.isEmpty else { return nil }
      return SessionService.canonicalDirectory(context)
    case .b4:
      guard let serverId = connection.localServerId, let server = try db.localServer(id: serverId),
        !server.projectPath.isEmpty
      else { return nil }
      return SessionService.canonicalDirectory(server.projectPath)
    }
  }

  /// The project a new thread joins, created (automatic, empty name) when its folder has none; nil for a
  /// thread with no folder, which is every remote B4 thread.
  public func projectId(forThread thread: ConversationThread, connection: Connection) async throws -> String?
  {
    guard let folder = try folder(forThread: thread, connection: connection) else { return nil }
    return try await ensureProject(folder: folder).id
  }

  /// The project that owns `folder` (any spelling), creating an automatic one when none does.
  @discardableResult
  public func ensureProject(folder: String) async throws -> Project {
    let (project, created) = try ensure(folder: SessionService.canonicalDirectory(folder))
    if created { await eventLog.publish(.projectChanged(projectId: project.id)) }
    return project
  }

  private func ensure(folder canonical: String) throws -> (project: Project, created: Bool) {
    if let existing = try db.project(folderPath: canonical) { return (existing, false) }
    let project = try db.insertProject(Project(id: Self.newId()), folders: [canonical])
    return (project, true)
  }

  /// Give every thread with no project the project of its folder. Idempotent: it looks only at threads
  /// with `projectId IS NULL`, so a second run (or the next coordinator start) assigns nothing new; a
  /// remote B4 thread has no folder and stays unassigned, and is cheaply re-examined each time. Returns
  /// how many threads it assigned. It publishes nothing: it runs before any client connects.
  @discardableResult
  public func backfill() throws -> Int {
    let unassigned = try db.listThreads(ThreadFilter(includeArchived: true)).filter { $0.projectId == nil }
    guard !unassigned.isEmpty else { return 0 }
    let connections = Dictionary(
      uniqueKeysWithValues: try db.listConnections(includeDisabled: true).map { ($0.id, $0) })
    var byProject: [String: [String]] = [:]
    for thread in unassigned {
      guard let connection = connections[thread.connectionId],
        let folder = try folder(forThread: thread, connection: connection)
      else { continue }
      byProject[try ensure(folder: folder).project.id, default: []].append(thread.id)
    }
    for (projectId, threadIds) in byProject {
      try db.setThreadProject(threadIds: threadIds, projectId: projectId)
    }
    return byProject.values.reduce(0) { $0 + $1.count }
  }

  // MARK: - Commands

  public func list() throws -> ProjectList.Result {
    ProjectList.Result(projects: try db.listProjects())
  }

  public func create(_ params: ProjectCreate.Params) async throws -> ProjectCreate.Result {
    let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let folders = try validatedFolders(params.folders, into: nil)
    guard !folders.isEmpty else {
      throw WorkspaceError(.protocolInvalid, "A project needs at least one folder.")
    }
    let threadsByFolder = try threadIdsByFolder()
    let placing = folders.map { FolderPlacement(path: $0, threadIds: threadsByFolder[$0] ?? []) }
    let edit = try db.createManualProject(
      Project(id: Self.newId(), name: name, manual: true), placing: placing)
    await publish(edit, threadIds: placing.flatMap(\.threadIds))
    return ProjectCreate.Result(project: try require(edit.project))
  }

  public func update(_ params: ProjectUpdate.Params) async throws -> ProjectUpdate.Result {
    guard let project = try db.project(id: params.projectId) else {
      throw WorkspaceError(.notFound, "Project \(params.projectId) does not exist.")
    }
    // Validate every folder first; nothing changes when any of them is bad. The edit itself is one
    // transaction (folders, threads, and rename together).
    let adds = try validatedFolders(params.addFolders ?? [], into: project).filter { path in
      !project.folders.contains { $0.path == path }
    }
    var removes: [String] = []
    for raw in params.removeFolders ?? [] {
      let path = SessionService.canonicalDirectory(raw)
      guard project.folders.contains(where: { $0.path == path }) else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(raw) is not in project \(project.displayName).",
          details: ["folder": .string(raw)])
      }
      guard !adds.contains(path) else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(raw) cannot be added and removed in one update.",
          details: ["folder": .string(raw)])
      }
      if !removes.contains(path) { removes.append(path) }
    }
    if !removes.isEmpty, !project.manual, adds.isEmpty {
      throw WorkspaceError(
        .protocolInvalid,
        "Project \(project.displayName) is automatic; add a folder first or create a project instead.")
    }
    let threadsByFolder = try threadIdsByFolder()
    let placing = adds.map { FolderPlacement(path: $0, threadIds: threadsByFolder[$0] ?? []) }
    let releasing = removes.map { path -> FolderRelease in
      let threadIds = threadsByFolder[path] ?? []
      return FolderRelease(
        path: path, threadIds: threadIds, replacement: threadIds.isEmpty ? nil : Project(id: Self.newId()))
    }
    let name = params.name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let edit = try db.updateProject(
      id: project.id, name: name, placing: placing, releasing: releasing)
    await publish(edit, threadIds: placing.flatMap(\.threadIds) + releasing.flatMap(\.threadIds))
    return ProjectUpdate.Result(project: try require(edit.project))
  }

  /// The rename the phone also does. The empty string restores the folder-name display.
  public func rename(_ params: ProjectRename.Params) async throws -> ProjectRename.Result {
    let name = params.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let renamed = try db.renameProject(id: params.projectId, name: name) else {
      throw WorkspaceError(.notFound, "Project \(params.projectId) does not exist.")
    }
    await eventLog.publish(.projectChanged(projectId: renamed.id))
    return ProjectRename.Result(project: renamed)
  }

  /// Delete a manual project. Each of its folders that threads work in returns to a new automatic
  /// project, and those threads follow; folders no thread uses are dropped (they get a project again
  /// the next time a thread uses them).
  public func delete(_ params: ProjectDelete.Params) async throws -> ProjectDelete.Result {
    guard let project = try db.project(id: params.projectId) else {
      throw WorkspaceError(.notFound, "Project \(params.projectId) does not exist.")
    }
    guard project.manual else {
      throw WorkspaceError(
        .protocolInvalid,
        "Project \(project.displayName) is automatic; only manual projects can be deleted.")
    }
    let threadsByFolder = try threadIdsByFolder()
    let releasing = project.folders.compactMap { folder -> FolderRelease? in
      let threadIds = threadsByFolder[folder.path] ?? []
      return threadIds.isEmpty
        ? nil : FolderRelease(path: folder.path, threadIds: threadIds, replacement: Project(id: Self.newId()))
    }
    // Threads that pointed here with no folder behind them become unassigned; tell viewers too.
    let orphaned = try db.listThreads(ThreadFilter(includeArchived: true, projectId: project.id)).map(\.id)
    let edit = try db.deleteManualProject(id: project.id, releasing: releasing)
    await publish(edit, threadIds: orphaned + releasing.flatMap(\.threadIds))
    return ProjectDelete.Result(projectId: project.id)
  }

  // MARK: - Helpers

  private static func newId() -> String { UUID().uuidString.lowercased() }

  private func require(_ project: Project?) throws -> Project {
    guard let project else { throw WorkspaceError(.internalError, "The edited project disappeared.") }
    return project
  }

  /// Canonical, de-duplicated, existing folders. A folder another manual project owns is refused (move
  /// it by removing it there first); one an automatic project owns is fair game.
  private func validatedFolders(_ raw: [String], into target: Project?) throws -> [String] {
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
      if let owner = try db.project(folderPath: canonical), owner.manual, owner.id != target?.id {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(path) already belongs to project \(owner.displayName).",
          details: ["folder": .string(path), "projectId": .string(owner.id)])
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

  private func publish(_ edit: ProjectEditResult, threadIds: [String]) async {
    var seenProjects = Set<String>()
    for projectId in edit.changedProjectIds where seenProjects.insert(projectId).inserted {
      await eventLog.publish(.projectChanged(projectId: projectId))
    }
    var seen = Set<String>()
    for id in threadIds where seen.insert(id).inserted {
      if let thread = try? db.thread(id: id), let event = try? AdapterEvent.threadUpdated(thread) {
        await eventLog.publish(event)
      }
    }
  }
}
