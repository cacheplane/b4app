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

  var threads: [ConversationThread]
  var turns: [Turn]
  var runtimeRequests: [RuntimeRequest]
  var expected: Expected

  private struct Document: Decodable {
    var threads: [ConversationThread]
    var turns: [Turn]
    var runtimeRequests: [RuntimeRequest]
    var expected: Expected
  }

  static func load(file: StaticString = #filePath) throws -> AttentionFixture {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/attention.json")
    let document = try JSONCoding.decoder.decode(Document.self, from: Data(contentsOf: url))
    return AttentionFixture(
      threads: document.threads, turns: document.turns, runtimeRequests: document.runtimeRequests,
      expected: document.expected)
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

  /// Latest turn by `createdAt` (ties by `id`), `lastActivityAt` = max of the thread's `createdAt`
  /// and its latest turn's and requests' `updatedAt`; never the thread's own `updatedAt`.
  var threadsWithActivity: [ConversationThread] {
    threads.map { thread in
      let own = turns.filter { $0.threadId == thread.id }
      let latest = own.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      let requests = runtimeRequests.filter { $0.threadId == thread.id }
      let stamps = [thread.createdAt] + [latest?.updatedAt].compactMap { $0 } + requests.map(\.updatedAt)
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
    #expect(Set(f.threads.map(\.connectionId)).count == 1)
    // The hard case: a newer thread `updatedAt` must not lift a thread whose activity is oldest.
    let stale = try #require(f.threads.first { $0.id == "t-stale-updated" })
    #expect(f.threads.allSatisfy { $0.updatedAt <= stale.updatedAt })
    #expect(f.expectedOrder.last == stale.id)
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
