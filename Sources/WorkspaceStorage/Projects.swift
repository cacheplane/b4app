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

  /// Give the folder at `path` to another project. A project that does not exist is `protocolInvalid`.
  public func moveFolder(path: String, toProject projectId: String) throws {
    try write {
      _ = try $0.execute(
        "UPDATE \"projectFolders\" SET \"projectId\" = $2 WHERE \"path\" = $1", [path, projectId])
    }
  }

  public func removeFolder(path: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"projectFolders\" WHERE \"path\" = $1", [path]) }
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
