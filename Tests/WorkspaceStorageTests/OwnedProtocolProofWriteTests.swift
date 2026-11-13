import CoreFoundation
import Foundation
import Synchronization
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

extension OwnedProtocolProofWriteTests {
  private struct OwnedProofPoolFacts {
    let bodyCalled: Bool
    let attemptReturned: Bool
    let returnedReceiptMatches: Bool
    let freshDiffersFromRetainedOld: Bool?
    let freshReleasedAfterReturn: Bool?
    let laterOrdinarySucceeded: Bool
  }

  @Test func ownedProofFreshCheckoutNeverReturnsFreshToIdle() throws {
    var observed: OwnedProofPoolFacts?
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memoryAdmissionCalls = Mutex(0)
      let admission = ProtocolProofMemoryAdmission {
        memoryAdmissionCalls.withLock { $0 += 1 }
      }
      // Obtain genuine malformed-reference refusal before the subject pool's nonthrowing body.
      let receiptControl = try Self.control(f).object as NSDictionary
      let receiptState = try Self.preserved(f)
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding,
        expectedTokenRef: "owned-proof-invalid-reference",
        memoryAdmission: admission)
      let receiptControlUnchanged = try (Self.control(f).object as NSDictionary) == receiptControl
      let receiptStateUnchanged = try Self.preserved(f) == receiptState
      guard receipt.operation == .bind, receipt.disposition == .confirmedNoncommit,
        memoryAdmissionCalls.withLock({ $0 }) == 0, receiptControlUnchanged, receiptStateUnchanged
      else { throw FixtureFailure.nativeShape }

      let endpoint = f.database.endpoint
      let application = "b4_owned_proof_pool_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let pool = try ConnectionPool(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database) application_name=\(application)",
        size: 1)
      defer { pool.close() }
      let old = try pool.withConnection { connection in
        let rows = try connection.execute("SELECT 1 AS n, current_database() AS name").rows
        guard rows.count == 1, rows.first?.int("n") == 1,
          rows.first?.text("name") == endpoint.database
        else { throw FixtureFailure.nativeShape }
        return connection
      }
      observed = try withExtendedLifetime(old) {
        var bodyCalled = false
        var attemptReturned = false
        var returnedReceiptMatches = false
        var freshDiffersFromRetainedOld: Bool?
        weak var freshConnection: PostgresConnection?
        do {
          let returned = try pool.withOwnedProofConnection { fresh in
            bodyCalled = true
            freshDiffersFromRetainedOld = fresh !== old
            freshConnection = fresh
            return receipt
          }
          attemptReturned = true
          returnedReceiptMatches =
            returned.operation == .bind && returned.disposition == .confirmedNoncommit
        } catch {
          // Only facts leave the attempt; native errors never reach assertion rendering.
        }
        let freshReleasedAfterReturn: Bool?
        if bodyCalled && attemptReturned {
          let deadline = ContinuousClock.now + .seconds(2)
          while freshConnection != nil, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
          }
          freshReleasedAfterReturn = freshConnection == nil
        } else {
          freshReleasedAfterReturn = nil
        }
        let laterOrdinarySucceeded = Self.validates {
          try pool.withConnection { connection in
            let rows = try connection.execute("SELECT 1 AS n").rows
            guard rows.count == 1, rows.first?.int("n") == 1 else {
              throw FixtureFailure.nativeShape
            }
          }
        }
        guard laterOrdinarySucceeded, memoryAdmissionCalls.withLock({ $0 }) == 0 else {
          throw FixtureFailure.nativeShape
        }
        return OwnedProofPoolFacts(
          bodyCalled: bodyCalled, attemptReturned: attemptReturned,
          returnedReceiptMatches: returnedReceiptMatches,
          freshDiffersFromRetainedOld: freshDiffersFromRetainedOld,
          freshReleasedAfterReturn: freshReleasedAfterReturn,
          laterOrdinarySucceeded: laterOrdinarySucceeded)
      }
    }
    // The retained alias, separate pool and existing native fixture have all ended before issues.
    guard let facts = observed else { throw FixtureFailure.nativeShape }
    #expect(facts.bodyCalled)
    #expect(facts.returnedReceiptMatches)
    if facts.bodyCalled && facts.attemptReturned {
      #expect(facts.freshDiffersFromRetainedOld == true)
      #expect(facts.freshReleasedAfterReturn == true)
      #expect(facts.laterOrdinarySucceeded)
    }
  }
}

// Retain the actual native operation, not a Task that merely schedules blocking work. The group
// makes join repeatable: unconditional cleanup never consumes a completion semaphore twice.
private final class OwnedProofNativeWork<Value: Sendable> {
  private final class State: Sendable {
    let value = Mutex<Value?>(nil)
    let completion = DispatchGroup()
  }
  private let state: State
  private let thread: Thread

  init(_ operation: @escaping @Sendable () -> Value) {
    let state = State()
    self.state = state
    state.completion.enter()
    thread = Thread {
      let value = operation()
      state.value.withLock { $0 = value }
      state.completion.leave()
    }
    thread.start()
  }

  func join() -> Value {
    state.completion.wait()
    return state.value.withLock { $0! }
  }
}

private final class OwnedProofHold: Sendable {
  struct Facts: Sendable {
    var entered = false
    var held = false
    var expired = false
    var released = false
    var expiry: UInt64 = 0
  }
  private let facts = Mutex(Facts())
  private let gate = DispatchSemaphore(value: 0)

  // This is the holder's original eight-second guard. No observation extends it.
  func wait() -> Bool {
    let deadline = DispatchTime.now() + .seconds(8)
    facts.withLock {
      $0.entered = true
      $0.held = true
      $0.expiry = deadline.uptimeNanoseconds
    }
    let completed = gate.wait(timeout: deadline) == .success
    facts.withLock {
      $0.held = false
      $0.expired = !completed
    }
    return completed
  }

  func snapshot() -> Facts { facts.withLock { $0 } }

  func heldUnexpired() -> Bool {
    let value = snapshot()
    return value.entered && value.held && !value.expired && !value.released
      && DispatchTime.now().uptimeNanoseconds < value.expiry
  }

  func release() {
    let signal = facts.withLock { value in
      if value.released { return false }
      value.released = true
      return true
    }
    if signal { gate.signal() }
  }
}

private final class OwnedProofSlotObservation: Sendable {
  struct Facts: Sendable {
    let start: UInt64
    let deadline: UInt64
    let observed: UInt64
    let hold: OwnedProofHold.Facts
  }
  private let facts = Mutex<Facts?>(nil)

  // Passive fixed-size memory facts only; this callback performs no scheduling or native work.
  func record(_ start: DispatchTime, _ deadline: DispatchTime, _ hold: OwnedProofHold) {
    let value = Facts(
      start: start.uptimeNanoseconds, deadline: deadline.uptimeNanoseconds,
      observed: DispatchTime.now().uptimeNanoseconds, hold: hold.snapshot())
    facts.withLock { $0 = value }
  }

  func snapshot() -> Facts? { facts.withLock { $0 } }
}

extension OwnedProtocolProofWriteTests {
  private enum OwnedProofOutcome: Sendable, Equatable {
    case receipt, closed, slotTimeout, roleLimit, other
  }

  private struct OwnedProofDrainFacts: Sendable {
    let drained: Bool
    let returnedWhileBodyHeld: Bool
  }

  private static func ownedOutcome(
    _ operation: () throws -> ProtocolOwnedProofWriteReceipt
  ) -> OwnedProofOutcome {
    do {
      let receipt = try operation()
      return receipt.operation == .bind && receipt.disposition == .confirmedNoncommit
        ? .receipt : .other
    } catch let error as WorkspaceError {
      guard error.code == .endpointUnavailable else { return .other }
      if error.message == "The store is closed." { return .closed }
      if error.message == "Timed out waiting for a proof-write connection." { return .slotTimeout }
      // Native constructor evidence, classified to a fixed enum before leaving this operation.
      if error.message.contains("too many connections for role") { return .roleLimit }
      return .other
    } catch {
      return .other
    }
  }

  private static func poolObserved(_ signal: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !signal(), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.005) }
    return signal()
  }

  // Both pool fixtures obtain genuine malformed-reference refusal outside their callbacks.
  // All pool controls and assertions otherwise retain the qualified behavior.
  private static func withPoolReceipt(
    _ body: (Fixture, ProtocolOwnedProofWriteReceipt) throws -> Void
  ) throws {
    try withFixture { f in
      _ = try validateFixture(f)
      let calls = Mutex(0)
      let admission = ProtocolProofMemoryAdmission { calls.withLock { $0 += 1 } }
      let receiptControl = try control(f).object as NSDictionary
      let receiptState = try preserved(f)
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding,
        expectedTokenRef: "owned-proof-invalid-reference",
        memoryAdmission: admission)
      let receiptControlUnchanged = try (control(f).object as NSDictionary) == receiptControl
      let receiptStateUnchanged = try preserved(f) == receiptState
      guard receipt.operation == .bind, receipt.disposition == .confirmedNoncommit,
        calls.withLock({ $0 }) == 0, receiptControlUnchanged, receiptStateUnchanged
      else { throw FixtureFailure.nativeShape }
      let result = Result { try body(f, receipt) }
      guard calls.withLock({ $0 }) == 0 else { throw FixtureFailure.nativeShape }
      try result.get()
    }
  }

  private static func proofPool(_ f: Fixture, size: Int) throws -> ConnectionPool {
    let endpoint = f.database.endpoint
    let application = "b4_owned_control_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    return try ConnectionPool(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database) application_name=\(application)",
      size: size)
  }

  private static func nativeOne(_ connection: PostgresConnection) throws {
    let rows = try connection.execute("SELECT 1 AS n").rows
    guard rows.count == 1, rows.first?.int("n") == 1 else { throw FixtureFailure.nativeShape }
  }

  private static func ordinaryHolder(
    _ pool: ConnectionPool, _ hold: OwnedProofHold
  ) -> OwnedProofNativeWork<Bool> {
    OwnedProofNativeWork {
      validates {
        try pool.withConnection { connection in
          try nativeOne(connection)
          guard hold.wait() else { throw FixtureFailure.nativeShape }
        }
      }
    }
  }

  private static func roleSessionPresent(_ f: Fixture, role: String, application: String) throws -> Bool {
    try f.inspector.execute(
      "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND usename=$2 AND application_name=$3",
      [f.database.endpoint.database, role, application]
    ).rows.first?.int("n") == 1
  }

  private static func withLimitedProofRole(
    _ f: Fixture, size: Int, _ body: (ConnectionPool, String, String) throws -> Void
  ) throws {
    let role = "b4_owned_role_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let application = "b4_owned_limited_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try f.inspector.execute("CREATE ROLE \(Rows.quote(role)) LOGIN NOSUPERUSER CONNECTION LIMIT 1")
    var roleExists = true
    var pool: ConnectionPool?
    func cleanup() throws {
      pool?.close()
      pool = nil
      let absent = poolObserved {
        (try? f.inspector.execute(
          "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name=$2",
          [f.database.endpoint.database, application]
        ).rows.isEmpty) == true
      }
      guard absent else { throw FixtureFailure.nativeShape }
      if roleExists {
        try f.inspector.execute("DROP ROLE \(Rows.quote(role))")
        roleExists = false
      }
      guard try f.inspector.execute("SELECT 1 FROM pg_roles WHERE rolname=$1", [role]).rows.isEmpty else {
        throw FixtureFailure.nativeShape
      }
    }
    // Register native cleanup immediately after CREATE, including catalog/probe/setup failure.
    defer { if roleExists { try? cleanup() } }
    let result = Result {
      let rows = try f.inspector.execute(
        "SELECT rolcanlogin, rolsuper, rolconnlimit FROM pg_roles WHERE rolname=$1", [role]
      ).rows
      guard rows.count == 1, rows.first?.text("rolcanlogin") == "t",
        rows.first?.text("rolsuper") == "f", rows.first?.int("rolconnlimit") == 1
      else { throw FixtureFailure.nativeShape }
      let endpoint = f.database.endpoint
      // A real successful constructor probe is required before any refusal can earn credit.
      let limited = try ConnectionPool(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(role) dbname=\(endpoint.database) application_name=\(application)",
        size: size)
      pool = limited
      try body(limited, role, application)
    }
    let cleaned = Result { try cleanup() }
    try cleaned.get()
    try result.get()
  }

  @Test func ownedProofClosedBeforeAdmissionDoesNotWaitOrRunBody() throws {
    var exactClosed = false
    var observerAbsent = false
    var bodyAbsent = false
    var finalDrain = false
    try Self.withPoolReceipt { f, receipt in
      let pool = try Self.proofPool(f, size: 1)
      defer { pool.close() }
      pool.close()
      var observerCalls = 0
      var bodyCalls = 0
      let outcome = Self.ownedOutcome {
        try pool.withOwnedProofConnection(onSlotWait: { _, _ in observerCalls += 1 }) { _ in
          bodyCalls += 1
          return receipt
        }
      }
      exactClosed = outcome == .closed
      observerAbsent = observerCalls == 0
      bodyAbsent = bodyCalls == 0
      finalDrain = pool.closeForMigration(timeout: .zero)
    }
    #expect(exactClosed)
    #expect(observerAbsent)
    #expect(bodyAbsent)
    #expect(finalDrain)
  }

  @Test func ownedProofTimesOutAtActualFiveSecondSlotDeadlineWithoutExtraLease() throws {
    var actualFiveSeconds = false
    var validGuardMargin = false
    var heldThroughTimeout = false
    var exactTimeout = false
    var bodyAbsent = false
    var boundedRecoveryAbsent = false
    var recoverySucceeded = false
    var finalDrain = false
    try Self.withPoolReceipt { f, receipt in
      let pool = try Self.proofPool(f, size: 1)
      defer { pool.close() }
      let hold = OwnedProofHold()
      let holder = Self.ordinaryHolder(pool, hold)
      var waiter: OwnedProofNativeWork<OwnedProofOutcome>?
      var recovery: OwnedProofNativeWork<Bool>?
      defer {
        hold.release()
        _ = holder.join()
        _ = waiter?.join()
        _ = recovery?.join()
      }
      guard Self.poolObserved({ hold.snapshot().entered }), hold.heldUnexpired() else {
        throw FixtureFailure.nativeShape
      }
      let slot = OwnedProofSlotObservation()
      let bodyCalls = Mutex(0)
      let owned = OwnedProofNativeWork {
        Self.ownedOutcome {
          try pool.withOwnedProofConnection(onSlotWait: { start, deadline in
            slot.record(start, deadline, hold)
          }) { _ in
            bodyCalls.withLock { $0 += 1 }
            return receipt
          }
        }
      }
      waiter = owned
      let outcome = owned.join()
      let ended = DispatchTime.now().uptimeNanoseconds
      guard let timing = slot.snapshot() else { throw FixtureFailure.nativeShape }
      let (budget, budgetUnderflow) = timing.deadline.subtractingReportingOverflow(timing.start)
      let (margin, marginUnderflow) = timing.hold.expiry.subtractingReportingOverflow(timing.deadline)
      actualFiveSeconds =
        !budgetUnderflow && budget == 5_000_000_000
        && timing.observed >= timing.start && timing.observed < timing.deadline
        && ended >= timing.deadline
      validGuardMargin =
        !marginUnderflow && margin >= 2_000_000_000
        && timing.hold.held && !timing.hold.expired && !timing.hold.released
      heldThroughTimeout = hold.heldUnexpired()
      guard actualFiveSeconds, validGuardMargin, heldThroughTimeout else {
        throw FixtureFailure.nativeShape
      }
      exactTimeout = outcome == .slotTimeout
      bodyAbsent = bodyCalls.withLock { $0 } == 0
      let beforeWaiting = Mutex(false)
      let recoveryBody = Mutex(false)
      let overlapsHolder = Mutex(false)
      let recoveryWorker = OwnedProofNativeWork {
        Self.validates {
          try pool.withConnection(beforeWaiting: { beforeWaiting.withLock { $0 = true } }) { connection in
            overlapsHolder.withLock { $0 = hold.snapshot().held }
            recoveryBody.withLock { $0 = true }
            try Self.nativeOne(connection)
          }
        }
      }
      recovery = recoveryWorker
      guard Self.poolObserved({ beforeWaiting.withLock { $0 } }), hold.heldUnexpired() else {
        throw FixtureFailure.nativeShape
      }
      // A bounded inverse observation after the actual ordinary wait marker. Source review is
      // also required: this does not claim a universal permit count or a kernel-wait theorem.
      Thread.sleep(forTimeInterval: 0.075)
      boundedRecoveryAbsent = !recoveryBody.withLock({ $0 }) && hold.heldUnexpired()
      guard boundedRecoveryAbsent else { throw FixtureFailure.nativeShape }
      hold.release()
      let holderSucceeded = holder.join()
      recoverySucceeded =
        recoveryWorker.join() && holderSucceeded
        && recoveryBody.withLock({ $0 }) && !overlapsHolder.withLock({ $0 })
      guard !hold.snapshot().expired else { throw FixtureFailure.nativeShape }
      finalDrain = pool.closeForMigration(timeout: .zero)
    }
    #expect(actualFiveSeconds)
    #expect(validGuardMargin)
    #expect(heldThroughTimeout)
    #expect(exactTimeout)
    #expect(bodyAbsent)
    #expect(boundedRecoveryAbsent)
    #expect(recoverySucceeded)
    #expect(finalDrain)
  }

  @Test func ownedProofQueuedAdmissionRefusesAfterConcurrentClose() throws {
    var closedBeforeDeadline = false
    var exactClosed = false
    var bodyAbsent = false
    var holderSucceeded = false
    var finalDrain = false
    try Self.withPoolReceipt { f, receipt in
      let pool = try Self.proofPool(f, size: 1)
      defer { pool.close() }
      let hold = OwnedProofHold()
      let holder = Self.ordinaryHolder(pool, hold)
      var waiter: OwnedProofNativeWork<OwnedProofOutcome>?
      defer {
        hold.release()
        _ = holder.join()
        _ = waiter?.join()
      }
      guard Self.poolObserved({ hold.snapshot().entered }), hold.heldUnexpired() else {
        throw FixtureFailure.nativeShape
      }
      let slot = OwnedProofSlotObservation()
      let calls = Mutex(0)
      let owned = OwnedProofNativeWork {
        Self.ownedOutcome {
          try pool.withOwnedProofConnection(onSlotWait: { start, deadline in
            slot.record(start, deadline, hold)
          }) { _ in
            calls.withLock { $0 += 1 }
            return receipt
          }
        }
      }
      waiter = owned
      guard Self.poolObserved({ slot.snapshot() != nil }), let timing = slot.snapshot(),
        hold.heldUnexpired(), DispatchTime.now().uptimeNanoseconds < timing.deadline
      else { throw FixtureFailure.nativeShape }
      pool.close()
      closedBeforeDeadline = DispatchTime.now().uptimeNanoseconds < timing.deadline
      guard closedBeforeDeadline, hold.heldUnexpired() else { throw FixtureFailure.nativeShape }
      hold.release()
      holderSucceeded = holder.join()
      exactClosed = owned.join() == .closed
      bodyAbsent = calls.withLock { $0 } == 0
      guard !hold.snapshot().expired else { throw FixtureFailure.nativeShape }
      finalDrain = pool.closeForMigration(timeout: .zero)
    }
    #expect(closedBeforeDeadline)
    #expect(exactClosed)
    #expect(bodyAbsent)
    #expect(holderSucceeded)
    #expect(finalDrain)
  }

  @Test func ownedProofBodyKeepsLogicalLeaseAndSlotThroughWork() throws {
    var drainRefusedWhileHeld = false
    var secondBodyAbsent = false
    var firstReturnedReceipt = false
    var secondClosed = false
    var finalDrain = false
    var openSerialResults = false
    try Self.withPoolReceipt { f, receipt in
      let pool = try Self.proofPool(f, size: 1)
      defer { pool.close() }
      let hold = OwnedProofHold()
      let first = OwnedProofNativeWork {
        Self.ownedOutcome {
          try pool.withOwnedProofConnection { _ in
            // The body is nonthrowing. Guard expiry is an INVALID fixture even though the
            // required genuine receipt is still returned; it never becomes success credit.
            _ = hold.wait()
            return receipt
          }
        }
      }
      var second: OwnedProofNativeWork<OwnedProofOutcome>?
      var drainer: OwnedProofNativeWork<OwnedProofDrainFacts>?
      defer {
        hold.release()
        _ = first.join()
        _ = second?.join()
        _ = drainer?.join()
      }
      guard Self.poolObserved({ hold.snapshot().entered }), hold.heldUnexpired() else {
        throw FixtureFailure.nativeShape
      }
      let slot = OwnedProofSlotObservation()
      let calls = Mutex(0)
      let waiting = OwnedProofNativeWork {
        Self.ownedOutcome {
          try pool.withOwnedProofConnection(onSlotWait: { start, deadline in
            slot.record(start, deadline, hold)
          }) { _ in
            calls.withLock { $0 += 1 }
            return receipt
          }
        }
      }
      second = waiting
      guard Self.poolObserved({ slot.snapshot() != nil }), hold.heldUnexpired() else {
        throw FixtureFailure.nativeShape
      }
      let drainWorker = OwnedProofNativeWork {
        let drained = pool.closeForMigration(timeout: .milliseconds(100))
        return OwnedProofDrainFacts(drained: drained, returnedWhileBodyHeld: hold.heldUnexpired())
      }
      drainer = drainWorker
      let drained = drainWorker.join()
      drainRefusedWhileHeld =
        !drained.drained && drained.returnedWhileBodyHeld
        && hold.heldUnexpired()
      secondBodyAbsent = calls.withLock { $0 } == 0
      guard drainRefusedWhileHeld else { throw FixtureFailure.nativeShape }
      hold.release()
      firstReturnedReceipt = first.join() == .receipt
      secondClosed = waiting.join() == .closed
      secondBodyAbsent = secondBodyAbsent && calls.withLock { $0 } == 0
      guard !hold.snapshot().expired else { throw FixtureFailure.nativeShape }
      finalDrain = pool.closeForMigration(timeout: .zero)

      // A separate OPEN size-one pool supplies the two-success positive control.
      let open = try Self.proofPool(f, size: 1)
      defer { open.close() }
      let serial = OwnedProofNativeWork {
        var calls = 0
        let first = Self.ownedOutcome {
          try open.withOwnedProofConnection { _ in
            calls += 1; return receipt
          }
        }
        let second = Self.ownedOutcome {
          try open.withOwnedProofConnection { _ in
            calls += 1; return receipt
          }
        }
        return first == .receipt && second == .receipt && calls == 2
      }
      defer { _ = serial.join() }
      openSerialResults = serial.join()
      guard open.closeForMigration(timeout: .zero) else { throw FixtureFailure.nativeShape }
    }
    #expect(drainRefusedWhileHeld)
    #expect(secondBodyAbsent)
    #expect(firstReturnedReceipt)
    #expect(secondClosed)
    #expect(finalDrain)
    #expect(openSerialResults)
  }

  @Test func ownedProofFreshConstructorRefusalReleasesLeaseAndSlotWithoutBody() throws {
    var nativeSession = false
    var bothNativeRefusals = false
    var heldThroughBoth = false
    var bodyAbsent = false
    var holderSucceeded = false
    var finalDrain = false
    try Self.withPoolReceipt { f, receipt in
      try Self.withLimitedProofRole(f, size: 2) { pool, role, application in
        let hold = OwnedProofHold()
        let holder = Self.ordinaryHolder(pool, hold)
        var first: OwnedProofNativeWork<OwnedProofOutcome>?
        var second: OwnedProofNativeWork<OwnedProofOutcome>?
        defer {
          hold.release()
          _ = holder.join()
          _ = first?.join()
          _ = second?.join()
        }
        guard Self.poolObserved({ hold.snapshot().entered }), hold.heldUnexpired() else {
          throw FixtureFailure.nativeShape
        }
        nativeSession = try Self.roleSessionPresent(f, role: role, application: application)
        guard nativeSession else { throw FixtureFailure.nativeShape }
        let calls = Mutex(0)
        let one = OwnedProofNativeWork {
          Self.ownedOutcome {
            try pool.withOwnedProofConnection { _ in
              calls.withLock { $0 += 1 }
              return receipt
            }
          }
        }
        first = one
        let firstOutcome = one.join()
        let stillHeldAfterFirst = hold.heldUnexpired()
        guard stillHeldAfterFirst else { throw FixtureFailure.nativeShape }
        let two = OwnedProofNativeWork {
          Self.ownedOutcome {
            try pool.withOwnedProofConnection { _ in
              calls.withLock { $0 += 1 }
              return receipt
            }
          }
        }
        second = two
        let secondOutcome = two.join()
        heldThroughBoth = stillHeldAfterFirst && hold.heldUnexpired()
        bothNativeRefusals = firstOutcome == .roleLimit && secondOutcome == .roleLimit
        bodyAbsent = calls.withLock { $0 } == 0
        guard heldThroughBoth else { throw FixtureFailure.nativeShape }
        hold.release()
        holderSucceeded = holder.join()
        guard !hold.snapshot().expired else { throw FixtureFailure.nativeShape }
        finalDrain = pool.closeForMigration(timeout: .zero)
      }
    }
    #expect(nativeSession)
    #expect(bothNativeRefusals)
    #expect(heldThroughBoth)
    #expect(bodyAbsent)
    #expect(holderSucceeded)
    #expect(finalDrain)
  }

  @Test func ownedProofDoesNotReuseLiveOrdinaryIdleProbeWhenFreshConnectMustFail() throws {
    var nativeSessionBefore = false
    var nativeSessionAfter = false
    var liveBefore = false
    var liveAfter = false
    var nativeRefusal = false
    var bodyAbsent = false
    var finalDrain = false
    try Self.withPoolReceipt { f, receipt in
      try Self.withLimitedProofRole(f, size: 1) { pool, role, application in
        // The probe has returned to ordinary idle, but this caller retains a live strong alias.
        // It is never exported from an OWNED body, and no second startup competes with it.
        let old = try pool.withConnection { connection in
          try Self.nativeOne(connection)
          return connection
        }
        try withExtendedLifetime(old) {
          liveBefore = Self.validates { try Self.nativeOne(old) }
          nativeSessionBefore = try Self.roleSessionPresent(f, role: role, application: application)
          guard liveBefore, nativeSessionBefore else { throw FixtureFailure.nativeShape }
          let calls = Mutex(0)
          let worker = OwnedProofNativeWork {
            Self.ownedOutcome {
              try pool.withOwnedProofConnection { _ in
                calls.withLock { $0 += 1 }
                return receipt
              }
            }
          }
          defer { _ = worker.join() }
          nativeRefusal = worker.join() == .roleLimit
          bodyAbsent = calls.withLock { $0 } == 0
          liveAfter = Self.validates { try Self.nativeOne(old) }
          nativeSessionAfter = try Self.roleSessionPresent(f, role: role, application: application)
          guard liveAfter, nativeSessionAfter else { throw FixtureFailure.nativeShape }
        }
        finalDrain = pool.closeForMigration(timeout: .zero)
        // withLimitedProofRole closes the pool and proves bounded named-backend absence after
        // this scope relinquishes the old alias, before DROP ROLE and catalog absence checks.
      }
    }
    #expect(nativeSessionBefore)
    #expect(nativeSessionAfter)
    #expect(liveBefore)
    #expect(liveAfter)
    #expect(nativeRefusal)
    #expect(bodyAbsent)
    #expect(finalDrain)
  }
}

extension OwnedProtocolProofWriteTests {
  @Test func ownedBindEqualBindingNoopRequiresActualCommitReceipt() throws {
    var committedCurrent = false
    var redeemed = false
    try Self.withFixture { f in
      let predecessor = try Self.validateFixture(f)
      let before = try Self.preserved(f)
      // Independently derive the entire bound image from native S0 and the fixture binding.
      var expected = predecessor.object
      expected["revision"] = "1"
      expected["binding"] = [
        "accountID": f.binding.accountID, "canonicalHubBase": f.binding.canonicalHubBase,
        "hubUserID": f.binding.hubUserID, "hubOrgID": f.binding.hubOrgID,
        "deviceID": f.binding.deviceID, "databaseName": f.binding.databaseName,
        "linkJoinedAt": f.binding.linkJoinedAt,
      ]
      let expectedControl = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
      // The ordinary captured overload is setup only; its returned bound snapshot is the anchor.
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding)
      let prepared = try Self.control(f)
      let setupMatches =
        try JSONSerialization.data(withJSONObject: prepared.object, options: [.sortedKeys])
        == expectedControl
      let setupPreserved = try Self.preserved(f) == before
      guard setupMatches, setupPreserved, bound.observation == nil else {
        throw FixtureFailure.nativeShape
      }
      try f.database.validateProtocolVerification(expectedSnapshot: bound)
      try f.database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: bound, accountID: f.binding.accountID,
        databaseName: f.binding.databaseName, hubBase: Self.base)
      try f.database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: bound, expectedTokenRef: f.link.tokenRef)

      let admission = ProtocolProofMemoryAdmission {}
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: bound, expectedBinding: f.binding, expectedTokenRef: f.link.tokenRef,
        memoryAdmission: admission)
      let actual = try Self.control(f)
      let controlUnchanged =
        try JSONSerialization.data(withJSONObject: actual.object, options: [.sortedKeys])
        == expectedControl
      // This includes every public table (including the original native link/reference) and
      // sequence state, excluding only the control row compared independently above.
      let preserved = try Self.preserved(f) == before
      let redacted =
        String(describing: receipt) == "ProtocolOwnedProofWriteReceipt(redacted)"
        && String(reflecting: receipt) == "ProtocolOwnedProofWriteReceipt(redacted)"
        && Mirror(reflecting: receipt).children.isEmpty
      guard controlUnchanged, preserved, receipt.operation == .bind, redacted else {
        throw FixtureFailure.nativeShape
      }
      committedCurrent = receipt.disposition == .committedCurrent
      do {
        _ = try receipt.currentSuccessor(
          expectedSnapshot: bound, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
        redeemed = true
      } catch {
        redeemed = false
      }
    }
    // Only primitive facts reach assertions, after the existing fixture has actually cleaned up.
    // No DML means no deferred probe: a committed receipt requires the writer's actual COMMIT ACK.
    #expect(committedCurrent)
    #expect(redeemed)
  }
}

extension OwnedProtocolProofWriteTests {
  @Test func ownedBindSettlementClassifierPreservesUnknownForInvalidAndUnacknowledgedStates() {
    // All sixteen inputs, including impossible histories. This is a pure decision test only;
    // it neither manufactures a receipt nor simulates a native missing acknowledgement.
    let cases: [(Bool, Bool, Bool, Bool, ProtocolProofSettlementDecision)] = [
      (false, false, false, false, .confirmedNoncommit),
      (false, false, false, true, .unknown),
      (false, false, true, false, .unknown),
      (false, false, true, true, .unknown),
      (false, true, false, false, .unknown),
      (false, true, false, true, .unknown),
      (false, true, true, false, .unknown),
      (false, true, true, true, .unknown),
      (true, false, false, false, .unknown),
      (true, false, false, true, .unknown),
      (true, false, true, false, .unknown),
      (true, false, true, true, .committed),
      (true, true, false, false, .confirmedNoncommit),
      (true, true, false, true, .unknown),
      (true, true, true, false, .unknown),
      (true, true, true, true, .unknown),
    ]
    for (begin, rollbackACK, commit, commitACK, expected) in cases {
      let actual = ProtocolProofSettlementClassifier.classify(
        beginSent: begin, rollbackAcknowledged: rollbackACK,
        commitSent: commit, commitAcknowledged: commitACK)
      #expect(actual == expected)
    }
  }

  private static func controlData(_ f: Fixture) throws -> Data {
    try JSONSerialization.data(withJSONObject: control(f).object, options: [.sortedKeys])
  }

  private static func expectedBoundControl(_ f: Fixture, predecessor: NativeControl) throws -> Data {
    var expected = predecessor.object
    expected["revision"] = String(predecessor.revision + 1)
    expected["binding"] = [
      "accountID": f.binding.accountID, "canonicalHubBase": f.binding.canonicalHubBase,
      "hubUserID": f.binding.hubUserID, "hubOrgID": f.binding.hubOrgID,
      "deviceID": f.binding.deviceID, "databaseName": f.binding.databaseName,
      "linkJoinedAt": f.binding.linkJoinedAt,
    ]
    return try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
  }

  private static func validateSuccessor(_ f: Fixture, _ successor: ProtocolVerificationSnapshot) throws {
    guard successor.observation == nil else { throw FixtureFailure.nativeShape }
    try f.database.validateProtocolVerification(expectedSnapshot: successor)
    try f.database.compareOriginalLinkedCaptureOwner(
      expectedSnapshot: successor, accountID: f.binding.accountID,
      databaseName: f.binding.databaseName, hubBase: base)
    try f.database.compareOriginalLinkedCredentialReference(
      expectedSnapshot: successor, expectedTokenRef: f.link.tokenRef)
  }

  @Test func ownedBindLegacyOnlyStoreCommitsWithoutHealthyProtocolTwoObservation() throws {
    var committedCurrent = false
    var redeemed = false
    var exactSuccessor = false
    var preserved = false
    try Self.withFixture { f in
      let predecessor = try Self.validateFixture(f)
      let originalControl = try Self.controlData(f)
      let originalLink = try Self.preserved(f).rows["hubLink"]
      // Only this fixture's modern profile and its retained witnesses are removed. Sequence
      // allocations from legitimate setup remain consumed; baseline is captured AFTER setup.
      try f.inspector.execute("DELETE FROM public.connections WHERE id='owned-proof-modern'")
      try f.inspector.execute(
        "DELETE FROM public.changes WHERE \"table\"='connections' AND \"rowId\"='owned-proof-modern'")
      try f.inspector.execute(
        "DELETE FROM public.\"columnClocks\" WHERE \"table\"='connections' AND \"rowId\"='owned-proof-modern'"
      )
      _ = try f.database.insertConnection(
        Connection(
          id: "owned-proof-legacy", kind: .codex, label: "Legacy owned bind fixture",
          target: "/fixture/codex"))
      let nativeLegacy =
        try f.inspector.execute(
          """
          SELECT count(*) AS n FROM public.connections
          WHERE id='owned-proof-legacy' AND kind='codex'
            AND "peerProfile" IS NULL AND "agentId" IS NULL AND "authMode" IS NULL
            AND "authHeaderName" IS NULL AND "protocolRetiredAt" IS NULL
            AND "protocolRetiredReason" IS NULL
          """
        ).rows.first?.int("n") == 1
      let nativeModernAbsent =
        try f.inspector.execute(
          "SELECT count(*) AS n FROM public.connections WHERE id='owned-proof-modern'"
        ).rows.first?.int("n") == 0
      let legacyOnly = try f.database.protocolSyncRequirement() == .legacyOnly
      let controlUnchanged = try Self.controlData(f) == originalControl
      let linkUnchanged = try Self.preserved(f).rows["hubLink"] == originalLink
      guard nativeLegacy, nativeModernAbsent, legacyOnly, controlUnchanged, linkUnchanged,
        f.anchor.observation == nil
      else { throw FixtureFailure.nativeShape }
      try Self.validateSuccessor(f, f.anchor)
      let before = try Self.preserved(f)
      let expected = try Self.expectedBoundControl(f, predecessor: predecessor)
      let admission = ProtocolProofMemoryAdmission {}
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding, expectedTokenRef: f.link.tokenRef,
        memoryAdmission: admission)
      guard receipt.operation == .bind else { throw FixtureFailure.nativeShape }
      committedCurrent = receipt.disposition == .committedCurrent
      exactSuccessor = try Self.controlData(f) == expected
      preserved = try Self.preserved(f) == before
      if let successor = try? receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      {
        try Self.validateSuccessor(f, successor)
        redeemed = true
      }
    }
    #expect(committedCurrent)
    #expect(exactSuccessor)
    #expect(preserved)
    #expect(redeemed)
  }

  @Test func ownedBindCurrentReceiptRequiresOriginalAnchorReferenceAdmissionAndFreshMemory() throws {
    var committedCurrent = false
    var positive = false
    var wrongAnchorRefused = false
    var wrongReferenceRefused = false
    var differentAdmissionRefused = false
    var laterMemoryRefused = false
    var dispositionRetained = false
    var unchanged = false
    try Self.withFixture { f in
      let predecessor = try Self.validateFixture(f)
      let before = try Self.preserved(f)
      let expected = try Self.expectedBoundControl(f, predecessor: predecessor)
      let current = Mutex(true)
      let admission = ProtocolProofMemoryAdmission {
        let accepted = current.withLock { $0 }
        guard accepted else { throw FixtureFailure.nativeShape }
      }
      let receipt = f.database.prepareProtocolVerification(
        expectedSnapshot: f.anchor, expectedBinding: f.binding, expectedTokenRef: f.link.tokenRef,
        memoryAdmission: admission)
      committedCurrent = receipt.operation == .bind && receipt.disposition == .committedCurrent
      guard committedCurrent, try Self.controlData(f) == expected,
        try Self.preserved(f) == before
      else { throw FixtureFailure.nativeShape }
      let successor = try receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      try Self.validateSuccessor(f, successor)
      positive = true
      let committedControl = try Self.controlData(f)
      let committedState = try Self.preserved(f)
      wrongAnchorRefused = !Self.validates {
        _ = try receipt.currentSuccessor(
          expectedSnapshot: successor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      }
      wrongReferenceRefused = !Self.validates {
        _ = try receipt.currentSuccessor(
          expectedSnapshot: f.anchor, expectedTokenRef: "secret:OWNED_PROOF_CHANGED_REFERENCE",
          memoryAdmission: admission)
      }
      differentAdmissionRefused = !Self.validates {
        _ = try receipt.currentSuccessor(
          expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef,
          memoryAdmission: ProtocolProofMemoryAdmission {})
      }
      current.withLock { $0 = false }
      laterMemoryRefused = !Self.validates {
        _ = try receipt.currentSuccessor(
          expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      }
      // Retirement after return affects redemption; it does not reclassify the COMMIT receipt.
      dispositionRetained = receipt.disposition == .committedCurrent
      unchanged = try Self.controlData(f) == committedControl && Self.preserved(f) == committedState
    }
    #expect(committedCurrent)
    #expect(positive)
    #expect(wrongAnchorRefused)
    #expect(wrongReferenceRefused)
    #expect(differentAdmissionRefused)
    #expect(laterMemoryRefused)
    #expect(dispositionRetained)
    #expect(unchanged)
  }
}

// Raw fixture qualification only. No owned proof API, admission, worker, holder, or waiter is
// invoked below. Future writer scenarios must run ownedBindRawStageControls themselves.
extension OwnedProtocolProofWriteTests {
  private struct OwnedBindImage: Equatable {
    let database: String
    let rows: [String: [Data]]
    let sequence: Data
  }

  private struct OwnedBindStageFixture {
    let before: OwnedBindImage
    let expected: OwnedBindImage
    let controlJSON: String
    let originalReference: String
    let replacement: String
    let device: String
    let lowerWall: UInt64
  }

  private struct OwnedBindProbe: Equatable {
    let last: Int64
    let called: Bool

    func advanced(from before: Self, by count: Int64) -> Bool {
      guard count >= 0 else { return false }
      if count == 0 { return self == before }
      let (wanted, overflow) = before.last.addingReportingOverflow(
        count - (before.called ? 0 : 1))
      return !overflow && called && last == wanted
    }
  }

  private enum OwnedBindRawControl: Int, CaseIterable {
    case imageReject, normalA, bodyFault, normalB
  }

  // Only these fixed primitive facts leave each completely torn-down native fixture.
  private struct OwnedBindRawFacts {
    let row: Int
    let dmlReturned: Bool
    let commitSent: Bool
    let commitAcknowledged: Bool
    let rollbackAcknowledged: Bool
    let predicateRejected: Bool
    let bodyFaultRejected: Bool
    let ownImageValidated: Bool
    let durableImageValidated: Bool
    let settingsValidated: Bool
    let bodyAllocations: Int64
    let commitAllocations: Int64

    var qualified: Bool {
      guard durableImageValidated else { return false }
      switch row {
      case OwnedBindRawControl.imageReject.rawValue:
        return !dmlReturned && !commitSent && !commitAcknowledged && rollbackAcknowledged
          && predicateRejected && !bodyFaultRejected && !ownImageValidated
          && !settingsValidated && bodyAllocations == 0 && commitAllocations == 0
      case OwnedBindRawControl.bodyFault.rawValue:
        return !dmlReturned && !commitSent && !commitAcknowledged && rollbackAcknowledged
          && !predicateRejected && bodyFaultRejected && !ownImageValidated
          && !settingsValidated && bodyAllocations == 1 && commitAllocations == 0
      case OwnedBindRawControl.normalA.rawValue, OwnedBindRawControl.normalB.rawValue:
        return dmlReturned && commitSent && commitAcknowledged && !rollbackAcknowledged
          && !predicateRejected && !bodyFaultRejected && ownImageValidated
          && settingsValidated && bodyAllocations == 1 && commitAllocations == 1
      default: return false
      }
    }
  }

  private static let ownedBindRawUpsert = """
    INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)
    ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value
    """

  private static func ownedBindJSON(_ text: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: Data(text.utf8)), options: [.sortedKeys])
  }

  private static func ownedBindText(_ data: Data) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else { throw FixtureFailure.nativeShape }
    return text
  }

  private static func ownedBindWall(_ c: PostgresConnection) throws -> UInt64 {
    let rows = try c.execute(
      "SELECT floor(extract(epoch FROM pg_catalog.clock_timestamp())*1000)::bigint AS wall"
    ).rows
    guard rows.count == 1, let text = rows[0].text("wall"), let wall = UInt64(text),
      wall <= 0xffff_ffff_ffff
    else { throw FixtureFailure.nativeShape }
    return wall
  }

  private static func ownedBindImage(_ c: PostgresConnection) throws -> OwnedBindImage {
    let identity = try c.execute("SELECT pg_catalog.current_database() AS name").rows
    guard identity.count == 1, let database = identity[0].text("name") else {
      throw FixtureFailure.nativeShape
    }
    var rows: [String: [Data]] = [:]
    for entry in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      guard let table = entry.text("tablename"), rows[table] == nil else {
        throw FixtureFailure.nativeShape
      }
      rows[table] = try c.execute(
        "SELECT pg_catalog.to_jsonb(t)::text AS value FROM public.\(Rows.quote(table)) t"
      ).rows.map { row in
        guard let text = row.text("value") else { throw FixtureFailure.nativeShape }
        return try ownedBindJSON(text)
      }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    let sequence = try c.execute(
      """
      SELECT pg_catalog.jsonb_build_object(
        'last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value
      FROM public.changes_seq_seq
      """
    ).rows
    guard sequence.count == 1, let text = sequence[0].text("value") else {
      throw FixtureFailure.nativeShape
    }
    return OwnedBindImage(database: database, rows: rows, sequence: try ownedBindJSON(text))
  }

  private static func ownedBindCatalogGuard(_ c: PostgresConnection) throws {
    let tables = try c.execute(
      """
      SELECT c.relname AS name,c.relkind::text AS kind,c.relpersistence::text AS persistence,
        pg_catalog.row_security_active(c.oid)::text AS secured
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      JOIN pg_catalog.pg_tables t ON t.schemaname=n.nspname AND t.tablename=c.relname
      WHERE n.nspname='public'
      """
    ).rows
    var names = Set<String>()
    for row in tables {
      guard let name = row.text("name"), names.insert(name).inserted,
        row.text("kind") == "r", row.text("persistence") == "p", row.text("secured") == "false"
      else { throw FixtureFailure.nativeShape }
    }
    let required: Set<String> = [
      "settings", "hubLink", "connections", "changes", "columnClocks", "schemaMigrations",
      "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
      "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
    ]
    guard required.isSubset(of: names) else { throw FixtureFailure.nativeShape }
    let shapes: [(String, [String: String], String)] = [
      ("settings", ["key": "text|true", "value": "jsonb|true"], "key"),
      (
        "hubLink",
        [
          "id": "integer|true", "url": "text|true", "deviceId": "text|true",
          "deviceName": "text|true", "tokenRef": "text|true", "orgSlug": "text|true",
          "username": "text|true", "cursor": "bigint|true", "lastPushAt": "text|false",
          "lastError": "text|false", "joinedAt": "text|true", "ownedAs": "text|false",
        ], "id"
      ),
    ]
    for (table, expected, uniqueColumn) in shapes {
      let qualified = "public." + Rows.quote(table)
      let columns = try c.execute(
        """
        SELECT a.attname AS name,pg_catalog.format_type(a.atttypid,a.atttypmod) AS kind,
          a.attnotnull::text AS required
        FROM pg_catalog.pg_attribute a WHERE a.attrelid=pg_catalog.to_regclass($1)
          AND a.attnum>0 AND NOT a.attisdropped
        """, [qualified]
      ).rows
      var actual: [String: String] = [:]
      for row in columns {
        guard let name = row.text("name"), let kind = row.text("kind"),
          let required = row.text("required"), actual[name] == nil
        else { throw FixtureFailure.nativeShape }
        actual[name] = kind + "|" + required
      }
      guard actual == expected else { throw FixtureFailure.nativeShape }
      let unique = try c.execute(
        """
        SELECT count(*) AS n FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=i.indkey[0]
        WHERE i.indrelid=pg_catalog.to_regclass($1) AND a.attname=$2
          AND i.indisunique AND i.indisvalid AND i.indisready AND i.indimmediate
          AND i.indnkeyatts=1 AND i.indpred IS NULL AND i.indexprs IS NULL
        """, [qualified, uniqueColumn]
      ).rows
      guard unique.count == 1, let count = unique[0].int("n"), count >= 1 else {
        throw FixtureFailure.nativeShape
      }
    }
    let sequence = try c.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_class c
      WHERE c.oid=pg_catalog.to_regclass('public.changes_seq_seq')
        AND c.relnamespace='public'::pg_catalog.regnamespace
        AND c.relkind='S' AND c.relpersistence='p'
      """
    ).rows
    let triggers = try c.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_trigger
      WHERE tgrelid IN ('public.settings'::pg_catalog.regclass,'public."hubLink"'::pg_catalog.regclass)
        AND NOT tgisinternal
      """
    ).rows
    guard sequence.count == 1, sequence[0].int("n") == 1,
      triggers.count == 1, triggers[0].int("n") == 0
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindFreeze(
    _ f: Fixture, predecessor: NativeControl, replacement: String
  ) throws -> OwnedBindStageFixture {
    try ownedBindCatalogGuard(f.inspector)
    let before = try ownedBindImage(f.inspector)
    let (revision, overflow) = predecessor.revision.addingReportingOverflow(1)
    guard !overflow, predecessor.object["binding"] == nil,
      predecessor.object["observation"] == nil,
      equalBytes(before.database, f.binding.databaseName),
      let settings = before.rows["settings"], let links = before.rows["hubLink"], links.count == 1
    else { throw FixtureFailure.nativeShape }
    // This positive transform is only for the independently validated inactive/unbound fixture.
    // Bound/no-op fixtures must retain their whole S0 instead of using this mutating transform.
    var expectedControl = predecessor.object
    expectedControl["revision"] = String(revision)
    expectedControl["binding"] = [
      "accountID": f.binding.accountID, "canonicalHubBase": f.binding.canonicalHubBase,
      "hubUserID": f.binding.hubUserID, "hubOrgID": f.binding.hubOrgID,
      "deviceID": f.binding.deviceID, "databaseName": f.binding.databaseName,
      "linkJoinedAt": f.binding.linkJoinedAt,
    ]
    let controlData = try JSONSerialization.data(withJSONObject: expectedControl, options: [.sortedKeys])
    var replacements = 0
    let nextSettings = try settings.map { data -> Data in
      guard var row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rowKey = row["key"] as? String
      else { throw FixtureFailure.nativeShape }
      if equalBytes(rowKey, key) {
        guard let value = row["value"] as? [String: Any],
          try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            == JSONSerialization.data(withJSONObject: predecessor.object, options: [.sortedKeys])
        else { throw FixtureFailure.nativeShape }
        replacements += 1
        row["value"] = expectedControl
      }
      return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    }.sorted { $0.lexicographicallyPrecedes($1) }
    guard replacements == 1,
      let link = try JSONSerialization.jsonObject(with: links[0]) as? [String: Any],
      let reference = link["tokenRef"] as? String, equalBytes(reference, f.link.tokenRef),
      !reference.utf8.contains(0), !replacement.utf8.contains(0)
    else { throw FixtureFailure.nativeShape }
    var nextRows = before.rows
    nextRows["settings"] = nextSettings
    let device = f.database.deviceId
    guard !device.isEmpty, !device.utf8.contains(0) else { throw FixtureFailure.nativeShape }
    return OwnedBindStageFixture(
      before: before,
      expected: OwnedBindImage(database: before.database, rows: nextRows, sequence: before.sequence),
      controlJSON: try ownedBindText(controlData), originalReference: reference,
      replacement: replacement, device: device, lowerWall: try ownedBindWall(f.inspector))
  }

  private static func ownedBindExpectedReference(
    _ stage: OwnedBindStageFixture
  ) throws -> OwnedBindImage {
    guard let links = stage.expected.rows["hubLink"], links.count == 1,
      var link = try JSONSerialization.jsonObject(with: links[0]) as? [String: Any]
    else { throw FixtureFailure.nativeShape }
    link["tokenRef"] = stage.replacement
    var rows = stage.expected.rows
    rows["hubLink"] = [try JSONSerialization.data(withJSONObject: link, options: [.sortedKeys])]
    return OwnedBindImage(database: stage.expected.database, rows: rows, sequence: stage.expected.sequence)
  }

  private static func ownedBindInstall(
    _ f: Fixture, stage: OwnedBindStageFixture, rawBodyFault: Bool
  ) throws {
    let c = f.inspector
    try c.execute(
      """
      CREATE SCHEMA "owned_bind_stage";
      CREATE TABLE "owned_bind_stage"."names"(name text PRIMARY KEY);
      CREATE TABLE "owned_bind_stage"."expected"(name text NOT NULL,value jsonb NOT NULL);
      CREATE TABLE "owned_bind_stage"."meta"(
        singleton integer PRIMARY KEY CHECK(singleton=1),database text NOT NULL,
        original_ref text NOT NULL,expected_control jsonb NOT NULL,expected_sequence jsonb NOT NULL,
        expected_device text NOT NULL,lower_wall bigint NOT NULL);
      CREATE TABLE "owned_bind_stage"."mode"(
        singleton integer PRIMARY KEY CHECK(singleton=1),replacement text NOT NULL,
        raw_body_fault boolean NOT NULL);
      CREATE SEQUENCE "owned_bind_stage"."body_probe" AS bigint START WITH 1 INCREMENT BY 1 CACHE 1 NO CYCLE;
      CREATE SEQUENCE "owned_bind_stage"."commit_probe" AS bigint START WITH 1 INCREMENT BY 1 CACHE 1 NO CYCLE;
      CREATE TABLE "owned_bind_stage"."observed"(
        isolation text NOT NULL,lock_budget text NOT NULL,statement_budget text NOT NULL,
        hlc text NOT NULL,device text);
      """)
    for name in stage.expected.rows.keys.sorted() {
      guard
        try c.execute(
          "INSERT INTO \"owned_bind_stage\".\"names\"(name) VALUES($1)", [name]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
      for value in stage.expected.rows[name]! {
        guard
          try c.execute(
            "INSERT INTO \"owned_bind_stage\".\"expected\"(name,value) VALUES($1,$2::jsonb)",
            [name, try ownedBindText(value)]
          ).affected == 1
        else { throw FixtureFailure.nativeShape }
      }
    }
    guard
      try c.execute(
        """
        INSERT INTO "owned_bind_stage"."meta"
          (singleton,database,original_ref,expected_control,expected_sequence,expected_device,lower_wall)
        VALUES(1,$1,$2,$3::jsonb,$4::jsonb,$5,$6::bigint)
        """,
        [
          stage.before.database, stage.originalReference, stage.controlJSON,
          try ownedBindText(stage.before.sequence), stage.device, String(stage.lowerWall),
        ]
      ).affected == 1,
      try c.execute(
        """
        INSERT INTO "owned_bind_stage"."mode"(singleton,replacement,raw_body_fault)
        VALUES(1,$1,$2::boolean)
        """, [stage.replacement, rawBodyFault ? "true" : "false"]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    try c.execute(
      """
      CREATE FUNCTION "owned_bind_stage"."assert_complete"(required_reference text)
      RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE t text; mismatch boolean;
      BEGIN
        IF required_reference IS NULL
          OR (SELECT count(*) FROM "owned_bind_stage"."meta")<>1
          OR (SELECT count(*) FROM "owned_bind_stage"."mode")<>1
          OR convert_to(current_database(),'UTF8') IS DISTINCT FROM
            (SELECT convert_to(database,'UTF8') FROM "owned_bind_stage"."meta" WHERE singleton=1)
          OR (SELECT count(*) FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1')<>1
          OR (SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1')
            IS DISTINCT FROM
            (SELECT expected_control FROM "owned_bind_stage"."meta" WHERE singleton=1)
          OR (SELECT count(*) FROM public."hubLink")<>1
          OR (SELECT count(*) FROM public."hubLink" WHERE id=1)<>1
          OR (SELECT convert_to("tokenRef",'UTF8') FROM public."hubLink" WHERE id=1)
            IS DISTINCT FROM convert_to(required_reference,'UTF8')
        THEN RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001'; END IF;
        IF EXISTS((SELECT tablename::text FROM pg_catalog.pg_tables WHERE schemaname='public')
            EXCEPT SELECT name FROM "owned_bind_stage"."names")
          OR EXISTS((SELECT name FROM "owned_bind_stage"."names")
            EXCEPT SELECT tablename::text FROM pg_catalog.pg_tables WHERE schemaname='public')
        THEN RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001'; END IF;
        FOR t IN SELECT name FROM "owned_bind_stage"."names" LOOP
          IF t='hubLink' THEN
            EXECUTE format(
              'SELECT EXISTS((SELECT to_jsonb(p) FROM public.%I p) EXCEPT ALL '
              '(SELECT value||jsonb_build_object(''tokenRef'',$2::text) '
              'FROM "owned_bind_stage"."expected" WHERE name=$1)) '
              'OR EXISTS((SELECT value||jsonb_build_object(''tokenRef'',$2::text) '
              'FROM "owned_bind_stage"."expected" WHERE name=$1) EXCEPT ALL '
              '(SELECT to_jsonb(p) FROM public.%I p))',t,t)
              INTO mismatch USING t,required_reference;
          ELSE
            EXECUTE format(
              'SELECT EXISTS((SELECT to_jsonb(p) FROM public.%I p) EXCEPT ALL '
              '(SELECT value FROM "owned_bind_stage"."expected" WHERE name=$1)) '
              'OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=$1) '
              'EXCEPT ALL (SELECT to_jsonb(p) FROM public.%I p))',t,t)
              INTO mismatch USING t;
          END IF;
          IF mismatch THEN
            RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001';
          END IF;
        END LOOP;
        IF (SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)
            FROM public.changes_seq_seq) IS DISTINCT FROM
            (SELECT expected_sequence FROM "owned_bind_stage"."meta" WHERE singleton=1)
        THEN RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001'; END IF;
      END $$;
      CREATE FUNCTION "owned_bind_stage"."assert_transaction"()
      RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE isolation_value text; lock_value text; statement_value text;
        stamp_value text; device_value text; wanted_device text;
      BEGIN
        isolation_value := current_setting('transaction_isolation');
        lock_value := current_setting('lock_timeout');
        statement_value := current_setting('statement_timeout');
        stamp_value := current_setting('b4app.hlc',true);
        device_value := current_setting('b4app.device_id',true);
        SELECT expected_device INTO STRICT wanted_device FROM "owned_bind_stage"."meta" WHERE singleton=1;
        IF isolation_value IS DISTINCT FROM 'read committed' OR lock_value IS DISTINCT FROM '2s'
          OR statement_value IS DISTINCT FROM '2s' OR stamp_value IS NULL
          OR stamp_value !~ '^[0-9a-f]{12}-[0-9a-f]{4}-.+$'
          OR convert_to(substring(stamp_value FROM 19),'UTF8')
            IS DISTINCT FROM convert_to(wanted_device,'UTF8')
          OR (wanted_device='local' AND coalesce(device_value,'')<>'')
          OR (wanted_device<>'local' AND convert_to(device_value,'UTF8')
            IS DISTINCT FROM convert_to(wanted_device,'UTF8'))
          OR (SELECT count(*) FROM "owned_bind_stage"."observed")<>0
        THEN RAISE EXCEPTION 'OWNED_BIND_TRANSACTION_MISMATCH' USING ERRCODE='P0001'; END IF;
        INSERT INTO "owned_bind_stage"."observed"(isolation,lock_budget,statement_budget,hlc,device)
          VALUES(isolation_value,lock_value,statement_value,stamp_value,device_value);
      END $$;
      CREATE FUNCTION "owned_bind_stage"."body"() RETURNS trigger
      LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE original text; replacement text; fault boolean; changed bigint;
      BEGIN
        SELECT original_ref INTO STRICT original FROM "owned_bind_stage"."meta" WHERE singleton=1;
        PERFORM "owned_bind_stage"."assert_complete"(original);
        PERFORM "owned_bind_stage"."assert_transaction"();
        SELECT m.replacement,m.raw_body_fault INTO STRICT replacement,fault
          FROM "owned_bind_stage"."mode" m WHERE singleton=1;
        UPDATE public."hubLink" SET "tokenRef"=replacement WHERE id=1;
        GET DIAGNOSTICS changed=ROW_COUNT;
        IF changed<>1 THEN
          RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001';
        END IF;
        PERFORM "owned_bind_stage"."assert_complete"(replacement);
        PERFORM nextval('"owned_bind_stage"."body_probe"'::regclass);
        IF fault THEN
          RAISE EXCEPTION 'OWNED_BIND_RAW_BODY_FAULT' USING ERRCODE='23514';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER "owned_bind_body" AFTER UPDATE ON public.settings FOR EACH ROW
        WHEN(NEW.key='__b4app_agent_protocol_activation_v1')
        EXECUTE FUNCTION "owned_bind_stage"."body"();
      CREATE FUNCTION "owned_bind_stage"."commit_normal"() RETURNS trigger
      LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE replacement text;
      BEGIN
        SELECT m.replacement INTO STRICT replacement FROM "owned_bind_stage"."mode" m WHERE singleton=1;
        PERFORM "owned_bind_stage"."assert_complete"(replacement);
        PERFORM nextval('"owned_bind_stage"."commit_probe"'::regclass);
        RETURN NEW;
      END $$;
      CREATE CONSTRAINT TRIGGER "owned_bind_commit_normal" AFTER UPDATE ON public.settings
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
        WHEN(NEW.key='__b4app_agent_protocol_activation_v1')
        EXECUTE FUNCTION "owned_bind_stage"."commit_normal"();
      """)
    let triggers = try c.execute(
      """
      SELECT t.tgname AS name,t.tgtype::text AS kind,t.tgenabled::text AS enabled,
        t.tgdeferrable::text AS deferrable,t.tginitdeferred::text AS deferred,
        p.proname AS function,n.nspname AS schema
      FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
      JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      WHERE t.tgrelid='public.settings'::pg_catalog.regclass AND NOT t.tgisinternal
      """
    ).rows
    guard triggers.count == 2 else { throw FixtureFailure.nativeShape }
    for row in triggers {
      let commit = row.text("name") == "owned_bind_commit_normal"
      guard commit || row.text("name") == "owned_bind_body",
        row.text("kind") == "17", row.text("enabled") == "O",
        row.text("schema") == "owned_bind_stage",
        row.text("function") == (commit ? "commit_normal" : "body"),
        row.text("deferrable") == (commit ? "true" : "false"),
        row.text("deferred") == (commit ? "true" : "false")
      else { throw FixtureFailure.nativeShape }
    }
    guard try ownedBindImage(c) == stage.before else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindProbe(
    _ c: PostgresConnection, _ name: String
  ) throws -> OwnedBindProbe {
    // Callers supply only the two private, fixed probe names; every identifier remains quoted.
    guard name == "body_probe" || name == "commit_probe" else { throw FixtureFailure.nativeShape }
    let rows = try c.execute(
      "SELECT last_value::text AS last,is_called::text AS called FROM \"owned_bind_stage\".\(Rows.quote(name))"
    ).rows
    guard rows.count == 1, let text = rows[0].text("last"), let last = Int64(text), last >= 1,
      let called = rows[0].text("called"), called == "true" || called == "false"
    else { throw FixtureFailure.nativeShape }
    return OwnedBindProbe(last: last, called: called == "true")
  }

  private static func ownedBindObserved(
    _ c: PostgresConnection, stage: OwnedBindStageFixture, authoredHLC: HLC
  ) throws -> Bool {
    let rows = try c.execute(
      "SELECT isolation,lock_budget,statement_budget,hlc,device FROM \"owned_bind_stage\".\"observed\""
    ).rows
    guard rows.count == 1, let row = rows.first, let text = row.text("hlc"),
      let native = HLC(rawValue: text), equalBytes(native.rawValue, text),
      equalBytes(native.rawValue, authoredHLC.rawValue), equalBytes(native.deviceId, stage.device),
      native.millis >= stage.lowerWall, native.millis <= (try ownedBindWall(c)),
      row.text("isolation") == "read committed", row.text("lock_budget") == "2s",
      row.text("statement_budget") == "2s"
    else { throw FixtureFailure.nativeShape }
    if equalBytes(stage.device, "local") {
      guard row.text("device") == nil || row.text("device") == "" else {
        throw FixtureFailure.nativeShape
      }
    } else {
      guard let device = row.text("device"), equalBytes(device, stage.device) else {
        throw FixtureFailure.nativeShape
      }
    }
    return true
  }

  private static func ownedBindRawDriver(
    _ f: Fixture, stage: OwnedBindStageFixture, row: OwnedBindRawControl
  ) throws -> OwnedBindRawFacts {
    do {
      let endpoint = f.database.endpoint
      // This connection never enters a pool, field, closure result, or returned facts.
      let ownedPostgresConnection = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      let c = ownedPostgresConnection
      let bodyBefore = try ownedBindProbe(c, "body_probe")
      let commitBefore = try ownedBindProbe(c, "commit_probe")
      guard bodyBefore == OwnedBindProbe(last: 1, called: false),
        commitBefore == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      var began = false
      var rollbackSent = false
      var commitSent = false
      var commitAcknowledged = false
      var rollbackAcknowledged = false
      var dmlReturned = false
      var predicateRejected = false
      var bodyFaultRejected = false
      var ownImageValidated = false
      var settingsValidated = false
      // Unexpected pre-COMMIT errors earn no evidence; best-effort cleanup is not an ACK fact.
      // Once COMMIT is sent, any unexpected error closes this lexical connection without
      // manufacturing rollback/noncommit/unknown settlement evidence.
      defer {
        if began && !commitSent && !rollbackSent {
          _ = try? c.execute("ROLLBACK")
        }
      }
      try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
      began = true
      try c.execute("SET LOCAL lock_timeout='2s'")
      try c.execute("SET LOCAL statement_timeout='2s'")
      try c.execute(
        "SELECT pg_catalog.pg_advisory_xact_lock($1::bigint)",
        [String(WorkspaceDatabase.remoteApplyLockKey)])
      // Independent native sample, not database.clock.next() or an owned writer output.
      let authoredHLC = HLC(millis: try ownedBindWall(c), counter: 0, deviceId: stage.device)
      guard HLC(rawValue: authoredHLC.rawValue) != nil else { throw FixtureFailure.nativeShape }
      try c.execute("SELECT pg_catalog.set_config('b4app.hlc',$1,true)", [authoredHLC.rawValue])
      if !equalBytes(stage.device, "local") {
        try c.execute("SELECT pg_catalog.set_config('b4app.device_id',$1,true)", [stage.device])
      }
      do {
        let result = try c.execute(ownedBindRawUpsert, [key, stage.controlJSON])
        guard result.affected == 1 else { throw FixtureFailure.nativeShape }
        dmlReturned = true
      } catch let error as PostgresError {
        // libpq currently exposes SQLSTATE + full rendered message + originating SQL only.
        // Match the ENTIRE first diagnostic line and exact originating DML, never contains().
        let firstLine = error.message.components(separatedBy: "\n").first
        predicateRejected =
          row == .imageReject && error.sqlState == "P0001"
          && firstLine == "ERROR:  OWNED_BIND_COMPLETE_MISMATCH"
          && equalBytes(error.sql, ownedBindRawUpsert)
        bodyFaultRejected =
          row == .bodyFault && error.sqlState == "23514"
          && firstLine == "ERROR:  OWNED_BIND_RAW_BODY_FAULT"
          && equalBytes(error.sql, ownedBindRawUpsert)
        guard predicateRejected || bodyFaultRejected else { throw FixtureFailure.redactedFailure }
      }
      let expectedAfter = try ownedBindExpectedReference(stage)
      if row == .imageReject || row == .bodyFault {
        guard !dmlReturned, predicateRejected == (row == .imageReject),
          bodyFaultRejected == (row == .bodyFault)
        else { throw FixtureFailure.nativeShape }
        rollbackSent = true
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        let observed = try c.execute("SELECT count(*) AS n FROM \"owned_bind_stage\".\"observed\"").rows
        guard observed.count == 1, observed[0].int("n") == 0 else { throw FixtureFailure.nativeShape }
      } else {
        guard dmlReturned else { throw FixtureFailure.nativeShape }
        try c.execute(
          "SELECT \"owned_bind_stage\".\"assert_complete\"($1)", [stage.replacement])
        ownImageValidated = try ownedBindImage(c) == expectedAfter
        settingsValidated = try ownedBindObserved(c, stage: stage, authoredHLC: authoredHLC)
        guard ownImageValidated, settingsValidated,
          try ownedBindProbe(c, "body_probe").advanced(from: bodyBefore, by: 1),
          try ownedBindProbe(c, "commit_probe").advanced(from: commitBefore, by: 0)
        else { throw FixtureFailure.nativeShape }
        commitSent = true
        try c.execute("COMMIT")
        commitAcknowledged = true
        guard try ownedBindObserved(f.inspector, stage: stage, authoredHLC: authoredHLC) else {
          throw FixtureFailure.nativeShape
        }
      }
      let bodyCount: Int64 = row == .imageReject ? 0 : 1
      let commitCount: Int64 = commitAcknowledged ? 1 : 0
      guard try ownedBindProbe(f.inspector, "body_probe").advanced(from: bodyBefore, by: bodyCount),
        try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commitBefore, by: commitCount)
      else { throw FixtureFailure.nativeShape }
      let durable = try ownedBindImage(f.inspector)
      let facts = OwnedBindRawFacts(
        row: row.rawValue, dmlReturned: dmlReturned, commitSent: commitSent,
        commitAcknowledged: commitAcknowledged, rollbackAcknowledged: rollbackAcknowledged,
        predicateRejected: predicateRejected, bodyFaultRejected: bodyFaultRejected,
        ownImageValidated: ownImageValidated,
        durableImageValidated: durable == (commitAcknowledged ? expectedAfter : stage.before),
        settingsValidated: settingsValidated, bodyAllocations: bodyCount, commitAllocations: commitCount)
      guard facts.qualified else { throw FixtureFailure.nativeShape }
      return facts
    } catch {
      // No arbitrary native error or private image/reference leaves this lexical driver.
      throw FixtureFailure.redactedFailure
    }
  }

  private static func ownedBindRawStageControls() throws -> [OwnedBindRawFacts] {
    var results: [OwnedBindRawFacts] = []
    var databases = Set<Data>()
    for row in OwnedBindRawControl.allCases {
      var observed: OwnedBindRawFacts?
      try withFixture { f in
        let predecessor = try validateFixture(f)
        let replacement = row == .normalB ? "secret:OWNED_BIND_RAW_REFERENCE_B" : f.link.tokenRef
        let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: replacement)
        guard databases.insert(Data(stage.before.database.utf8)).inserted else {
          throw FixtureFailure.nativeShape
        }
        // Every row gets a distinct endpoint/database, independently captured native S0, exact
        // checked S1, and the identical two enabled UPDATE-only functions/triggers.
        try ownedBindInstall(f, stage: stage, rawBodyFault: row == .bodyFault)
        if row == .imageReject {
          guard
            try f.inspector.execute(
              """
              UPDATE "owned_bind_stage"."expected"
              SET value=pg_catalog.jsonb_set(value,'{value}',
                pg_catalog.to_jsonb('OWNED_BIND_PRIVATE_IMAGE_CORRUPTION'::text))
              WHERE name='settings' AND value->>'key'=$1
              """, [sentinelKey]
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        }
        guard try ownedBindImage(f.inspector) == stage.before else { throw FixtureFailure.nativeShape }
        observed = try ownedBindRawDriver(f, stage: stage, row: row)
      }
      // withFixture has closed its database and relinquished its inspector/physical root first.
      guard let observed, observed.qualified else { throw FixtureFailure.nativeShape }
      results.append(observed)
    }
    guard results.count == 4 else { throw FixtureFailure.nativeShape }
    return results
  }

  @Test func ownedBindRawStageFixtureValidation() throws {
    let rows = try Self.ownedBindRawStageControls()
    #expect(rows.count == 4)
    for row in rows {
      #expect(row.qualified)
      #expect(row.durableImageValidated)
      #expect(row.bodyAllocations == (row.row == 0 ? 0 : 1))
      #expect(row.commitAllocations == (row.commitAcknowledged ? 1 : 0))
      if row.row == 1 || row.row == 3 {
        #expect(row.dmlReturned && row.ownImageValidated && row.settingsValidated)
        #expect(row.commitSent && row.commitAcknowledged && !row.rollbackAcknowledged)
      } else {
        #expect(!row.dmlReturned && !row.commitSent && row.rollbackAcknowledged)
        #expect(row.predicateRejected == (row.row == 0))
        #expect(row.bodyFaultRejected == (row.row == 2))
      }
    }
  }
}
