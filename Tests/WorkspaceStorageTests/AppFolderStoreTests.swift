import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite struct AppFolderStoreTests {
  private let folder = AppFolder(path: "/p/one", threadId: "t1", createdAt: "2026-11-10T00:00:00Z")

  @Test func anAppFolderIsFoundByPathAndByThread() throws {
    let db = try WorkspaceDatabase.temporary()
    try db.insertAppFolder(folder)
    #expect(try db.appFolder(path: "/p/one") == folder)
    #expect(try db.appFolder(threadId: "t1") == folder)
    #expect(try db.appFolder(path: "/p/none") == nil)
    #expect(try db.appFolder(threadId: "none") == nil)
    #expect(try db.listAppFolders() == [folder])
    try db.deleteAppFolder(path: "/p/one")
    #expect(try db.listAppFolders().isEmpty)
  }

  @Test func aSecondFolderForTheSameThreadIsRefused() throws {
    let db = try WorkspaceDatabase.temporary()
    try db.insertAppFolder(folder)
    #expect(throws: (any Error).self) {
      try db.insertAppFolder(AppFolder(path: "/p/two", threadId: "t1", createdAt: folder.createdAt))
    }
    #expect(try db.listAppFolders() == [folder])
  }

  @Test func insertingAnAppFolderWritesNoChange() throws {
    let db = try WorkspaceDatabase.temporary()
    let before = try db.changes(after: 0).count
    try db.insertAppFolder(folder)
    try db.deleteAppFolder(path: folder.path)
    #expect(try db.changes(after: 0).count == before)
  }

  @Test func appFoldersSurviveBackupAndRestore() throws {
    let source = try WorkspaceDatabase.temporary()
    _ = try source.insertConnection(
      Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
    try source.insertAppFolder(folder)
    try source.insertAppFolder(AppFolder(path: "/p/two", threadId: "t2", createdAt: folder.createdAt))
    let path =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try source.export(to: path)
    let target = try WorkspaceDatabase.temporary()
    try target.restore(from: path)
    #expect(try target.listAppFolders() == source.listAppFolders())
    #expect(try target.listAppFolders().count == 2)
  }
}
