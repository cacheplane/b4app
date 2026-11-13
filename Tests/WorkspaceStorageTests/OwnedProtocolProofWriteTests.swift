import CoreFoundation
import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Native fixture and dormant owned-bind expectations. These comparisons establish no HTTP,
/// authenticated owner, account lease, runtime admission, or native quiescence authority.
@Suite struct OwnedProtocolProofWriteTests {
  private static let key = "__b4app_agent_protocol_activation_v1"
  private static let base = "https://example.invalid/OwnedProof"
  private static let stamp = "2026-11-13T00:00:00.000Z"
  private static let sentinelKey = "owned-proof-unrelated"
  private enum FixtureFailure: Error { case nativeShape, redactedFailure }

  private struct Fixture {
    let database: WorkspaceDatabase
    let inspector: PostgresConnection
    let link: WorkspaceDatabase.HubLink
    let binding: ProtocolMembershipBinding
    let anchor: ProtocolVerificationSnapshot
  }
  private struct NativeControl {
    let object: [String: Any]
    let store: String
    let member: String
    let revision: Int64
  }
  private struct PreservedState: Equatable {
    let rows: [String: [Data]]
    let sequence: Data
  }

  private static func equalBytes(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
  }

  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    do {
      let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "owned-proof-\(UUID())"
      try FileManager.default.createDirectory(
        atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(atPath: root) }
      // Keep the inspector's entire lifetime inside this call, before its physical root is removed.
      try withNativeFixture(root, body)
    } catch {
      // Neither SQL errors nor fixture values may escape through Swift Testing's error rendering.
      throw FixtureFailure.redactedFailure
    }
  }

  private static func withNativeFixture(_ root: String, _ body: (Fixture) throws -> Void) throws {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let database = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
    defer { try? database.close() }
    let outcome = Result<Void, any Error> {
      let inspector = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      let link = WorkspaceDatabase.HubLink(
        url: base, deviceId: "OWNED_PROOF_DEVICE", deviceName: "fixture",
        tokenRef: "secret:OWNED_PROOF_REFERENCE", orgSlug: "not-principal-proof",
        username: "not-principal-proof", joinedAt: stamp)
      // Existing normal APIs are fixture setup only. The new proof-write API is never used here.
      try database.saveHubLink(link)
      try database.setSetting(key: sentinelKey, value: .string("OWNED_PROOF_RETAINED"))
      _ = try database.insertConnection(
        Connection(
          id: "owned-proof-modern", kind: .agentProtocol, label: "Stored modern fixture",
          target: "https://example.invalid/agent", nativeScope: "owned-proof-native",
          peerProfile: .agentProtocol, agentId: "fixture-agent", authMode: ConnectionAuthMode.none))
      let binding = try ProtocolMembershipBinding(
        accountID: "OWNED_PROOF_ACCOUNT", canonicalHubBase: base, hubUserID: "OWNED_PROOF_USER",
        hubOrgID: "OWNED_PROOF_ORG", deviceID: link.deviceId, databaseName: endpoint.database,
        linkJoinedAt: link.joinedAt)
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: link.url, deviceID: link.deviceId, linkJoinedAt: link.joinedAt)
      let anchor = try database.captureProtocolVerification(
        accountID: binding.accountID, expectedMembership: membership)
      try body(
        Fixture(database: database, inspector: inspector, link: link, binding: binding, anchor: anchor))
    }
    // Close the real pool even when setup, native inspection, or an intended assertion fails.
    let closed = Result { try database.close() }
    try outcome.get()
    try closed.get()
  }

  private static func control(_ f: Fixture) throws -> NativeControl {
    let rows = try f.inspector.execute(
      "SELECT value::text AS value FROM public.settings WHERE key=$1", [key]
    ).rows
    guard rows.count == 1, let text = rows.first?.text("value"),
      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let number = object["version"] as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), number.stringValue == "1",
      let store = object["storeIncarnation"] as? String,
      let member = object["membershipIncarnation"] as? String,
      UUID(uuidString: store)?.uuidString == store, UUID(uuidString: member)?.uuidString == member,
      !equalBytes(store, member), let revisionText = object["revision"] as? String,
      let revision = Int64(revisionText), revision >= 0, equalBytes(String(revision), revisionText)
    else { throw FixtureFailure.nativeShape }
    return NativeControl(object: object, store: store, member: member, revision: revision)
  }

  private static func preserved(_ f: Fixture) throws -> PreservedState {
    var rows: [String: [Data]] = [:]
    for row in try f.inspector.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      guard let table = row.text("tablename") else { throw FixtureFailure.nativeShape }
      let condition = table == "settings" ? " WHERE t.key IS DISTINCT FROM $1" : ""
      let parameters: [String?] = table == "settings" ? [key] : []
      rows[table] = try f.inspector.execute(
        "SELECT to_jsonb(t)::text AS value FROM public.\(Rows.quote(table)) t\(condition)", parameters
      ).rows.map {
        guard let value = $0.text("value") else { throw FixtureFailure.nativeShape }
        return Data(value.utf8)
      }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    guard
      let sequence = try f.inspector.execute(
        "SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value FROM public.changes_seq_seq"
      ).rows.first?.text("value")
    else { throw FixtureFailure.nativeShape }
    return PreservedState(rows: rows, sequence: Data(sequence.utf8))
  }

  private static func validates(_ body: () throws -> Void) -> Bool {
    do { try body(); return true } catch { return false }
  }

  private static func validateFixture(_ f: Fixture) throws -> NativeControl {
    // Require independent native linked/control/modern facts BEFORE invoking the API under test.
    let rows = try f.inspector.execute("SELECT * FROM public.\"hubLink\"").rows
    guard rows.count == 1, let row = rows.first else { throw FixtureFailure.nativeShape }
    let expected: [(String, String?)] = [
      ("id", "1"), ("url", f.link.url), ("deviceId", f.link.deviceId),
      ("deviceName", f.link.deviceName), ("tokenRef", f.link.tokenRef),
      ("orgSlug", f.link.orgSlug), ("username", f.link.username), ("cursor", "0"),
      ("joinedAt", f.link.joinedAt), ("lastPushAt", nil), ("lastError", nil), ("ownedAs", nil),
    ]
    let exactLink = expected.allSatisfy { column, wanted in
      switch (row.text(column), wanted) {
      case (nil, nil): return true
      case (.some(let actual), .some(let desired)): return equalBytes(actual, desired)
      default: return false
      }
    }
    try #require(exactLink)
    let nativeDatabase = try f.inspector.execute("SELECT current_database() AS name").rows.first?.text("name")
    let exactDatabase = nativeDatabase.map { equalBytes($0, f.binding.databaseName) } ?? false
    try #require(exactDatabase)
    let inactive = try control(f)
    let exactInactive =
      inactive.revision == 0
      && Set(inactive.object.keys)
        == Set([
          "version", "storeIncarnation", "membershipIncarnation", "revision",
        ])
    try #require(exactInactive)
    let modernNative =
      try f.inspector.execute(
        "SELECT count(*) AS n FROM public.connections WHERE id='owned-proof-modern' AND kind='agentProtocol'"
      ).rows.first?.int("n") == 1
    let sentinelNative =
      try f.inspector.execute(
        "SELECT (value=to_jsonb('OWNED_PROOF_RETAINED'::text))::text AS exact FROM public.settings WHERE key=$1",
        [sentinelKey]
      ).rows.first?.text("exact") == "true"
    try #require(modernNative && sentinelNative)
    let before = try preserved(f)
    let ownerMatches = validates {
      try f.database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: f.anchor, accountID: f.binding.accountID,
        databaseName: f.binding.databaseName, hubBase: base)
    }
    let referenceMatches = validates {
      try f.database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef)
    }
    let verificationMatches = validates {
      try f.database.validateProtocolVerification(expectedSnapshot: f.anchor)
    }
    let syncRefuses = !validates { try f.database.validateProtocolSync(expectedSnapshot: f.anchor) }
    let modernWholeStore = try f.database.protocolSyncRequirement() == .protocolTwo
    let unchanged = try preserved(f) == before
    let latestControl = try control(f)
    let controlUnchanged = (latestControl.object as NSDictionary) == (inactive.object as NSDictionary)
    try #require(ownerMatches && referenceMatches && verificationMatches)
    try #require(modernWholeStore && syncRefuses && unchanged && controlUnchanged)
    return inactive
  }

  @Test func independentlyValidatedLinkedModernInactiveFixture() throws {
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
    }
  }

  @Test func ownedBindCommitsExactSuccessorFromModernInactiveAnchor() throws {
    try Self.withFixture { f in
      let predecessor = try Self.validateFixture(f)
      let before = try Self.preserved(f)
      let admission = ProtocolProofMemoryAdmission {}
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding, expectedTokenRef: f.link.tokenRef,
        memoryAdmission: admission)
      let isBind = receipt.operation == .bind
      let committedCurrent = receipt.disposition == .committedCurrent
      #expect(isBind)
      #expect(committedCurrent)
      // Native successor expectations stay positive while the reviewed no-BEGIN stub is dormant.
      let actual = try Self.control(f)
      let expectedBinding = [
        "accountID": f.binding.accountID, "canonicalHubBase": f.binding.canonicalHubBase,
        "hubUserID": f.binding.hubUserID, "hubOrgID": f.binding.hubOrgID,
        "deviceID": f.binding.deviceID, "databaseName": f.binding.databaseName,
        "linkJoinedAt": f.binding.linkJoinedAt,
      ]
      let actualBinding = actual.object["binding"] as? [String: String]
      let bindingMatches =
        actualBinding.map { actual in
          Set(actual.keys) == Set(expectedBinding.keys)
            && expectedBinding.allSatisfy { key, value in
              actual[key].map { Self.equalBytes($0, value) } ?? false
            }
        } ?? false
      let successorMatches =
        actual.revision == predecessor.revision + 1
        && Self.equalBytes(actual.store, predecessor.store)
        && Self.equalBytes(actual.member, predecessor.member)
        && Set(actual.object.keys)
          == Set([
            "version", "storeIncarnation", "membershipIncarnation", "revision", "binding",
          ])
        && bindingMatches
      let preserved = try Self.preserved(f) == before
      #expect(successorMatches)
      #expect(preserved)
      let redemption = Result {
        try receipt.currentSuccessor(
          expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      }
      let redeemed: Bool
      switch redemption {
      case .success: redeemed = true
      case .failure: redeemed = false
      }
      #expect(redeemed)
      if case .success(let successor) = redemption {
        // The returned snapshot must compare to the actual exact successor and retain its context.
        let nativeMatches = Self.validates {
          try f.database.validateProtocolVerification(expectedSnapshot: successor)
          try f.database.compareOriginalLinkedCredentialReference(
            expectedSnapshot: successor, expectedTokenRef: f.link.tokenRef)
          try f.database.compareOriginalLinkedCaptureOwner(
            expectedSnapshot: successor, accountID: f.binding.accountID,
            databaseName: f.binding.databaseName, hubBase: Self.base)
        }
        let noObservation = successor.observation == nil
        #expect(nativeMatches && noObservation)
      }
      let redacted =
        String(describing: receipt) == "ProtocolOwnedProofWriteReceipt(redacted)"
        && String(reflecting: receipt) == "ProtocolOwnedProofWriteReceipt(redacted)"
        && Mirror(reflecting: receipt).children.isEmpty
      #expect(redacted)
    }
  }
}
