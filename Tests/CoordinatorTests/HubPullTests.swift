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
    let hub = HubSync(
      database: db, secretStore: MemorySecretStore(), eventLog: events, makeAPI: { _, _ in fake })
    await hub.start()
    let harness = PullHarness(db: db, fake: fake, events: events, hub: hub)
    if join {
      _ = try await hub.join(url: "http://127.0.0.1:8080", code: code, deviceName: "Mac")
      // The first pull walks past the Mac's own pushes (all skipped) to the feed's tip.
      let tip = await fake.stored.last?.hubSeq ?? 0
      try await harness.waitFor("the cursor to reach the tip") { try db.hubLink()?.cursor == tip }
    }
    return harness
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

  func waitFor(
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

/// Collects the events published after it was created.
private actor EventRecorder {
  private(set) var events: [EventEnvelope] = []
  private var task: Task<Void, Never>?

  init(_ log: EventLog) async {
    let stream = await log.subscribe()
    task = Task { [weak self] in
      for await event in stream { await self?.add(event) }
    }
  }

  private func add(_ event: EventEnvelope) { events.append(event) }

  func threadUpdates(_ id: String) -> [EventEnvelope] {
    events.filter { $0.event.kind == .threadUpdated && $0.event.threadId == id }
  }

  func projectChanges(_ id: String) -> [EventEnvelope] {
    events.filter { $0.event.kind == .projectChanged && $0.event.payload["projectId"] == .string(id) }
  }
}

@Suite(.serialized) struct HubPullTests {
  @Test func pullAppliesPhoneEditsAndPublishes() async throws {
    let h = try await PullHarness.start()
    defer { Task { await h.close() } }
    let recorder = await EventRecorder(h.events)
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
      "threads", "t1", column: "archived", value: true, hlc: phoneClock(device: "dev-mac"), device: "dev-mac")
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

  @Test func appliesNothingUntilTheDeviceListLoads() async throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    _ = try db.insertThread(
      ConversationThread(id: "t1", connectionId: "c1", nativeThreadId: "n1", title: "First"))
    try db.saveHubLink(
      WorkspaceDatabase.HubLink(
        url: "http://127.0.0.1:8080", deviceId: "dev-mac", deviceName: "Mac", tokenRef: "r", orgSlug: "acme",
        username: "brian", joinedAt: Timestamp.now()))
    let fake = FakeHubAPI(stored: [
      StoredChange(
        hubSeq: 1, deviceId: "dev-phone", deviceSeq: 1, wall: 1, table: "threads", rowId: "t1", op: "update",
        column: "title", value: "Phone", hlc: phoneClock())
    ])
    await fake.setDevices(devices)
    await fake.setFailNext(HubError(kind: "transport", code: "transport", message: "offline", status: 0))
    let pull = HubPull(
      database: db, api: fake, eventLog: EventLog(), ownDeviceId: "dev-mac",
      initialBackoff: .milliseconds(600))
    let run = Task { await pull.run() }
    let deadline = ContinuousClock.now + .seconds(5)
    while await pull.lastError == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await pull.lastError?.contains("offline") == true)
    #expect(try db.thread(id: "t1")?.title == "First")
    #expect(try db.hubLink()?.cursor == 0)
    while try db.hubLink()?.cursor != 1, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try db.thread(id: "t1")?.title == "Phone")
    await pull.stop()
    await run.value
    try db.close()
  }

  @Test func staleCursorResyncsFromSnapshotWithoutLosingLocalRows() async throws {
    let h = try await PullHarness.start()
    defer { Task { await h.close() } }
    let recorder = await EventRecorder(h.events)
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
    try db.close()
  }

  @Test func unauthorizedLeaveAndStopEndThePull() async throws {
    let h = try await PullHarness.start()
    defer { Task { await h.close() } }
    await h.fake.setFailNext(
      HubError(kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401))
    try await h.waitFor("the 401 to be recorded") {
      try h.db.hubLink()?.lastError?.contains("unauthorized") == true
    }
    let seq = await h.append("threads", "t1", column: "title", value: "After 401", hlc: phoneClock())
    try await Task.sleep(for: .milliseconds(500))
    #expect(try h.db.thread(id: "t1")?.title == "First")
    #expect(try h.db.hubLink()?.cursor ?? 0 < seq)

    // A fresh harness: leaving stops the loop before the link is gone.
    let other = try await PullHarness.start()
    defer { Task { await other.close() } }
    try await other.hub.leave()
    _ = await other.append("threads", "t1", column: "title", value: "After leave", hlc: phoneClock())
    try await Task.sleep(for: .milliseconds(500))
    #expect(try other.db.thread(id: "t1")?.title == "First")

    let third = try await PullHarness.start()
    await third.hub.stop()
    _ = await third.append("threads", "t1", column: "title", value: "After stop", hlc: phoneClock())
    try await Task.sleep(for: .milliseconds(500))
    #expect(try third.db.thread(id: "t1")?.title == "First")
    try? third.db.close()
  }
}
