import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func connection(_ id: String, kind: ConnectionKind = .codex) -> Connection {
  Connection(id: id, kind: kind, label: id, target: "/usr/local/bin/codex")
}

private func thread(
  _ id: String, _ connectionId: String, native: String, scope: String = "acct"
) -> ConversationThread {
  ConversationThread(
    id: id, connectionId: connectionId, nativeThreadId: native, nativeScope: scope,
    title: "ConversationThread \(id)", context: "/tmp/project")
}

@Suite struct DatabaseTests {
  @Test func createsSchemaWithWalForeignKeysAndPrivateMode() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try db.appliedMigrations() == ["v1", "v2"])
    #expect(try db.journalMode() == "wal")
    let mode = try FileManager.default.attributesOfItem(atPath: db.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    try db.close()
  }

  @Test func isIdempotentOnReopen() throws {
    let first = try WorkspaceDatabase.temporary()
    let path = first.path
    try first.close()
    let second = try WorkspaceDatabase(path: path)
    #expect(try second.appliedMigrations() == ["v1", "v2"])
    try second.close()
  }

  @Test func allowsSameNativeIdUnderDifferentConnections() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(connection("c1"))
    _ = try db.insertConnection(connection("c2"))
    _ = try db.insertThread(thread("t1", "c1", native: "thr_1"))
    _ = try db.insertThread(thread("t2", "c2", native: "thr_1"))
    #expect(try db.listThreads(ThreadFilter(includeArchived: true)).count == 2)
  }

  @Test func rejectsDuplicateNativeIdWithinConnectionAndScope() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(connection("c1"))
    _ = try db.insertThread(thread("t1", "c1", native: "thr_1"))
    #expect(throws: (any Error).self) { try db.insertThread(thread("t2", "c1", native: "thr_1")) }
    _ = try db.insertThread(thread("t3", "c1", native: "thr_1", scope: "other-account"))
  }

  @Test func rejectsThreadForUnknownConnection() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(throws: (any Error).self) { try db.insertThread(thread("t1", "missing", native: "thr_1")) }
  }

  @Test func listsPinnedFirstFiltersArchivedAndSearchesTitles() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(connection("c1"))
    _ = try db.insertThread(thread("a", "c1", native: "1"))
    _ = try db.insertThread(thread("b", "c1", native: "2"))
    _ = try db.insertThread(thread("c", "c1", native: "3"))
    _ = try db.updateThread(id: "b") { $0.title = "Release notes" }
    _ = try db.updateThread(id: "c") { $0.pinned = true }
    _ = try db.updateThread(id: "a") { $0.archived = true }
    #expect(try db.listThreads().map(\.id) == ["c", "b"])
    #expect(Set(try db.listThreads(ThreadFilter(includeArchived: true)).map(\.id)) == ["a", "b", "c"])
    #expect(try db.listThreads(ThreadFilter(includeArchived: true)).first?.id == "c")
    #expect(try db.listThreads(ThreadFilter(query: "release")).map(\.id) == ["b"])
    #expect(try db.listThreads(ThreadFilter(query: "%")).isEmpty)
  }

  @Test func savesDraftsWithoutTouchingThreads() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(connection("c1"))
    _ = try db.insertThread(thread("t1", "c1", native: "thr_1"))
    _ = try db.saveDraft(threadId: "t1", text: "unsent")
    #expect(try db.draft(threadId: "t1")?.text == "unsent")
    _ = try db.saveDraft(threadId: "t1", text: "edited")
    #expect(try db.draft(threadId: "t1")?.text == "edited")
    #expect(try db.draft(threadId: "nope") == nil)
    #expect(throws: (any Error).self) { try db.saveDraft(threadId: "missing", text: "x") }
  }

  @Test func transitionsRuntimeRequestsOnceAndExpiresOlderGenerations() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(connection("c1"))
    _ = try db.insertThread(thread("t1", "c1", native: "thr_1"))
    let request = try db.insertRuntimeRequest(
      RuntimeRequest(
        id: "r1", nativeRequestId: "n1", threadId: "t1", adapterGeneration: 1, kind: .commandApproval,
        payload: ["command": "ls"]))
    #expect(request.payload["command"]?.stringValue == "ls")
    #expect(try db.transitionRuntimeRequest(id: "r1", to: .resolved) == true)
    #expect(try db.transitionRuntimeRequest(id: "r1", to: .resolved) == false)
    _ = try db.insertRuntimeRequest(
      RuntimeRequest(
        id: "r2", nativeRequestId: "n2", threadId: "t1", adapterGeneration: 1, kind: .userQuestion,
        payload: [:]))
    #expect(try db.expireRuntimeRequests(threadId: "t1", olderThanGeneration: 2) == 1)
    #expect(try db.pendingRuntimeRequests(threadId: "t1").isEmpty)
  }

  @Test func storesCapabilitiesAndTurnsAsTypedRecords() throws {
    let db = try WorkspaceDatabase.temporary()
    var c = connection("c1", kind: .claude)
    c.capabilities[.streaming] = .supported
    _ = try db.insertConnection(c)
    #expect(try db.connection(id: "c1")?.capabilities[.streaming] == .supported)
    _ = try db.insertThread(thread("t1", "c1", native: "s1"))
    _ = try db.insertTurn(Turn(id: "u1", threadId: "t1", operationId: "op1"))
    #expect(try db.turn(operationId: "op1")?.status == .submitting)
    #expect(try db.unresolvedTurns().count == 1)
    _ = try db.updateTurn(id: "u1") {
      $0.status = .terminal
      $0.outcome = .completed
    }
    #expect(try db.unresolvedTurns().isEmpty)
  }

  @Test func localServersRoundTripUpdateAndUniqueName() throws {
    let db = try WorkspaceDatabase.temporary()
    let route = LocalServerRoute(id: "/chat", kind: "agent", entryFile: "src/app/chat/index.ts")
    let server = try db.insertLocalServer(
      LocalServer(
        id: "s1", name: "research", projectPath: "/p", nodePath: "/n", cliPath: "/p/cli.js",
        launchMode: .source, requestedPort: 3101, routes: [route]))
    #expect(try db.localServer(name: "research") == server)
    #expect(try db.localServer(projectPath: "/p")?.routes == [route])
    let updated = try db.updateLocalServer(id: "s1") {
      $0.pid = 42
      $0.health = .ready
    }
    #expect(updated?.pid == 42)
    #expect(try db.localServer(id: "s1")?.health == .ready)
    #expect(updated!.updatedAt >= server.updatedAt)
    #expect(throws: (any Error).self) {
      try db.insertLocalServer(
        LocalServer(
          id: "s2", name: "research", projectPath: "/q", nodePath: "/n", cliPath: "/q/cli.js",
          launchMode: .source))
    }
    _ = try db.insertConnection(
      Connection(
        id: "c1", kind: .b4, label: "chat", target: "http://127.0.0.1:3101", routeKey: "/chat#agent",
        b4Mode: .managedLocal, localServerId: "s1"))
    #expect(try db.connections(localServerId: "s1").map(\.id) == ["c1"])
    try db.close()
  }
}
