import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct WireTests {
  /// The fixture the hub's Rust tests read too. SwiftPM cannot declare a resource outside the target
  /// directory and copies a symlink as a dangling link, so the test reads the shared file in place,
  /// relative to this source file.
  private func fixtureChanges(file: StaticString = #filePath) throws -> [SyncChange] {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/changes.json")
    return try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
  }

  @Test func decodesTheSharedFixture() throws {
    let changes = try fixtureChanges()
    #expect(changes.count == 12)
    #expect(changes[0].table == "connections" && changes[0].op == "insert")
    #expect(changes[0].deviceSeq == 1)
    #expect(changes[0].value?["id"] == "conn-1")
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
