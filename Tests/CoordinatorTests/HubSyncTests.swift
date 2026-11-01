import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

private let enrolled = EnrollResponse(
  deviceId: "dev-mac", token: "tok-very-secret", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"))
private let code = "BCDF2345"
private let unauthorized = HubError(
  kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401)

/// A ChangeRecord as the change log would hold it (the type has no public memberwise init).
private func record(
  _ seq: Int, _ table: String, _ op: String, rowId: String = "r1", column: String? = nil, value: JSONValue?
) throws -> ChangeRecord {
  var object: [String: JSONValue] = [
    "seq": .number(Double(seq)), "deviceId": "local", "wall": 1_700_000_000_000, "table": .string(table),
    "rowId": .string(rowId), "op": .string(op), "synced": false,
  ]
  if let column { object["column"] = .string(column) }
  if let value { object["value"] = value }
  return try JSONValue.object(object).decode(ChangeRecord.self)
}

private struct HubHarness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let secrets: MemorySecretStore
  let fake: FakeHubAPI
  let workDir: String

  static func start() async throws -> HubHarness {
    let base = NSTemporaryDirectory() + "b4h-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(code, enrolled)
    let secrets = MemorySecretStore()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: secrets, hubAPIFactory: { _, _ in fake }))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    return HubHarness(
      coordinator: coordinator, client: client, secrets: secrets, fake: fake, workDir: base + "/work")
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }

  func addThread() async throws {
    let connection = try await client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    ).connection
    _ = try await client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: connection.id, workingDirectory: workDir),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }

  func join(url: String = "http://localhost:8080") async throws -> HubStatus.Result {
    try await client.request(
      HubJoin.self, HubJoin.Params(url: url, code: code, deviceName: "Test Mac"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }

  func status() async throws -> HubStatus.Result {
    try await client.request(HubStatus.self, EmptyParams())
  }
}

@Suite struct SyncFilterTests {
  @Test func filterBlanksConnectionSecretsAndPathsAndTruncatesBigItems() throws {
    let connection = try record(
      1, "connections", "insert", rowId: "c1",
      value: [
        "id": "c1", "label": "B4", "target": "/Users/me/bin/codex", "authReference": "ref-123",
        "localServerId": "s1",
      ])
    let out = try #require(SyncFilter.outbound(connection))
    #expect(out.deviceSeq == 1)
    #expect(out.wall == 1_700_000_000_000)
    #expect(out.table == "connections")
    #expect(out.rowId == "c1")
    #expect(out.value?["authReference"] == .null)
    #expect(out.value?["localServerId"] == .null)
    #expect(out.value?["target"] == .string(""))
    #expect(out.value?["label"] == .string("B4"))

    for column in ["target", "authReference", "localServerId"] {
      #expect(SyncFilter.outbound(try record(2, "connections", "update", column: column, value: "x")) == nil)
    }
    let label = try #require(
      SyncFilter.outbound(try record(3, "connections", "update", column: "label", value: "Renamed")))
    #expect(label.column == "label")
    #expect(label.value == .string("Renamed"))

    // A cleared column stays a JSON null on the wire; a delete carries no value.
    let cleared = try #require(
      SyncFilter.outbound(try record(4, "threads", "update", column: "archivedAt", value: nil)))
    #expect(cleared.value == .null)
    let deleted = try #require(SyncFilter.outbound(try record(5, "drafts", "delete", value: nil)))
    #expect(deleted.value == nil)

    let big: JSONValue = ["text": .string(String(repeating: "a", count: 2 * 1024 * 1024))]
    let bytes = try JSONCoding.encoder.encode(big).count
    let item = try #require(
      SyncFilter.outbound(
        try record(6, "displayItems", "insert", value: ["id": "d1", "type": "agentMessage", "payload": big])))
    #expect(item.value?["payload"] == ["truncated": true, "bytes": .number(Double(bytes))])
    #expect(item.value?["type"] == .string("agentMessage"))
    let bigUpdate = try #require(
      SyncFilter.outbound(try record(7, "displayItems", "update", column: "payload", value: big)))
    #expect(bigUpdate.value == ["truncated": true, "bytes": .number(Double(bytes))])
    let small: JSONValue = ["id": "d2", "payload": ["text": "hi"]]
    #expect(SyncFilter.outbound(try record(8, "displayItems", "insert", value: small))?.value == small)

    #expect(SyncFilter.outbound(try record(9, "localServers", "insert", value: ["id": "s1"])) == nil)
    #expect(SyncFilter.outbound(try record(10, "hubLink", "insert", value: ["id": 1])) == nil)
  }

  @Test func nativeScopesWithPathsOrURLsTravelAsStableOpaqueTokens() throws {
    let origin = "http://127.0.0.1:3001"
    let configPath = "/Users/me/.claude"
    let b4 = try #require(
      SyncFilter.outbound(
        try record(
          1, "connections", "insert", rowId: "c1", value: ["id": "c1", "nativeScope": .string(origin)])))
    let b4Scope = try #require(b4.value?["nativeScope"]?.stringValue)
    #expect(b4Scope.hasPrefix("scope:"))
    #expect(b4Scope.count == "scope:".count + 16)
    #expect(!b4Scope.contains("127.0.0.1") && !b4Scope.contains("3001"))
    let hex = b4Scope.dropFirst("scope:".count)
    #expect(hex.allSatisfy { $0.isHexDigit })

    // The same scope on a thread, and on an update, maps to the same token, so uniqueness holds.
    let thread = try #require(
      SyncFilter.outbound(
        try record(2, "threads", "insert", rowId: "t1", value: ["id": "t1", "nativeScope": .string(origin)])))
    #expect(thread.value?["nativeScope"] == .string(b4Scope))
    let update = try #require(
      SyncFilter.outbound(try record(3, "threads", "update", column: "nativeScope", value: .string(origin))))
    #expect(update.value == .string(b4Scope))

    let claude = try #require(
      SyncFilter.outbound(
        try record(
          4, "connections", "update", rowId: "c2", column: "nativeScope", value: .string(configPath))))
    let claudeScope = try #require(claude.value?.stringValue)
    #expect(claudeScope.hasPrefix("scope:"))
    #expect(!claudeScope.contains("Users"))
    #expect(claudeScope != b4Scope)

    let email = try #require(
      SyncFilter.outbound(
        try record(
          5, "connections", "insert", rowId: "c3", value: ["id": "c3", "nativeScope": "me@example.com"])))
    #expect(email.value?["nativeScope"] == .string("me@example.com"))
    let codex = try #require(
      SyncFilter.outbound(try record(6, "threads", "update", column: "nativeScope", value: "chatgpt")))
    #expect(codex.value == .string("chatgpt"))
  }

  @Test func oversizedRuntimeRequestPayloadsAreTruncated() throws {
    let big: JSONValue = ["text": .string(String(repeating: "a", count: 2 * 1024 * 1024))]
    let marker: JSONValue = [
      "truncated": true, "bytes": .number(Double(try JSONCoding.encoder.encode(big).count)),
    ]
    let insert = try #require(
      SyncFilter.outbound(
        try record(1, "runtimeRequests", "insert", value: ["id": "q1", "kind": "approval", "payload": big])))
    #expect(insert.value?["payload"] == marker)
    #expect(insert.value?["kind"] == .string("approval"))
    let update = try #require(
      SyncFilter.outbound(try record(2, "runtimeRequests", "update", column: "payload", value: big)))
    #expect(update.value == marker)
    let small: JSONValue = ["id": "q2", "payload": ["command": "ls"]]
    #expect(SyncFilter.outbound(try record(3, "runtimeRequests", "insert", value: small))?.value == small)
  }

  @Test func connectionInsertsKeepOnlyTheKnownColumns() throws {
    #expect(SyncFilter.outbound(try record(1, "connections", "insert", value: "not an object")) == nil)
    #expect(SyncFilter.outbound(try record(2, "connections", "insert", value: nil)) == nil)

    var row: [String: JSONValue] = [:]
    for column in SyncFilter.connectionColumns { row[column] = .string("v-\(column)") }
    row["futureSecret"] = "do-not-upload"
    let out = try #require(SyncFilter.outbound(try record(3, "connections", "insert", value: .object(row))))
    guard case .object(let sent) = out.value else {
      Issue.record("expected an object")
      return
    }
    #expect(sent["futureSecret"] == nil)
    #expect(Set(sent.keys) == SyncFilter.connectionColumns)
    #expect(sent.count == 16)
    #expect(sent["authReference"] == .null)
    #expect(sent["localServerId"] == .null)
    #expect(sent["target"] == .string(""))
    #expect(sent["label"] == .string("v-label"))
    #expect(sent["nativeScope"] == .string("v-nativeScope"))
  }
}

@Suite(.serialized) struct HubSyncTests {
  @Test func joinPushesTheBacklogAndMarksItSynced() async throws {
    let h = try await HubHarness.start()
    defer { Task { await h.close() } }
    let db = h.coordinator.database
    try await h.addThread()
    let backlog = try db.changes(after: 0).compactMap(SyncFilter.outbound)
    #expect(!backlog.isEmpty)
    #expect(try db.unsyncedChangeCount() > 0)

    let joined = try await h.join()
    #expect(joined.joined)
    #expect(joined.deviceId == "dev-mac")
    #expect(joined.deviceName == "Test Mac")
    #expect(joined.orgSlug == "acme")
    #expect(joined.username == "brian")
    #expect(joined.url == "http://localhost:8080")
    #expect(joined.unsyncedChanges == 0)
    #expect(joined.lastPushAt != nil)
    #expect(joined.lastError == nil)

    let pushed = await h.fake.pushed.flatMap { $0 }
    #expect(pushed.map(\.deviceSeq) == backlog.map(\.deviceSeq))
    #expect(pushed.allSatisfy { $0.table != "localServers" })
    #expect(pushed.first { $0.table == "connections" && $0.op == "insert" }?.value?["target"] == .string(""))
    #expect(try db.unsyncedChangeCount() == 0)
    let link = try #require(try db.hubLink())
    #expect(link.deviceId == "dev-mac")
    #expect(link.deviceName == "Test Mac")
    #expect(db.deviceId == "dev-mac")
    let ref = try #require(SecretRef(rawValue: link.tokenRef))
    #expect(try await h.secrets.read(ref) == "tok-very-secret")

    // The result carries neither the token, its reference, nor the enrollment code.
    let json = String(decoding: try JSONCoding.encoder.encode(joined), as: UTF8.self)
    for secret in ["tok-very-secret", link.tokenRef, code] { #expect(!json.contains(secret)) }

    // A 401 is recorded, leaves the rows unsynced, and stops write-driven pushes until the next join.
    await h.fake.setFailNext(unauthorized)
    try await h.addThread()
    var status = try await h.status()
    let deadline = ContinuousClock.now + .seconds(10)
    while status.lastError == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      status = try await h.status()
    }
    #expect(status.lastError?.contains("unauthorized") == true)
    #expect(status.unsyncedChanges > 0)
    #expect(try db.changes(after: 0).last?.deviceId == "dev-mac")
    let attempts = await h.fake.pushed.count
    try await h.addThread()
    try await Task.sleep(for: .milliseconds(600))
    #expect(await h.fake.pushed.count == attempts)
  }

  @Test func joinRefusesANonLoopbackHTTPURL() async throws {
    let h = try await HubHarness.start()
    defer { Task { await h.close() } }
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await h.join(url: "http://192.168.1.10:8080")
    }
    #expect(error?.code == .protocolInvalid)
    #expect(await h.fake.enrollCalls == 0)
    #expect(try await h.status().joined == false)
  }

  @Test func leaveRevokesAndForgets() async throws {
    let h = try await HubHarness.start()
    defer { Task { await h.close() } }
    try await h.addThread()
    _ = try await h.join()
    let db = h.coordinator.database
    let link = try #require(try db.hubLink())
    let ref = try #require(SecretRef(rawValue: link.tokenRef))

    let left = try await h.client.request(
      HubLeave.self, EmptyParams(),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(left.joined == false)
    #expect(await h.fake.revoked)
    #expect(try await h.status().joined == false)
    #expect(try await h.secrets.read(ref) == nil)
    #expect(try db.hubLink() == nil)
    #expect(db.deviceId == "local")
    #expect(try db.unsyncedChangeCount() == db.changes(after: 0).count)
  }

  @Test func restoreIsRefusedWhileJoined() async throws {
    let h = try await HubHarness.start()
    defer { Task { await h.close() } }
    let db = h.coordinator.database
    // An archive of the empty store: restoring an archive whose change log holds scalar jsonb values
    // fails independently of the hub (see the Task 7 fix report).
    let backup = try await h.client.request(
      DatabaseBackup.self, DatabaseBackup.Params(path: h.workDir + "/archive.jsonl"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    try await h.addThread()
    _ = try await h.join()
    let counts = try db.tableCounts()
    let changes = try db.changes(after: 0)
    let link = try db.hubLink()

    for replace in [true, false] {
      let error = await #expect(throws: WorkspaceError.self) {
        _ = try await h.client.request(
          DatabaseRestore.self, DatabaseRestore.Params(path: backup.path, replace: replace),
          options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
      }
      #expect(error?.code == .protocolInvalid)
      #expect(error?.message.contains("hub leave") == true)
    }
    #expect(try db.tableCounts() == counts)
    #expect(try db.changes(after: 0) == changes)
    #expect(try db.hubLink() == link)

    _ = try await h.client.request(
      HubLeave.self, EmptyParams(),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    let restored = try await h.client.request(
      DatabaseRestore.self, DatabaseRestore.Params(path: backup.path, replace: true),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(restored.rows == backup.rows)
    #expect(try db.listConnections(includeDisabled: true).isEmpty)
    #expect(try db.changes(after: 0).isEmpty)
  }

  @Test func pushBatchesByRowsAndBytes() async throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    _ = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "n1", nativeScope: "s", title: "T", context: "/tmp"))
    // Nine items just under the 1 MiB truncation: about 9 MB, so the byte budget splits them.
    for index in 0..<9 {
      _ = try db.insertDisplayItem(
        DisplayItem(
          id: "big\(index)", threadId: "t1", turnId: nil, nativeItemId: nil, role: .assistant,
          type: "agentMessage", payload: ["text": .string(String(repeating: "x", count: 1_000_000))],
          sequence: index, provenance: .live))
    }
    for index in 0..<600 { _ = try db.saveDraft(threadId: "t1", text: "draft \(index)") }
    let total = try db.unsyncedChangeCount()

    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(code, enrolled)
    let hub = HubSync(
      database: db, secretStore: MemorySecretStore(), eventLog: EventLog(), makeAPI: { _, _ in fake })
    let status = try await hub.join(url: "http://127.0.0.1:8080", code: code, deviceName: "Mac")
    #expect(status.unsyncedChanges == 0)

    let batches = await fake.pushed
    #expect(batches.allSatisfy { $0.count <= 500 })
    for batch in batches {
      let bytes = try JSONCoding.encoder.encode(batch).count
      #expect(bytes <= 8 * 1024 * 1024 || batch.count == 1)
    }
    #expect(batches.first?.count ?? 0 < 11)
    #expect(batches.flatMap { $0 }.count == total)
    #expect(Set(batches.flatMap { $0 }.map(\.deviceSeq)).count == total)
    try db.close()
  }
}
