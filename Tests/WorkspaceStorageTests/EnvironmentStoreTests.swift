import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seedConnection(_ db: WorkspaceDatabase) throws {
  _ = try db.insertConnection(
    Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
}

private func seedThread(_ db: WorkspaceDatabase, _ id: String) throws {
  if try db.connection(id: "c1") == nil { try seedConnection(db) }
  _ = try db.insertThread(
    ConversationThread(id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, context: "/tmp/p"))
}

@Suite struct EnvironmentStoreTests {
  @Test func displayNameFallsBackToTheFolder() throws {
    let db = try WorkspaceDatabase.temporary()
    let created = try db.insertEnvironment(WorkEnvironment(id: "p1", name: ""), folders: ["/x/b4app"])
    #expect(created.displayName == "b4app")
    #expect(created.folders.map(\.path) == ["/x/b4app"])
    #expect(created.folders.allSatisfy { $0.environmentId == "p1" })

    #expect(try db.renameEnvironment(id: "p1", name: "Site")?.displayName == "Site")
    #expect(try db.renameEnvironment(id: "p1", name: "")?.displayName == "b4app")
    #expect(try db.environment(id: "p1")?.displayName == "b4app")
    #expect(try db.renameEnvironment(id: "missing", name: "x") == nil)

    let bare = try db.insertEnvironment(WorkEnvironment(id: "p2", name: ""), folders: [])
    #expect(bare.displayName == "Untitled environment")
  }

  @Test func theOldestFolderNamesAnUnnamedEnvironment() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1"), folders: ["/x/first", "/x/second"])
    let environment = try #require(try db.environment(id: "p1"))
    #expect(environment.folders.map(\.path) == ["/x/first", "/x/second"])
    #expect(environment.displayName == "first")
    try db.removeFolder(path: "/x/first")
    #expect(try db.environment(id: "p1")?.displayName == "second")
  }

  @Test func renamingBumpsTheEnvironmentAndChangesTheName() throws {
    let db = try WorkspaceDatabase.temporary()
    let created = try db.insertEnvironment(
      WorkEnvironment(
        id: "p1", name: "Old", manual: true, createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z"),
      folders: [])
    let renamed = try #require(try db.renameEnvironment(id: "p1", name: "New"))
    #expect(renamed.updatedAt > created.updatedAt)
    #expect(renamed.manual && renamed.createdAt == "2026-01-01T00:00:00Z")
    let change = try #require(
      try db.changes(after: 0).last { $0.table == "environments" && $0.column == "name" })
    #expect(change.value?.stringValue == "New")
  }

  @Test func aFolderBelongsToOneEnvironment() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1"), folders: ["/x/b4app"])
    #expect(throws: WorkspaceError.self) {
      _ = try db.insertEnvironment(WorkEnvironment(id: "p2"), folders: ["/x/b4app"])
    }
    do {
      _ = try db.insertEnvironment(WorkEnvironment(id: "p2"), folders: ["/x/b4app"])
      Issue.record("expected protocolInvalid")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    // The failed insert rolled back, environment and all.
    #expect(try db.environment(id: "p2") == nil)
    #expect(try db.listEnvironments().map(\.id) == ["p1"])
  }

  @Test func foldersLookUpTheirEnvironmentAndMove() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1"), folders: ["/x/a", "/x/b"])
    _ = try db.insertEnvironment(WorkEnvironment(id: "p2", name: "Two"), folders: [])
    #expect(try db.environment(folderPath: "/x/b")?.id == "p1")
    #expect(try db.environment(folderPath: "/x/none") == nil)

    try db.moveFolder(path: "/x/b", toEnvironment: "p2")
    #expect(try db.environment(folderPath: "/x/b")?.id == "p2")
    #expect(try db.environment(id: "p1")?.folders.map(\.path) == ["/x/a"])
    #expect(try db.environment(id: "p2")?.folders.map(\.path) == ["/x/b"])

    try db.removeFolder(path: "/x/a")
    #expect(try db.environment(folderPath: "/x/a") == nil)
    #expect(try db.listEnvironments().map(\.id) == ["p1", "p2"])
  }

  @Test func deletingAEnvironmentUnassignsItsThreadsAndFolders() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    try seedThread(db, "t2")
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1", name: "One"), folders: ["/x/a"])
    try db.setThreadEnvironment(threadIds: ["t1", "t2"], environmentId: "p1")
    #expect(try db.thread(id: "t1")?.environmentId == "p1")
    #expect(try db.listThreads(ThreadFilter(environmentId: "p1")).map(\.id).sorted() == ["t1", "t2"])
    try db.setThreadEnvironment(threadIds: ["t2"], environmentId: nil)
    #expect(try db.listThreads(ThreadFilter(environmentId: "p1")).map(\.id) == ["t1"])

    try db.deleteEnvironment(id: "p1")
    #expect(try db.environment(id: "p1") == nil)
    #expect(try db.environment(folderPath: "/x/a") == nil)
    #expect(try db.thread(id: "t1")?.environmentId == nil)
    #expect(try db.listEnvironments().isEmpty)
  }

  @Test func settingAThreadEnvironmentRecordsAClockedChange() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1", name: "One"), folders: [])
    let before = try db.thread(id: "t1")
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "p1")
    let change = try #require(
      try db.changes(after: 0).last { $0.table == "threads" && $0.column == "environmentId" })
    #expect(change.value?.stringValue == "p1")
    #expect(try db.thread(id: "t1")?.environmentId == "p1")
    #expect(try db.thread(id: "t1")?.updatedAt == before?.updatedAt)
    #expect(throws: WorkspaceError.self) {
      try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "no-such-environment")
    }
  }

  @Test func moveAndRemoveRefuseAFolderNoEnvironmentOwns() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1"), folders: ["/x/a"])
    for body in [
      { try db.moveFolder(path: "/x/none", toEnvironment: "p1") }, { try db.removeFolder(path: "/x/none") },
    ] {
      do {
        try body()
        Issue.record("expected protocolInvalid")
      } catch let error as WorkspaceError {
        #expect(error.code == .protocolInvalid)
        #expect(error.message.contains("/x/none"))
      }
    }
    #expect(try db.environment(id: "p1")?.folders.map(\.path) == ["/x/a"])
  }

  @Test func creatingAManualEnvironmentMovesFoldersAndThreadsAndDropsTheEmptyAutomaticOne() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertEnvironment(WorkEnvironment(id: "auto"), folders: ["/x/a", "/x/b"])
    _ = try db.insertEnvironment(WorkEnvironment(id: "other"), folders: ["/x/c"])
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "auto")

    let result = try db.createManualEnvironment(
      WorkEnvironment(id: "m", name: "Site", manual: true),
      placing: [FolderPlacement(path: "/x/a", threadIds: ["t1"]), FolderPlacement(path: "/x/c")])
    #expect(result.environment?.folders.map(\.path) == ["/x/a", "/x/c"])
    // `auto` keeps /x/b and stays; `other` lost its only folder and is deleted.
    #expect(result.deletedEnvironmentIds == ["other"])
    #expect(Set(result.changedEnvironmentIds) == ["m", "auto", "other"])
    #expect(try db.environment(id: "auto")?.folders.map(\.path) == ["/x/b"])
    #expect(try db.environment(id: "other") == nil)
    #expect(try db.thread(id: "t1")?.environmentId == "m")
  }

  @Test func aFailedEditChangesNothing() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertEnvironment(WorkEnvironment(id: "auto"), folders: ["/x/a"])
    _ = try db.insertEnvironment(WorkEnvironment(id: "m", name: "M", manual: true), folders: [])
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "auto")
    do {
      _ = try db.updateEnvironment(
        id: "m", name: "Renamed", placing: [FolderPlacement(path: "/x/a", threadIds: ["t1"])],
        releasing: [FolderRelease(path: "/x/not-here")])
      Issue.record("expected protocolInvalid")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
      #expect(error.message.contains("/x/not-here"))
    }
    #expect(try db.environment(id: "auto")?.folders.map(\.path) == ["/x/a"])
    #expect(try db.environment(id: "m")?.name == "M")
    #expect(try db.thread(id: "t1")?.environmentId == "auto")
    do {
      _ = try db.updateEnvironment(id: "missing", name: "x", placing: [], releasing: [])
      Issue.record("expected notFound")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
  }

  @Test func addingAFolderToAnAutomaticEnvironmentMakesItManual() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "auto"), folders: ["/x/a"])
    _ = try db.updateEnvironment(
      id: "auto", name: nil, placing: [FolderPlacement(path: "/x/b")], releasing: [])
    let environment = try #require(try db.environment(id: "auto"))
    #expect(environment.manual)
    #expect(environment.folders.map(\.path) == ["/x/a", "/x/b"])
  }

  @Test func releasingAFolderGivesItsThreadsAReplacementEnvironment() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertEnvironment(
      WorkEnvironment(id: "m", name: "M", manual: true), folders: ["/x/a", "/x/b"])
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "m")

    let result = try db.updateEnvironment(
      id: "m", name: nil, placing: [],
      releasing: [FolderRelease(path: "/x/a", threadIds: ["t1"], replacement: WorkEnvironment(id: "r"))])
    #expect(Set(result.changedEnvironmentIds) == ["m", "r"])
    #expect(try db.environment(id: "m")?.folders.map(\.path) == ["/x/b"])
    let replacement = try #require(try db.environment(id: "r"))
    #expect(!replacement.manual)
    #expect(replacement.folders.map(\.path) == ["/x/a"])
    #expect(try db.thread(id: "t1")?.environmentId == "r")
  }

  @Test func deletingAnyEnvironmentLeavesItsThreadsWithNoEnvironment() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    try seedThread(db, "t2")
    _ = try db.insertEnvironment(
      WorkEnvironment(id: "m", name: "M", manual: true), folders: ["/x/a", "/x/b"])
    _ = try db.insertEnvironment(WorkEnvironment(id: "auto"), folders: ["/x/c"])
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "m")
    try db.setThreadEnvironment(threadIds: ["t2"], environmentId: "auto")

    let result = try db.deleteEnvironment(id: "m")
    #expect(result.deletedEnvironmentIds == ["m"] && result.changedEnvironmentIds == ["m"])
    #expect(try db.environment(id: "m") == nil)
    #expect(try db.environment(folderPath: "/x/a") == nil)
    #expect(try db.environment(folderPath: "/x/b") == nil)
    #expect(try db.thread(id: "t1")?.environmentId == nil)
    // An automatic environment can be deleted too.
    try db.deleteEnvironment(id: "auto")
    #expect(try db.thread(id: "t2")?.environmentId == nil)
    #expect(try db.listEnvironments().isEmpty)
    #expect(throws: WorkspaceError.self) { try db.deleteEnvironment(id: "auto") }
  }

  @Test func takingAManualEnvironmentsLastFolderDeletesIt() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertEnvironment(WorkEnvironment(id: "a", name: "A", manual: true), folders: ["/x/a"])
    _ = try db.insertEnvironment(WorkEnvironment(id: "b", name: "B", manual: true), folders: ["/x/b"])
    try db.setThreadEnvironment(threadIds: ["t1"], environmentId: "b")

    let result = try db.updateEnvironment(
      id: "a", name: nil, placing: [FolderPlacement(path: "/x/b", threadIds: ["t1"])], releasing: [])
    #expect(result.deletedEnvironmentIds == ["b"])
    #expect(try db.environment(id: "b") == nil)
    #expect(try db.environment(id: "a")?.folders.map(\.path) == ["/x/a", "/x/b"])
    #expect(try db.thread(id: "t1")?.environmentId == "a")
  }
}
