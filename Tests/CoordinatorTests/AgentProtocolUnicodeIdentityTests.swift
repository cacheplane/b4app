import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Opaque protocol identity preserves its spelling. Swift's canonically equivalent String == is
/// intentionally a setup control here, never the retained-identity or snapshot oracle.
@Suite(.serialized) struct AgentProtocolUnicodeIdentityTests {
  private typealias F = AgentProtocolIdentityManagedFixture
  private struct Bytes: Sendable, Equatable {
    var rows: [String: [Data]]
    var catalog: [Data]
    var sequences: [Data]
  }
  private static func bytes(_ c: PostgresConnection) throws -> Bytes {
    let value = try F.snapshot(c)
    return Bytes(
      rows: value.rows.mapValues { $0.map { Data($0.utf8) } },
      catalog: value.catalog.map { Data($0.utf8) }, sequences: value.sequences.map { Data($0.utf8) })
  }
  private static func identityBytes(_ value: Connection) -> [Data?] {
    [
      Data(value.id.utf8), Data(value.target.utf8),
      value.agentId.map { Data($0.utf8) }, value.nativeScope.map { Data($0.utf8) },
    ]
  }
  private static func profile(_ spelling: String) -> Connection {
    Connection(
      id: "unicode-profile-" + spelling, kind: .agentProtocol, label: "Opaque identity",
      target: "https://example.invalid/" + spelling, nativeScope: "scope-" + spelling,
      peerProfile: .agentProtocol, agentId: "agent-" + spelling, authMode: ConnectionAuthMode.none)
  }

  @Test func canonicallyEquivalentOpaqueIdentityEditsRefuseAndRetainExactBytes() async throws {
    let nfc = "caf\u{00E9}", nfd = "cafe\u{0301}"
    let equivalent = nfc == nfd
    let differentBytes = Data(nfc.utf8) != Data(nfd.utf8)
    try #require(equivalent && differentBytes, "The fixture needs canonical equivalence with distinct UTF-8.")
    let edits: [(String, @Sendable (inout Connection, String) -> Void)] = [
      ("id", { $0.id = "unicode-profile-" + $1 }),
      ("target", { $0.target = "https://example.invalid/" + $1 }),
      ("agentId", { $0.agentId = "agent-" + $1 }),
      ("nativeScope", { $0.nativeScope = "scope-" + $1 }),
    ]
    for (direction, source, replacement) in [("nfc-to-nfd", nfc, nfd), ("nfd-to-nfc", nfd, nfc)] {
      for (field, mutate) in edits {
        try await F.withStore(branch: direction + "-" + field) { f in
          // Fresh complete AP profile through the ordinary insert API. No setup retargeting/update.
          let inserted = Self.profile(source)
          _ = try f.database.insertConnection(inserted)
          let original = try #require(try f.database.connection(id: inserted.id))
          let originalSpelling = Self.identityBytes(original) == Self.identityBytes(inserted)
          try #require(originalSpelling, "Insertion must retain exact fixture identity bytes.")
          let before = try Self.bytes(f.raw)
          var error: WorkspaceError?
          do { _ = try f.database.updateConnection(id: inserted.id) { mutate(&$0, replacement) } } catch let
            caught
          { error = WorkspaceError.from(caught) }
          #expect(error?.code == .protocolInvalid, "Opaque identity field \(field) needs a fresh profile.")
          let exactSnapshotRetained = try Self.bytes(f.raw) == before
          #expect(exactSnapshotRetained)
          let retained = try #require(try f.database.connection(id: inserted.id))
          let exactIdentityRetained = Self.identityBytes(retained) == Self.identityBytes(inserted)
          #expect(exactIdentityRetained)
        }
      }
    }
    // SQL0010 requires present, nonempty agentId/nativeScope on complete AP profiles. Do not invent
    // invalid nil-source profiles. A present-to-nil attempt must refuse before SQL and keep spelling.
    let missing: [@Sendable (inout Connection) -> Void] = [{ $0.agentId = nil }, { $0.nativeScope = nil }]
    for (index, mutate) in missing.enumerated() {
      try await F.withStore(branch: index == 0 ? "agentId-to-nil" : "nativeScope-to-nil") { f in
        let inserted = Self.profile(nfc)
        _ = try f.database.insertConnection(inserted)
        let before = try Self.bytes(f.raw)
        var error: WorkspaceError?
        do { _ = try f.database.updateConnection(id: inserted.id, mutate) } catch let caught {
          error = WorkspaceError.from(caught)
        }
        #expect(error?.code == .protocolInvalid)
        let exactSnapshotRetained = try Self.bytes(f.raw) == before
        #expect(exactSnapshotRetained)
        let retained = try #require(try f.database.connection(id: inserted.id))
        let exactIdentityRetained = Self.identityBytes(retained) == Self.identityBytes(inserted)
        #expect(exactIdentityRetained)
      }
    }
  }
}
