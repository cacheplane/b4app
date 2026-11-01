import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

@Suite struct MirrorTransportTests {
  @Test func transportAnswersReadsAndRefusesWrites() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let client = WorkspaceClient(transport: transport)
    let hello = try await client.ready()
    #expect(hello.sequence == 0 && hello.coordinator.version == "0.2.0")
    #expect(hello.coordinator.pid == ProcessInfo.processInfo.processIdentifier)

    #expect(try await client.request(ThreadList.self, .init()).threads.count == 1)
    let read = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    #expect(read.items.count == 4)
    #expect(read.thread.title == "Renamed")
    #expect(read.turns.count == 2 && read.requests.count == 1)
    #expect(try await client.request(ConnectionList.self, .init()).connections.first?.target == "")
    #expect(try await client.request(DraftRead.self, .init(threadId: "thread-1")).draft == nil)
    #expect(try await client.request(ServerList.self, EmptyParams()).servers.isEmpty)
    let work = try await client.request(WorkspaceActiveWork.self, EmptyParams())
    #expect(work.turns.isEmpty && work.servers.isEmpty)
    let ping = try await client.request(SystemPing.self, EmptyParams())
    #expect(ping.epoch == hello.epoch && ping.coordinator.version == "0.2.0")

    let missing = await #expect(throws: WorkspaceError.self) {
      try await client.request(ThreadRead.self, .init(threadId: "nope"))
    }
    #expect(missing?.code == .notFound)

    let refused = await #expect(throws: WorkspaceError.self) {
      try await client.request(TurnSend.self, TurnSend.Params(threadId: "thread-1", text: "hi"))
    }
    #expect(refused?.code == .unsupportedCapability)
    #expect(
      refused?.message == "Writing from this device arrives in M8b; sending turns through the hub in M8c.")
    let refusedWithOperation = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        DraftSave.self, .init(threadId: "thread-1", text: "x"), options: RequestOptions(operationId: "op-1"))
    }
    #expect(refusedWithOperation?.code == .unsupportedCapability)
    await client.close()
  }

  @Test func snapshotAndReplayFollowTheTransportsEpoch() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    var disabled = try #require(try fixtureAsStored()[0].value?.objectValue)
    disabled["id"] = "conn-2"
    disabled["enabled"] = false
    disabled["createdAt"] = "2026-10-31T12:30:00Z"
    _ = try store.apply([change("connections", "conn-2", "insert", value: .object(disabled))])
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    let hello = try await client.ready()

    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    #expect(snapshot.epoch == hello.epoch && snapshot.sequence == 0)
    #expect(snapshot.connections.map(\.id) == ["conn-1", "conn-2"])
    #expect(snapshot.threads.map(\.id) == ["thread-1"])
    #expect(snapshot.activeTurns.isEmpty)
    #expect(try await client.request(ConnectionList.self, .init()).connections.map(\.id) == ["conn-1"])
    #expect(
      try await client.request(ConnectionList.self, .init(includeDisabled: true)).connections.count == 2)

    let replay = try await client.request(EventsReplay.self, .init(epoch: hello.epoch, afterSequence: 0))
    #expect(replay.events.isEmpty)
    let desync = await #expect(throws: WorkspaceError.self) {
      try await client.request(EventsReplay.self, .init(epoch: "another", afterSequence: 0))
    }
    #expect(desync?.code == .snapshotRequired)
    await client.close()
  }

  @Test func publishEmitsThreadConnectionAndItemEventsInSequence() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let client = WorkspaceClient(transport: transport)
    let hello = try await client.ready()
    let events = await client.events()
    let fixture = try fixtureAsStored()

    transport.publish(try store.apply(Array(fixture.prefix(2))))
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    transport.publish(try store.apply(Array(fixture[2..<8])))

    var received: [EventEnvelope] = []
    for await envelope in events {
      received.append(envelope)
      if received.count == 7 { break }
    }
    #expect(received.map(\.sequence) == [1, 2, 3, 4, 5, 6, 7])
    #expect(received.allSatisfy { $0.epoch == hello.epoch })
    let kinds = received.map(\.event.kind)
    #expect(Set(kinds.prefix(2)) == [.threadUpdated, .connectionChanged])
    // The second batch's turns touch their thread (M8b), so it is published again before its items.
    #expect(kinds[2] == .threadUpdated)
    #expect(Array(kinds.suffix(4)) == Array(repeating: .messageCompleted, count: 4))

    let connection = try #require(received.first { $0.event.kind == .connectionChanged }?.event)
    #expect(connection.connectionId == "conn-1")
    #expect(connection.payload["status"] == "ready" && connection.payload["authStatus"] == "authenticated")
    let thread = try #require(received.first { $0.event.kind == .threadUpdated }?.event)
    #expect(try thread.payload["thread"]?.decode(ConversationThread.self).title == "Fix the login bug")
    let items = try received.suffix(4).map {
      try #require($0.event.payload["displayItem"]).decode(DisplayItem.self)
    }
    #expect(items.map(\.id) == ["item-1", "item-2", "item-3", "item-4"])
    #expect(received.suffix(4).allSatisfy { $0.event.threadId == "thread-1" })

    let ping = try await client.request(SystemPing.self, EmptyParams())
    #expect(ping.sequence == 7)
    await client.close()
  }

  @Test func itemsOfAThreadNotReadAreNotPublished() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    let events = await client.events()
    let fixture = try fixtureAsStored()
    transport.publish(try store.apply(Array(fixture.prefix(8))))
    transport.publish(try store.apply([fixture[9]]))  // the title update

    var kinds: [EventKind] = []
    for await envelope in events {
      kinds.append(envelope.event.kind)
      if kinds.count == 3 { break }
    }
    #expect(kinds.filter { $0 == .threadUpdated }.count == 2)
    #expect(!kinds.contains(.messageCompleted))
    await client.close()
  }

  @Test func diagnosticsDescribeTheMirrorAndItsLink() async throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { MirrorStoreTests.remove(path) }
    let store = try MirrorStore(path: path)
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    let hello = try await client.ready()

    let unlinked = try await client.request(DiagnosticsRead.self, EmptyParams())
    #expect(unlinked.sync == nil)
    #expect(unlinked.coordinator.version == "0.2.0")
    #expect(unlinked.coordinator.epoch == hello.epoch)
    #expect(unlinked.coordinator.socketPath == "mirror")
    #expect(unlinked.coordinator.databasePath == path)
    #expect(unlinked.coordinator.dataDir == (path as NSString).deletingLastPathComponent)
    #expect(unlinked.coordinator.host == "iPhone")
    #expect(unlinked.host.platform == "macOS")
    #expect(unlinked.runtimes.isEmpty && unlinked.recentErrors.isEmpty)

    // A row this build cannot read is counted in the sync section.
    _ = try store.apply(Array(try fixtureAsStored().prefix(3)))
    var future = try #require(try fixtureAsStored()[3].value?.objectValue)
    future["submission"] = "teleported"
    _ = try store.apply([change("turns", "turn-2", "insert", value: .object(future))])

    try store.saveLink(
      MirrorLink(
        hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone", tokenRef: "secret:t",
        orgSlug: "o", username: "u", lastSyncAt: "2026-10-31T12:00:00Z",
        lastError: "Hub error 503 shutting_down"))
    try store.setCursor(7)
    let linked = try await client.request(DiagnosticsRead.self, EmptyParams())
    #expect(
      linked.sync
        == SyncDiagnostic(
          hubURL: "http://localhost:8080", deviceName: "Test Phone", cursor: 7,
          lastSyncAt: "2026-10-31T12:00:00Z",
          lastError: "Hub error 503 shutting_down", undecodableRows: 1))
    #expect(linked.coordinator.host == "Test Phone")
    #expect(linked.recentErrors.map(\.message) == ["Hub error 503 shutting_down"])
    // The token reference never leaves the store.
    let encoded = String(decoding: try JSONCoding.encoder.encode(linked), as: UTF8.self)
    #expect(!encoded.contains("secret:t"))
    await client.close()
  }

  @Test func diagnosticsCountUndecodableRowsWithoutReadingTheRowTables() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    var future = try #require(try fixtureAsStored()[3].value?.objectValue)
    future["status"] = "teleporting"
    _ = try store.apply([change("turns", "turn-2", "insert", value: .object(future))])
    try store.saveLink(
      MirrorLink(
        hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone", tokenRef: "secret:t",
        orgSlug: "o", username: "u"))
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    _ = try await client.ready()

    store.recordStatements()
    let report = try await client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.sync?.undecodableRows == 1)
    let statements = store.recordedStatements()
    #expect(statements.contains { $0.contains(#""undecodableRows""#) })
    for table in ["connections", "threads", "turns", "displayItems", "runtimeRequests", "drafts"] {
      #expect(!statements.contains { $0.contains("\"\(table)\"") }, "diagnostics read \(table)")
    }
    await client.close()
  }

  @Test func closeEndsTheStreamAndPublishAfterCloseIsANoOp() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    var lines = transport.incoming.makeAsyncIterator()
    let hello = try #require(await lines.next())
    #expect(ServerEnvelope.decode(hello).map { if case .hello = $0 { true } else { false } } == true)
    await transport.close()
    transport.publish(try store.apply(Array(try fixtureAsStored().prefix(2))))
    #expect(await lines.next() == nil)
    let refused = await #expect(throws: WorkspaceError.self) { try await transport.send(Data("{}".utf8)) }
    #expect(refused?.code == .endpointUnavailable)
  }

  @Test func malformedAndUnknownCommandsAreAnswered() async throws {
    let transport = MirrorTransport(store: try MirrorStore.inMemory(), version: "0.2.0")
    var lines = transport.incoming.makeAsyncIterator()
    _ = await lines.next()  // hello
    try await transport.send(
      Data(#"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"nope.nope"}"#.utf8))
    let unknown = try JSONCoding.decoder.decode(ResponseEnvelope.self, from: try #require(await lines.next()))
    #expect(unknown.requestId == "r1" && unknown.error?.code == .methodUnknown)
    try await transport.send(Data("not json".utf8))
    let malformed = try JSONCoding.decoder.decode(
      ResponseEnvelope.self, from: try #require(await lines.next()))
    #expect(malformed.requestId == "unknown" && malformed.error?.code == .protocolInvalid)
    await transport.close()
  }
}
