import Foundation
import WorkspaceProtocol

/// Projects and their folders (migration 0004). Folder paths are `SessionService.canonicalDirectory`
/// forms, a caller's job; a path belongs to at most one project (`projectFolders."path"` is UNIQUE).
extension WorkspaceDatabase {
  private static let foldersInOrder =
    "SELECT * FROM \"projectFolders\" ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\""

  /// Every project, oldest first, each with its folders (oldest first).
  public func listProjects() throws -> [Project] {
    try read { c in
      let projects = try all(
        c, Project.self,
        "SELECT * FROM \"projects\" ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\"")
      let folders = Dictionary(
        grouping: try all(c, ProjectFolder.self, Self.foldersInOrder), by: \.projectId)
      return projects.map { project in
        var project = project
        project.folders = folders[project.id] ?? []
        return project
      }
    }
  }

  public func project(id: String) throws -> Project? {
    try read { try project(c: $0, where: "p.\"id\" = $1", [id]) }
  }

  /// The project that owns the folder `path`.
  public func project(folderPath: String) throws -> Project? {
    try read {
      try project(
        c: $0, where: "p.\"id\" = (SELECT \"projectId\" FROM \"projectFolders\" WHERE \"path\" = $1)",
        [folderPath])
    }
  }

  private func project(c: PostgresConnection, where clause: String, _ params: [String?]) throws -> Project? {
    guard var project = try one(c, Project.self, "SELECT p.* FROM \"projects\" p WHERE " + clause, params)
    else { return nil }
    project.folders = try all(
      c, ProjectFolder.self,
      "SELECT * FROM \"projectFolders\" WHERE \"projectId\" = $1 ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\"",
      [project.id])
    return project
  }

  /// Insert a project and its folders in one transaction; a folder another project already owns, or a
  /// repeated id, fails with `protocolInvalid` and inserts nothing. Folders are stamped a millisecond
  /// apart in the order given, so the first is the oldest.
  public func insertProject(_ project: Project, folders: [String]) throws -> Project {
    try write { c in
      try insert(c, "projects", project)
      let base = Date()
      var stored: [ProjectFolder] = []
      for (index, path) in folders.enumerated() {
        let folder = ProjectFolder(
          id: UUID().uuidString.lowercased(), projectId: project.id, path: path,
          createdAt: Timestamp.string(from: base.addingTimeInterval(Double(index) / 1000)))
        try insert(c, "projectFolders", folder)
        stored.append(folder)
      }
      var inserted = project
      inserted.folders = stored
      return inserted
    }
  }

  /// A Mac write to the name (bumps `projects.updatedAt`); the empty string is allowed and restores the
  /// folder-name display. Nil when there is no such project.
  public func renameProject(id: String, name: String) throws -> Project? {
    try write { c in
      let renamed = try c.execute(
        "UPDATE \"projects\" SET \"name\" = $2, \"updatedAt\" = $3 WHERE \"id\" = $1",
        [id, name, Timestamp.now()]
      ).affected
      guard renamed > 0 else { return nil }
      return try project(c: c, where: "p.\"id\" = $1", [id])
    }
  }

  /// Give the folder at `path` to another project. A project that does not exist, or a folder no
  /// project owns, is `protocolInvalid`.
  public func moveFolder(path: String, toProject projectId: String) throws {
    try write { c in
      let moved = try c.execute(
        "UPDATE \"projectFolders\" SET \"projectId\" = $2 WHERE \"path\" = $1", [path, projectId]
      ).affected
      guard moved > 0 else { throw Self.unownedFolder(path) }
    }
  }

  /// Remove the folder at `path` from whichever project owns it; a folder no project owns is
  /// `protocolInvalid`.
  public func removeFolder(path: String) throws {
    try write { c in
      let removed = try c.execute("DELETE FROM \"projectFolders\" WHERE \"path\" = $1", [path]).affected
      guard removed > 0 else { throw Self.unownedFolder(path) }
    }
  }

  private static func unownedFolder(_ path: String) -> WorkspaceError {
    WorkspaceError(
      .protocolInvalid, "Folder \(path) belongs to no project.", details: ["folder": .string(path)])
  }

  /// Delete a project. Its folders go with it and its threads become unassigned.
  public func deleteProject(id: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"projects\" WHERE \"id\" = $1", [id]) }
  }

  /// Assign threads to a project, or unassign them with nil. Does not move the threads' `updatedAt`.
  /// A project that does not exist is `protocolInvalid`.
  public func setThreadProject(threadIds: [String], projectId: String?) throws {
    guard !threadIds.isEmpty else { return }
    try write { c in
      for id in threadIds {
        _ = try c.execute(
          "UPDATE \"threads\" SET \"projectId\" = $2::text WHERE \"id\" = $1", [id, projectId])
      }
    }
  }
}

// MARK: - Edits that move folders and threads together

/// A folder to put into a project, with the threads that work in it (their `projectId` is rewritten in
/// the same transaction). A folder no project owns yet is added; one another project owns is moved.
public struct FolderPlacement: Sendable, Equatable {
  public var path: String
  public var threadIds: [String]
  public init(path: String, threadIds: [String] = []) {
    self.path = path
    self.threadIds = threadIds
  }
}

/// A folder to take out of a project. When `replacement` is given the folder goes straight into that
/// new automatic project and `threadIds` move to it; without one the folder simply leaves.
public struct FolderRelease: Sendable, Equatable {
  public var path: String
  public var threadIds: [String]
  public var replacement: Project?
  public init(path: String, threadIds: [String] = [], replacement: Project? = nil) {
    self.path = path
    self.threadIds = threadIds
    self.replacement = replacement
  }
}

/// What an edit touched, for `project.changed` events: every project it created, changed, or deleted
/// (deleted ones included in `changedProjectIds`).
public struct ProjectEditResult: Sendable, Equatable {
  public var project: Project?
  public var changedProjectIds: [String]
  public var deletedProjectIds: [String]
}

extension WorkspaceDatabase {
  /// Insert a manual project and place its folders in one transaction. See `updateProject`.
  public func createManualProject(_ project: Project, placing: [FolderPlacement]) throws -> ProjectEditResult
  {
    try write { c in
      var manual = project
      manual.manual = true
      try insert(c, "projects", manual)
      return try applyEdit(c, id: project.id, name: nil, placing: placing, releasing: [])
    }
  }

  /// Rename a project and move folders into or out of it, with the affected threads' `projectId`, in one
  /// transaction: a failure leaves everything as it was.
  ///
  /// Placing a folder makes the project manual (a person curated it) and may take the folder from
  /// another project; an automatic project left with no folders is deleted, a manual one is kept.
  /// Releasing a folder the project does not own is `protocolInvalid`. Unknown project: `notFound`.
  public func updateProject(
    id: String, name: String?, placing: [FolderPlacement], releasing: [FolderRelease]
  ) throws -> ProjectEditResult {
    try write { c in
      guard try one(c, Project.self, "SELECT * FROM \"projects\" WHERE \"id\" = $1", [id]) != nil else {
        throw WorkspaceError(.notFound, "Project \(id) does not exist.")
      }
      return try applyEdit(c, id: id, name: name, placing: placing, releasing: releasing)
    }
  }

  /// Delete a manual project (anything else is `protocolInvalid`). Each release gives a folder back to a
  /// new automatic project with the threads that use it; folders without a release are dropped.
  public func deleteManualProject(id: String, releasing: [FolderRelease]) throws -> ProjectEditResult {
    try write { c in
      guard let project = try one(c, Project.self, "SELECT * FROM \"projects\" WHERE \"id\" = $1", [id])
      else { throw WorkspaceError(.notFound, "Project \(id) does not exist.") }
      guard project.manual else {
        throw WorkspaceError(
          .protocolInvalid, "Project \(id) is automatic; only manual projects can be deleted.")
      }
      // The project's folders go with it (cascade) and its threads become unassigned, which frees each
      // released folder's unique path for its replacement.
      try c.execute("DELETE FROM \"projects\" WHERE \"id\" = $1", [id])
      var changed = [id]
      for release in releasing {
        guard let replacement = release.replacement else { continue }
        try placeReplacement(c, replacement, release)
        changed.append(replacement.id)
      }
      return ProjectEditResult(project: nil, changedProjectIds: changed, deletedProjectIds: [id])
    }
  }

  private func applyEdit(
    _ c: PostgresConnection, id: String, name: String?, placing: [FolderPlacement],
    releasing: [FolderRelease]
  ) throws -> ProjectEditResult {
    var changed: [String] = [id]
    var deleted: [String] = []
    var touched = false
    if let name {
      try c.execute("UPDATE \"projects\" SET \"name\" = $2 WHERE \"id\" = $1", [id, name])
      touched = true
    }
    var previousOwners: [String] = []
    for placement in placing {
      let owner = try one(
        c, ProjectFolder.self, "SELECT * FROM \"projectFolders\" WHERE \"path\" = $1 FOR UPDATE",
        [placement.path])
      if let owner {
        guard owner.projectId != id else { continue }
        try c.execute(
          "UPDATE \"projectFolders\" SET \"projectId\" = $2 WHERE \"path\" = $1", [placement.path, id])
        if !previousOwners.contains(owner.projectId) { previousOwners.append(owner.projectId) }
      } else {
        try insert(
          c, "projectFolders",
          ProjectFolder(id: UUID().uuidString.lowercased(), projectId: id, path: placement.path))
      }
      try assign(c, threadIds: placement.threadIds, to: id)
      touched = true
    }
    for release in releasing {
      let removed = try c.execute(
        "DELETE FROM \"projectFolders\" WHERE \"path\" = $1 AND \"projectId\" = $2", [release.path, id]
      ).affected
      guard removed > 0 else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(release.path) is not in project \(id).",
          details: ["folder": .string(release.path)])
      }
      touched = true
      if let replacement = release.replacement {
        try placeReplacement(c, replacement, release)
        changed.append(replacement.id)
      }
    }
    if touched {
      // Placing a folder is a deliberate act: an automatic project that gains one stays for good.
      let manualSQL = placing.isEmpty ? "" : ", \"manual\" = true"
      try c.execute(
        "UPDATE \"projects\" SET \"updatedAt\" = $2\(manualSQL) WHERE \"id\" = $1", [id, Timestamp.now()])
    }
    for owner in previousOwners {
      changed.append(owner)
      let remaining = try c.execute(
        "SELECT 1 FROM \"projectFolders\" WHERE \"projectId\" = $1 LIMIT 1", [owner]
      ).rows.count
      let manual = try one(c, Project.self, "SELECT * FROM \"projects\" WHERE \"id\" = $1", [owner])?.manual
      if remaining == 0, manual == false {
        try c.execute("DELETE FROM \"projects\" WHERE \"id\" = $1", [owner])
        deleted.append(owner)
      } else {
        try c.execute(
          "UPDATE \"projects\" SET \"updatedAt\" = $2 WHERE \"id\" = $1", [owner, Timestamp.now()])
      }
    }
    return ProjectEditResult(
      project: try project(c: c, where: "p.\"id\" = $1", [id]), changedProjectIds: changed,
      deletedProjectIds: deleted)
  }

  private func placeReplacement(
    _ c: PostgresConnection, _ replacement: Project, _ release: FolderRelease
  ) throws {
    var automatic = replacement
    automatic.manual = false
    try insert(c, "projects", automatic)
    try insert(
      c, "projectFolders",
      ProjectFolder(id: UUID().uuidString.lowercased(), projectId: replacement.id, path: release.path))
    try assign(c, threadIds: release.threadIds, to: replacement.id)
  }

  private func assign(_ c: PostgresConnection, threadIds: [String], to projectId: String) throws {
    for threadId in threadIds {
      try c.execute("UPDATE \"threads\" SET \"projectId\" = $2 WHERE \"id\" = $1", [threadId, projectId])
    }
  }
}

// MARK: - Connections and settings (migration 0005)

extension WorkspaceDatabase {
  /// Set (or with nil clear) the project a local B4 connection serves. The change log records it as an
  /// update of `projectId` alone, and does not move `updatedAt`. A project that does not exist is
  /// `protocolInvalid`; a connection that does not exist changes nothing.
  public func setConnectionProject(id: String, projectId: String?) throws {
    try write { c in
      _ = try c.execute(
        "UPDATE \"connections\" SET \"projectId\" = $2::text WHERE \"id\" = $1", [id, projectId])
    }
  }

  /// This Mac's own setting `key`, nil when it was never set. Settings are never synced and never in the
  /// change log.
  public func settings(key: String) throws -> JSONValue? {
    try read { c in
      guard
        let text = try c.execute(
          "SELECT \"value\"::text AS \"value\" FROM \"settings\" WHERE \"key\" = $1", [key]
        )
        .rows.first?.text("value")
      else { return nil }
      return try JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
    }
  }

  /// Store (replace) the setting `key`.
  public func setSetting(key: String, value: JSONValue) throws {
    let json = String(decoding: try JSONCoding.encoder.encode(value), as: UTF8.self)
    try write { c in
      _ = try c.execute(
        """
        INSERT INTO "settings" ("key", "value") VALUES ($1, $2::jsonb)
        ON CONFLICT ("key") DO UPDATE SET "value" = EXCLUDED."value"
        """, [key, json])
    }
  }
}
