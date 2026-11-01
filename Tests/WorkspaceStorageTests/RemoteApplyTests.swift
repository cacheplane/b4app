import Foundation
import Synchronization
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private let mac = "dev-mac"
private let oldMac = "dev-old-mac"
private let phone = "dev-phone"

private func stamp(_ millis: UInt64, _ device: String, counter: UInt16 = 0) -> String {
  HLC(millis: millis, counter: counter, deviceId: device).rawValue
}

private func remote(
  _ device: String, _ hlc: String, _ table: String, _ rowId: String, _ op: String = "update",
  column: String? = nil, value: JSONValue?
) -> RemoteChange {
  RemoteChange(deviceId: device, hlc: hlc, table: table, rowId: rowId, op: op, column: column, value: value)
}

/// A joined Mac with one connection (a real target and a path scope) and one thread (a path scope).
private func seed(_ db: WorkspaceDatabase) throws {
  try db.saveHubLink(
    WorkspaceDatabase.HubLink(
      url: "http://localhost:8080", deviceId: mac, deviceName: "Mac", tokenRef: "ref", orgSlug: "acme",
      username: "brian", joinedAt: "2026-10-31T12:00:00.000Z"))
  db.deviceId = mac
  _ = try db.insertConnection(
    Connection(
      id: "c1", kind: .claude, label: "Claude", target: "/usr/local/bin/claude",
      authReference: "secret-ref-1",
      nativeScope: "/Users/me/.claude"))
  _ = try db.insertThread(
    ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "n1", nativeScope: "/x", title: "First", context: "/tmp/p"
    ))
}

private func clock(_ db: WorkspaceDatabase, _ table: String, _ rowId: String, _ column: String) throws -> HLC
{
  try #require(try db.columnClock(table: table, rowId: rowId, column: column).flatMap(HLC.init(rawValue:)))
}

@Suite struct RemoteApplyTests {
  @Test func remoteTitleAppliesAndOlderLoses() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let local = try clock(db, "threads", "t1", "title")
    let before = try #require(try db.thread(id: "t1"))
    let logged = try db.changes(after: 0).count

    let newer = stamp(local.millis + 1, phone)
    let applied = try db.applyRemote(
      [remote(phone, newer, "threads", "t1", column: "title", value: "Phone title")], ownDeviceId: mac,
      macDeviceIds: [mac], cursor: 7)
    #expect(applied.applied == 1 && applied.skipped == 0)
    #expect(applied.touchedThreadIds == ["t1"])
    let after = try #require(try db.thread(id: "t1"))
    #expect(after.title == "Phone title")
    // A phone edit is not an edit of the Mac's row: updatedAt stays, and nothing is re-recorded.
    #expect(after.updatedAt == before.updatedAt)
    #expect(try db.changes(after: 0).count == logged)
    #expect(try db.columnClock(table: "threads", rowId: "t1", column: "title") == newer)
    #expect(try db.hubLink()?.cursor == 7)

    // Older than the stored clock, or equal to it: skipped.
    for hlc in [stamp(local.millis - 1, phone), newer] {
      let lost = try db.applyRemote(
        [remote(phone, hlc, "threads", "t1", column: "title", value: "Stale")], ownDeviceId: mac,
        macDeviceIds: [mac], cursor: 8)
      #expect(lost.applied == 0 && lost.skipped == 1 && lost.touchedThreadIds.isEmpty)
    }
    #expect(try db.thread(id: "t1")?.title == "Phone title")
    #expect(try db.hubLink()?.cursor == 8)

    // A later local edit wins against a pulled edit stamped before it.
    _ = try db.updateThread(id: "t1") { $0.title = "Mac title" }
    let lateLocal = try clock(db, "threads", "t1", "title")
    #expect(lateLocal.rawValue > newer)
    _ = try db.applyRemote(
      [remote(phone, stamp(lateLocal.millis - 1, phone), "threads", "t1", column: "title", value: "Late")],
      ownDeviceId: mac, macDeviceIds: [mac], cursor: 9)
    #expect(try db.thread(id: "t1")?.title == "Mac title")
  }

  @Test func everyPhoneWritableColumnApplies() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.insertProject(Project(id: "p1", name: ""), folders: ["/tmp/p"])
    let at = stamp(epochMillis() + 1_000, phone)
    let applied = try db.applyRemote(
      [
        remote(phone, at, "threads", "t1", column: "pinned", value: true),
        remote(phone, at, "threads", "t1", column: "archived", value: true),
        remote(phone, at, "threads", "t1", column: "readTurnId", value: "turn-9"),
        remote(phone, at, "projects", "p1", column: "name", value: "Renamed"),
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 3)
    #expect(applied.applied == 4)
    #expect(applied.touchedThreadIds == ["t1"])
    #expect(applied.touchedProjectIds == ["p1"])
    let thread = try #require(try db.thread(id: "t1"))
    #expect(thread.pinned && thread.archived && thread.readTurnId == "turn-9")
    #expect(try db.project(id: "p1")?.name == "Renamed")
  }

  @Test func remoteRowsNeverOverwriteLocalMacColumns() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let connection = try #require(try db.connection(id: "c1"))
    let thread = try #require(try db.thread(id: "t1"))
    let far = stamp(epochMillis() + 60_000, oldMac)
    // What the hub holds of this Mac's rows: blanked target and secret, hashed scopes, as a snapshot or
    // a pull from zero after a rejoin delivers them under the old device id.
    let rows: [RemoteChange] = [
      remote(
        oldMac, far, "connections", "c1", "insert",
        value: [
          "id": "c1", "kind": "claude", "label": "Hub label", "target": "", "authReference": .null,
          "nativeScope": "scope:0123456789abcdef",
        ]),
      remote(
        oldMac, far, "threads", "t1", "insert",
        value: [
          "id": "t1", "connectionId": "c1", "nativeThreadId": "n1", "nativeScope": "scope:fedcba9876543210",
          "title": "Hub title", "context": "/tmp/p",
        ]),
      remote(oldMac, far, "threads", "t1", column: "title", value: "Old Mac title"),
    ]
    let fromOldMac = try db.applyRemote(rows, ownDeviceId: mac, macDeviceIds: [mac, oldMac], cursor: 5)
    #expect(fromOldMac.applied == 0 && fromOldMac.skipped == 3)
    #expect(try db.connection(id: "c1") == connection)
    #expect(try db.thread(id: "t1") == thread)

    // Even from a phone, an insert of any table but drafts and every Mac-only column are refused.
    let phoneRows: [RemoteChange] =
      rows.dropLast().map {
        var row = $0; row.deviceId = phone; row.hlc = stamp(epochMillis() + 60_000, phone); return row
      }
      + [
        remote(phone, stamp(epochMillis() + 60_000, phone), "connections", "c1", column: "target", value: ""),
        remote(
          phone, stamp(epochMillis() + 60_000, phone), "threads", "t1", column: "nativeScope", value: "s"),
        remote(phone, stamp(epochMillis() + 60_000, phone), "threads", "t1", column: "projectId", value: "p"),
        remote(phone, stamp(epochMillis() + 60_000, phone), "threads", "t1", column: "updatedAt", value: "x"),
        remote(
          phone, stamp(epochMillis() + 60_000, phone), "threads", "t2", "insert",
          value: ["id": "t2", "connectionId": "c1", "nativeThreadId": "n2", "title": "New"]),
        remote(phone, stamp(epochMillis() + 60_000, phone), "threads", "t1", "delete", value: nil),
        remote(phone, stamp(epochMillis() + 60_000, phone), "turns", "u1", "insert", value: ["id": "u1"]),
      ]
    let fromPhone = try db.applyRemote(phoneRows, ownDeviceId: mac, macDeviceIds: [mac, oldMac], cursor: 6)
    #expect(fromPhone.applied == 0 && fromPhone.skipped == phoneRows.count)
    #expect(try db.connection(id: "c1") == connection)
    #expect(try db.thread(id: "t1") == thread)
    #expect(try db.thread(id: "t2") == nil)
    #expect(try db.hubLink()?.cursor == 6)
  }

  @Test func ownAndOtherMacChangesAreSkipped() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let later = epochMillis() + 60_000
    let skipped = try db.applyRemote(
      [
        remote(mac, stamp(later, mac), "threads", "t1", column: "title", value: "Own echo"),
        remote(oldMac, stamp(later, oldMac), "threads", "t1", column: "title", value: "Old Mac"),
        // Attributed to a phone but stamped with a Mac's clock: still the Mac's write.
        remote(phone, stamp(later, oldMac), "threads", "t1", column: "title", value: "Mac clock"),
        // `local` is this Mac before it joined (a snapshot can carry such clocks); a phone never is.
        remote("local", stamp(later, "local"), "threads", "t1", column: "title", value: "Pre-join"),
        remote(phone, stamp(later, "local"), "threads", "t1", column: "title", value: "Pre-join clock"),
      ], ownDeviceId: mac, macDeviceIds: [oldMac], cursor: 11)
    #expect(skipped.applied == 0 && skipped.skipped == 5)
    #expect(try db.thread(id: "t1")?.title == "First")
    // The cursor advances even when every change was skipped.
    #expect(try db.hubLink()?.cursor == 11)

    let applied = try db.applyRemote(
      [remote(phone, stamp(later, phone), "threads", "t1", column: "title", value: "Phone")],
      ownDeviceId: mac,
      macDeviceIds: [oldMac], cursor: 12)
    #expect(applied.applied == 1)
    #expect(try db.thread(id: "t1")?.title == "Phone")
  }

  @Test func remoteDraftInsertCreatesTheRow() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let at = epochMillis() + 1_000
    let inserted = try db.applyRemote(
      [
        remote(
          phone, stamp(at, phone), "drafts", "t1", "insert",
          value: ["threadId": "t1", "text": "from the phone", "updatedAt": "2026-10-31T12:00:00.000Z"]),
        remote(
          phone, stamp(at, phone), "drafts", "t404", "insert",
          value: ["threadId": "t404", "text": "orphan", "updatedAt": "2026-10-31T12:00:00.000Z"]),
        // A row id that disagrees with the value's key is not a draft of either thread.
        remote(
          phone, stamp(at, phone), "drafts", "t1", "insert",
          value: ["threadId": "t404", "text": "mismatch", "updatedAt": "2026-10-31T12:00:00.000Z"]),
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 1)
    #expect(inserted.applied == 1 && inserted.skipped == 2)
    #expect(inserted.touchedDraftThreadIds == ["t1"])
    #expect(inserted.touchedThreadIds.isEmpty)
    #expect(try db.draft(threadId: "t1")?.text == "from the phone")
    #expect(try db.draft(threadId: "t404") == nil)

    // The phone clears it (an update); an older edit loses; a newer local save wins over an older pull.
    _ = try db.applyRemote(
      [
        remote(phone, stamp(at + 2, phone), "drafts", "t1", column: "text", value: ""),
        remote(phone, stamp(at + 1, phone), "drafts", "t1", column: "text", value: "older"),
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 2)
    #expect(try db.draft(threadId: "t1")?.text == "")
    _ = try db.saveDraft(threadId: "t1", text: "typed on the Mac")
    let saved = try clock(db, "drafts", "t1", "text")
    let lost = try db.applyRemote(
      [
        remote(
          phone, stamp(saved.millis - 1, phone), "drafts", "t1", "insert",
          value: ["threadId": "t1", "text": "stale insert", "updatedAt": "2026-10-31T12:00:00.000Z"])
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 3)
    #expect(lost.applied == 0)
    #expect(try db.draft(threadId: "t1")?.text == "typed on the Mac")
  }

  @Test func aBadValueIsSkippedWithoutFailingTheBatch() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let at = stamp(epochMillis() + 1_000, phone)
    let applied = try db.applyRemote(
      [
        remote(phone, at, "threads", "t1", column: "title", value: .null),
        remote(phone, at, "threads", "t1", column: "pinned", value: "not a boolean"),
        remote(phone, "not a clock", "threads", "t1", column: "archived", value: true),
        remote(phone, at, "threads", "t1", column: "readTurnId", value: "turn-1"),
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 4)
    #expect(applied.applied == 1 && applied.skipped == 3)
    let thread = try #require(try db.thread(id: "t1"))
    #expect(thread.title == "First" && !thread.pinned && !thread.archived && thread.readTurnId == "turn-1")
    #expect(try db.hubLink()?.cursor == 4)
  }

  @Test func receivedClocksAdvanceTheLocalClockAndFarFutureOnesAreClamped() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let soon = epochMillis() + 200_000
    _ = try db.applyRemote(
      [remote(phone, stamp(soon, phone), "threads", "t1", column: "pinned", value: true)], ownDeviceId: mac,
      macDeviceIds: [mac], cursor: 1)
    #expect(db.clock.next().millis >= soon)

    // An hour ahead: rewritten to the receiver's wall clock before it is compared, stored, or observed.
    let far = epochMillis() + 3_600_000
    _ = try db.applyRemote(
      [remote(phone, stamp(far, phone), "threads", "t1", column: "title", value: "Far")], ownDeviceId: mac,
      macDeviceIds: [mac], cursor: 2)
    #expect(try db.thread(id: "t1")?.title == "Far")
    #expect(try clock(db, "threads", "t1", "title").millis < far - 3_000_000)
    #expect(db.clock.next().millis < far - 3_000_000)
  }

  @Test func theCursorIsSetEvenForAnEmptyBatchAndSavingTheLinkKeepsIt() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let applied = try db.applyRemote([], ownDeviceId: mac, macDeviceIds: [], cursor: 42)
    #expect(applied == RemoteApplied())
    #expect(try db.hubLink()?.cursor == 42)
    var link = try #require(try db.hubLink())
    link.cursor = 0
    link.lastError = "boom"
    try db.saveHubLink(link)
    #expect(try db.hubLink()?.cursor == 42)
    #expect(try db.hubLink()?.lastError == "boom")
    try db.setHubCursor(50)
    #expect(try db.hubLink()?.cursor == 50)
  }

  @Test func replaySkipsAMissingParentInsteadOfFailing() throws {
    // A real connection and thread insert from another store's log, with a turn whose thread no store
    // has between them.
    let source = try WorkspaceDatabase.temporary()
    _ = try source.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    _ = try source.insertThread(ConversationThread(id: "t1", connectionId: "c1", nativeThreadId: "n1"))
    let good = try source.changes(after: 0)
    #expect(good.map(\.table) == ["connections", "threads"])
    let orphan = ChangeRecord(
      seq: 99, deviceId: "d", wall: 2, table: "turns", rowId: "u1", op: "insert", column: nil,
      value: try JSONValue(encoding: Turn(id: "u1", threadId: "missing", operationId: "op1")), synced: false,
      hlc: stamp(2, "d"))

    let db = try WorkspaceDatabase.temporary()
    #expect(try db.replay([good[0], orphan, good[1]]) == 2)
    #expect(try db.connection(id: "c1") == source.connection(id: "c1"))
    #expect(try db.thread(id: "t1") != nil)
    #expect(try db.turn(id: "u1") == nil)
  }
}

// MARK: - Concurrent local writes

/// Runs `holding` in a write transaction on another thread and keeps that transaction open until some
/// other connection is waiting on a lock it holds (`pg_locks` and `pg_blocking_pids`, which are read
/// live, unlike `pg_stat_activity`, which a transaction snapshots once), then calls `whenBlocked` with
/// that connection's pid and commits. Meanwhile `body` runs here, so it is the waiter. Returns `body`'s
/// outcome and whether the wait was seen (giving up after ten seconds).
///
/// The holder runs on its own `Thread`, not a global dispatch queue: the caller blocks a Swift
/// concurrency thread on a semaphore, and on a three-core CI runner three such tests used every thread
/// GCD would grant at that priority, so queued holders never started and the whole suite hung.
private func interleave<T>(
  _ db: WorkspaceDatabase, holding: @escaping @Sendable (PostgresConnection) throws -> Void,
  whenBlocked: @escaping @Sendable (PostgresConnection, Int) throws -> Void = { _, _ in },
  _ body: () throws -> T
) throws -> (result: Result<T, any Error>, blocked: Bool) {
  let held = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  let blocked = Mutex(false)
  let failure = Mutex<String?>(nil)
  Thread {
    do {
      try db.write { c in
        try holding(c)
        held.signal()
        let me = try c.execute("SELECT pg_backend_pid() AS \"pid\"").rows.first?.int("pid") ?? 0
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
          if let waiter = try c.execute(
            "SELECT \"pid\" FROM pg_locks WHERE NOT \"granted\" AND $1::int = ANY(pg_blocking_pids(\"pid\"))",
            [String(me)]
          ).rows.first?.int("pid") {
            try whenBlocked(c, waiter)
            blocked.withLock { $0 = true }
            break
          }
          usleep(10_000)
        }
      }
    } catch {
      failure.withLock { $0 = String(describing: error) }
      held.signal()
    }
    done.signal()
  }.start()
  held.wait()
  let result = Result { try body() }
  done.wait()
  if let failure = failure.withLock({ $0 }) { Issue.record("the holding transaction failed: \(failure)") }
  return (result, blocked.withLock { $0 })
}

/// A settable wall clock for `WorkspaceDatabase.temporary(wall:)`.
private final class PinnedWall: Sendable {
  private let millis = Mutex<UInt64>(1_000)
  func set(_ value: UInt64) { millis.withLock { $0 = value } }
  func read() -> UInt64 { millis.withLock { $0 } }
}

/// A store whose clock reads the returned wall, seeded at 1000 ms.
private func pinnedStore() throws -> (WorkspaceDatabase, PinnedWall) {
  let wall = PinnedWall()
  let db = try WorkspaceDatabase.temporary(wall: { wall.read() })
  try seed(db)
  return (db, wall)
}

extension RemoteApplyTests {
  /// A local title edit (clock 3000) holds the row while a pull of an older phone title (2000) starts:
  /// the pull waits for the row, then reads the local clock and loses, instead of comparing against the
  /// insert's clock (1000) and writing the old value under the new clock.
  @Test func aPulledEditWaitsForALocalEditHoldingTheRow() throws {
    let (db, wall) = try pinnedStore()
    wall.set(3_000)
    let (result, blocked) = try interleave(
      db,
      holding: { c in try c.execute("UPDATE \"threads\" SET \"title\" = 'Mac title' WHERE \"id\" = 't1'") }
    ) {
      try db.applyRemote(
        [remote(phone, stamp(2_000, phone), "threads", "t1", column: "title", value: "Phone title")],
        ownDeviceId: mac, macDeviceIds: [mac], cursor: 1)
    }
    #expect(blocked)
    #expect(try result.get().applied == 0)
    #expect(try db.thread(id: "t1")?.title == "Mac title")
    #expect(try db.columnClock(table: "threads", rowId: "t1", column: "title") == stamp(3_000, mac))
  }

  /// A local title edit starts while a pull batch holds the lock and before it has looked at its
  /// changes (whose clock, 9000, is ahead of this Mac's wall, 5000). The edit waits for the batch to
  /// commit and only then takes its clock, which has observed the pulled one: it is stamped after it,
  /// wins, and the row, its column clock, and the change sent to the hub all agree.
  @Test func aLocalEditStartedDuringAPullIsStampedAfterIt() throws {
    let (db, wall) = try pinnedStore()
    wall.set(5_000)
    let pulled = stamp(9_000, phone)
    let localDone = DispatchSemaphore(value: 0)
    let localFailure = Mutex<String?>(nil)
    let waited = Mutex(false)
    let result = try db.applyRemote(
      [remote(phone, pulled, "threads", "t1", column: "title", value: "Phone title")],
      ownDeviceId: mac, macDeviceIds: [mac], cursor: 1
    ) { c in
      // Its own thread, for the reason `interleave` gives.
      Thread {
        do {
          _ = try db.updateThread(id: "t1") { $0.title = "Mac title" }
        } catch {
          localFailure.withLock { $0 = String(describing: error) }
        }
        localDone.signal()
      }.start()
      // Hold the batch until the local edit is seen waiting on it (or, were it not made to wait, done).
      let me = try c.execute("SELECT pg_backend_pid() AS \"pid\"").rows.first?.int("pid") ?? 0
      let deadline = Date().addingTimeInterval(10)
      while Date() < deadline {
        if try !c.execute(
          "SELECT \"pid\" FROM pg_locks WHERE NOT \"granted\" AND $1::int = ANY(pg_blocking_pids(\"pid\"))",
          [String(me)]
        ).rows.isEmpty {
          waited.withLock { $0 = true }
          break
        }
        if localDone.wait(timeout: .now() + .milliseconds(10)) == .success {
          localDone.signal()
          break
        }
      }
    }
    localDone.wait()
    if let failure = localFailure.withLock({ $0 }) { Issue.record("the local edit failed: \(failure)") }
    #expect(waited.withLock { $0 })
    #expect(result.applied == 1)

    let local = try #require(try db.changes(after: 0).last { $0.column == "title" })
    #expect(local.value == "Mac title")
    #expect(local.hlc.utf8.lexicographicallyPrecedes(pulled.utf8) == false && local.hlc != pulled)
    #expect(try db.thread(id: "t1")?.title == "Mac title")
    #expect(try db.columnClock(table: "threads", rowId: "t1", column: "title") == local.hlc)
  }

  /// A local save creates the draft (clock 2000) while a newer phone draft (3000) is pulled: the pull
  /// waits on the thread, then finds the draft and wins column by column, instead of hitting the unique
  /// key and dropping the newer edit.
  @Test func aPulledDraftWaitsForALocalSaveOfTheSameDraft() throws {
    let (db, wall) = try pinnedStore()
    wall.set(2_000)
    let (result, blocked) = try interleave(
      db,
      holding: { c in
        try c.execute(
          "INSERT INTO \"drafts\" (\"threadId\", \"text\", \"updatedAt\") VALUES ('t1', 'typed on the Mac', 'x')"
        )
      }
    ) {
      try db.applyRemote(
        [
          remote(
            phone, stamp(3_000, phone), "drafts", "t1", "insert",
            value: ["threadId": "t1", "text": "from the phone", "updatedAt": "y"])
        ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 1)
    }
    #expect(blocked)
    #expect(try result.get().applied == 1)
    #expect(try db.draft(threadId: "t1")?.text == "from the phone")
  }

  /// The reverse: a pulled title commits while a local `updateThread` (which rewrites the whole row) is
  /// about to read it. The local edit waits and keeps the phone's title.
  @Test func aLocalThreadEditKeepsAPulledTitleThatCommittedFirst() throws {
    let (db, _) = try pinnedStore()
    let (result, blocked) = try interleave(
      db,
      holding: { c in
        try c.execute("SET LOCAL b4app.replaying = 'on'")
        try c.execute("UPDATE \"threads\" SET \"title\" = 'Phone title' WHERE \"id\" = 't1'")
      }
    ) {
      try db.updateThread(id: "t1") { $0.pinned = true }
    }
    #expect(blocked)
    #expect(try result.get()?.title == "Phone title")
    let thread = try #require(try db.thread(id: "t1"))
    #expect(thread.title == "Phone title" && thread.pinned)
  }

  /// A failure that is not about the value (here a cancelled statement, 57014) fails the batch: the
  /// cursor stays, so the batch is pulled again.
  @Test func aCancelledStatementFailsTheBatchAndKeepsTheCursor() throws {
    let (db, _) = try pinnedStore()
    try db.setHubCursor(5)
    let (result, blocked) = try interleave(
      db,
      holding: { c in try c.execute("UPDATE \"threads\" SET \"title\" = 'Mac title' WHERE \"id\" = 't1'") },
      whenBlocked: { c, pid in try c.execute("SELECT pg_cancel_backend($1::int)", [String(pid)]) }
    ) {
      try db.applyRemote(
        [remote(phone, stamp(9_000, phone), "threads", "t1", column: "title", value: "Phone title")],
        ownDeviceId: mac, macDeviceIds: [mac], cursor: 9)
    }
    #expect(blocked)
    #expect(throws: (any Error).self) { try result.get() }
    #expect(try db.hubLink()?.cursor == 5)
    #expect(try db.thread(id: "t1")?.title == "Mac title")
  }

  @Test func aCancelledStatementFailsTheReplay() throws {
    let (db, _) = try pinnedStore()
    let update = ChangeRecord(
      seq: 1, deviceId: "d", wall: 1, table: "threads", rowId: "t1", op: "update", column: "title",
      value: "Replayed", synced: false, hlc: stamp(9_000, "d"))
    let (result, blocked) = try interleave(
      db,
      holding: { c in try c.execute("UPDATE \"threads\" SET \"title\" = 'Mac title' WHERE \"id\" = 't1'") },
      whenBlocked: { c, pid in try c.execute("SELECT pg_cancel_backend($1::int)", [String(pid)]) }
    ) {
      try db.replay([update])
    }
    #expect(blocked)
    #expect(throws: (any Error).self) { try result.get() }
    #expect(try db.thread(id: "t1")?.title == "Mac title")
  }
}

// MARK: - The cross-language conflict fixture

/// `Tests/Fixtures/sync/conflicts.json`, which the hub's suite replays through its own merge.
private struct ConflictFixture: Decodable {
  struct Entry: Decodable {
    var platform: String
    var device: String
    var deviceSeq: Int
    var wall: Int
    var table: String
    var rowId: String
    var op: String
    var column: String?
    var value: JSONValue?
    var hlc: String
  }
  var changes: [Entry]
  var expected: [String: JSONValue]

  static func load(file: StaticString = #filePath) throws -> ConflictFixture {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/conflicts.json")
    return try JSONCoding.decoder.decode(ConflictFixture.self, from: Data(contentsOf: url))
  }
}

extension RemoteApplyTests {
  /// The `macos` entries are this Mac's own writes, made through the ordinary store methods with the
  /// database clock pinned to the entry's milliseconds and device, so the trigger stamps exactly the
  /// fixture's clock into `changes` and `columnClocks`. The `ios` entries are pulled through
  /// `applyRemote`. Three orders must agree with `expected`: as listed (local and remote interleaved),
  /// every Mac write first then the phone's in one batch, and that with the phone's batch reversed.
  @Test(arguments: ["interleaved", "macFirst", "macFirstReversed"])
  func conflictFixtureMergesToTheExpectedValues(order: String) throws {
    let fixture = try ConflictFixture.load()
    let wall = Mutex<UInt64>(0)
    let db = try WorkspaceDatabase.temporary(wall: { wall.withLock { $0 } })
    let macEntries = fixture.changes.filter { $0.platform == "macos" }
    let phoneEntries = fixture.changes.filter { $0.platform != "macos" }
    let macId = try #require(HLC(rawValue: macEntries[0].hlc)).deviceId
    db.deviceId = macId

    func local(_ entry: ConflictFixture.Entry) throws {
      let hlc = try #require(HLC(rawValue: entry.hlc))
      wall.withLock { $0 = hlc.millis }
      switch (entry.table, entry.op) {
      case ("connections", "insert"):
        _ = try db.insertConnection(
          Connection(
            id: entry.rowId, kind: .codex, label: entry.value?["label"]?.stringValue ?? "", target: "/bin/c"))
      case ("threads", "insert"):
        _ = try db.insertThread(
          ConversationThread(
            id: entry.rowId, connectionId: entry.value?["connectionId"]?.stringValue ?? "",
            nativeThreadId: "native-" + entry.rowId, title: entry.value?["title"]?.stringValue ?? ""))
      case ("turns", "insert"):
        _ = try db.insertTurn(
          Turn(
            id: entry.rowId, threadId: entry.value?["threadId"]?.stringValue ?? "",
            operationId: "op-" + entry.rowId,
            status: .terminal))
      case ("threads", "update") where entry.column == "title":
        _ = try db.updateThread(id: entry.rowId) { $0.title = entry.value?.stringValue ?? "" }
      case ("drafts", "insert"):
        _ = try db.saveDraft(threadId: entry.rowId, text: entry.value?["text"]?.stringValue ?? "")
      default:
        Issue.record("the fixture has a Mac write this replay does not map: \(entry.table) \(entry.op)")
      }
      // The trigger stamped exactly the fixture's clock.
      #expect(try db.changes(after: 0).last?.hlc == entry.hlc)
    }
    func pulled(_ entry: ConflictFixture.Entry) throws -> RemoteChange {
      let device = try #require(HLC(rawValue: entry.hlc)).deviceId
      return RemoteChange(
        deviceId: device, hlc: entry.hlc, table: entry.table, rowId: entry.rowId, op: entry.op,
        column: entry.column, value: entry.value)
    }

    var cursor = 0
    switch order {
    case "interleaved":
      for entry in fixture.changes {
        if entry.platform == "macos" {
          try local(entry)
        } else {
          cursor += 1
          _ = try db.applyRemote([try pulled(entry)], ownDeviceId: macId, macDeviceIds: [], cursor: cursor)
        }
      }
    default:
      for entry in macEntries { try local(entry) }
      var batch = try phoneEntries.map(pulled)
      if order == "macFirstReversed" { batch.reverse() }
      let applied = try db.applyRemote(batch, ownDeviceId: macId, macDeviceIds: [], cursor: 1)
      // Both phone titles lose to the Mac's later title; the draft clear and the read marker win.
      #expect(applied.applied == 2 && applied.skipped == 2)
    }

    let thread = try #require(try db.thread(id: "thread-1"))
    #expect(JSONValue.string(thread.title) == fixture.expected["threads.title"])
    #expect(thread.readTurnId.map(JSONValue.string) ?? .null == fixture.expected["threads.readTurnId"])
    #expect(
      try db.draft(threadId: "thread-1").map { JSONValue.string($0.text) } == fixture.expected["drafts.text"])
  }
}
