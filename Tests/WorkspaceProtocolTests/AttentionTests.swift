import Foundation
import Testing

@testable import WorkspaceProtocol

/// The shared attention fixture (`Tests/Fixtures/sync/attention.json`, read in place as the sync
/// tests read `changes.json`). The hub's SQL and the mirror's SQL run the same file, so this
/// reference implementation of `activity` exists only to check the fixture and the Swift ordering.
struct AttentionFixture {
  struct Expected: Decodable {
    var bands: [String: String]
    var order: [String]
  }

  /// Ways to get `activity` wrong, each of which the fixture must expose by changing a band or the order.
  enum Variant: CaseIterable {
    case reference
    case threadCreatedAtOnly
    case ignoringTurnUpdatedAt
    case ignoringRequestUpdatedAt
    case latestTurnByUpdatedAt
    case tieBreakLeastId
    case threadUpdatedAt
  }

  var connections: [Connection]
  var threads: [ConversationThread]
  var turns: [Turn]
  var runtimeRequests: [RuntimeRequest]
  var expected: Expected

  private struct Document: Decodable {
    var connections: [Connection]
    var threads: [ConversationThread]
    var turns: [Turn]
    var runtimeRequests: [RuntimeRequest]
    var expected: Expected
  }

  static func url(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/attention.json")
  }

  static func load(file: StaticString = #filePath) throws -> AttentionFixture {
    let document = try JSONCoding.decoder.decode(Document.self, from: Data(contentsOf: url(file: file)))
    return AttentionFixture(
      connections: document.connections, threads: document.threads, turns: document.turns,
      runtimeRequests: document.runtimeRequests, expected: document.expected)
  }

  var expectedBand: [String: AttentionBand] {
    expected.bands.mapValues { name in
      switch name {
      case "needsInput": .needsInput
      case "unread": .unread
      case "working": .working
      default: .quiet
      }
    }
  }

  var expectedOrder: [String] { expected.order }

  var threadsWithActivity: [ConversationThread] { threadsWithActivity(.reference) }

  /// Reference `activity`: latest turn by `createdAt` (ties by greatest `id`), `lastActivityAt` = max of
  /// the thread's `createdAt` and its latest turn's and requests' `updatedAt`; never the thread's own
  /// `updatedAt`. The other variants are deliberate mistakes.
  func threadsWithActivity(_ variant: Variant) -> [ConversationThread] {
    threads.map { thread in
      let own = turns.filter { $0.threadId == thread.id }
      let latest: Turn?
      switch variant {
      case .latestTurnByUpdatedAt: latest = own.max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
      case .tieBreakLeastId: latest = own.max { ($0.createdAt, $1.id) < ($1.createdAt, $0.id) }
      default: latest = own.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      }
      let requests = runtimeRequests.filter { $0.threadId == thread.id }
      var stamps = [thread.createdAt]
      if variant == .threadUpdatedAt { stamps.append(thread.updatedAt) }
      if variant != .threadCreatedAtOnly {
        if variant != .ignoringTurnUpdatedAt, let latest { stamps.append(latest.updatedAt) }
        if variant != .ignoringRequestUpdatedAt { stamps += requests.map(\.updatedAt) }
      }
      var copy = thread
      copy.activity = ThreadActivity(
        latestTurnId: latest?.id, latestTurnStatus: latest?.status, latestTurnOutcome: latest?.outcome,
        pendingRequests: requests.filter { $0.state == .pending }.count, lastActivityAt: stamps.max()!)
      return copy
    }
  }
}

@Suite struct AttentionTests {
  @Test func fixtureBandsAndOrder() throws {
    let f = try AttentionFixture.load()
    for t in f.threadsWithActivity { #expect(Attention.band(of: t) == f.expectedBand[t.id], "\(t.id)") }
    #expect(Attention.ordered(f.threadsWithActivity).map(\.id) == f.expectedOrder)
  }

  @Test func fixtureCoversEveryBandAndTheHardCases() throws {
    let f = try AttentionFixture.load()
    #expect(Set(f.expectedBand.values) == [.needsInput, .unread, .working, .quiet])
    #expect(f.connections.map(\.id) == ["conn-attn"])
    #expect(Set(f.threads.map(\.connectionId)) == ["conn-attn"])
    // A newer thread `updatedAt` must not lift a thread whose activity is oldest.
    let stale = try #require(f.threads.first { $0.id == "t-stale-updated" })
    #expect(f.threads.allSatisfy { $0.updatedAt <= stale.updatedAt })
    #expect(f.expectedOrder.last == stale.id)
  }

  /// Each way of getting `lastActivityAt` or the latest turn wrong must change a band or the order, so a
  /// SQL query that makes the mistake cannot pass this file.
  @Test func fixtureExposesEveryActivityMistake() throws {
    let f = try AttentionFixture.load()
    for variant in AttentionFixture.Variant.allCases where variant != .reference {
      let threads = f.threadsWithActivity(variant)
      let bands = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, Attention.band(of: $0)) })
      let order = Attention.ordered(threads).map(\.id)
      #expect(bands != f.expectedBand || order != f.expectedOrder, "\(variant) goes undetected")
    }
  }

  @Test func fixtureOrdersTheHardCasesByTheirActivitySource() throws {
    let f = try AttentionFixture.load()
    let order = f.expectedOrder
    func before(_ a: String, _ b: String) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
    func thread(_ id: String) -> ConversationThread { f.threads.first { $0.id == id }! }
    // (a) unread: thread createdAt order is the reverse of the latest turn's updatedAt order.
    #expect(thread("t-unread-a").createdAt > thread("t-unread-b").createdAt)
    #expect(before("t-unread-b", "t-unread-a"))
    // (b) the latest request updates after the latest turn and decides the position in the band.
    let late = f.threadsWithActivity.first { $0.id == "t-ask-request-late" }!
    let turn = f.turns.first { $0.id == "u-arl1" }!
    #expect(late.activity!.lastActivityAt > turn.updatedAt)
    #expect(before("t-ask-request-late", "t-ask-turn-late"))
    // (c) createdAt order and updatedAt order of one thread's turns disagree.
    let lc1 = f.turns.first { $0.id == "u-lc1" }!
    let lc2 = f.turns.first { $0.id == "u-lc2" }!
    #expect(lc1.createdAt < lc2.createdAt && lc1.updatedAt > lc2.updatedAt)
    #expect(f.expectedBand["t-latest-created"] == .working)
    // (d) two turns with equal createdAt: the greatest id is the latest.
    let eqA = f.turns.first { $0.id == "u-eq-a" }!
    let eqB = f.turns.first { $0.id == "u-eq-b" }!
    #expect(eqA.createdAt == eqB.createdAt && eqA.id < eqB.id)
    #expect(f.threadsWithActivity.first { $0.id == "t-equal-created" }!.activity!.latestTurnId == "u-eq-b")
  }

  /// Tasks 3 and 9 load this file into tables with these NOT NULL columns (`0001_init.sql`).
  @Test func fixtureRowsCarryEveryNotNullColumn() throws {
    let raw = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: AttentionFixture.url())) as? [String: Any])
    let required: [String: [String]] = [
      "connections": [
        "id", "kind", "label", "enabled", "profileRevision", "target", "capabilities", "status",
        "authStatus", "createdAt", "updatedAt",
      ],
      "threads": [
        "id", "connectionId", "nativeThreadId", "nativeScope", "title", "pinned", "archived", "continuity",
        "createdAt", "updatedAt",
      ],
      "turns": [
        "id", "threadId", "operationId", "status", "submission", "createdAt", "updatedAt",
      ],
      "runtimeRequests": [
        "id", "nativeRequestId", "threadId", "adapterGeneration", "kind", "state", "payload", "createdAt",
        "updatedAt",
      ],
    ]
    for (table, columns) in required {
      let rows = try #require(raw[table] as? [[String: Any]], "\(table)")
      #expect(!rows.isEmpty)
      for row in rows {
        for column in columns {
          #expect(!(row[column] is NSNull) && row[column] != nil, "\(table).\(column)")
        }
      }
    }
    let rows = try #require(raw["connections"] as? [[String: Any]])
    #expect(rows.first?["target"] as? String == "")
  }

  @Test func bandsAreRankedByDisplayOrder() {
    #expect(AttentionBand.needsInput < .unread)
    #expect(AttentionBand.unread < .working)
    #expect(AttentionBand.working < .quiet)
  }

  @Test func aThreadWithoutActivityIsQuietAtItsCreation() {
    let thread = ConversationThread(
      id: "t", connectionId: "c", nativeThreadId: "n", createdAt: "2026-10-31T09:00:00Z",
      updatedAt: "2026-12-01T00:00:00Z")
    #expect(thread.activity == nil && thread.ownerDeviceName == nil)
    #expect(thread.projectId == nil && thread.readTurnId == nil)
    #expect(Attention.band(of: thread) == .quiet)
  }

  @Test func pinnedThreadsComeFirstThenBandsThenActivityThenId() {
    func thread(
      _ id: String, pinned: Bool = false, at: String, pending: Int = 0, status: TurnStatus? = nil
    )
      -> ConversationThread
    {
      var t = ConversationThread(id: id, connectionId: "c", nativeThreadId: id, pinned: pinned, createdAt: at)
      t.activity = ThreadActivity(
        latestTurnId: status == nil ? nil : "turn-" + id, latestTurnStatus: status, latestTurnOutcome: nil,
        pendingRequests: pending, lastActivityAt: at)
      return t
    }
    let ordered = Attention.ordered([
      thread("quiet-new", at: "2026-10-31T10:00:00Z"),
      thread("pinned-quiet", pinned: true, at: "2026-10-31T01:00:00Z"),
      thread("working", at: "2026-10-31T05:00:00Z", status: .running),
      thread("asks", at: "2026-10-31T02:00:00Z", pending: 1, status: .waitingForUser),
      thread("b", at: "2026-10-31T09:00:00Z"),
      thread("a", at: "2026-10-31T09:00:00Z"),
    ])
    #expect(ordered.map(\.id) == ["pinned-quiet", "asks", "working", "quiet-new", "a", "b"])
  }

  @Test func theNewFieldsAreOptionalOnTheWire() throws {
    let json = Data(
      #"{"id":"t","connectionId":"c","nativeThreadId":"n","nativeScope":"","title":"","pinned":false,"archived":false,"continuity":"available","createdAt":"x","updatedAt":"x"}"#
        .utf8)
    let thread = try JSONCoding.decoder.decode(ConversationThread.self, from: json)
    #expect(thread.projectId == nil && thread.readTurnId == nil && thread.activity == nil)
    let encoded = String(decoding: try JSONCoding.encoder.encode(thread), as: UTF8.self)
    #expect(!encoded.contains("activity") && !encoded.contains("ownerDeviceName"))
  }
}
