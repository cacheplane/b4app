import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct WireTests {
  /// The fixture the hub's Rust tests read too. SwiftPM cannot declare a resource outside the target
  /// directory and copies a symlink as a dangling link, so the test reads the shared file in place,
  /// relative to this source file.
  private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/\(name)")
  }

  private func fixtureChanges() throws -> [SyncChange] {
    try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: fixtureURL("changes.json")))
  }

  @Test func decodesTheSharedFixture() throws {
    let changes = try fixtureChanges()
    #expect(changes.count == 12)
    #expect(changes[0].table == "connections" && changes[0].op == "insert")
    #expect(changes[0].deviceSeq == 1)
    #expect(changes[0].value?["id"] == "conn-1")
    #expect(changes[0].value?["projectId"] == "project-1")
    #expect(changes.allSatisfy { $0.hlc != nil })
    #expect(changes[0].hlc == "019a396c76e8-0000-01a194cf-0d12-7418-b3b5-5559dbee2441")
    #expect(HLC(rawValue: changes[11].hlc ?? "") != nil)
  }

  /// One entry of `conflicts.json`: the change the device made, which device it was, and its place.
  private struct ConflictEntry: Decodable {
    var platform: String
    var device: String
    var change: SyncChange

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Keys.self)
      platform = try container.decode(String.self, forKey: .platform)
      device = try container.decode(String.self, forKey: .device)
      change = try SyncChange(from: decoder)
    }

    private enum Keys: String, CodingKey { case platform, device }
  }

  private struct Conflicts: Decodable {
    var changes: [ConflictEntry]
    var expected: [String: JSONValue]
  }

  @Test func decodesTheConflictFixture() throws {
    let fixture = try JSONCoding.decoder.decode(
      Conflicts.self, from: Data(contentsOf: fixtureURL("conflicts.json")))

    #expect(fixture.changes.count == 9)
    #expect(Set(fixture.changes.map(\.platform)).isSubset(of: ["macos", "ios", "cli"]))
    #expect(fixture.changes.allSatisfy { !$0.device.isEmpty && $0.change.hlc != nil })
    #expect(fixture.changes[0].change.op == "insert" && fixture.changes[0].change.column == nil)
    #expect(fixture.changes[3].platform == "ios" && fixture.changes[3].change.value == "Phone title")
    #expect(fixture.expected["threads.title"] == "Mac title")
    #expect(fixture.expected["drafts.text"] == "")
    #expect(fixture.expected.count == 3)
  }

  @Test func fixtureRoundTripsWithoutLoss() throws {
    let changes = try fixtureChanges()
    let encoded = try JSONCoding.encoder.encode(changes)
    let decoded = try JSONCoding.decoder.decode([SyncChange].self, from: encoded)
    #expect(decoded == changes)
  }

  @Test func anUpdateWithJSONNullDecodesAsNullNotAbsent() throws {
    let present = Data(
      #"{"deviceSeq":1,"wall":2,"table":"threads","rowId":"t","op":"update","column":"title","value":null}"#
        .utf8)
    let absent = Data(#"{"deviceSeq":1,"wall":2,"table":"threads","rowId":"t","op":"delete"}"#.utf8)

    let cleared = try JSONCoding.decoder.decode(SyncChange.self, from: present)
    let deleted = try JSONCoding.decoder.decode(SyncChange.self, from: absent)

    #expect(cleared.value == .some(.null))
    #expect(deleted.value == nil)
    #expect(cleared != deleted)
    // The distinction survives a round trip through the encoder.
    let again = try JSONCoding.decoder.decode(SyncChange.self, from: JSONCoding.encoder.encode(cleared))
    #expect(again.value == .some(.null))
    let encodedDelete = try JSONCoding.encoder.encode(deleted)
    #expect(try JSONCoding.decoder.decode(SyncChange.self, from: encodedDelete).value == nil)
    #expect(!String(decoding: encodedDelete, as: UTF8.self).contains("value"))
  }

  @Test func aStoredChangeKeepsTheSameDistinction() throws {
    let json = Data(
      #"""
      {"hubSeq":9,"deviceId":"d","deviceSeq":3,"wall":4,"table":"threads","rowId":"t","op":"update","column":"title","value":null}
      """#.utf8)
    let stored = try JSONCoding.decoder.decode(StoredChange.self, from: json)
    #expect(stored.hubSeq == 9 && stored.deviceId == "d")
    #expect(stored.value == .some(.null))
  }

  @Test func aStoredChangeWithoutHlcDerivesOne() throws {
    let old = Data(
      #"""
      {"hubSeq":9,"deviceId":"01a1-dev","deviceSeq":3,"wall":1761900001000,"table":"threads","rowId":"t","op":"delete"}
      """#.utf8)
    let stored = try JSONCoding.decoder.decode(StoredChange.self, from: old)
    #expect(stored.hlc == "019a396c76e8-0000-01a1-dev")

    let negative = Data(
      #"{"hubSeq":1,"deviceId":"d","deviceSeq":1,"wall":-5,"table":"t","rowId":"r","op":"delete"}"#.utf8)
    #expect(try JSONCoding.decoder.decode(StoredChange.self, from: negative).hlc == "000000000000-0000-d")

    let explicit = Data(
      #"{"hubSeq":1,"deviceId":"d","deviceSeq":1,"wall":5,"table":"t","rowId":"r","op":"delete","hlc":"0000000000ff-0002-d"}"#
        .utf8)
    let kept = try JSONCoding.decoder.decode(StoredChange.self, from: explicit)
    #expect(kept.hlc == "0000000000ff-0002-d")
    // The initialiser derives it the same way, and a round trip keeps it.
    #expect(
      StoredChange(hubSeq: 1, deviceId: "d", deviceSeq: 1, wall: 255, table: "t", rowId: "r", op: "delete")
        .hlc
        == "0000000000ff-0000-d")
    #expect(try JSONCoding.decoder.decode(StoredChange.self, from: JSONCoding.encoder.encode(kept)) == kept)
  }

  @Test func aPushResponseOmitsAndDecodesRejections() throws {
    let plain = try JSONCoding.decoder.decode(PushResponse.self, from: Data(#"{"acceptedThrough":12}"#.utf8))
    #expect(plain.acceptedThrough == 12 && plain.rejected.isEmpty)
    let encoded = String(decoding: try JSONCoding.encoder.encode(plain), as: UTF8.self)
    #expect(!encoded.contains("rejected"))

    let refused = try JSONCoding.decoder.decode(
      PushResponse.self,
      from: Data(#"{"acceptedThrough":12,"rejected":[{"deviceSeq":7,"code":"column_not_writable"}]}"#.utf8))
    #expect(refused.rejected == [RejectedChange(deviceSeq: 7, code: "column_not_writable")])
  }

  @Test func aSyncChangeKeepsItsClockThroughARoundTrip() throws {
    let change = SyncChange(
      deviceSeq: 1, wall: 2, table: "threads", rowId: "t", op: "update", column: "title", value: "x",
      hlc: "000000000002-0000-d")
    let again = try JSONCoding.decoder.decode(SyncChange.self, from: JSONCoding.encoder.encode(change))
    #expect(again == change && again.hlc == "000000000002-0000-d")
    let bare = SyncChange(deviceSeq: 1, wall: 2, table: "threads", rowId: "t", op: "delete")
    #expect(!String(decoding: try JSONCoding.encoder.encode(bare), as: UTF8.self).contains("hlc"))
  }

  @Test func decodesTheHubResponses() throws {
    let enroll = Data(
      #"""
      {"deviceId":"0198","token":"tok","org":{"slug":"cacheplane","name":"cacheplane"},
       "user":{"username":"blove","displayName":"Brian Love"}}
      """#.utf8)
    let response = try JSONCoding.decoder.decode(EnrollResponse.self, from: enroll)
    #expect(response.org.slug == "cacheplane" && response.user.displayName == "Brian Love")

    let pull = Data(#"{"changes":[],"next":12,"more":false}"#.utf8)
    let page = try JSONCoding.decoder.decode(PullResponse.self, from: pull)
    #expect(page.next == 12 && !page.more && page.changes.isEmpty)

    let me = Data(
      #"""
      {"deviceId":"0198","deviceName":"Mac","platform":"macos","org":{"slug":"o","name":"O"},
       "user":{"username":"u","displayName":"U"},"createdAt":"2026-10-31T12:00:00.000000Z"}
      """#.utf8)
    #expect(
      try JSONCoding.decoder.decode(MeResponse.self, from: me).createdAt == "2026-10-31T12:00:00.000000Z")
  }

  @Test func decodesB4sErrorEnvelope() throws {
    let json = Data(
      #"{"error":{"kind":"request_error","message":"nope","details":{"code":"unauthorized"}}}"#.utf8)
    let body = try JSONCoding.decoder.decode(HubErrorBody.self, from: json)
    #expect(body.error.kind == "request_error" && body.error.message == "nope")
    #expect(body.error.details?.code == "unauthorized")
  }
}
