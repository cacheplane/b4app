import Foundation
import WorkspaceProtocol

/// Environments and their folders (migration 0004). Folder paths are `SessionService.canonicalDirectory`
/// forms, a caller's job; a path belongs to at most one environment (`environmentFolders."path"` is UNIQUE).
extension WorkspaceDatabase {
  private static let foldersInOrder =
    "SELECT * FROM \"environmentFolders\" ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\""

  /// Every environment, oldest first, each with its folders (oldest first).
  public func listEnvironments() throws -> [WorkEnvironment] {
    try read { c in
      let environments = try all(
        c, WorkEnvironment.self,
        "SELECT * FROM \"environments\" ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\"")
      let folders = Dictionary(
        grouping: try all(c, EnvironmentFolder.self, Self.foldersInOrder), by: \.environmentId)
      return environments.map { environment in
        var environment = environment
        environment.folders = folders[environment.id] ?? []
        return environment
      }
    }
  }

  public func environment(id: String) throws -> WorkEnvironment? {
    try read { try environment(c: $0, where: "p.\"id\" = $1", [id]) }
  }

  /// The environment that owns the folder `path`.
  public func environment(folderPath: String) throws -> WorkEnvironment? {
    try read {
      try environment(
        c: $0, where: "p.\"id\" = (SELECT \"environmentId\" FROM \"environmentFolders\" WHERE \"path\" = $1)",
        [folderPath])
    }
  }

  private func environment(
    c: PostgresConnection, where clause: String, _ params: [String?]
  ) throws -> WorkEnvironment? {
    guard
      var environment = try one(
        c, WorkEnvironment.self, "SELECT p.* FROM \"environments\" p WHERE " + clause, params)
    else { return nil }
    environment.folders = try all(
      c, EnvironmentFolder.self,
      "SELECT * FROM \"environmentFolders\" WHERE \"environmentId\" = $1 ORDER BY \"createdAt\" COLLATE \"C\", \"id\" COLLATE \"C\"",
      [environment.id])
    return environment
  }

  /// Insert an environment and its folders in one transaction; a folder another environment already owns, or a
  /// repeated id, fails with `protocolInvalid` and inserts nothing. Folders are stamped a millisecond
  /// apart in the order given, so the first is the oldest.
  public func insertEnvironment(_ environment: WorkEnvironment, folders: [String]) throws -> WorkEnvironment {
    try write { c in
      try insert(c, "environments", environment)
      let base = Date()
      var stored: [EnvironmentFolder] = []
      for (index, path) in folders.enumerated() {
        let folder = EnvironmentFolder(
          id: UUID().uuidString.lowercased(), environmentId: environment.id, path: path,
          createdAt: Timestamp.string(from: base.addingTimeInterval(Double(index) / 1000)))
        try insert(c, "environmentFolders", folder)
        stored.append(folder)
      }
      var inserted = environment
      inserted.folders = stored
      return inserted
    }
  }

  /// A Mac write to the name (bumps `environments.updatedAt`); the empty string is allowed and restores the
  /// folder-name display. Nil when there is no such environment.
  public func renameEnvironment(id: String, name: String) throws -> WorkEnvironment? {
    try write { c in
      let renamed = try c.execute(
        "UPDATE \"environments\" SET \"name\" = $2, \"updatedAt\" = $3 WHERE \"id\" = $1",
        [id, name, Timestamp.now()]
      ).affected
      guard renamed > 0 else { return nil }
      return try environment(c: c, where: "p.\"id\" = $1", [id])
    }
  }

  /// Give the folder at `path` to another environment. An environment that does not exist, or a folder no
  /// environment owns, is `protocolInvalid`.
  public func moveFolder(path: String, toEnvironment environmentId: String) throws {
    try write { c in
      let moved = try c.execute(
        "UPDATE \"environmentFolders\" SET \"environmentId\" = $2 WHERE \"path\" = $1", [path, environmentId]
      ).affected
      guard moved > 0 else { throw Self.unownedFolder(path) }
    }
  }

  /// Remove the folder at `path` from whichever environment owns it; a folder no environment owns is
  /// `protocolInvalid`.
  public func removeFolder(path: String) throws {
    try write { c in
      let removed = try c.execute("DELETE FROM \"environmentFolders\" WHERE \"path\" = $1", [path]).affected
      guard removed > 0 else { throw Self.unownedFolder(path) }
    }
  }

  private static func unownedFolder(_ path: String) -> WorkspaceError {
    WorkspaceError(
      .protocolInvalid, "Folder \(path) belongs to no environment.", details: ["folder": .string(path)])
  }

  /// Delete an environment. Its folders go with it and its threads become unassigned.
  public func deleteEnvironment(id: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"environments\" WHERE \"id\" = $1", [id]) }
  }

  /// Assign threads to an environment, or unassign them with nil. Does not move the threads' `updatedAt`.
  /// An environment that does not exist is `protocolInvalid`.
  public func setThreadEnvironment(threadIds: [String], environmentId: String?) throws {
    guard !threadIds.isEmpty else { return }
    try write { c in
      for id in threadIds {
        _ = try c.execute(
          "UPDATE \"threads\" SET \"environmentId\" = $2::text WHERE \"id\" = $1", [id, environmentId])
      }
    }
  }
}

// MARK: - Edits that move folders and threads together

/// A folder to put into an environment, with the threads that work in it (their `environmentId` is rewritten in
/// the same transaction). A folder no environment owns yet is added; one another environment owns is moved.
public struct FolderPlacement: Sendable, Equatable {
  public var path: String
  public var threadIds: [String]
  public init(path: String, threadIds: [String] = []) {
    self.path = path
    self.threadIds = threadIds
  }
}

/// A folder to take out of an environment. When `replacement` is given the folder goes straight into that
/// new automatic environment and `threadIds` move to it; without one the folder simply leaves.
public struct FolderRelease: Sendable, Equatable {
  public var path: String
  public var threadIds: [String]
  public var replacement: WorkEnvironment?
  public init(path: String, threadIds: [String] = [], replacement: WorkEnvironment? = nil) {
    self.path = path
    self.threadIds = threadIds
    self.replacement = replacement
  }
}

/// What an edit touched, for `environment.changed` events: every environment it created, changed, or deleted
/// (deleted ones included in `changedEnvironmentIds`).
public struct EnvironmentEditResult: Sendable, Equatable {
  public var environment: WorkEnvironment?
  public var changedEnvironmentIds: [String]
  public var deletedEnvironmentIds: [String]
}

extension WorkspaceDatabase {
  /// Insert a manual environment and place its folders in one transaction. See `updateEnvironment`.
  public func createManualEnvironment(
    _ environment: WorkEnvironment, placing: [FolderPlacement]
  ) throws -> EnvironmentEditResult {
    try write { c in
      var manual = environment
      manual.manual = true
      try insert(c, "environments", manual)
      return try applyEdit(c, id: environment.id, name: nil, placing: placing, releasing: [])
    }
  }

  /// Rename an environment and move folders into or out of it, with the affected threads' `environmentId`, in one
  /// transaction: a failure leaves everything as it was.
  ///
  /// Placing a folder makes the environment manual (a person curated it) and may take the folder from
  /// another environment; an automatic environment left with no folders is deleted, a manual one is kept.
  /// Releasing a folder the environment does not own is `protocolInvalid`. Unknown environment: `notFound`.
  public func updateEnvironment(
    id: String, name: String?, placing: [FolderPlacement], releasing: [FolderRelease]
  ) throws -> EnvironmentEditResult {
    try write { c in
      guard try one(c, WorkEnvironment.self, "SELECT * FROM \"environments\" WHERE \"id\" = $1", [id]) != nil
      else {
        throw WorkspaceError(.notFound, "Environment \(id) does not exist.")
      }
      return try applyEdit(c, id: id, name: name, placing: placing, releasing: releasing)
    }
  }

  /// Delete a manual environment (anything else is `protocolInvalid`). Each release gives a folder back to a
  /// new automatic environment with the threads that use it; folders without a release are dropped.
  public func deleteManualEnvironment(id: String, releasing: [FolderRelease]) throws -> EnvironmentEditResult
  {
    try write { c in
      guard
        let environment = try one(
          c, WorkEnvironment.self, "SELECT * FROM \"environments\" WHERE \"id\" = $1", [id])
      else { throw WorkspaceError(.notFound, "Environment \(id) does not exist.") }
      guard environment.manual else {
        throw WorkspaceError(
          .protocolInvalid, "Environment \(id) is automatic; only manual environments can be deleted.")
      }
      // The environment's folders go with it (cascade) and its threads become unassigned, which frees each
      // released folder's unique path for its replacement.
      try c.execute("DELETE FROM \"environments\" WHERE \"id\" = $1", [id])
      var changed = [id]
      for release in releasing {
        guard let replacement = release.replacement else { continue }
        try placeReplacement(c, replacement, release)
        changed.append(replacement.id)
      }
      return EnvironmentEditResult(
        environment: nil, changedEnvironmentIds: changed, deletedEnvironmentIds: [id])
    }
  }

  private func applyEdit(
    _ c: PostgresConnection, id: String, name: String?, placing: [FolderPlacement],
    releasing: [FolderRelease]
  ) throws -> EnvironmentEditResult {
    var changed: [String] = [id]
    var deleted: [String] = []
    var touched = false
    if let name {
      try c.execute("UPDATE \"environments\" SET \"name\" = $2 WHERE \"id\" = $1", [id, name])
      touched = true
    }
    var previousOwners: [String] = []
    for placement in placing {
      let owner = try one(
        c, EnvironmentFolder.self, "SELECT * FROM \"environmentFolders\" WHERE \"path\" = $1 FOR UPDATE",
        [placement.path])
      if let owner {
        guard owner.environmentId != id else { continue }
        try c.execute(
          "UPDATE \"environmentFolders\" SET \"environmentId\" = $2 WHERE \"path\" = $1",
          [placement.path, id])
        if !previousOwners.contains(owner.environmentId) { previousOwners.append(owner.environmentId) }
      } else {
        try insert(
          c, "environmentFolders",
          EnvironmentFolder(id: UUID().uuidString.lowercased(), environmentId: id, path: placement.path))
      }
      try assign(c, threadIds: placement.threadIds, to: id)
      touched = true
    }
    for release in releasing {
      let removed = try c.execute(
        "DELETE FROM \"environmentFolders\" WHERE \"path\" = $1 AND \"environmentId\" = $2",
        [release.path, id]
      ).affected
      guard removed > 0 else {
        throw WorkspaceError(
          .protocolInvalid, "Folder \(release.path) is not in environment \(id).",
          details: ["folder": .string(release.path)])
      }
      touched = true
      if let replacement = release.replacement {
        try placeReplacement(c, replacement, release)
        changed.append(replacement.id)
      }
    }
    if touched {
      // Placing a folder is a deliberate act: an automatic environment that gains one stays for good.
      let manualSQL = placing.isEmpty ? "" : ", \"manual\" = true"
      try c.execute(
        "UPDATE \"environments\" SET \"updatedAt\" = $2\(manualSQL) WHERE \"id\" = $1", [id, Timestamp.now()])
    }
    for owner in previousOwners {
      changed.append(owner)
      let remaining = try c.execute(
        "SELECT 1 FROM \"environmentFolders\" WHERE \"environmentId\" = $1 LIMIT 1", [owner]
      ).rows.count
      let manual = try one(
        c, WorkEnvironment.self, "SELECT * FROM \"environments\" WHERE \"id\" = $1", [owner])?
        .manual
      if remaining == 0, manual == false {
        try c.execute("DELETE FROM \"environments\" WHERE \"id\" = $1", [owner])
        deleted.append(owner)
      } else {
        try c.execute(
          "UPDATE \"environments\" SET \"updatedAt\" = $2 WHERE \"id\" = $1", [owner, Timestamp.now()])
      }
    }
    return EnvironmentEditResult(
      environment: try environment(c: c, where: "p.\"id\" = $1", [id]), changedEnvironmentIds: changed,
      deletedEnvironmentIds: deleted)
  }

  private func placeReplacement(
    _ c: PostgresConnection, _ replacement: WorkEnvironment, _ release: FolderRelease
  ) throws {
    var automatic = replacement
    automatic.manual = false
    try insert(c, "environments", automatic)
    try insert(
      c, "environmentFolders",
      EnvironmentFolder(id: UUID().uuidString.lowercased(), environmentId: replacement.id, path: release.path)
    )
    try assign(c, threadIds: release.threadIds, to: replacement.id)
  }

  private func assign(_ c: PostgresConnection, threadIds: [String], to environmentId: String) throws {
    for threadId in threadIds {
      try c.execute(
        "UPDATE \"threads\" SET \"environmentId\" = $2 WHERE \"id\" = $1", [threadId, environmentId])
    }
  }
}

// MARK: - Connections and settings (migration 0005)

extension WorkspaceDatabase {
  /// Set (or with nil clear) the environment a local B4 connection serves. The change log records it as an
  /// update of `environmentId` alone, and does not move `updatedAt`. An environment that does not exist is
  /// `protocolInvalid`; a connection that does not exist changes nothing.
  public func setConnectionEnvironment(id: String, environmentId: String?) throws {
    try write { c in
      _ = try c.execute(
        "UPDATE \"connections\" SET \"environmentId\" = $2::text WHERE \"id\" = $1", [id, environmentId])
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
