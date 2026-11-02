import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let syncedLink = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone", tokenRef: "secret:t",
  orgSlug: "o", username: "u")

/// Counts `onLocalWrite` calls.
private final class WriteCounter: Sendable {
  private let value = Mutex(0)
  var count: Int { value.withLock { $0 } }
  func bump() { value.withLock { $0 += 1 } }
}

@Suite(.timeLimit(.minutes(1))) struct MirrorTransportTests {
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
    #expect(refused?.message.hasSuffix("is done on the Mac.") == true)
    let refusedWithOperation = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        ThreadCreate.self, .init(connectionId: "conn-1", workingDirectory: "/tmp"),
        options: RequestOptions(operationId: "op-1"))
    }
    #expect(refusedWithOperation?.code == .unsupportedCapability)
    #expect(refusedWithOperation?.message.hasSuffix("is done on the Mac.") == true)
    await client.close()
  }

  @Test func transportRefusesProjectCreateNamingTheMac() async throws {
    let client = WorkspaceClient(
      transport: MirrorTransport(store: try MirrorStore.inMemory(), version: "0.2.0"))
    _ = try await client.ready()
    let options = RequestOptions(operationId: "op-1")
    let create = await #expect(throws: WorkspaceError.self) {
      try await client.request(ProjectCreate.self, .init(name: "x", folders: ["/tmp"]), options: options)
    }
    #expect(create?.code == .unsupportedCapability)
    #expect(create?.message.contains("the Mac") == true)
    let update = await #expect(throws: WorkspaceError.self) {
      try await client.request(ProjectUpdate.self, .init(projectId: "p1", name: "x"), options: options)
    }
    #expect(update?.code == .unsupportedCapability && update?.message.contains("the Mac") == true)
    let delete = await #expect(throws: WorkspaceError.self) {
      try await client.request(ProjectDelete.self, .init(projectId: "p1"), options: options)
    }
    #expect(delete?.code == .unsupportedCapability && delete?.message.contains("the Mac") == true)
    await client.close()
  }

  @Test func transportRenamesAndPublishes() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(syncedLink)
    _ = try store.apply(try fixtureAsStored())
    _ = try store.apply([
      change("projects", "p1", "insert", value: projectJSON("p1")),
      change(
        "projectFolders", "f1", "insert",
        value: folderJSON("f1", projectId: "p1", path: "/Users/blove/repos/b4app")),
    ])
    let writes = WriteCounter()
    let transport = MirrorTransport(store: store, version: "0.2.0", onLocalWrite: { writes.bump() })
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    let events = await client.events()
    var n = 0
    func options() -> RequestOptions {
      n += 1
      return RequestOptions(operationId: "op-\(n)")
    }

    let listed = try await client.request(ProjectList.self, EmptyParams())
    #expect(listed.projects.map(\.id) == ["p1"] && listed.projects.first?.displayName == "b4app")
    #expect(writes.count == 0)

    let renamed = try await client.request(
      ProjectRename.self, .init(projectId: "p1", name: "Agent Workspace"), options: options())
    #expect(renamed.project.displayName == "Agent Workspace")
    let updated = try await client.request(
      ThreadUpdate.self, .init(threadId: "thread-1", title: "From phone", pinned: true), options: options())
    #expect(updated.thread.title == "From phone" && updated.thread.pinned)
    let draft = try await client.request(
      DraftSave.self, .init(threadId: "thread-1", text: "later"), options: options())
    #expect(draft.draft.text == "later")
    #expect(try await client.request(DraftRead.self, .init(threadId: "thread-1")).draft?.text == "later")
    let read = try await client.request(
      ThreadMarkRead.self, .init(threadId: "thread-1", turnId: "turn-1"), options: options())
    #expect(read.thread.readTurnId == "turn-1")
    #expect(writes.count == 4)
    #expect(store.outboxCount == 5)

    let missing = await #expect(throws: WorkspaceError.self) {
      try await client.request(ProjectRename.self, .init(projectId: "nope", name: "x"), options: options())
    }
    #expect(missing?.code == .notFound)
    let missingThread = await #expect(throws: WorkspaceError.self) {
      try await client.request(ThreadUpdate.self, .init(threadId: "nope", title: "x"), options: options())
    }
    #expect(missingThread?.code == .notFound)
    #expect(writes.count == 4)  // a refused write is not a local write

    // A pulled batch announces the projects it touched, and the threads its turns belong to.
    transport.publish(AppliedBatch(touchedThreadIds: ["thread-1"], touchedProjectIds: ["p1"]))

    var received: [AdapterEvent] = []
    for await envelope in events {
      received.append(envelope.event)
      if received.count == 5 { break }
    }
    // Rename, update, and mark-read each announce themselves (a draft is not part of the thread row),
    // in the order the writes were made, before the pulled batch's.
    #expect(received.prefix(3).map(\.kind) == [.projectChanged, .threadUpdated, .threadUpdated])
    #expect(received[0].payload["projectId"] == "p1")
    #expect(received[1].threadId == "thread-1" && received[2].threadId == "thread-1")
    #expect(Set(received.suffix(2).map(\.kind)) == [.projectChanged, .threadUpdated])
    await client.close()
  }

  @Test func anUnavailableMirrorRefusesWritesAndSaysWhyInDiagnostics() async throws {
    let reason = "The mirror database needs rebuilding, but it holds edits not yet uploaded, so it was kept."
    let writes = WriteCounter()
    let transport = MirrorTransport(
      store: try MirrorStore.inMemory(), version: "0.2.0", onLocalWrite: { writes.bump() },
      unavailable: reason)
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    #expect(try await client.request(ThreadList.self, .init()).threads.isEmpty)
    let refused = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        DraftSave.self, .init(threadId: "thread-1", text: "x"), options: RequestOptions(operationId: "op-1"))
    }
    #expect(refused?.code == .endpointUnavailable && refused?.message == reason)
    #expect(writes.count == 0)
    let report = try await client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.recentErrors.first?.message == reason)
    await client.close()
  }

  @Test func diagnosticsCountsPendingUploads() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(syncedLink)
    _ = try store.apply(try fixtureAsStored())
    _ = try store.updateThread(id: "thread-1", title: "A", pinned: true, archived: nil)
    _ = try store.saveDraft(threadId: "thread-1", text: "x")
    try store.addRefusedUploads(3)
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    _ = try await client.ready()
    let report = try await client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.sync?.pendingUploads == 3)
    #expect(report.sync?.refusedUploads == 3)
    try store.removeOutbox(through: 2)
    #expect(try await client.request(DiagnosticsRead.self, EmptyParams()).sync?.pendingUploads == 1)

    // An older sync section, from before uploads, reads as zero.
    let older = Data(#"{"hubURL":"h","deviceName":"d","cursor":1}"#.utf8)
    let sync = try JSONCoding.decoder.decode(SyncDiagnostic.self, from: older)
    #expect(sync.pendingUploads == 0 && sync.refusedUploads == 0)
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
          lastError: "Hub error 503 shutting_down", undecodableRows: 1, pendingUploads: 0,
          refusedUploads: 0))
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

  @Test func unservedCommandsSayDoneOnTheMac() async throws {
    let h = RelayHarness()
    let client = WorkspaceClient(
      transport: MirrorTransport(store: try MirrorStore.inMemory(), version: "0.2.0", relay: h.relay))
    _ = try await client.ready()
    let options = RequestOptions(operationId: "op-1")
    var refusals: [WorkspaceError?] = []
    refusals.append(
      await #expect(throws: WorkspaceError.self) {
        try await client.request(
          ThreadCreate.self, .init(connectionId: "conn-1", workingDirectory: "/tmp"), options: options)
      })
    refusals.append(
      await #expect(throws: WorkspaceError.self) {
        try await client.request(TurnAbandon.self, .init(threadId: "thread-1"), options: options)
      })
    refusals.append(
      await #expect(throws: WorkspaceError.self) {
        try await client.request(ServerStart.self, .init(serverId: "s1"), options: options)
      })
    refusals.append(
      await #expect(throws: WorkspaceError.self) {
        try await client.request(ProjectDelete.self, .init(projectId: "p1"), options: options)
      })
    refusals.append(
      await #expect(throws: WorkspaceError.self) {
        try await client.request(HubLeave.self, EmptyParams(), options: options)
      })
    for refusal in refusals {
      #expect(refusal?.code == .unsupportedCapability)
      #expect(refusal?.message.hasSuffix("is done on the Mac.") == true, "\(refusal?.message ?? "")")
      #expect(refusal?.message.contains("M8c") == false)
    }
    await client.close()
  }

  // MARK: - Through the relay

  @Test func watchesTheMostRecentlyReadThread() async throws {
    let (store, h, socket) = try await relayedMirror()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    #expect(try await RelayHarness.nextFrame(socket) == .watch(threadId: "thread-1"))
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-2"))
    #expect(try await RelayHarness.nextFrame(socket) == .unwatch(threadId: "thread-1"))
    #expect(try await RelayHarness.nextFrame(socket) == .watch(threadId: "thread-2"))
    #expect(await h.relay.watched == ["thread-2"])
    await client.close()
    await h.relay.stop()
  }

  @Test func lateDeltaForACompletedItemIsIgnored() async throws {
    let (store, h, socket) = try await relayedMirror()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()
    var events = (await client.events()).makeAsyncIterator()
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))

    // item-2 is stored and its turn has finished; item-4 is stored but its turn still runs.
    socket.deliver(.event(delta("stale", native: "native-item-2")))
    socket.deliver(.event(delta(" more", native: "native-item-4")))
    let item = agent("item-9", native: "native-item-9", text: "Done", sequence: 9)
    socket.deliver(.event(try itemEvent(.messageCompleted, item)))
    socket.deliver(.event(delta("late", native: "native-item-9")))
    socket.deliver(.event(marker()))

    let seen = try await collect(&events, until: .turnStateChanged)
    #expect(seen.map(\.kind) == [.messageDelta, .messageCompleted, .turnStateChanged])
    #expect(seen[0].nativeIds["itemId"] == "native-item-4" && seen[0].payload["delta"] == " more")
    await client.close()
    await h.relay.stop()
  }

  @Test func aStreamGapCompletesOpenItemsAndMutesThem() async throws {
    let (store, h, socket) = try await relayedMirror()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()
    var events = (await client.events()).makeAsyncIterator()
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))

    let started = agent("item-9", native: "native-item-9", text: "", sequence: 9)
    socket.deliver(.event(try itemEvent(.messageStarted, started)))
    socket.deliver(.event(delta("Hel", native: "native-item-9")))
    socket.deliver(.streamGap(threadId: "thread-1"))
    socket.deliver(.event(delta("lo", native: "native-item-9")))
    let done = agent("item-9", native: "native-item-9", text: "Hello", sequence: 9)
    socket.deliver(.event(try itemEvent(.messageCompleted, done)))
    socket.deliver(.event(delta("!", native: "native-item-9")))
    socket.deliver(.event(marker()))

    let seen = try await collect(&events, until: .turnStateChanged)
    #expect(
      seen.map(\.kind) == [
        .messageStarted, .messageDelta, .messageCompleted, .messageCompleted, .turnStateChanged,
      ])
    // The gap ends the open item's live text (as its last known state), and its later deltas are dropped.
    #expect(try seen[2].payload["displayItem"]?.decode(DisplayItem.self) == started)
    #expect(try seen[3].payload["displayItem"]?.decode(DisplayItem.self) == done)

    // A dropped link is a gap too.
    socket.deliver(
      .event(
        try itemEvent(.messageStarted, agent("item-10", native: "native-item-10", text: "", sequence: 10))))
    socket.deliver(.event(delta("Hi", native: "native-item-10")))
    _ = try await collect(&events, until: .messageDelta)
    socket.closeFromHub(code: 1001)
    let afterDrop = try await collect(&events, until: .messageCompleted)
    #expect(afterDrop.last?.nativeIds["itemId"] == "native-item-10")
    await client.close()
    await h.relay.stop()
  }

  @Test func aSyncedRowOfAStreamingItemKeepsItsLiveText() async throws {
    let (store, h, socket) = try await relayedMirror()
    let transport = MirrorTransport(store: store, version: "0.2.0", relay: h.relay)
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    var events = (await client.events()).makeAsyncIterator()
    _ = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))

    let started = agent("item-9", native: "native-item-9", text: "", sequence: 9)
    socket.deliver(.event(try itemEvent(.messageStarted, started)))
    socket.deliver(.event(delta("Hel", native: "native-item-9")))
    _ = try await collect(&events, until: .messageDelta)

    // A relayed item not yet synced is part of the thread when it is read again.
    let reread = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    #expect(reread.items.map(\.id) == ["item-1", "item-2", "item-3", "item-4", "item-9"])

    // The Mac's started row arrives first: announced as started, so the live text stays.
    transport.publish(
      try store.apply([change("displayItems", "item-9", "insert", value: try JSONValue(encoding: started))]))
    #expect(try await collect(&events, until: .messageStarted).last?.nativeIds["itemId"] == "native-item-9")
    let done = agent("item-9", native: "native-item-9", text: "Hello", sequence: 9)
    socket.deliver(.event(try itemEvent(.messageCompleted, done)))
    _ = try await collect(&events, until: .messageCompleted)
    // Until the synced row catches up, the relayed completed item is what a read shows.
    #expect(try await client.request(ThreadRead.self, .init(threadId: "thread-1")).items.last == done)

    // Once complete, a synced row is an ordinary completed item, and the read is the store's alone.
    transport.publish(
      try store.apply([
        change("displayItems", "item-9", "update", column: "payload", value: ["text": "Hello"]),
        change("turns", "turn-2", "update", column: "status", value: "terminal"),
      ]))
    let synced = try await collect(&events, until: .messageCompleted)
    #expect(try synced.last?.payload["displayItem"]?.decode(DisplayItem.self).payload["text"] == "Hello")
    let final = try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    #expect(final.items.map(\.id) == ["item-1", "item-2", "item-3", "item-4", "item-9"])
    #expect(final.items.last?.payload["text"] == "Hello")
    await client.close()
    await h.relay.stop()
  }

  @Test func threadStartPlaceholderBuffersAndIsReplacedByTheRow() async throws {
    let (store, h, socket) = try await relayedMirror()
    let now = ManualNow()
    let transport = MirrorTransport(store: store, version: "0.2.0", relay: h.relay, now: now.now)
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    var events = (await client.events()).makeAsyncIterator()

    let params = ThreadStart.Params(
      threadId: "thread-new", projectId: "p1", connectionId: "conn-1", folder: "/Users/brian/project",
      text: "Hi")
    async let started = client.request(ThreadStart.self, params, options: RequestOptions(operationId: "op-s"))
    #expect(
      try await RelayHarness.nextFrame(socket)
        == .command(id: "op-s", method: .threadStart, params: try JSONValue(encoding: params)))

    // The hub watches the new thread for the phone at once, so its events can beat the reply.
    let turn = relayTurn("turn-new", threadId: "thread-new", operationId: "op-s")
    let user = DisplayItem(
      id: "item-u", threadId: "thread-new", turnId: "turn-new", role: .user, type: "userMessage",
      payload: ["text": "Hi"], sequence: 1, provenance: .live, createdAt: "2026-11-01T10:00:00.000Z")
    let reply = agent(
      "item-a", native: "native-a", turnId: "turn-new", text: "", sequence: 2, threadId: "thread-new")
    socket.deliver(.event(try itemEvent(.messageStarted, user)))
    socket.deliver(
      .event(
        AdapterEvent(
          kind: .turnAcknowledged, connectionId: "conn-1", threadId: "thread-new", turnId: "turn-new",
          payload: ["turn": try JSONValue(encoding: turn)])))
    socket.deliver(.event(try itemEvent(.messageStarted, reply)))
    socket.deliver(.event(delta("Hel", native: "native-a", threadId: "thread-new")))
    socket.deliver(.event(delta("lo", native: "native-a", threadId: "thread-new")))
    let thread = ConversationThread(
      id: "thread-new", connectionId: "conn-1", nativeThreadId: "native-new",
      nativeScope: "/Users/brian/project",
      title: "Hi", context: "/Users/brian/project", createdAt: "2026-11-01T10:00:00.000Z",
      updatedAt: "2026-11-01T10:00:00.000Z", projectId: "p1")
    socket.deliver(
      .reply(id: "op-s", result: try JSONValue(encoding: ThreadStart.Result(thread: thread, turn: turn))))
    #expect(try await started.thread == thread)

    // Not in the mirror yet: the read answers with the placeholder and what its events said.
    let read = try await client.request(ThreadRead.self, .init(threadId: "thread-new"))
    #expect(read.thread == thread)
    #expect(read.turns == [turn])
    #expect(read.items.map(\.id) == ["item-u", "item-a"])
    #expect(try await RelayHarness.nextFrame(socket) == .watch(threadId: "thread-new"))

    // The buffered text reaches the model with the next delta, so nothing streamed is lost.
    socket.deliver(.event(delta("!", native: "native-a", threadId: "thread-new")))
    let first = try await collect(&events, until: .messageDelta)
    #expect(first.count == 1 && first[0].payload["delta"] == "Hello!")

    // The synced row replaces the placeholder, and outlives its two minutes.
    var row = try #require(try fixtureAsStored()[1].value?.objectValue)
    row["id"] = "thread-new"
    row["nativeThreadId"] = "native-new"
    row["title"] = "From the Mac"
    transport.publish(try store.apply([change("threads", "thread-new", "insert", value: .object(row))]))
    let updated = try await collect(&events, until: .threadUpdated)
    #expect(updated.last?.threadId == "thread-new")
    now.advance(by: .seconds(180))
    let synced = try await client.request(ThreadRead.self, .init(threadId: "thread-new"))
    #expect(synced.thread.title == "From the Mac")
    #expect(synced.items.map(\.id) == ["item-u", "item-a"])
    await client.close()
    await h.relay.stop()
  }

  @Test func placeholderExpiresAfterTwoMinutes() async throws {
    let (store, h, socket) = try await relayedMirror()
    let now = ManualNow()
    let client = WorkspaceClient(
      transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay, now: now.now))
    _ = try await client.ready()
    let params = ThreadStart.Params(
      threadId: "thread-new", projectId: "p1", connectionId: "conn-1", text: "Hi")
    async let started = client.request(ThreadStart.self, params, options: RequestOptions(operationId: "op-s"))
    _ = try await RelayHarness.nextFrame(socket)
    let turn = relayTurn("turn-new", threadId: "thread-new", operationId: "op-s")
    let thread = ConversationThread(
      id: "thread-new", connectionId: "conn-1", nativeThreadId: "n", title: "Hi")
    socket.deliver(
      .reply(id: "op-s", result: try JSONValue(encoding: ThreadStart.Result(thread: thread, turn: turn))))
    _ = try await started

    now.advance(by: .seconds(119))
    #expect(try await client.request(ThreadRead.self, .init(threadId: "thread-new")).thread == thread)
    now.advance(by: .seconds(2))
    let gone = await #expect(throws: WorkspaceError.self) {
      try await client.request(ThreadRead.self, .init(threadId: "thread-new"))
    }
    #expect(gone?.code == .notFound)

    // A refused start leaves no placeholder behind.
    let other = ThreadStart.Params(
      threadId: "thread-other", projectId: "p1", connectionId: "conn-1", text: "Hi")
    let refused = Task {
      try await client.request(ThreadStart.self, other, options: RequestOptions(operationId: "op-t"))
    }
    #expect(
      try await RelayHarness.nextCommand(socket)
        == .command(id: "op-t", method: .threadStart, params: try JSONValue(encoding: other)))
    socket.deliver(.reply(id: "op-t", error: RelayWireError(.deviceOffline, "offline")))
    let refusal = await #expect(throws: WorkspaceError.self) { try await refused.value }
    #expect(refusal?.code == .deviceOffline)
    await #expect(throws: WorkspaceError.self) {
      try await client.request(ThreadRead.self, .init(threadId: "thread-other"))
    }
    await client.close()
    await h.relay.stop()
  }
}

// MARK: - Relay helpers

/// The fixture plus a second thread, and a relay connected to a fake hub.
private func relayedMirror() async throws -> (MirrorStore, RelayHarness, FakeHubLinkSocket) {
  let store = try MirrorStore.inMemory()
  _ = try store.apply(try fixtureAsStored())
  var second = try #require(try fixtureAsStored()[1].value?.objectValue)
  second["id"] = "thread-2"
  second["nativeThreadId"] = "native-thread-2"
  _ = try store.apply([change("threads", "thread-2", "insert", value: .object(second))])
  let h = RelayHarness()
  let socket = await h.connect()
  return (store, h, socket)
}

private func agent(
  _ id: String, native: String, turnId: String = "turn-2", text: String, sequence: Int,
  threadId: String = "thread-1"
) -> DisplayItem {
  DisplayItem(
    id: id, threadId: threadId, turnId: turnId, nativeItemId: native, role: .assistant, type: "agentMessage",
    payload: ["text": .string(text)], sequence: sequence, provenance: .live,
    createdAt: "2026-11-01T10:00:02.000Z")
}

/// A relayed item event as the Mac's coordinator emits it.
private func itemEvent(_ kind: EventKind, _ item: DisplayItem) throws -> AdapterEvent {
  AdapterEvent(
    kind: kind, connectionId: "conn-1", threadId: item.threadId, turnId: item.turnId,
    nativeIds: item.nativeItemId.map { ["itemId": $0] } ?? [:],
    payload: ["displayItem": try JSONValue(encoding: item)])
}

private func delta(_ text: String, native: String, threadId: String = "thread-1") -> AdapterEvent {
  AdapterEvent(
    kind: .messageDelta, connectionId: "conn-1", threadId: threadId, nativeIds: ["itemId": native],
    payload: ["delta": .string(text)])
}

/// An event that ends a test's batch.
private func marker() -> AdapterEvent {
  AdapterEvent(
    kind: .turnStateChanged, connectionId: "conn-1", threadId: "thread-1", payload: ["status": "running"])
}

/// Events up to and including the first of `kind`, skipping `host.presence`.
private func collect(
  _ events: inout AsyncStream<EventEnvelope>.Iterator, until kind: EventKind,
  isolation: isolated (any Actor)? = #isolation
) async throws -> [AdapterEvent] {
  var seen: [AdapterEvent] = []
  while let envelope = await events.next(isolation: isolation) {
    if envelope.event.kind == .hostPresence { continue }
    seen.append(envelope.event)
    if envelope.event.kind == kind { return seen }
  }
  throw WorkspaceError(.internalError, "the event stream ended")
}
