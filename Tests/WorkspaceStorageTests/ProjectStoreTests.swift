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

@Suite struct ProjectStoreTests {
  @Test func displayNameFallsBackToTheFolder() throws {
    let db = try WorkspaceDatabase.temporary()
    let created = try db.insertProject(Project(id: "p1", name: ""), folders: ["/x/b4app"])
    #expect(created.displayName == "b4app")
    #expect(created.folders.map(\.path) == ["/x/b4app"])
    #expect(created.folders.allSatisfy { $0.projectId == "p1" })

    #expect(try db.renameProject(id: "p1", name: "Site")?.displayName == "Site")
    #expect(try db.renameProject(id: "p1", name: "")?.displayName == "b4app")
    #expect(try db.project(id: "p1")?.displayName == "b4app")
    #expect(try db.renameProject(id: "missing", name: "x") == nil)

    let bare = try db.insertProject(Project(id: "p2", name: ""), folders: [])
    #expect(bare.displayName == "Untitled project")
  }

  @Test func theOldestFolderNamesAnUnnamedProject() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertProject(Project(id: "p1"), folders: ["/x/first", "/x/second"])
    let project = try #require(try db.project(id: "p1"))
    #expect(project.folders.map(\.path) == ["/x/first", "/x/second"])
    #expect(project.displayName == "first")
    try db.removeFolder(path: "/x/first")
    #expect(try db.project(id: "p1")?.displayName == "second")
  }

  @Test func renamingBumpsTheProjectAndChangesTheName() throws {
    let db = try WorkspaceDatabase.temporary()
    let created = try db.insertProject(
      Project(
        id: "p1", name: "Old", manual: true, createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z"),
      folders: [])
    let renamed = try #require(try db.renameProject(id: "p1", name: "New"))
    #expect(renamed.updatedAt > created.updatedAt)
    #expect(renamed.manual && renamed.createdAt == "2026-01-01T00:00:00Z")
    let change = try #require(
      try db.changes(after: 0).last { $0.table == "projects" && $0.column == "name" })
    #expect(change.value?.stringValue == "New")
  }

  @Test func aFolderBelongsToOneProject() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertProject(Project(id: "p1"), folders: ["/x/b4app"])
    #expect(throws: WorkspaceError.self) {
      _ = try db.insertProject(Project(id: "p2"), folders: ["/x/b4app"])
    }
    do {
      _ = try db.insertProject(Project(id: "p2"), folders: ["/x/b4app"])
      Issue.record("expected protocolInvalid")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    // The failed insert rolled back, project and all.
    #expect(try db.project(id: "p2") == nil)
    #expect(try db.listProjects().map(\.id) == ["p1"])
  }

  @Test func foldersLookUpTheirProjectAndMove() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertProject(Project(id: "p1"), folders: ["/x/a", "/x/b"])
    _ = try db.insertProject(Project(id: "p2", name: "Two"), folders: [])
    #expect(try db.project(folderPath: "/x/b")?.id == "p1")
    #expect(try db.project(folderPath: "/x/none") == nil)

    try db.moveFolder(path: "/x/b", toProject: "p2")
    #expect(try db.project(folderPath: "/x/b")?.id == "p2")
    #expect(try db.project(id: "p1")?.folders.map(\.path) == ["/x/a"])
    #expect(try db.project(id: "p2")?.folders.map(\.path) == ["/x/b"])

    try db.removeFolder(path: "/x/a")
    #expect(try db.project(folderPath: "/x/a") == nil)
    #expect(try db.listProjects().map(\.id) == ["p1", "p2"])
  }

  @Test func deletingAProjectUnassignsItsThreadsAndFolders() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    try seedThread(db, "t2")
    _ = try db.insertProject(Project(id: "p1", name: "One"), folders: ["/x/a"])
    try db.setThreadProject(threadIds: ["t1", "t2"], projectId: "p1")
    #expect(try db.thread(id: "t1")?.projectId == "p1")
    #expect(try db.listThreads(ThreadFilter(projectId: "p1")).map(\.id).sorted() == ["t1", "t2"])
    try db.setThreadProject(threadIds: ["t2"], projectId: nil)
    #expect(try db.listThreads(ThreadFilter(projectId: "p1")).map(\.id) == ["t1"])

    try db.deleteProject(id: "p1")
    #expect(try db.project(id: "p1") == nil)
    #expect(try db.project(folderPath: "/x/a") == nil)
    #expect(try db.thread(id: "t1")?.projectId == nil)
    #expect(try db.listProjects().isEmpty)
  }

  @Test func settingAThreadProjectRecordsAClockedChange() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertProject(Project(id: "p1", name: "One"), folders: [])
    let before = try db.thread(id: "t1")
    try db.setThreadProject(threadIds: ["t1"], projectId: "p1")
    let change = try #require(
      try db.changes(after: 0).last { $0.table == "threads" && $0.column == "projectId" })
    #expect(change.value?.stringValue == "p1")
    #expect(try db.thread(id: "t1")?.projectId == "p1")
    #expect(try db.thread(id: "t1")?.updatedAt == before?.updatedAt)
    #expect(throws: WorkspaceError.self) {
      try db.setThreadProject(threadIds: ["t1"], projectId: "no-such-project")
    }
  }

  @Test func moveAndRemoveRefuseAFolderNoProjectOwns() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertProject(Project(id: "p1"), folders: ["/x/a"])
    for body in [
      { try db.moveFolder(path: "/x/none", toProject: "p1") }, { try db.removeFolder(path: "/x/none") },
    ] {
      do {
        try body()
        Issue.record("expected protocolInvalid")
      } catch let error as WorkspaceError {
        #expect(error.code == .protocolInvalid)
        #expect(error.message.contains("/x/none"))
      }
    }
    #expect(try db.project(id: "p1")?.folders.map(\.path) == ["/x/a"])
  }

  @Test func creatingAManualProjectMovesFoldersAndThreadsAndDropsTheEmptyAutomaticOne() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertProject(Project(id: "auto"), folders: ["/x/a", "/x/b"])
    _ = try db.insertProject(Project(id: "other"), folders: ["/x/c"])
    try db.setThreadProject(threadIds: ["t1"], projectId: "auto")

    let result = try db.createManualProject(
      Project(id: "m", name: "Site", manual: true),
      placing: [FolderPlacement(path: "/x/a", threadIds: ["t1"]), FolderPlacement(path: "/x/c")])
    #expect(result.project?.folders.map(\.path) == ["/x/a", "/x/c"])
    // `auto` keeps /x/b and stays; `other` lost its only folder and is deleted.
    #expect(result.deletedProjectIds == ["other"])
    #expect(Set(result.changedProjectIds) == ["m", "auto", "other"])
    #expect(try db.project(id: "auto")?.folders.map(\.path) == ["/x/b"])
    #expect(try db.project(id: "other") == nil)
    #expect(try db.thread(id: "t1")?.projectId == "m")
  }

  @Test func aFailedEditChangesNothing() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertProject(Project(id: "auto"), folders: ["/x/a"])
    _ = try db.insertProject(Project(id: "m", name: "M", manual: true), folders: [])
    try db.setThreadProject(threadIds: ["t1"], projectId: "auto")
    do {
      _ = try db.updateProject(
        id: "m", name: "Renamed", placing: [FolderPlacement(path: "/x/a", threadIds: ["t1"])],
        releasing: [FolderRelease(path: "/x/not-here")])
      Issue.record("expected protocolInvalid")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
      #expect(error.message.contains("/x/not-here"))
    }
    #expect(try db.project(id: "auto")?.folders.map(\.path) == ["/x/a"])
    #expect(try db.project(id: "m")?.name == "M")
    #expect(try db.thread(id: "t1")?.projectId == "auto")
    do {
      _ = try db.updateProject(id: "missing", name: "x", placing: [], releasing: [])
      Issue.record("expected notFound")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
  }

  @Test func addingAFolderToAnAutomaticProjectMakesItManual() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertProject(Project(id: "auto"), folders: ["/x/a"])
    _ = try db.updateProject(
      id: "auto", name: nil, placing: [FolderPlacement(path: "/x/b")], releasing: [])
    let project = try #require(try db.project(id: "auto"))
    #expect(project.manual)
    #expect(project.folders.map(\.path) == ["/x/a", "/x/b"])
  }

  @Test func releasingAFolderGivesItsThreadsAReplacementProject() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertProject(Project(id: "m", name: "M", manual: true), folders: ["/x/a", "/x/b"])
    try db.setThreadProject(threadIds: ["t1"], projectId: "m")

    let result = try db.updateProject(
      id: "m", name: nil, placing: [],
      releasing: [FolderRelease(path: "/x/a", threadIds: ["t1"], replacement: Project(id: "r"))])
    #expect(Set(result.changedProjectIds) == ["m", "r"])
    #expect(try db.project(id: "m")?.folders.map(\.path) == ["/x/b"])
    let replacement = try #require(try db.project(id: "r"))
    #expect(!replacement.manual)
    #expect(replacement.folders.map(\.path) == ["/x/a"])
    #expect(try db.thread(id: "t1")?.projectId == "r")
  }

  @Test func deletingAManualProjectKeepsFoldersThreadsUseAsAutomaticProjects() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    _ = try db.insertProject(Project(id: "m", name: "M", manual: true), folders: ["/x/a", "/x/b"])
    _ = try db.insertProject(Project(id: "auto"), folders: ["/x/c"])
    try db.setThreadProject(threadIds: ["t1"], projectId: "m")

    #expect(throws: WorkspaceError.self) { _ = try db.deleteManualProject(id: "auto", releasing: []) }
    #expect(try db.project(id: "auto") != nil)

    let result = try db.deleteManualProject(
      id: "m",
      releasing: [FolderRelease(path: "/x/a", threadIds: ["t1"], replacement: Project(id: "r"))])
    #expect(result.deletedProjectIds == ["m"])
    #expect(Set(result.changedProjectIds) == ["m", "r"])
    #expect(try db.project(id: "m") == nil)
    #expect(try db.project(folderPath: "/x/b") == nil)
    #expect(try db.project(folderPath: "/x/a")?.id == "r")
    #expect(try db.thread(id: "t1")?.projectId == "r")
  }
}
