import Foundation

/// A folder the app made for a thread started with no folder (migration 0012). Local to this Mac.
public struct AppFolder: Sendable, Equatable, Codable {
  public var path: String
  public var threadId: String
  public var createdAt: String

  public init(path: String, threadId: String, createdAt: String) {
    self.path = path
    self.threadId = threadId
    self.createdAt = createdAt
  }
}

/// The record of folders the app made (migration 0012). Not in the change log: no trigger, never
/// synced. It has no foreign key to `threads`, because the record is written before the thread row
/// and outlives a deleted thread.
extension WorkspaceDatabase {
  public func insertAppFolder(_ folder: AppFolder) throws {
    try write {
      _ = try $0.execute(
        "INSERT INTO \"appFolders\" (\"path\", \"threadId\", \"createdAt\") VALUES ($1, $2, $3)",
        [folder.path, folder.threadId, folder.createdAt])
    }
  }

  public func appFolder(path: String) throws -> AppFolder? {
    try appFolders(where: "\"path\" = $1", path)
  }

  public func appFolder(threadId: String) throws -> AppFolder? {
    try appFolders(where: "\"threadId\" = $1", threadId)
  }

  public func deleteAppFolder(path: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"appFolders\" WHERE \"path\" = $1", [path]) }
  }

  public func listAppFolders() throws -> [AppFolder] {
    try read {
      try $0.execute("SELECT * FROM \"appFolders\" ORDER BY \"createdAt\", \"path\"").rows.compactMap(
        Self.appFolder)
    }
  }

  private func appFolders(where clause: String, _ value: String) throws -> AppFolder? {
    try read {
      try $0.execute("SELECT * FROM \"appFolders\" WHERE \(clause)", [value]).rows.first.flatMap(
        Self.appFolder)
    }
  }

  private static func appFolder(_ row: Row) -> AppFolder? {
    guard let path = row.text("path"), let threadId = row.text("threadId"),
      let createdAt = row.text("createdAt")
    else { return nil }
    return AppFolder(path: path, threadId: threadId, createdAt: createdAt)
  }
}
