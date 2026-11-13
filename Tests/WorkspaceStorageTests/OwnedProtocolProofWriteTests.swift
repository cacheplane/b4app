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
