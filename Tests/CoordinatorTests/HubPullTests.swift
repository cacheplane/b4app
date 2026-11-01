import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

private let enrolled = EnrollResponse(
  deviceId: "dev-mac", token: "tok-pull", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"))
private let code = "PULL2345"
private let devices = [
  DeviceInfo(id: "dev-old-mac", name: "Old Mac", platform: "macos", revokedAt: "2026-10-01T00:00:00.000000Z"),
  DeviceInfo(id: "dev-mac", name: "Mac", platform: "macos"),
  DeviceInfo(id: "dev-phone", name: "Phone", platform: "ios"),
]

private func phoneClock(ahead: UInt64 = 60_000, device: String = "dev-phone") -> String {
  HLC(millis: epochMillis() + ahead, counter: 0, deviceId: device).rawValue
}

/// A Mac store with one connection and one thread, a fake hub that knows the Mac and a phone, and a
/// started `HubSync` joined to it (so its pull loop runs).
private struct PullHarness {
  let db: WorkspaceDatabase
  let fake: FakeHubAPI
  let events: EventLog
  let hub: HubSync
  /// Fired as each hub call starts and ends, and by an `EventRecorder` given it.
  let signal: SyncSignal

  static func start(join: Bool = true) async throws -> PullHarness {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(
      Connection(
        id: "c1", kind: .claude, label: "Claude", target: "/usr/local/bin/claude",
        nativeScope: "/Users/me/.claude"))
    _ = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "n1", nativeScope: "/x", title: "First",
        context: "/tmp/p"))
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(code, enrolled)
    await fake.setDevices(devices)
    let events = EventLog()
    let signal = SyncSignal()
    let hub = HubSync(
      database: db, secretStore: MemorySecretStore(), eventLog: events,
      makeAPI: { _, _ in ProbedHub(fake, signal) })
    await hub.start()
    let harness = PullHarness(db: db, fake: fake, events: events, hub: hub, signal: signal)
    do {
      if join {
        _ = try await hub.join(url: "http://127.0.0.1:8080", code: code, deviceName: "Mac")
        // The first pull walks past the Mac's own pushes (all skipped) to the feed's tip.
        let tip = await fake.stored.last?.hubSeq ?? 0
        try await harness.waitFor("the cursor to reach the tip") { try db.hubLink()?.cursor == tip }
      }
    } catch {
      await harness.close()
      throw error
    }
    return harness
  }

  /// Starts a harness, runs `body`, and closes the harness (awaited) whether `body` threw or not.
  static func with(join: Bool = true, _ body: (PullHarness) async throws -> Void) async throws {
    let harness = try await start(join: join)
    try await withCleanup({ await harness.close() }) { try await body(harness) }
  }

  func close() async {
    await hub.stop()
    try? db.close()
  }

  func append(
    _ table: String, _ rowId: String, _ op: String = "update", column: String? = nil, value: JSONValue?,
    hlc: String, device: String = "dev-phone"
  ) async -> Int {
    let next = (await fake.stored.last?.hubSeq ?? 0) + 1
    await fake.append([
      StoredChange(
        hubSeq: next, deviceId: device, deviceSeq: next, wall: Int(epochMillis()), table: table, rowId: rowId,
        op: op,
        column: column, value: value, hlc: hlc)
    ])
    return next
  }

  /// Re-checks `condition` as each hub call starts and ends (the pull writes the store only before its
  /// next call) and as an `EventRecorder` given `signal` records an event; records an issue if it never
  /// holds.
  func waitFor(_ what: String, _ condition: () async throws -> Bool) async throws {
    if try await !signal.until(condition) { Issue.record("timed out waiting for \(what)") }
  }

  /// Polls `condition`, for the one write no later step follows: `HubSync` records a 401 on the link
  /// and the pull ends, publishing nothing and calling the hub no more.
  func pollFor(
    _ what: String, timeout: Duration = .seconds(10), _ condition: () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for \(what)")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

/// Runs `body`, then `cleanup` (awaited) whether `body` threw or not, so no loop or database connection
/// outlives the test.
private func withCleanup<T>(_ cleanup: () async -> Void, _ body: () async throws -> T) async throws -> T {
  do {
    let value = try await body()
    await cleanup()
    return value
  } catch {
    await cleanup()
    throw error
  }
}

/// Collects the events published after it was created, firing `signal` after each.
private actor EventRecorder {
  private(set) var events: [EventEnvelope] = []
  private var task: Task<Void, Never>?
  private let signal: SyncSignal?

  init(_ log: EventLog, signal: SyncSignal? = nil) async {
    self.signal = signal
    let stream = await log.subscribe()
    task = Task { [weak self] in
      for await event in stream { await self?.add(event) }
    }
  }

  private func add(_ event: EventEnvelope) {
    events.append(event)
    signal?.fire()
  }

  func threadUpdates(_ id: String) -> [EventEnvelope] {
    events.filter { $0.event.kind == .threadUpdated && $0.event.threadId == id }
  }

  func projectChanges(_ id: String) -> [EventEnvelope] {
    events.filter { $0.event.kind == .projectChanged && $0.event.payload["projectId"] == .string(id) }
  }
}

@Suite(.serialized) struct HubPullTests {
  @Test func pullAppliesPhoneEditsAndPublishes() async throws {
    try await PullHarness.with { h in
      let recorder = await EventRecorder(h.events, signal: h.signal)
      _ = try h.db.insertProject(Project(id: "p1", name: ""), folders: ["/tmp/p"])
      let before = try #require(try h.db.thread(id: "t1"))
      let logged = try h.db.changes(after: 0).count

      _ = await h.append("threads", "t1", column: "title", value: "Phone title", hlc: phoneClock())
      _ = await h.append("projects", "p1", column: "name", value: "Phone project", hlc: phoneClock())
      // A revoked old Mac's row and an echo of this Mac's own edit are skipped.
      _ = await h.append(
        "threads", "t1", column: "pinned", value: true, hlc: phoneClock(device: "dev-old-mac"),
        device: "dev-old-mac")
      _ = await h.append(
        "threads", "t1", column: "archived", value: true, hlc: phoneClock(device: "dev-mac"),
        device: "dev-mac")
      let last = await h.append(
        "drafts", "t1", "insert",
        value: ["threadId": "t1", "text": "from the phone", "updatedAt": .string(Timestamp.now())],
        hlc: phoneClock())

      try await h.waitFor("the cursor to pass the phone's edits") { try h.db.hubLink()?.cursor == last }
      let thread = try #require(try h.db.thread(id: "t1"))
      #expect(thread.title == "Phone title")
      #expect(!thread.pinned && !thread.archived)
      #expect(thread.updatedAt == before.updatedAt)
      #expect(try h.db.project(id: "p1")?.name == "Phone project")
      #expect(try h.db.draft(threadId: "t1")?.text == "from the phone")
      try await h.waitFor("thread.updated and project.changed") {
        let threads = await recorder.threadUpdates("t1")
        let projects = await recorder.projectChanges("p1")
        return !threads.isEmpty && !projects.isEmpty
      }
      let published = await recorder.threadUpdates("t1").last
      #expect(published?.event.payload["thread"]?["title"] == .string("Phone title"))
      // Applying a pull records nothing, so there is nothing to push back.
      #expect(try h.db.changes(after: 0).count == logged)
    }
  }

  /// The first pull waits for the device list, which is what keeps a revoked old Mac's rows (this Mac
  /// before a rejoin) from applying; afterwards they are skipped and the phone's edit applies.
  @Test func appliesNothingUntilTheDeviceListLoads() async throws {
    let db = try WorkspaceDatabase.temporary()
    try await withCleanup({ try? db.close() }) {
      _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
      _ = try db.insertThread(
        ConversationThread(id: "t1", connectionId: "c1", nativeThreadId: "n1", title: "First"))
      try db.saveHubLink(
        WorkspaceDatabase.HubLink(
          url: "http://127.0.0.1:8080", deviceId: "dev-mac", deviceName: "Mac", tokenRef: "r",
          orgSlug: "acme",
          username: "brian", joinedAt: Timestamp.now()))
      let fake = FakeHubAPI(stored: [
        StoredChange(
          hubSeq: 1, deviceId: "dev-old-mac", deviceSeq: 1, wall: 1, table: "threads", rowId: "t1",
          op: "update", column: "pinned", value: true, hlc: phoneClock(device: "dev-old-mac")),
        StoredChange(
          hubSeq: 2, deviceId: "dev-phone", deviceSeq: 1, wall: 1, table: "threads", rowId: "t1",
          op: "update",
          column: "title", value: "Phone", hlc: phoneClock()),
      ])
      await fake.setDevices(devices)
      await fake.setFailNext(HubError(kind: "transport", code: "transport", message: "offline", status: 0))
      // The pull reports the failure and then waits inside `onError` (before its backoff) until the
      // test has looked, so the retry cannot clear it first.
      let signal = SyncSignal()
      let looked = Gate()
      let pull = HubPull(
        database: db, api: ProbedHub(fake, signal), eventLog: EventLog(), ownDeviceId: "dev-mac",
        initialBackoff: .milliseconds(600),
        onError: { message in
          signal.fire()
          if message != nil { await looked.wait() }
        })
      let run = Task { await pull.run() }
      try await withCleanup({
        looked.open()
        await pull.stop()
        await run.value
      }) {
        _ = await signal.until { await pull.lastError != nil }
        #expect(await pull.lastError?.contains("offline") == true)
        #expect(try db.thread(id: "t1")?.title == "First")
        #expect(try db.thread(id: "t1")?.pinned == false)
        #expect(try db.hubLink()?.cursor == 0)
        looked.open()
        _ = try await signal.until { try db.hubLink()?.cursor == 2 }
        let thread = try #require(try db.thread(id: "t1"))
        #expect(thread.title == "Phone")
        #expect(!thread.pinned)
      }
    }
  }

  @Test func staleCursorResyncsFromSnapshotWithoutLosingLocalRows() async throws {
    try await PullHarness.with { h in
      let recorder = await EventRecorder(h.events, signal: h.signal)
      let connection = try #require(try h.db.connection(id: "c1"))
      let before = try #require(try h.db.thread(id: "t1"))
      let macClock = HLC(millis: epochMillis() + 30_000, counter: 0, deviceId: "dev-mac").rawValue
      let renamed = phoneClock()
      // The hub's materialised copy: blanked and hashed Mac columns, a title the phone renamed, a pinned
      // flag whose clock is the Mac's own, and a draft only the phone has.
      await h.fake.setSnapshot(
        SnapshotResponse(
          changes: [
            StoredChange(
              hubSeq: 0, deviceId: "dev-mac", deviceSeq: 0, wall: 0, table: "connections", rowId: "c1",
              op: "insert",
              value: [
                "id": "c1", "kind": "claude", "label": "Hub label", "target": "", "authReference": .null,
                "nativeScope": "scope:0123456789abcdef",
              ], hlc: macClock),
            StoredChange(
              hubSeq: 0, deviceId: "dev-mac", deviceSeq: 0, wall: 0, table: "threads", rowId: "t1",
              op: "insert",
              value: [
                "id": "t1", "connectionId": "c1", "nativeThreadId": "n1",
                "nativeScope": "scope:fedcba9876543210",
                "title": "Renamed on the phone", "pinned": true, "context": "/tmp/p",
              ], hlc: renamed),
            StoredChange(
              hubSeq: 0, deviceId: "dev-phone", deviceSeq: 0, wall: 0, table: "drafts", rowId: "t1",
              op: "insert",
              value: ["threadId": "t1", "text": "phone draft", "updatedAt": "2026-10-31T12:00:00.000Z"],
              hlc: renamed),
          ],
          clocks: [
            ColumnClock(table: "threads", rowId: "t1", column: "title", hlc: renamed),
            ColumnClock(table: "threads", rowId: "t1", column: "pinned", hlc: macClock),
            ColumnClock(table: "drafts", rowId: "t1", column: "text", hlc: renamed),
          ], next: 500))
      await h.fake.setFailNext(
        HubError(kind: "request_error", code: "resync_required", message: "Pruned.", status: 410))

      try await h.waitFor("the snapshot's cursor") { try h.db.hubLink()?.cursor == 500 }
      let thread = try #require(try h.db.thread(id: "t1"))
      #expect(thread.title == "Renamed on the phone")
      #expect(!thread.pinned)
      #expect(thread.nativeScope == before.nativeScope && thread.context == before.context)
      #expect(try h.db.connection(id: "c1") == connection)
      #expect(try h.db.draft(threadId: "t1")?.text == "phone draft")
      try await h.waitFor("thread.updated") { await !recorder.threadUpdates("t1").isEmpty }
    }
  }

  @Test func snapshotRowsBecomePerColumnChangesAttributedToTheirClocks() throws {
    let phone = HLC(millis: 2_000, counter: 0, deviceId: "dev-phone").rawValue
    let mac = HLC(millis: 3_000, counter: 0, deviceId: "dev-mac").rawValue
    let snapshot = SnapshotResponse(
      changes: [
        StoredChange(
          hubSeq: 0, deviceId: "dev-mac", deviceSeq: 0, wall: 0, table: "threads", rowId: "t1", op: "insert",
          value: ["id": "t1", "title": "T", "pinned": true, "archived": false, "nativeScope": "scope:x"],
          hlc: mac),
        StoredChange(
          hubSeq: 0, deviceId: "dev-mac", deviceSeq: 0, wall: 0, table: "connections", rowId: "c1",
          op: "insert",
          value: ["id": "c1"], hlc: mac),
        StoredChange(
          hubSeq: 0, deviceId: "dev-mac", deviceSeq: 0, wall: 0, table: "drafts", rowId: "t1", op: "insert",
          value: ["threadId": "t1", "text": "", "updatedAt": "u"], hlc: mac),
      ],
      clocks: [
        ColumnClock(table: "threads", rowId: "t1", column: "title", hlc: phone),
        ColumnClock(table: "threads", rowId: "t1", column: "pinned", hlc: mac),
        ColumnClock(table: "drafts", rowId: "t1", column: "threadId", hlc: mac),
        ColumnClock(table: "drafts", rowId: "t1", column: "text", hlc: phone),
      ], next: 9)
    let changes = HubPull.remoteChanges(fromSnapshot: snapshot)
    #expect(
      changes == [
        // Column by column in name order, each as its clock's device; `archived` has no clock.
        RemoteChange(
          deviceId: "dev-mac", hlc: mac, table: "threads", rowId: "t1", op: "update", column: "pinned",
          value: true),
        RemoteChange(
          deviceId: "dev-phone", hlc: phone, table: "threads", rowId: "t1", op: "update", column: "title",
          value: "T"),
        // The draft travels whole, as the device of its newest column clock wrote it.
        RemoteChange(
          deviceId: "dev-mac", hlc: mac, table: "drafts", rowId: "t1", op: "insert", column: nil,
          value: ["threadId": "t1", "text": "", "updatedAt": "u"]),
      ])
  }

  @Test func rejectedChangesAreRecordedAndDoNotStall() async throws {
    let db = try WorkspaceDatabase.temporary()
    try await withCleanup({ try? db.close() }) {
      _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
      _ = try db.insertThread(
        ConversationThread(id: "t1", connectionId: "c1", nativeThreadId: "n1", title: "First"))
      let fake = FakeHubAPI()
      await fake.addEnrollmentCode(code, enrolled)
      let hub = HubSync(
        database: db, secretStore: MemorySecretStore(), eventLog: EventLog(), makeAPI: { _, _ in fake })
      _ = try await hub.join(url: "http://127.0.0.1:8080", code: code, deviceName: "Mac")
      #expect(try db.unsyncedChangeCount() == 0)

      // Pretend the hub sees this device as a phone: a turn insert and the rename's updatedAt are refused,
      // the title is accepted, and all three leave the queue.
      await fake.setPlatform("ios")
      _ = try db.insertTurn(Turn(id: "u1", threadId: "t1", operationId: "op1"))
      _ = try db.updateThread(id: "t1") { $0.title = "Renamed" }
      let queued = try db.unsyncedChanges(limit: 100)
      #expect(queued.count == 3)
      let accepted = try await hub.pushNow()
      #expect(accepted == 3)
      #expect(try db.unsyncedChangeCount() == 0)
      let status = try await hub.status()
      #expect(status.lastError == "2 changes refused by the hub: column_not_writable")
      let pushed = await fake.pushed.last ?? []
      #expect(pushed.allSatisfy { $0.hlc != nil })
      #expect(pushed.map(\.hlc) == queued.map(\.hlc))

      // Not suspended: the next push goes out, and a clean one clears the message.
      await fake.setPlatform("macos")
      _ = try db.updateThread(id: "t1") { $0.pinned = true }
      #expect(try await hub.pushNow() > 0)
      #expect(try await hub.status().lastError == nil)
    }
  }

  @Test func unauthorizedLeaveAndStopEndThePull() async throws {
    try await PullHarness.with { h in
      await h.fake.setFailNext(
        HubError(kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401))
      try await h.pollFor("the 401 to be recorded") {
        try h.db.hubLink()?.lastError?.contains("unauthorized") == true
      }
      let seq = await h.append("threads", "t1", column: "title", value: "After 401", hlc: phoneClock())
      try await Task.sleep(for: .milliseconds(500))  // timed on purpose: the edit must not apply
      #expect(try h.db.thread(id: "t1")?.title == "First")
      #expect(try h.db.hubLink()?.cursor ?? 0 < seq)
    }

    // Leaving stops the loop before the link is gone.
    try await PullHarness.with { h in
      try await h.hub.leave()
      _ = await h.append("threads", "t1", column: "title", value: "After leave", hlc: phoneClock())
      try await Task.sleep(for: .milliseconds(500))  // timed on purpose: the edit must not apply
      #expect(try h.db.thread(id: "t1")?.title == "First")
    }

    try await PullHarness.with { h in
      await h.hub.stop()
      _ = await h.append("threads", "t1", column: "title", value: "After stop", hlc: phoneClock())
      try await Task.sleep(for: .milliseconds(500))  // timed on purpose: the edit must not apply
      #expect(try h.db.thread(id: "t1")?.title == "First")
    }
  }

}
