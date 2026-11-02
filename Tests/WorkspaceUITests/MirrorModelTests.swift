import Foundation
import Testing
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceUI

/// The shared wire fixture as the hub serves it (`hubSeq = index + 1`, from `mac-1`), read in place.
private func fixtureAsStored(file: StaticString = #filePath) throws -> [StoredChange] {
  let url = URL(fileURLWithPath: "\(file)")
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sync/changes.json")
  let wire = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
  return wire.enumerated().map { index, change in
    StoredChange(
      hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
      table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
  }
}

/// The real `WorkspaceModel` over a `MirrorTransport`: no coordinator, no socket.
@Suite(.serialized) @MainActor struct MirrorModelTests {
  @Test func modelShowsMirroredThreadsAndLiveItems() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    let fixture = try fixtureAsStored()

    transport.publish(try store.apply(Array(fixture.prefix(2))))  // connection + thread
    try await waitUntil("thread listed") { model.threads.count == 1 }
    try await waitUntil("connection listed") { model.connections.count == 1 }

    await model.openThread(id: "thread-1")
    try await waitUntil("detail") { model.detail != nil }
    #expect(model.detail?.items.isEmpty == true)

    transport.publish(try store.apply(Array(fixture[2..<8])))  // turns + items
    try await waitUntil("items") { model.detail?.items.count == 4 }
    #expect(model.detail?.items.map(\.id) == ["item-1", "item-2", "item-3", "item-4"])

    transport.publish(try store.apply([fixture[9]]))  // the title update
    try await waitUntil("renamed") { model.threads.first?.title == "Renamed" }
    #expect(model.detail?.thread.title == "Renamed")
    #expect(model.connections.first?.target == "")
    #expect(model.connections.first?.authReference == nil)

    await model.refreshDiagnostics()
    #expect(model.diagnostics?.coordinator.socketPath == "mirror")
    await model.disconnect()
  }

  // MARK: - Live progress through the relay (M8c)

  /// The model over a mirror of the fixture, with a relay on a fake hub, and thread-1 open.
  private func relayedModel() async throws -> (
    WorkspaceModel, MirrorStore, MirrorTransport, FakeHubLinkSocket
  ) {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    let connection = FakeHubLinkConnection()
    // A clock that never moves: the fake hub sends no pongs, and on the real clock the relay's 30 s
    // silence timer ended the link when a busy run kept the test going that long.
    let relay = MirrorRelay(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: connection,
      clock: TestClock(), jitter: { 1.0 })
    await relay.start()
    let socket = await connection.nextSocket()
    socket.deliver(
      .hello(
        protocol: 1, minClientProtocol: 1, deviceId: "phone-1", role: .client, heartbeatSeconds: 10,
        hubTime: Timestamp.now()))
    let transport = MirrorTransport(store: store, version: "0.2.0", relay: relay)
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: "thread-1")
    try await waitUntil("detail") { model.detail?.items.count == 4 }
    return (model, store, transport, socket)
  }

  /// A model that connects over a relay already linked, whose presence was heard before the
  /// transport and the model existed (a model reconnect): the snapshot carries it.
  @Test func presenceHeardBeforeTheModelConnectsIsShown() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    let connection = FakeHubLinkConnection()
    // A clock that never moves: the fake hub sends no pongs, and on the real clock the relay's 30 s
    // silence timer ended the link when a busy run kept the test going that long.
    let relay = MirrorRelay(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: connection,
      clock: TestClock(), jitter: { 1.0 })
    await relay.start()
    let socket = await connection.nextSocket()
    socket.deliver(
      .hello(
        protocol: 1, minClientProtocol: 1, deviceId: "phone-1", role: .client, heartbeatSeconds: 10,
        hubTime: Timestamp.now()))
    let mac = RelayHostPresence(deviceId: "mac-1", name: "Brian's MacBook Pro", online: true)
    socket.deliver(.presence(hosts: [mac]))
    for _ in 0..<500 where await relay.hosts != [mac] { try await Task.sleep(for: .milliseconds(2)) }
    try #require(await relay.hosts == [mac])

    let transport = MirrorTransport(store: store, version: "0.2.0", relay: relay)
    let model = WorkspaceModel(transportProvider: { transport })
    model.accountSource = .host
    model.connect()
    try #require(await model.settledLink() == .ready)
    try await waitUntil("presence", timeout: .seconds(10)) {
      model.hostPhase(deviceId: "mac-1") == .connected
    }
    #expect(model.hubLinkPhase == .connected)
    #expect(model.hostPresence["mac-1"]?.name == "Brian's MacBook Pro")
    await model.disconnect()
    await relay.stop()
  }

  /// Each presence frame is the whole set of the user's Macs: one that leaves it (revoked) is dropped,
  /// from the model and from the snapshot a reconnecting model reads.
  @Test func aMacMissingFromTheNextPresenceIsDropped() async throws {
    let (model, _, _, socket) = try await relayedModel()
    model.accountSource = .host
    let mac = RelayHostPresence(deviceId: "mac-1", name: "Brian's MacBook Pro", online: true)
    let studio = RelayHostPresence(deviceId: "mac-2", name: "Studio", online: true)
    socket.deliver(.presence(hosts: [mac, studio]))
    try await waitUntil("both Macs", timeout: .seconds(10)) {
      Set(model.hostPresence.keys) == ["mac-1", "mac-2"]
    }
    socket.deliver(.presence(hosts: [studio]))
    try await waitUntil("the revoked Mac dropped", timeout: .seconds(10)) {
      Set(model.hostPresence.keys) == ["mac-2"]
    }
    socket.deliver(.presence(hosts: []))
    try await waitUntil("no Macs", timeout: .seconds(10)) { model.hostPresence.isEmpty }
    await model.disconnect()
  }

  private func agent(_ text: String) -> DisplayItem {
    DisplayItem(
      id: "item-9", threadId: "thread-1", turnId: "turn-2", nativeItemId: "native-9", role: .assistant,
      type: "agentMessage", payload: ["text": .string(text)], sequence: 9, provenance: .live,
      createdAt: "2026-11-01T10:00:02.000Z")
  }

  private func itemEvent(_ kind: EventKind, _ item: DisplayItem) throws -> RelayMessage {
    .event(
      AdapterEvent(
        kind: kind, connectionId: "conn-1", threadId: "thread-1", turnId: "turn-2",
        nativeIds: ["itemId": "native-9"], payload: ["displayItem": try JSONValue(encoding: item)]))
  }

  private func delta(_ text: String) -> RelayMessage {
    .event(
      AdapterEvent(
        kind: .messageDelta, connectionId: "conn-1", threadId: "thread-1", nativeIds: ["itemId": "native-9"],
        payload: ["delta": .string(text)]))
  }

  private func count(_ model: WorkspaceModel, _ id: String) -> Int {
    model.detail?.items.filter { $0.id == id }.count ?? 0
  }

  @Test func relayedDeltaStreamsThenSyncedItemReplacesIt() async throws {
    let (model, store, transport, socket) = try await relayedModel()
    socket.deliver(try itemEvent(.messageStarted, agent("")))
    socket.deliver(delta("Hel"))
    socket.deliver(delta("lo"))
    try await waitUntil("streamed") { model.detail?.liveText["native-9"] == "Hello" }
    #expect(count(model, "item-9") == 1)

    // The Mac uploads the started row mid-reply: the same item, and the live text keeps streaming.
    transport.publish(
      try store.apply([change("displayItems", "item-9", "insert", value: try JSONValue(encoding: agent("")))])
    )
    socket.deliver(delta(" there"))
    try await waitUntil("still streaming") { model.detail?.liveText["native-9"] == "Hello there" }
    #expect(count(model, "item-9") == 1)

    socket.deliver(try itemEvent(.messageCompleted, agent("Hello there")))
    try await waitUntil("completed") { model.detail?.liveText["native-9"] == nil }
    #expect(model.detail?.items.first { $0.id == "item-9" }?.payload["text"] == "Hello there")

    // The finished row syncs: one item, never two, and a refetch keeps it.
    transport.publish(
      try store.apply([
        change("displayItems", "item-9", "update", column: "payload", value: ["text": "Hello there"]),
        change("turns", "turn-2", "update", column: "status", value: "terminal"),
      ]))
    try await waitUntil("turn synced") {
      model.detail?.turns.first { $0.id == "turn-2" }?.status == .terminal
    }
    #expect(count(model, "item-9") == 1)
    #expect(model.detail?.items.count == 5)
    #expect(model.detail?.items.first { $0.id == "item-9" }?.payload["text"] == "Hello there")
    await model.disconnect()
  }

  @Test func streamGapClearsLiveText() async throws {
    let (model, _, _, socket) = try await relayedModel()
    socket.deliver(try itemEvent(.messageStarted, agent("")))
    socket.deliver(delta("Hel"))
    try await waitUntil("streamed") { model.detail?.liveText["native-9"] == "Hel" }

    socket.deliver(.streamGap(threadId: "thread-1"))
    try await waitUntil("live text dropped") { model.detail?.liveText["native-9"] == nil }
    // Later deltas of that message wait for sync; a new message still streams.
    socket.deliver(delta("lo"))
    let next = DisplayItem(
      id: "item-10", threadId: "thread-1", turnId: "turn-2", nativeItemId: "native-10", role: .assistant,
      type: "agentMessage", payload: ["text": ""], sequence: 10, provenance: .live,
      createdAt: "2026-11-01T10:00:03.000Z")
    socket.deliver(
      .event(
        AdapterEvent(
          kind: .messageStarted, connectionId: "conn-1", threadId: "thread-1", turnId: "turn-2",
          nativeIds: ["itemId": "native-10"], payload: ["displayItem": try JSONValue(encoding: next)])))
    socket.deliver(
      .event(
        AdapterEvent(
          kind: .messageDelta, connectionId: "conn-1", threadId: "thread-1",
          nativeIds: ["itemId": "native-10"],
          payload: ["delta": "Next"])))
    try await waitUntil("the next message") { model.detail?.liveText["native-10"] == "Next" }
    #expect(model.detail?.liveText["native-9"] == nil)
    #expect(count(model, "item-9") == 1)

    socket.deliver(try itemEvent(.messageCompleted, agent("Hello")))
    try await waitUntil("completed") {
      model.detail?.items.first { $0.id == "item-9" }?.payload["text"] == "Hello"
    }
    await model.disconnect()
  }

  /// The Mac's catch-up: one delta carrying the whole text so far, marked `catchUp`.
  private func catchUp(_ text: String) -> RelayMessage {
    .event(
      AdapterEvent(
        kind: .messageDelta, connectionId: "conn-1", threadId: "thread-1", nativeIds: ["itemId": "native-9"],
        payload: ["delta": .string(text), "catchUp": true]))
  }

  /// The Mac relinked mid-reply: its catch-up repeats what the phone already shows, so only the rest is
  /// added, and nothing when there is no rest.
  @Test func aCatchUpAfterAMacRelinkResumesTheText() async throws {
    let (model, _, _, socket) = try await relayedModel()
    socket.deliver(try itemEvent(.messageStarted, agent("")))
    socket.deliver(delta("Hel"))
    try await waitUntil("streamed") { model.detail?.liveText["native-9"] == "Hel" }

    socket.deliver(catchUp("Hello"))
    try await waitUntil("resumed", timeout: .seconds(10)) { model.detail?.liveText["native-9"] == "Hello" }
    socket.deliver(catchUp("Hello"))
    socket.deliver(delta(" there"))
    try await waitUntil("streaming on", timeout: .seconds(10)) {
      model.detail?.liveText["native-9"] == "Hello there"
    }
    #expect(count(model, "item-9") == 1)

    // A catch-up that does not start with what is shown replaces it.
    socket.deliver(catchUp("Howdy"))
    try await waitUntil("replaced", timeout: .seconds(10)) { model.detail?.liveText["native-9"] == "Howdy" }
    socket.deliver(delta("!"))
    try await waitUntil("appended", timeout: .seconds(10)) { model.detail?.liveText["native-9"] == "Howdy!" }
    #expect(count(model, "item-9") == 1)
    await model.disconnect()
  }

  /// After a gap (the phone's link dropped), the item's live text was cleared and its deltas muted; the
  /// catch-up that follows the rewatch shows the whole text, and later deltas append to it.
  @Test func aCatchUpAfterAGapShowsTheTextAgain() async throws {
    let (model, _, _, socket) = try await relayedModel()
    socket.deliver(try itemEvent(.messageStarted, agent("")))
    socket.deliver(delta("Hel"))
    try await waitUntil("streamed") { model.detail?.liveText["native-9"] == "Hel" }
    socket.deliver(.streamGap(threadId: "thread-1"))
    try await waitUntil("live text dropped") { model.detail?.liveText["native-9"] == nil }

    socket.deliver(catchUp("Hello"))
    try await waitUntil("caught up", timeout: .seconds(10)) { model.detail?.liveText["native-9"] == "Hello" }
    socket.deliver(delta(" there"))
    try await waitUntil("appended", timeout: .seconds(10)) {
      model.detail?.liveText["native-9"] == "Hello there"
    }
    #expect(count(model, "item-9") == 1)
    await model.disconnect()
  }
}

/// Stamps changes after the fixture's clocks, as a Mac writing in order would.
private let macClock = HybridClock(deviceId: "mac-1")

private func change(
  _ table: String, _ rowId: String, _ op: String, column: String? = nil, value: JSONValue? = nil
) -> StoredChange {
  StoredChange(
    hubSeq: 1000, deviceId: "mac-1", deviceSeq: 1000, wall: 0, table: table, rowId: rowId, op: op,
    column: column, value: value, hlc: macClock.next().rawValue)
}
