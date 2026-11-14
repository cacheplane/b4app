import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let phoneId = "phone-1"
private let macId = "mac-1"

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: phoneId, deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove")

private func linkedStore() throws -> MirrorStore {
  let store = try MirrorStore.inMemory()
  try store.saveLink(link)
  return store
}

/// A view settings change pulled from the hub, from the Mac unless `deviceId` says otherwise.
private func pulled(
  _ op: String, column: String? = nil, value: JSONValue?, hlc: String, deviceId: String = macId
) -> StoredChange {
  StoredChange(
    hubSeq: 700, deviceId: deviceId, deviceSeq: 700, wall: Int(HLC(rawValue: hlc)?.millis ?? 0),
    table: "viewSettings", rowId: ViewSettings.rowId, op: op, column: column, value: value, hlc: hlc)
}

/// The Mac's clock at `millis`.
private func hlc(_ millis: UInt64) -> String { HLC(millis: millis, counter: 0, deviceId: macId).rawValue }

/// The row's stored cell for `column`, as text, exactly as the mirror holds it (nil for NULL).
private func stored(_ store: MirrorStore, _ column: String) throws -> String? {
  let cell = try store.locked {
    try store.query(
      "SELECT \(MirrorStore.quote(column)) AS \"v\" FROM \"viewSettings\" WHERE \"id\" = 'view'"
    ).first?["v"]
  }
  switch cell {
  case .text(let text)?: return text
  case .integer(let value)?: return String(value)
  default: return nil
  }
}

private func settingsEvent(_ events: AsyncStream<EventEnvelope>) async throws -> ViewSettings? {
  for await envelope in events where envelope.event.kind == .viewSettingsChanged {
    return try envelope.event.payload["settings"]?.decode(ViewSettings.self)
  }
  return nil
}

@Suite(.timeLimit(.minutes(1))) struct MirrorViewSettingsTests {
  @Test func aFreshMirrorReadsDefaults() async throws {
    let store = try MirrorStore.inMemory()
    #expect(try store.viewSettings() == ViewSettings())
    #expect(try store.rowCount("viewSettings") == 0)

    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    _ = try await client.ready()
    #expect(try await client.request(ViewSettingsGet.self, EmptyParams()) == ViewSettings())
    // Reading writes nothing.
    #expect(try store.rowCount("viewSettings") == 0)
    #expect(store.outboxCount == 0)
    await client.close()
  }

  @Test func settingOnThePhoneQueuesOneOutboxChangePerColumn() throws {
    let store = try linkedStore()
    let first = try store.setViewSettings(quietThreads: .collapsed)
    #expect(first == ViewSettings(quietThreads: .collapsed))
    #expect(try store.viewSettings() == first)

    // The row is missing, so the first write is one insert of the key and what it set.
    let insert = try #require(try store.outbox(limit: 10).first)
    #expect(store.outboxCount == 1)
    #expect(insert.op == "insert" && insert.table == "viewSettings" && insert.rowId == "view")
    #expect(insert.column == nil)
    let row = try #require(insert.value?.objectValue)
    #expect(Set(row.keys) == ["id", "quietThreads", "updatedAt"])
    #expect(row["id"] == "view" && row["quietThreads"] == "collapsed")
    for column in ["id", "quietThreads", "updatedAt"] {
      #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: column) == insert.hlc)
    }
    for column in ["arrangement", "showArchived"] {
      #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: column) == nil)
    }

    // Then one update per changed column, all at one clock.
    let second = try store.setViewSettings(arrangement: .byEnvironment, showArchived: true)
    #expect(second == ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed, showArchived: true))
    let updates = Array(try store.outbox(limit: 10).dropFirst())
    #expect(updates.allSatisfy { $0.op == "update" && $0.table == "viewSettings" && $0.rowId == "view" })
    #expect(updates.compactMap(\.column).filter { $0 != "updatedAt" } == ["arrangement", "showArchived"])
    #expect(updates.filter { $0.column == "updatedAt" }.count <= 1)
    #expect(updates.first { $0.column == "arrangement" }?.value == "byEnvironment")
    #expect(updates.first { $0.column == "showArchived" }?.value == .bool(true))
    #expect(Set(updates.map(\.hlc)).count == 1)
    #expect(try stored(store, "showArchived") == "1")

    // A write that changes nothing queues nothing.
    let count = store.outboxCount
    #expect(try store.setViewSettings(arrangement: .byEnvironment) == second)
    #expect(try store.setViewSettings() == second)
    #expect(store.outboxCount == count)
  }

  @Test func aPulledChangeUpdatesTheMirrorAndEmitsChanged() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    let events = await client.events()

    // The shared fixture: an insert of the row, then an update of `quietThreads`.
    let batch = try store.apply(Array(try fixtureAsStored().suffix(2)))
    #expect(batch.touchedViewSettings)
    #expect(batch.skipped == 0)
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed))
    transport.publish(batch)
    #expect(try await settingsEvent(events) == ViewSettings(quietThreads: .collapsed))
    #expect(store.outboxCount == 0)

    // A pulled update to null is an update: the field reads as its default again.
    let cleared = try store.apply([
      pulled("update", column: "quietThreads", value: .null, hlc: macClock.next().rawValue)
    ])
    #expect(cleared.touchedViewSettings)
    #expect(try store.viewSettings() == ViewSettings())

    // A batch that does not touch the row says so.
    #expect(!(try store.apply(Array(try fixtureAsStored().prefix(2)))).touchedViewSettings)
    await client.close()
  }

  /// A snapshot or resync may deliver the row as updates with no insert; the row is created then.
  @Test func aPulledUpdateWithoutAnInsertCreatesTheRow() throws {
    let store = try MirrorStore.inMemory()
    let hlc = macClock.next().rawValue
    let batch = try store.apply([pulled("update", column: "arrangement", value: "byEnvironment", hlc: hlc)])
    #expect(batch.touchedViewSettings && batch.skipped == 0)
    #expect(try store.viewSettings() == ViewSettings(arrangement: .byEnvironment))
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "arrangement") == hlc)
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads") == nil)

    // Only the one row, and never its key.
    let other = try store.apply([
      StoredChange(
        hubSeq: 701, deviceId: macId, deviceSeq: 701, wall: 0, table: "viewSettings", rowId: "other",
        op: "update", column: "arrangement", value: "byEnvironment", hlc: macClock.next().rawValue),
      pulled("update", column: "id", value: "other", hlc: macClock.next().rawValue),
    ])
    #expect(other.skipped == 2 && !other.touchedViewSettings)
    #expect(try store.rowCount("viewSettings") == 1)
  }

  @Test func tinyFromTheMacReadsAsDenseAndStaysTinyInTheMirror() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply([
      pulled("update", column: "quietThreads", value: "tiny", hlc: macClock.next().rawValue)
    ])
    let settings = try store.viewSettings()
    #expect(settings == ViewSettings(density: .dense))
    #expect(try stored(store, "quietThreads") == "tiny")

    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    _ = try await client.ready()
    #expect(try await client.request(ViewSettingsGet.self, EmptyParams()) == ViewSettings(density: .dense))
    // Reading the old value writes nothing back.
    #expect(store.outboxCount == 0)
    #expect(try stored(store, "quietThreads") == "tiny")
    await client.close()
  }

  @Test func changingShowArchivedOnThePhoneLeavesTinyStored() async throws {
    let store = try linkedStore()
    _ = try store.apply([
      pulled("update", column: "quietThreads", value: "tiny", hlc: macClock.next().rawValue),
      pulled("update", column: "arrangement", value: "grid", hlc: macClock.next().rawValue),
    ])
    let writes = Mutex(0)
    let transport = MirrorTransport(
      store: store, version: "0.2.0", onLocalWrite: { writes.withLock { $0 += 1 } })
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    let events = await client.events()
    var n = 0
    func options() -> RequestOptions {
      n += 1
      return RequestOptions(operationId: "op-\(n)")
    }

    let result = try await client.request(
      ViewSettingsSet.self, .init(showArchived: true), options: options())
    // An unknown arrangement reads as the default; the stored tiny is answered as shown and dense.
    #expect(result == ViewSettings(showArchived: true, density: .dense))
    #expect(try await settingsEvent(events) == result)
    #expect(writes.withLock { $0 } == 1)

    let queued = try store.outbox(limit: 10)
    #expect(queued.allSatisfy { $0.op == "update" })
    #expect(queued.compactMap(\.column).filter { $0 != "updatedAt" } == ["showArchived"])
    #expect(try stored(store, "quietThreads") == "tiny")
    #expect(try stored(store, "arrangement") == "grid")

    // A write that changes nothing announces nothing: the next event is the next real change.
    _ = try await client.request(ViewSettingsSet.self, .init(showArchived: true), options: options())
    let changed = try await client.request(
      ViewSettingsSet.self, .init(arrangement: .byEnvironment), options: options())
    #expect(try await settingsEvent(events) == changed)
    #expect(changed == ViewSettings(arrangement: .byEnvironment, showArchived: true, density: .dense))
    await client.close()
  }

  @Test func settingDensityOnAnEmptyMirrorInsertsOnlyDensity() throws {
    let store = try linkedStore()
    #expect(try store.setViewSettings(density: .dense) == ViewSettings(density: .dense))
    #expect(try stored(store, "density") == "dense")
    #expect(store.outboxCount == 1)
    let insert = try #require(try store.outbox(limit: 10).first)
    #expect(insert.op == "insert")
    let row = try #require(insert.value?.objectValue)
    #expect(Set(row.keys) == ["id", "density", "updatedAt"])
    #expect(row["density"] == "dense")
  }

  /// Replacing a stored `tiny` with no density also writes the density it implied, so the rows keep
  /// their size.
  @Test func replacingTinyAlsoWritesTheDensityItImplied() throws {
    let store = try linkedStore()
    _ = try store.apply([
      pulled("update", column: "quietThreads", value: "tiny", hlc: macClock.next().rawValue)
    ])
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .shown, density: .dense))
    #expect(try stored(store, "density") == nil)

    let settings = try store.setViewSettings(quietThreads: .hidden)
    #expect(settings == ViewSettings(quietThreads: .hidden, density: .dense))
    #expect(try store.viewSettings() == settings)
    #expect(try stored(store, "quietThreads") == "hidden")
    #expect(try stored(store, "density") == "dense")
    let queued = try store.outbox(limit: 10)
    #expect(queued.allSatisfy { $0.op == "update" })
    #expect(Set(queued.compactMap(\.column).filter { $0 != "updatedAt" }) == ["quietThreads", "density"])
    #expect(queued.first { $0.column == "density" }?.value == "dense")
    #expect(Set(queued.map(\.hlc)).count == 1)
    let densityClock = try store.columnClock(table: "viewSettings", rowId: "view", column: "density")
    #expect(densityClock == queued.first?.hlc)

    // Once a density is stored, setting `quietThreads` writes only that (folded into its unsent
    // update), and the queued density keeps its clock.
    let densityHLC = queued.first { $0.column == "density" }?.hlc
    _ = try store.setViewSettings(quietThreads: .collapsed)
    let later = try store.outbox(limit: 10)
    #expect(later.first { $0.column == "quietThreads" }?.value == "collapsed")
    #expect(later.filter { $0.column == "density" }.map(\.hlc) == [densityHLC])
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed, density: .dense))
  }

  /// A density this build does not know (a newer build's) is never replaced by the implied one.
  @Test func anUnknownStoredDensityIsKeptWhenTinyIsReplaced() throws {
    let store = try linkedStore()
    _ = try store.apply([
      pulled("update", column: "quietThreads", value: "tiny", hlc: macClock.next().rawValue),
      pulled("update", column: "density", value: "huge", hlc: macClock.next().rawValue),
    ])
    _ = try store.setViewSettings(quietThreads: .collapsed)
    #expect(try stored(store, "density") == "huge")
    #expect(try stored(store, "quietThreads") == "collapsed")
    let queued = try store.outbox(limit: 10)
    #expect(!queued.contains { $0.column == "density" })
    #expect(queued.compactMap(\.column).filter { $0 != "updatedAt" } == ["quietThreads"])
  }

  /// The hub's log can still end in an old `tiny` that no migration rewrote; a pulled replacement of it
  /// keeps the dense rows `tiny` implied, stored here without a clock or an outbox entry, so any real
  /// density change still wins over it.
  @Test func aPulledSidebarChangeKeepsTheDensityTinyImplied() throws {
    let store = try linkedStore()
    let at = UInt64(Date().timeIntervalSince1970 * 1000) - 10_000
    let batch = try store.apply([
      pulled("insert", value: ["id": "view", "quietThreads": "tiny"], hlc: hlc(at)),
      pulled("update", column: "quietThreads", value: "collapsed", hlc: hlc(at + 1)),
    ])
    #expect(batch.touchedViewSettings && batch.skipped == 0)
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed, density: .dense))
    #expect(try stored(store, "density") == "dense")
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "density") == nil)
    #expect(store.outboxCount == 0)

    // A real density change, older than every clock so far, still applies over it.
    let later = try store.apply([pulled("update", column: "density", value: "normal", hlc: hlc(at - 5_000))])
    #expect(later.touchedViewSettings)
    #expect(try stored(store, "density") == "normal")
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed))
    #expect(store.outboxCount == 0)
  }

  /// A density change pulled between the old `tiny` and its replacement is kept: nothing is implied
  /// over a stored density.
  @Test func aPulledDensityBeforeTheSidebarChangeIsKept() throws {
    let store = try linkedStore()
    let at = UInt64(Date().timeIntervalSince1970 * 1000) - 10_000
    _ = try store.apply([
      pulled("insert", value: ["id": "view", "quietThreads": "tiny"], hlc: hlc(at)),
      pulled("update", column: "density", value: "normal", hlc: hlc(at + 1)),
      pulled("update", column: "quietThreads", value: "collapsed", hlc: hlc(at + 2)),
    ])
    #expect(try stored(store, "density") == "normal")
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed))
    #expect(store.outboxCount == 0)
  }

  /// A stored density this build does not know is a newer build's value; a pulled sidebar change over
  /// `tiny` keeps it.
  @Test func aPulledSidebarChangeKeepsAnUnknownDensity() throws {
    let store = try linkedStore()
    _ = try store.apply([
      pulled(
        "insert", value: ["id": "view", "quietThreads": "tiny", "density": "huge"],
        hlc: macClock.next().rawValue),
      pulled("update", column: "quietThreads", value: "collapsed", hlc: macClock.next().rawValue),
    ])
    #expect(try stored(store, "density") == "huge")
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed))
    #expect(store.outboxCount == 0)
  }

  /// A first write of `quietThreads` on a missing row implies nothing: the insert carries only it.
  @Test func aFirstQuietThreadsWriteInsertsNoDensity() throws {
    let store = try linkedStore()
    _ = try store.setViewSettings(quietThreads: .hidden)
    let insert = try #require(try store.outbox(limit: 10).first)
    #expect(Set(try #require(insert.value?.objectValue).keys) == ["id", "quietThreads", "updatedAt"])
    #expect(try stored(store, "density") == nil)
  }

  @Test func theTransportPassesDensity() async throws {
    let store = try linkedStore()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0"))
    _ = try await client.ready()
    let result = try await client.request(
      ViewSettingsSet.self, .init(density: .dense), options: RequestOptions(operationId: "op-1"))
    #expect(result == ViewSettings(density: .dense))
    #expect(try stored(store, "density") == "dense")
    await client.close()
  }

  @Test func anUnavailableMirrorRefusesViewSettingsWrites() async throws {
    let store = try MirrorStore.inMemory()
    let client = WorkspaceClient(
      transport: MirrorTransport(store: store, version: "0.2.0", unavailable: "Kept for its edits."))
    _ = try await client.ready()
    #expect(try await client.request(ViewSettingsGet.self, EmptyParams()) == ViewSettings())
    let refused = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        ViewSettingsSet.self, .init(showArchived: true), options: RequestOptions(operationId: "op-1"))
    }
    #expect(refused?.code == .endpointUnavailable)
    #expect(store.outboxCount == 0)
    await client.close()
  }

  enum Order: String, CaseIterable { case phoneFirst, macFirst }

  /// Two devices each create the row before seeing the other's, each setting a different field. The
  /// phone's insert carries and clocks only what it set, and a pulled insert's null or absent column is
  /// "not set", so neither overwrites the other's setting, whichever clock is newer and whichever
  /// arrives first, and whether the Mac's insert names the unset field as null or leaves it out.
  @Test(arguments: Order.allCases, [(false, false), (false, true), (true, false), (true, true)])
  func firstInsertsOnTwoDevicesKeepBothSettings(order: Order, mac: (isNewer: Bool, sendsNull: Bool)) throws {
    let macIsNewer = mac.isNewer
    let store = try linkedStore()
    var macRow: [String: JSONValue] = [
      "id": "view", "arrangement": "byEnvironment", "updatedAt": "2026-11-11T12:00:00.000Z",
    ]
    if mac.sendsNull {
      macRow["quietThreads"] = .null
      macRow["showArchived"] = .null
    }
    let macInsert: (String) -> StoredChange = { hlc in pulled("insert", value: .object(macRow), hlc: hlc) }
    var macHLC = ""
    switch order {
    case .phoneFirst:
      // Offline: the phone has never seen the Mac's row.
      _ = try store.setViewSettings(quietThreads: .hidden)
      let phoneHLC = try store.outbox(limit: 1).first?.hlc ?? ""
      let phone = try #require(HLC(rawValue: phoneHLC))
      macHLC =
        HLC(millis: macIsNewer ? phone.millis + 10 : phone.millis - 10, counter: 0, deviceId: macId).rawValue
      #expect(try store.apply([macInsert(macHLC)]).touchedViewSettings)
    case .macFirst:
      let now = UInt64(Date().timeIntervalSince1970 * 1000)
      macHLC = HLC(millis: macIsNewer ? now + 10_000 : now - 10_000, counter: 0, deviceId: macId).rawValue
      _ = try store.apply([macInsert(macHLC)])
      _ = try store.setViewSettings(quietThreads: .hidden)
    }

    #expect(try store.viewSettings() == ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden))
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "arrangement") == macHLC)
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "showArchived") == nil)
    let own = try #require(try store.outbox(limit: 10).first)
    #expect(try store.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads") == own.hlc)
    if order == .phoneFirst {
      #expect(own.op == "insert")
      let keys = Set(try #require(own.value?.objectValue).keys)
      #expect(!keys.contains("arrangement") && !keys.contains("showArchived"))
    } else {
      #expect(own.op == "update" && own.column == "quietThreads")
    }

    // The phone's own change coming back from the hub, and a snapshot that replays the unsent edit
    // over the Mac's row, leave both settings in place.
    _ = try store.apply([
      StoredChange(
        hubSeq: 800, deviceId: phoneId, deviceSeq: own.deviceSeq, wall: own.wall, table: own.table,
        rowId: own.rowId, op: own.op, column: own.column, value: own.value, hlc: own.hlc)
    ])
    try store.applySnapshot(
      SnapshotResponse(
        changes: [macInsert(macHLC)],
        clocks: [
          ColumnClock(table: "viewSettings", rowId: "view", column: "id", hlc: macHLC),
          ColumnClock(table: "viewSettings", rowId: "view", column: "arrangement", hlc: macHLC),
          ColumnClock(table: "viewSettings", rowId: "view", column: "updatedAt", hlc: macHLC),
        ], next: 900))
    #expect(try store.viewSettings() == ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden))
  }
}
