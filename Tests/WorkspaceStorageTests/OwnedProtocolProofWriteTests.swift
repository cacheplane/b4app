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

  private enum OwnedRawDriverFamily: String, Sendable { case bind, positive, fence }

  private enum OwnedRawDriverPhase: String {
    case connect
    case bodyProbeBefore
    case commitProbeBefore
    case initialProbeGuard
    case begin
    case lockBudget
    case statementBudget
    case advisoryLock
    case wallSample
    case hlcShapeGuard
    case setHLC
    case setDevice
    case upsert
    case unexpectedUpsertError
    case expectedReference
    case refusalShapeGuard
    case rollback
    case rollbackObservedRead
    case rollbackObservedGuard
    case dmlReturnedGuard
    case assertComplete
    case ownImage
    case settingsBeforeCommit
    case beforeCommitProbeGuard
    case commit
    case settingsAfterCommitGuard
    case finalProbeGuard
    case durableImage
    case finalFactsGuard
  }

  private enum OwnedRawDriverCategory: String {
    case postgresError, nativeShape, redactedFailure, otherError
  }

  private enum OwnedRawDriverSQLState: String {
    case none, unlisted
    case code08003 = "08003"
    case code08006 = "08006"
    case code22023 = "22023"
    case code22P02 = "22P02"
    case code23502 = "23502"
    case code23503 = "23503"
    case code23505 = "23505"
    case code23514 = "23514"
    case code25P02 = "25P02"
    case code40001 = "40001"
    case code40P01 = "40P01"
    case code53100 = "53100"
    case code53200 = "53200"
    case code53300 = "53300"
    case code53400 = "53400"
    case code55P03 = "55P03"
    case code57014 = "57014"
    case code57P01 = "57P01"
    case code58030 = "58030"
    case code58P01 = "58P01"
    case codeP0001 = "P0001"

    static func classify(_ code: String) -> Self {
      guard let state = Self(rawValue: code), state != .none else { return .unlisted }
      return state
    }
  }

  private enum OwnedRawDriverNativeReason: String {
    case none, statementTimeout, userRequest, lockTimeout, unlisted

    static func classify(_ error: PostgresError) -> Self {
      let firstLine = error.message.components(separatedBy: "\n").first
      if error.sqlState == "57014" {
        if firstLine == "ERROR:  canceling statement due to statement timeout" {
          return .statementTimeout
        }
        if firstLine == "ERROR:  canceling statement due to user request" {
          return .userRequest
        }
      } else if error.sqlState == "55P03",
        firstLine == "ERROR:  canceling statement due to lock timeout"
      {
        return .lockTimeout
      }
      return .unlisted
    }
  }

  private enum OwnedRawDriverElapsedMicroseconds {
    case none, overflow
    case value(Int64)

    static func classify(_ elapsed: Duration?) -> Self {
      guard let elapsed else { return .none }
      let components = elapsed.components
      guard components.seconds >= 0, components.attoseconds >= 0 else { return .none }
      let (whole, multiplyOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000)
      guard !multiplyOverflow else { return .overflow }
      let fraction = components.attoseconds / 1_000_000_000_000
      let (microseconds, addOverflow) = whole.addingReportingOverflow(fraction)
      guard !addOverflow else { return .overflow }
      return .value(microseconds)
    }

    var fieldValue: String {
      switch self {
      case .none: return "none"
      case .overflow: return "overflow"
      case .value(let microseconds): return String(microseconds)
      }
    }
  }

  /// Only an exact final rendered frame is observed. Earlier SQL is transient and untrusted.
  /// Fabricated whole messages cannot be authenticated here; this proves no CPU or lock cause.
  private struct OwnedRawDriverRenderedContext: Sendable {
    enum State: String, Sendable { case absent, known, unlisted }
    enum Function: String, Sendable {
      case none, unlisted, assertComplete, assertTransaction, body, commitNormal
    }
    enum Site: String, Sendable { case none, execute, perform, sqlStatement, other }

    let state: State
    let function: Function
    let line: Int?
    let site: Site

    static let absent = Self(state: .absent, function: .none, line: nil, site: .none)
    private static let unlisted = Self(
      state: .unlisted, function: .unlisted, line: nil, site: .none)

    static func classify(_ rendered: String) -> Self {
      let lines = rendered.components(separatedBy: "\n")
      let labels = lines.indices.filter { lines[$0].hasPrefix("CONTEXT:") }
      guard !labels.isEmpty else { return .absent }
      guard labels.count == 1, let label = labels.first,
        lines[label].hasPrefix("CONTEXT:  "),
        let tailIndex = lines.lastIndex(where: { !$0.isEmpty }), tailIndex >= label
      else { return .unlisted }
      // Never scan backward for a more convenient frame. Multiline SQL may contain fake frames.
      let tail =
        tailIndex == label ? String(lines[tailIndex].dropFirst("CONTEXT:  ".count)) : lines[tailIndex]
      let prefix = "PL/pgSQL function owned_bind_stage."
      guard tail.hasPrefix(prefix) else { return .unlisted }
      let parts = String(tail.dropFirst(prefix.count)).components(separatedBy: " line ")
      guard parts.count == 2 else { return .unlisted }
      let function: Function
      switch parts[0] {
      case "assert_complete(text)": function = .assertComplete
      case "assert_transaction()": function = .assertTransaction
      case "body()": function = .body
      case "commit_normal()": function = .commitNormal
      default: return .unlisted
      }
      let location = parts[1].components(separatedBy: " at ")
      guard location.count == 2 else { return .unlisted }
      let number = location[0]
      guard !number.isEmpty, number.utf8.count <= 3, number.first != "0",
        number.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let line = Int(number), (1...512).contains(line)
      else { return .unlisted }
      let site: Site
      switch location[1] {
      case "EXECUTE": site = .execute
      case "PERFORM": site = .perform
      case "SQL statement": site = .sqlStatement
      case "RAISE", "assignment", "IF", "RETURN", "FOR over SELECT rows": site = .other
      default: return .unlisted
      }
      return Self(state: .known, function: function, line: line, site: site)
    }

    var lineField: String { line.map { String($0) } ?? "none" }
  }

  /// No arbitrary native error, message, SQL, image, reference, or fixture is retained here.
  private struct OwnedRawDriverDiagnostic: Error {
    let row: OwnedBindRawControl
    let family: OwnedRawDriverFamily
    let phase: OwnedRawDriverPhase
    let category: OwnedRawDriverCategory
    let sqlState: OwnedRawDriverSQLState
    let nativeReason: OwnedRawDriverNativeReason
    let elapsedMicroseconds: OwnedRawDriverElapsedMicroseconds
    let queue: NativeDBCaseQueueSnapshot
    let context: OwnedRawDriverRenderedContext

    init(
      row: OwnedBindRawControl, family: OwnedRawDriverFamily, phase: OwnedRawDriverPhase,
      error: any Error,
      elapsed: Duration? = nil
    ) {
      self.row = row
      self.family = family
      self.phase = phase
      elapsedMicroseconds = OwnedRawDriverElapsedMicroseconds.classify(elapsed)
      // Capture primitives now; the diagnostic never retains the TaskLocal executor or resources.
      queue = NativeDBCaseExecutorScope.current?.snapshot() ?? .unavailable
      if let postgres = error as? PostgresError {
        category = .postgresError
        sqlState = OwnedRawDriverSQLState.classify(postgres.sqlState)
        nativeReason = OwnedRawDriverNativeReason.classify(postgres)
        context = OwnedRawDriverRenderedContext.classify(postgres.message)
      } else {
        context = .absent
        sqlState = .none
        nativeReason = .none
        switch error as? FixtureFailure {
        case .nativeShape?: category = .nativeShape
        case .redactedFailure?: category = .redactedFailure
        case nil: category = .otherError
        }
      }
    }
  }

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
    } catch let diagnostic as OwnedRawDriverDiagnostic {
      // Native fixture close and physical-root unwind have completed before this bounded record.
      print(
        "OWNED_RAW_DRIVER_DIAGNOSTIC_V1 row=\(diagnostic.row.rawValue) phase=\(diagnostic.phase.rawValue) category=\(diagnostic.category.rawValue) sqlstate=\(diagnostic.sqlState.rawValue)"
      )
      Issue.record(
        Comment(
          rawValue: """
            OWNED_RAW_DRIVER_DETAIL_V1 row=\(diagnostic.row.rawValue) \
            phase=\(diagnostic.phase.rawValue) \
            category=\(diagnostic.category.rawValue) \
            sqlstate=\(diagnostic.sqlState.rawValue) \
            reason=\(diagnostic.nativeReason.rawValue) \
            elapsedMicroseconds=\(diagnostic.elapsedMicroseconds.fieldValue)
            OWNED_RAW_DRIVER_CONTEXT_V1 family=\(diagnostic.family.rawValue) \
            contextState=\(diagnostic.context.state.rawValue) framePosition=renderedTail \
            renderedOnly=true structuredFieldAuthenticated=false causality=unqualified \
            function=\(diagnostic.context.function.rawValue) \
            line=\(diagnostic.context.lineField) site=\(diagnostic.context.site.rawValue)
            OWNED_RAW_DRIVER_QUEUE_V1 family=\(diagnostic.family.rawValue) \
            casePreferenceQueue=\(diagnostic.queue.availability.rawValue) partial=true \
            enqueueCount=\(diagnostic.queue.enqueueCountField) \
            enqueueCountOverflow=\(diagnostic.queue.enqueueOverflowField) \
            firstObservedWaitMicroseconds=\(diagnostic.queue.firstWait.fieldValue) \
            maxObservedWaitMicroseconds=\(diagnostic.queue.maxWait.fieldValue)
            """))
      throw FixtureFailure.redactedFailure
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

  @Test(NativeDBResources()) func independentlyValidatedLinkedModernInactiveFixture() throws {
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
    }
  }

  @Test(NativeDBResources()) func ownedBindCommitsExactSuccessorFromModernInactiveAnchor() throws {
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

  @Test(NativeDBResources()) func ownedProofFreshCheckoutNeverReturnsFreshToIdle() throws {
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

  @Test(NativeDBResources()) func ownedProofClosedBeforeAdmissionDoesNotWaitOrRunBody() throws {
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

  @Test(NativeDBResources()) func ownedProofTimesOutAtActualFiveSecondSlotDeadlineWithoutExtraLease() throws {
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

  @Test(NativeDBResources()) func ownedProofQueuedAdmissionRefusesAfterConcurrentClose() throws {
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

  @Test(NativeDBResources()) func ownedProofBodyKeepsLogicalLeaseAndSlotThroughWork() throws {
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

  @Test(NativeDBResources()) func ownedProofFreshConstructorRefusalReleasesLeaseAndSlotWithoutBody() throws {
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

  @Test(NativeDBResources()) func ownedProofDoesNotReuseLiveOrdinaryIdleProbeWhenFreshConnectMustFail() throws
  {
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
  @Test(NativeDBResources()) func ownedBindEqualBindingNoopRequiresActualCommitReceipt() throws {
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

  @Test(NativeDBResources()) func ownedBindLegacyOnlyStoreCommitsWithoutHealthyProtocolTwoObservation() throws
  {
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

  @Test(NativeDBResources())
  func ownedBindCurrentReceiptRequiresOriginalAnchorReferenceAdmissionAndFreshMemory() throws {
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
          ELSIF convert_to(t,'UTF8')=convert_to('appFolders','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."appFolders" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."appFolders" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('changes','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."changes" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."changes" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('columnClocks','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."columnClocks" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."columnClocks" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('connectionUsage','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."connectionUsage" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."connectionUsage" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('connections','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."connections" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."connections" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('devices','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."devices" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."devices" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('displayItems','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."displayItems" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."displayItems" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('drafts','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."drafts" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."drafts" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('localServers','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."localServers" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."localServers" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('projectFolders','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."projectFolders" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."projectFolders" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('projects','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."projects" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."projects" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolGrantSecrets','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolGrants','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrants" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrants" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolHistoryAnchors','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolOperations','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolOperations" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolOperations" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolPromptAnswers','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolRunSegments','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolRunSegments" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolRunSegments" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolSubscriptions','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolSubscriptions" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolSubscriptions" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('runtimeRequests','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."runtimeRequests" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."runtimeRequests" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('schemaMigrations','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."schemaMigrations" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."schemaMigrations" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('settings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."settings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."settings" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('threadDeletes','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."threadDeletes" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."threadDeletes" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('threads','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."threads" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."threads" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('tokenUsage','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."tokenUsage" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."tokenUsage" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('turns','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."turns" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."turns" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('usageReadings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."usageReadings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."usageReadings" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('viewSettings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."viewSettings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."viewSettings" p))
              INTO mismatch;
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
    _ f: Fixture, stage: OwnedBindStageFixture, row: OwnedBindRawControl,
    family: OwnedRawDriverFamily
  ) throws -> OwnedBindRawFacts {
    var phase = OwnedRawDriverPhase.connect
    do {
      let endpoint = f.database.endpoint
      // This connection never enters a pool, field, closure result, or returned facts.
      phase = .connect
      let ownedPostgresConnection = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      let c = ownedPostgresConnection
      phase = .bodyProbeBefore
      let bodyBefore = try ownedBindProbe(c, "body_probe")
      phase = .commitProbeBefore
      let commitBefore = try ownedBindProbe(c, "commit_probe")
      phase = .initialProbeGuard
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
      phase = .begin
      try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
      began = true
      phase = .lockBudget
      try c.execute("SET LOCAL lock_timeout='2s'")
      phase = .statementBudget
      try c.execute("SET LOCAL statement_timeout='2s'")
      phase = .advisoryLock
      try c.execute(
        "SELECT pg_catalog.pg_advisory_xact_lock($1::bigint)",
        [String(WorkspaceDatabase.remoteApplyLockKey)])
      // Independent native sample, not database.clock.next() or an owned writer output.
      phase = .wallSample
      let authoredHLC = HLC(millis: try ownedBindWall(c), counter: 0, deviceId: stage.device)
      phase = .hlcShapeGuard
      guard HLC(rawValue: authoredHLC.rawValue) != nil else { throw FixtureFailure.nativeShape }
      phase = .setHLC
      try c.execute("SELECT pg_catalog.set_config('b4app.hlc',$1,true)", [authoredHLC.rawValue])
      if !equalBytes(stage.device, "local") {
        phase = .setDevice
        try c.execute("SELECT pg_catalog.set_config('b4app.device_id',$1,true)", [stage.device])
      }
      phase = .upsert
      let upsertStarted = ContinuousClock.now
      do {
        let result = try c.execute(ownedBindRawUpsert, [key, stage.controlJSON])
        guard result.affected == 1 else { throw FixtureFailure.nativeShape }
        dmlReturned = true
      } catch let error as PostgresError {
        let upsertElapsed = upsertStarted.duration(to: ContinuousClock.now)
        phase = .unexpectedUpsertError
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
        guard predicateRejected || bodyFaultRejected else {
          throw OwnedRawDriverDiagnostic(
            row: row, family: family, phase: .unexpectedUpsertError, error: error,
            elapsed: upsertElapsed)
        }
      }
      phase = .expectedReference
      let expectedAfter = try ownedBindExpectedReference(stage)
      if row == .imageReject || row == .bodyFault {
        phase = .refusalShapeGuard
        guard !dmlReturned, predicateRejected == (row == .imageReject),
          bodyFaultRejected == (row == .bodyFault)
        else { throw FixtureFailure.nativeShape }
        rollbackSent = true
        phase = .rollback
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        phase = .rollbackObservedRead
        let observed = try c.execute("SELECT count(*) AS n FROM \"owned_bind_stage\".\"observed\"").rows
        phase = .rollbackObservedGuard
        guard observed.count == 1, observed[0].int("n") == 0 else { throw FixtureFailure.nativeShape }
      } else {
        phase = .dmlReturnedGuard
        guard dmlReturned else { throw FixtureFailure.nativeShape }
        phase = .assertComplete
        try c.execute(
          "SELECT \"owned_bind_stage\".\"assert_complete\"($1)", [stage.replacement])
        phase = .ownImage
        ownImageValidated = try ownedBindImage(c) == expectedAfter
        phase = .settingsBeforeCommit
        settingsValidated = try ownedBindObserved(c, stage: stage, authoredHLC: authoredHLC)
        phase = .beforeCommitProbeGuard
        guard ownImageValidated, settingsValidated,
          try ownedBindProbe(c, "body_probe").advanced(from: bodyBefore, by: 1),
          try ownedBindProbe(c, "commit_probe").advanced(from: commitBefore, by: 0)
        else { throw FixtureFailure.nativeShape }
        commitSent = true
        phase = .commit
        try c.execute("COMMIT")
        commitAcknowledged = true
        phase = .settingsAfterCommitGuard
        guard try ownedBindObserved(f.inspector, stage: stage, authoredHLC: authoredHLC) else {
          throw FixtureFailure.nativeShape
        }
      }
      let bodyCount: Int64 = row == .imageReject ? 0 : 1
      let commitCount: Int64 = commitAcknowledged ? 1 : 0
      phase = .finalProbeGuard
      guard try ownedBindProbe(f.inspector, "body_probe").advanced(from: bodyBefore, by: bodyCount),
        try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commitBefore, by: commitCount)
      else { throw FixtureFailure.nativeShape }
      phase = .durableImage
      let durable = try ownedBindImage(f.inspector)
      let facts = OwnedBindRawFacts(
        row: row.rawValue, dmlReturned: dmlReturned, commitSent: commitSent,
        commitAcknowledged: commitAcknowledged, rollbackAcknowledged: rollbackAcknowledged,
        predicateRejected: predicateRejected, bodyFaultRejected: bodyFaultRejected,
        ownImageValidated: ownImageValidated,
        durableImageValidated: durable == (commitAcknowledged ? expectedAfter : stage.before),
        settingsValidated: settingsValidated, bodyAllocations: bodyCount, commitAllocations: commitCount)
      phase = .finalFactsGuard
      guard facts.qualified else { throw FixtureFailure.nativeShape }
      return facts
    } catch let diagnostic as OwnedRawDriverDiagnostic {
      throw diagnostic
    } catch {
      // Only closed primitive categories leave this lexical driver, after normal rollback cleanup.
      throw OwnedRawDriverDiagnostic(row: row, family: family, phase: phase, error: error)
    }
  }

  private static func ownedBindRawStageControls(
    diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> [OwnedBindRawFacts] {
    var results: [OwnedBindRawFacts] = []
    var databases = Set<Data>()
    for row in OwnedBindRawControl.allCases {
      diagnostic?.selectRawRow(row)
      diagnostic?.phase = .rawFixture
      var observed: OwnedBindRawFacts?
      try withFixture { f in
        diagnostic?.phase = .rawValidate
        let predecessor = try validateFixture(f)
        let replacement = row == .normalB ? "secret:OWNED_BIND_RAW_REFERENCE_B" : f.link.tokenRef
        diagnostic?.phase = .rawFreeze
        let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: replacement)
        guard databases.insert(Data(stage.before.database.utf8)).inserted else {
          throw FixtureFailure.nativeShape
        }
        // Every row gets a distinct endpoint/database, independently captured native S0, exact
        // checked S1, and the identical two enabled UPDATE-only functions/triggers.
        diagnostic?.phase = .rawInstall
        try ownedBindInstall(f, stage: stage, rawBodyFault: row == .bodyFault)
        diagnostic?.phase = .rawExpectedDamage
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
        diagnostic?.phase = .rawInitialImage
        guard try ownedBindImage(f.inspector) == stage.before else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .rawDriver
        observed = try ownedBindRawDriver(f, stage: stage, row: row, family: .bind)
        diagnostic?.phase = .rawTeardown
      }
      // withFixture has closed its database and relinquished its inspector/physical root first.
      diagnostic?.phase = .rawFacts
      guard let observed, observed.qualified else { throw FixtureFailure.nativeShape }
      results.append(observed)
    }
    guard results.count == 4 else { throw FixtureFailure.nativeShape }
    return results
  }

  // The same whole-image predicate must retain duplicate bags and names outside the static
  // plan branches. These native controls run only in this test's new private fixture.
  private static func ownedBindStaticPlanBagControls() throws -> [Bool] {
    var outcomes: [Bool] = []
    try withFixture { f in
      let predecessor = try validateFixture(f)
      let stage = try ownedBindFreeze(
        f, predecessor: predecessor, replacement: f.link.tokenRef)
      try ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let raw = try ownedBindRawDriver(f, stage: stage, row: .normalA, family: .bind)
      guard raw.qualified else { throw FixtureFailure.nativeShape }
      let c = f.inspector
      let assertion = "SELECT \"owned_bind_stage\".\"assert_complete\"($1)"
      try c.execute("BEGIN")
      defer { _ = try? c.execute("ROLLBACK") }
      try c.execute(assertion, [stage.replacement])
      outcomes.append(true)
      // This name is deliberately absent from every static branch. Equal duplicate bags must
      // still pass through the original dynamic fallback, including its runtime names lookup.
      try c.execute(
        """
        CREATE TABLE public."owned_plan_cache_extra"(value text NOT NULL);
        INSERT INTO public."owned_plan_cache_extra" VALUES ('same'),('same');
        INSERT INTO "owned_bind_stage"."names"(name) VALUES ('owned_plan_cache_extra');
        INSERT INTO "owned_bind_stage"."expected"(name,value)
          SELECT 'owned_plan_cache_extra',to_jsonb(p) FROM public."owned_plan_cache_extra" p;
        """)
      try c.execute(assertion, [stage.replacement])
      outcomes.append(true)

      // A caught server error aborts the subtransaction: restore its savepoint before proving
      // recovery or testing a different multiplicity mismatch. Never print the rendered error.
      func rejectsMismatch() -> Bool {
        do {
          try c.execute(assertion, [stage.replacement])
          return false
        } catch let error as PostgresError {
          return error.sqlState == "P0001"
            && error.message.components(separatedBy: "\n").first
              == "ERROR:  OWNED_BIND_COMPLETE_MISMATCH"
            && equalBytes(error.sql, assertion)
        } catch {
          return false
        }
      }

      try c.execute("SAVEPOINT owned_plan_cache_probe")
      guard
        try c.execute(
          """
          INSERT INTO "owned_bind_stage"."expected"(name,value)
            SELECT name,value FROM "owned_bind_stage"."expected" WHERE name='settings' LIMIT 1
          """
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
      outcomes.append(rejectsMismatch())
      try c.execute("ROLLBACK TO SAVEPOINT owned_plan_cache_probe")
      try c.execute(assertion, [stage.replacement])
      outcomes.append(true)
      try c.execute("RELEASE SAVEPOINT owned_plan_cache_probe")

      try c.execute("SAVEPOINT owned_plan_cache_probe")
      guard
        try c.execute("INSERT INTO public.\"owned_plan_cache_extra\" VALUES ('same')").affected == 1
      else { throw FixtureFailure.nativeShape }
      outcomes.append(rejectsMismatch())
      try c.execute("ROLLBACK TO SAVEPOINT owned_plan_cache_probe")
      try c.execute(assertion, [stage.replacement])
      outcomes.append(true)
      try c.execute("RELEASE SAVEPOINT owned_plan_cache_probe")
    }
    return outcomes
  }

  @Test(NativeDBResources()) func ownedBindRawStageFixtureValidation() throws {
    // Synthetic inputs stay transient; assertions expose only closed output primitives.
    let known = OwnedRawDriverRenderedContext.classify(
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line 17 at EXECUTE")
    #expect(known.state == .known)
    #expect(known.function == .assertComplete && known.line == 17 && known.site == .execute)
    let multiline = OwnedRawDriverRenderedContext.classify(
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  SQL statement \"SELECT secret:PRIVATE\nFROM private_data\"\n"
        + "PL/pgSQL function owned_bind_stage.assert_complete(text) line 17 at EXECUTE\n"
        + "SQL statement \"SELECT \"owned_bind_stage\".\"assert_complete\"(original)\"\n"
        + "PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n")
    #expect(multiline.state == .known && multiline.function == .body)
    #expect(multiline.line == 4 && multiline.site == .perform)
    let transaction = OwnedRawDriverRenderedContext.classify(
      "ERROR:  canceling statement due to lock timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_transaction() line 1 at SQL statement")
    #expect(transaction.state == .known && transaction.function == .assertTransaction)
    #expect(transaction.line == 1 && transaction.site == .sqlStatement)
    let finalKnown = OwnedRawDriverRenderedContext.classify(
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  SQL statement \"SELECT secret:PRIVATE\n"
        + "PL/pgSQL function owned_bind_stage.assert_complete(text) line 1 at EXECUTE\n\"\n"
        + "PL/pgSQL function owned_bind_stage.commit_normal() line 512 at RETURN")
    #expect(finalKnown.state == .known && finalKnown.function == .commitNormal)
    #expect(finalKnown.line == 512 && finalKnown.site == .other)
    let absent = OwnedRawDriverRenderedContext.classify(
      "ERROR:  canceling statement due to statement timeout\n"
        + "PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM")
    #expect(absent.state == .absent && absent.function == .none)
    #expect(absent.line == nil && absent.site == .none)
    let unlistedInputs = [
      "ERROR:  secret:PRIVATE\nCONTEXT:  PL/pgSQL function private.secret() line 2 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n"
        + "unknown final secret:PRIVATE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line 0 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line 513 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line 01 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line +1 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line ١ at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.assert_complete(text) line 2 at secret:PRIVATE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT: PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  SQL statement \"SELECT secret:PRIVATE\n"
        + "PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n\"",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.commit_normal() line 7 at RETURN",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n"
        + "PL/pgSQL function owned_bind_stage.transaction_checked(boolean) line 2 at EXECUTE",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\n ",
      // CRLF/control/trailing-junk tails are unsupported; no earlier frame is substituted.
      "ERROR:  canceling statement due to statement timeout\r\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\r\n",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM\0",
      "ERROR:  canceling statement due to statement timeout\n"
        + "CONTEXT:  PL/pgSQL function owned_bind_stage.body() line 4 at PERFORM secret:PRIVATE",
    ]
    for input in unlistedInputs {
      let closed = OwnedRawDriverRenderedContext.classify(input)
      #expect(closed.state == .unlisted && closed.function == .unlisted)
      #expect(closed.line == nil && closed.site == .none)
    }
    let missingWait = NativeDBCaseQueueWait.classify(nil)
    let negativeWait = NativeDBCaseQueueWait.classify(.seconds(-1))
    let finiteWait = NativeDBCaseQueueWait.classify(.seconds(1) + .microseconds(7))
    let overflowWait = NativeDBCaseQueueWait.classify(.seconds(Int64.max))
    let negativeFractionWait = NativeDBCaseQueueWait.classify(.nanoseconds(-1))
    let subMicrosecondWait = NativeDBCaseQueueWait.classify(.nanoseconds(999))
    let largestWait = NativeDBCaseQueueWait.classify(
      .seconds(9_223_372_036_854) + .microseconds(775_807))
    let addOverflowWait = NativeDBCaseQueueWait.classify(
      .seconds(9_223_372_036_854) + .microseconds(775_808))
    #expect(missingWait == .none && negativeWait == .none && negativeFractionWait == .none)
    #expect(subMicrosecondWait == .value(0))
    #expect(largestWait == .value(Int64.max) && addOverflowWait == .overflow)
    #expect(finiteWait == .value(1_000_007) && overflowWait == .overflow)
    #expect(NativeDBCaseQueueWait.maximum(.value(9), .value(4)) == .value(9))
    #expect(NativeDBCaseQueueWait.maximum(.overflow, .value(4)) == .overflow)
    let rows = try Self.ownedBindRawStageControls()
    let planBags = try Self.ownedBindStaticPlanBagControls()
    #expect(planBags == [true, true, true, true, true, true])
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

// Prospective T04/T08 owned-writer pairs. The raw controls qualify the installed recipe;
// only these actual owned calls and native observations supply the target evidence.
extension OwnedProtocolProofWriteTests {
  private final class OwnedBindMemory: Sendable {
    private struct State: Sendable {
      var current = true
      var calls = 0
      var selected: Int?
    }
    private let state: Mutex<State>

    init(selected: Int?) { state = Mutex(State(selected: selected)) }

    func compare() -> Bool {
      state.withLock {
        $0.calls += 1
        return $0.current && $0.selected != $0.calls
      }
    }

    func calls() -> Int { state.withLock { $0.calls } }
    func setCurrent(_ current: Bool) { state.withLock { $0.current = current } }
    func disableSelector() { state.withLock { $0.selected = nil } }
  }

  private final class OwnedBindFinished: Sendable {
    private let finished = Mutex(false)
    func markReturned() { finished.withLock { $0 = true } }
    // This conservative rejection guard is not a native stage or Thread-exit oracle.
    func pending() -> Bool { finished.withLock { !$0 } }
  }

  private enum OwnedBindWaitKind: Sendable, Equatable { case advisory, link }

  private final class OwnedBindHolderState: Sendable {
    struct Facts: Sendable {
      var pid = 0
      var acquired = false
    }
    private let facts = Mutex(Facts())
    func acquired(pid: Int) { facts.withLock { $0 = Facts(pid: pid, acquired: true) } }
    func snapshot() -> Facts { facts.withLock { $0 } }
  }

  private struct OwnedBindHolderResult: Sendable {
    let acquired: Bool
    let released: Bool
    let expired: Bool
    let rollbackAcknowledged: Bool

    var normal: Bool { acquired && released && !expired && rollbackAcknowledged }
    static let invalid = Self(
      acquired: false, released: false, expired: false, rollbackAcknowledged: false)
  }

  private struct OwnedBindPairFacts {
    let rawControls: Int
    let negativeCalls: Int
    let positiveCalls: Int
    let redemptionCalls: Int
    let nativeWaits: Int
    let normalHolders: Int
    let qualified: Bool
  }

  private static func ownedBindWriter(
    database: WorkspaceDatabase, anchor: ProtocolVerificationSnapshot,
    binding: ProtocolMembershipBinding, reference: String,
    admission: ProtocolProofMemoryAdmission, finished: OwnedBindFinished
  ) -> OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt> {
    OwnedProofNativeWork { [database, anchor, binding, reference, admission, finished] in
      let receipt = database.prepareProtocolVerification(
        expectedSnapshot: anchor, expectedBinding: binding, expectedTokenRef: reference,
        memoryAdmission: admission)
      finished.markReturned()
      return receipt
    }
  }

  private static func ownedBindHolder(
    binDir: String, socketDir: String, port: Int, database: String, user: String,
    application: String, kind: OwnedBindWaitKind, hold: OwnedProofHold,
    state: OwnedBindHolderState
  ) -> OwnedProofNativeWork<OwnedBindHolderResult> {
    OwnedProofNativeWork {
      [binDir, socketDir, port, database, user, application, kind, hold, state] in
      do {
        // The native connection is lexical to this actual operation's Thread.
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: binDir),
          connectionString:
            "host=\(socketDir) port=\(port) user=\(user) dbname=\(database) application_name=\(application)")
        var beginAttempted = false
        var rollbackAcknowledged = false
        // Installed before BEGIN; best effort on an error never earns ACK evidence.
        defer {
          if beginAttempted && !rollbackAcknowledged { _ = try? c.execute("ROLLBACK") }
        }
        beginAttempted = true
        try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        try c.execute("SET LOCAL lock_timeout='2s'")
        try c.execute("SET LOCAL statement_timeout='2s'")
        let identity = try c.execute("SELECT pg_catalog.pg_backend_pid() AS pid").rows
        guard identity.count == 1, let pid = identity[0].int("pid"), pid > 0 else {
          return .invalid
        }
        switch kind {
        case .advisory:
          try c.execute(
            "SELECT pg_catalog.pg_advisory_xact_lock($1::bigint)",
            [String(WorkspaceDatabase.remoteApplyLockKey)])
        case .link:
          let locked = try c.execute("SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE").rows
          guard locked.count == 1, locked[0].int("id") == 1 else { return .invalid }
        }
        state.acquired(pid: pid)
        let released = hold.wait()
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        let final = hold.snapshot()
        return OwnedBindHolderResult(
          acquired: true, released: released && final.released, expired: final.expired,
          rollbackAcknowledged: rollbackAcknowledged)
      } catch {
        return .invalid
      }
    }
  }

  private static func ownedBindHolderReady(
    _ state: OwnedBindHolderState, hold: OwnedProofHold, deadline: UInt64
  ) throws -> Int {
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let holder = state.snapshot()
      let held = hold.heldUnexpired()
      let end = DispatchTime.now().uptimeNanoseconds
      guard end <= deadline else { throw FixtureFailure.nativeShape }
      if holder.pid > 0 && holder.acquired && held { return holder.pid }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static let ownedBindAdvisoryWait = """
    SELECT a.pid::text AS pid FROM pg_catalog.pg_stat_activity a
    WHERE a.datname=$1 AND a.usename=current_user AND a.application_name='b4app'
      AND a.backend_type='client backend' AND a.pid<>pg_backend_pid() AND a.pid<>$2::int
      AND NOT(a.pid=ANY($5::int[]))
      AND a.state='active' AND a.wait_event_type='Lock' AND a.query=$4
      AND $2::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks w WHERE w.pid=a.pid
        AND w.locktype='advisory' AND w.mode='ExclusiveLock' AND NOT w.granted
        AND w.classid=0::oid AND w.objid=$3::oid AND w.objsubid=1)
    """

  private static let ownedBindLinkWait = """
    SELECT a.pid::text AS pid FROM pg_catalog.pg_stat_activity a
    WHERE a.datname=$1 AND a.usename=current_user AND a.application_name='b4app'
      AND a.backend_type='client backend' AND a.pid<>pg_backend_pid() AND a.pid<>$2::int
      AND NOT(a.pid=ANY($5::int[]))
      AND a.state='active' AND a.wait_event_type='Lock' AND a.query=$4
      AND $2::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks g WHERE g.pid=a.pid
        AND g.locktype='advisory' AND g.mode='ExclusiveLock' AND g.granted
        AND g.classid=0::oid AND g.objid=$3::oid AND g.objsubid=1)
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks w WHERE w.pid=a.pid AND NOT w.granted
        AND ((w.locktype='transactionid' AND w.mode='ShareLock'
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$2::int
            AND h.locktype='transactionid' AND h.mode='ExclusiveLock' AND h.granted
            AND h.transactionid=w.transactionid))
        OR (w.locktype='tuple' AND w.relation='public."hubLink"'::pg_catalog.regclass
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$2::int
            AND h.locktype='tuple' AND h.granted AND h.database=w.database
            AND h.relation=w.relation AND h.page=w.page AND h.tuple=w.tuple))))
    """

  private static func ownedBindObserveWait(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    kind: OwnedBindWaitKind, hold: OwnedProofHold, finished: OwnedBindFinished,
    memory: OwnedBindMemory, invocationStart: Int, deadline: UInt64
  ) throws {
    guard holderPID > 0, !knownOwnedPIDs.isEmpty,
      knownOwnedPIDs.allSatisfy({ $0 > 0 }), knownOwnedPIDs.contains(holderPID)
    else { throw FixtureFailure.nativeShape }
    let query =
      kind == .advisory
      ? "SELECT pg_advisory_xact_lock($1::bigint)"
      : "SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE"
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    let sql = kind == .advisory ? ownedBindAdvisoryWait : ownedBindLinkWait
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard finished.pending(), hold.heldUnexpired(), memory.calls() == invocationStart else {
        throw FixtureFailure.nativeShape
      }
      let rows = try c.execute(
        sql, [database, String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey), query, excluded]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      // A truthy result after the original deadline is invalid, including the final query.
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(),
        hold.heldUnexpired(), memory.calls() == invocationStart
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid)
        else { throw FixtureFailure.nativeShape }
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedBindReleaseObservedHold(
    _ hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedBindMemory,
    invocationStart: Int, retiring: Bool, deadline: UInt64
  ) throws {
    guard hold.heldUnexpired(), finished.pending(), memory.calls() == invocationStart else {
      throw FixtureFailure.nativeShape
    }
    if retiring { memory.setCurrent(false) }
    // Retirement's mutex is released before this monotonic sample or any release operation.
    let retirement = DispatchTime.now().uptimeNanoseconds
    let original = hold.snapshot()
    guard original.entered, original.held, !original.expired, !original.released,
      retirement < original.expiry, finished.pending(), memory.calls() == invocationStart
    else { throw FixtureFailure.nativeShape }
    let releaseStart = DispatchTime.now().uptimeNanoseconds
    hold.release()
    let releaseEnd = DispatchTime.now().uptimeNanoseconds
    let released = hold.snapshot()
    // No SQL or scheduling is interposed between the retirement and prompt release.
    guard retirement <= releaseStart, releaseStart <= releaseEnd,
      releaseEnd < original.expiry, releaseEnd <= deadline, released.released, !released.expired
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindMode(_ c: PostgresConnection, replacement: String) throws {
    let rows = try c.execute(
      """
      SELECT singleton::text AS singleton,replacement,raw_body_fault::text AS fault
      FROM "owned_bind_stage"."mode"
      """
    ).rows
    guard rows.count == 1, rows[0].text("singleton") == "1",
      let actual = rows[0].text("replacement"), equalBytes(actual, replacement),
      rows[0].text("fault") == "false"
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindObservedEmpty(_ c: PostgresConnection) throws {
    let rows = try c.execute("SELECT count(*) AS n FROM \"owned_bind_stage\".\"observed\"").rows
    guard rows.count == 1, rows[0].int("n") == 0 else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindWriterReady(
    _ f: Fixture, stage: OwnedBindStageFixture, replacement: String,
    body: OwnedBindProbe, commit: OwnedBindProbe
  ) throws {
    try ownedBindMode(f.inspector, replacement: replacement)
    try ownedBindObservedEmpty(f.inspector)
    guard try ownedBindImage(f.inspector) == stage.before,
      try ownedBindProbe(f.inspector, "body_probe") == body,
      try ownedBindProbe(f.inspector, "commit_probe") == commit
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedBindWriterObserved(
    _ c: PostgresConnection, stage: OwnedBindStageFixture, actualDevice: String
  ) throws {
    let rows = try c.execute(
      "SELECT isolation,lock_budget,statement_budget,hlc,device FROM \"owned_bind_stage\".\"observed\""
    ).rows
    // This native upper wall sample follows the actual writer join. No readback stamp is
    // substituted for an independently authored clock expectation.
    let serverUpper = try ownedBindWall(c)
    guard rows.count == 1, let row = rows.first, let text = row.text("hlc"),
      let native = HLC(rawValue: text), equalBytes(native.rawValue, text),
      equalBytes(stage.device, actualDevice), equalBytes(native.deviceId, actualDevice),
      native.millis >= stage.lowerWall, native.millis <= serverUpper,
      row.text("isolation") == "read committed", row.text("lock_budget") == "2s",
      row.text("statement_budget") == "2s"
    else { throw FixtureFailure.nativeShape }
    if equalBytes(actualDevice, "local") {
      guard row.text("device") == nil || row.text("device") == "" else {
        throw FixtureFailure.nativeShape
      }
    } else {
      guard let device = row.text("device"), equalBytes(device, actualDevice) else {
        throw FixtureFailure.nativeShape
      }
    }
  }

  private static func ownedBindCheckRefusal(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture,
    stage: OwnedBindStageFixture, admission: ProtocolProofMemoryAdmission,
    memory: OwnedBindMemory, invocationStart: Int, expectedCalls: Int,
    bodyBefore: OwnedBindProbe, commitBefore: OwnedBindProbe, bodyAllocations: Int64
  ) throws -> Int {
    let beforeRedemption = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == .confirmedNoncommit,
      beforeRedemption - invocationStart == expectedCalls
    else { throw FixtureFailure.nativeShape }
    let refusedSuccessor =
      (try? receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission))
      == nil
    guard refusedSuccessor, memory.calls() == beforeRedemption,
      try ownedBindImage(f.inspector) == stage.before,
      try ownedBindProbe(f.inspector, "body_probe").advanced(from: bodyBefore, by: bodyAllocations),
      try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commitBefore, by: 0)
    else { throw FixtureFailure.nativeShape }
    try ownedBindObservedEmpty(f.inspector)
    return beforeRedemption - invocationStart
  }

  private static func ownedBindCheckCurrent(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture,
    stage: OwnedBindStageFixture, admission: ProtocolProofMemoryAdmission,
    memory: OwnedBindMemory, invocationStart: Int,
    bodyBefore: OwnedBindProbe, commitBefore: OwnedBindProbe
  ) throws -> (calls: Int, redemption: Int) {
    let beforeRedemption = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == .committedCurrent,
      beforeRedemption - invocationStart == 4,
      try ownedBindImage(f.inspector) == stage.expected,
      try ownedBindProbe(f.inspector, "body_probe").advanced(from: bodyBefore, by: 1),
      try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commitBefore, by: 1)
    else { throw FixtureFailure.nativeShape }
    try ownedBindWriterObserved(f.inspector, stage: stage, actualDevice: f.database.deviceId)
    // Redemption compares sealed lineage plus fresh memory; it performs no native read.
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
    let afterRedemption = memory.calls()
    guard afterRedemption - beforeRedemption == 1 else { throw FixtureFailure.nativeShape }
    try validateSuccessor(f, successor)
    guard try ownedBindImage(f.inspector) == stage.expected else { throw FixtureFailure.nativeShape }
    return (beforeRedemption - invocationStart, afterRedemption - beforeRedemption)
  }

  private static func ownedBindHeldPair(_ kind: OwnedBindWaitKind) throws -> OwnedBindPairFacts {
    // Each unit completes all four distinct raw fixture teardowns before opening its target.
    let raw = try ownedBindRawStageControls()
    guard raw.count == 4, raw.allSatisfy({ $0.qualified }) else { throw FixtureFailure.nativeShape }
    var facts: OwnedBindPairFacts?
    try withFixture { f in
      let predecessor = try validateFixture(f)
      let reference = f.link.tokenRef
      guard reference.utf8.allSatisfy({ $0 > 0 && $0 < 128 }),
        ProtocolCredentialReference(reference) != nil
      else { throw FixtureFailure.nativeShape }
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: reference)
      try ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let bodyBefore = try ownedBindProbe(f.inspector, "body_probe")
      let commitBefore = try ownedBindProbe(f.inspector, "commit_probe")
      guard bodyBefore == OwnedBindProbe(last: 1, called: false),
        commitBefore == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      try ownedBindWriterReady(
        f, stage: stage, replacement: reference, body: bodyBefore, commit: commitBefore)
      let inspectorRows = try f.inspector.execute("SELECT pg_catalog.pg_backend_pid() AS pid").rows
      guard inspectorRows.count == 1, let inspectorPID = inspectorRows[0].int("pid"), inspectorPID > 0
      else { throw FixtureFailure.nativeShape }
      let database = f.database
      let anchor = f.anchor
      let binding = f.binding
      let endpoint = database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let originalHold = OwnedProofHold()
      let inverseHold = OwnedProofHold()
      let originalState = OwnedBindHolderState()
      let inverseState = OwnedBindHolderState()
      let originalFinished = OwnedBindFinished()
      let inverseFinished = OwnedBindFinished()
      var originalHolder: OwnedProofNativeWork<OwnedBindHolderResult>?
      var inverseHolder: OwnedProofNativeWork<OwnedBindHolderResult>?
      var originalWriter: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      var inverseWriter: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      // One cleanup covers every partial attempt. Release ALL holds before joining ANY work.
      defer {
        originalHold.release()
        inverseHold.release()
        if let originalHolder { _ = originalHolder.join() }
        if let inverseHolder { _ = inverseHolder.join() }
        if let originalWriter { _ = originalWriter.join() }
        if let inverseWriter { _ = inverseWriter.join() }
      }
      let user = NSUserName()
      let originalApplication = "owned-bind-holder-\(UUID().uuidString)"
      let inverseApplication = "owned-bind-holder-\(UUID().uuidString)"
      let readinessDeadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      originalHolder = ownedBindHolder(
        binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: user, application: originalApplication,
        kind: kind, hold: originalHold, state: originalState)
      let originalPID = try ownedBindHolderReady(
        originalState, hold: originalHold, deadline: readinessDeadline)
      let negativeStart = memory.calls()
      guard negativeStart == 0 else { throw FixtureFailure.nativeShape }
      let originalDeadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      originalWriter = ownedBindWriter(
        database: database, anchor: anchor, binding: binding, reference: reference,
        admission: admission, finished: originalFinished)
      // The sequencer exports no raw PID and has already closed every raw connection. Exclude
      // all known owned PIDs here, including the lexical inspector and this actual holder.
      try ownedBindObserveWait(
        f.inspector, database: endpoint.database, holderPID: originalPID,
        knownOwnedPIDs: [inspectorPID, originalPID], kind: kind, hold: originalHold,
        finished: originalFinished, memory: memory, invocationStart: negativeStart,
        deadline: originalDeadline)
      try ownedBindReleaseObservedHold(
        originalHold, finished: originalFinished, memory: memory, invocationStart: negativeStart,
        retiring: true, deadline: originalDeadline)
      let originalHeld = originalHolder!.join()
      let negativeReceipt = originalWriter!.join()
      guard originalHeld.normal else { throw FixtureFailure.nativeShape }
      let negativeCalls = try ownedBindCheckRefusal(
        negativeReceipt, fixture: f, stage: stage, admission: admission, memory: memory,
        invocationStart: negativeStart, expectedCalls: 1, bodyBefore: bodyBefore,
        commitBefore: commitBefore, bodyAllocations: 0)
      let bodyInverse = try ownedBindProbe(f.inspector, "body_probe")
      let commitInverse = try ownedBindProbe(f.inspector, "commit_probe")
      // Same target/stage/installer/anchor/reference/admission/probes; only current changes.
      memory.setCurrent(true)
      try ownedBindWriterReady(
        f, stage: stage, replacement: reference, body: bodyInverse, commit: commitInverse)
      let inverseReadinessDeadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      inverseHolder = ownedBindHolder(
        binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: user, application: inverseApplication,
        kind: kind, hold: inverseHold, state: inverseState)
      let inversePID = try ownedBindHolderReady(
        inverseState, hold: inverseHold, deadline: inverseReadinessDeadline)
      let positiveStart = memory.calls()
      guard positiveStart == negativeStart + negativeCalls else { throw FixtureFailure.nativeShape }
      let inverseDeadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      inverseWriter = ownedBindWriter(
        database: database, anchor: anchor, binding: binding, reference: reference,
        admission: admission, finished: inverseFinished)
      try ownedBindObserveWait(
        f.inspector, database: endpoint.database, holderPID: inversePID,
        knownOwnedPIDs: [inspectorPID, originalPID, inversePID], kind: kind, hold: inverseHold,
        finished: inverseFinished, memory: memory, invocationStart: positiveStart,
        deadline: inverseDeadline)
      try ownedBindReleaseObservedHold(
        inverseHold, finished: inverseFinished, memory: memory, invocationStart: positiveStart,
        retiring: false, deadline: inverseDeadline)
      let inverseHeld = inverseHolder!.join()
      let positiveReceipt = inverseWriter!.join()
      guard inverseHeld.normal else { throw FixtureFailure.nativeShape }
      let positive = try ownedBindCheckCurrent(
        positiveReceipt, fixture: f, stage: stage, admission: admission, memory: memory,
        invocationStart: positiveStart, bodyBefore: bodyInverse, commitBefore: commitInverse)
      facts = OwnedBindPairFacts(
        rawControls: raw.count, negativeCalls: negativeCalls, positiveCalls: positive.calls,
        redemptionCalls: positive.redemption, nativeWaits: 2,
        normalHolders: (originalHeld.normal ? 1 : 0) + (inverseHeld.normal ? 1 : 0), qualified: true)
    }
    guard let facts else { throw FixtureFailure.nativeShape }
    return facts
  }

  private static func ownedBindUnheldPair(
    selector: Int?, replacingReference: Bool
  ) throws -> OwnedBindPairFacts {
    guard replacingReference ? selector == nil : (selector == 2 || selector == 3) else {
      throw FixtureFailure.nativeShape
    }
    let raw = try ownedBindRawStageControls()
    guard raw.count == 4, raw.allSatisfy({ $0.qualified }) else { throw FixtureFailure.nativeShape }
    var facts: OwnedBindPairFacts?
    try withFixture { f in
      let predecessor = try validateFixture(f)
      let reference = f.link.tokenRef
      let replacement = replacingReference ? "secret:OWNED_BIND_WRITER_REFERENCE_B" : reference
      guard reference.utf8.allSatisfy({ $0 > 0 && $0 < 128 }),
        replacement.utf8.allSatisfy({ $0 > 0 && $0 < 128 }),
        ProtocolCredentialReference(reference) != nil,
        ProtocolCredentialReference(replacement) != nil,
        !replacingReference || !equalBytes(reference, replacement)
      else { throw FixtureFailure.nativeShape }
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: replacement)
      try ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let bodyBefore = try ownedBindProbe(f.inspector, "body_probe")
      let commitBefore = try ownedBindProbe(f.inspector, "commit_probe")
      guard bodyBefore == OwnedBindProbe(last: 1, called: false),
        commitBefore == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      try ownedBindWriterReady(
        f, stage: stage, replacement: replacement, body: bodyBefore, commit: commitBefore)
      let database = f.database
      let anchor = f.anchor
      let binding = f.binding
      let memory = OwnedBindMemory(selected: selector)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let originalFinished = OwnedBindFinished()
      let inverseFinished = OwnedBindFinished()
      var originalWriter: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      var inverseWriter: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      // Installed before the first actual writer, including a partially started inverse.
      defer {
        if let originalWriter { _ = originalWriter.join() }
        if let inverseWriter { _ = inverseWriter.join() }
      }
      let negativeStart = memory.calls()
      guard negativeStart == 0 else { throw FixtureFailure.nativeShape }
      originalWriter = ownedBindWriter(
        database: database, anchor: anchor, binding: binding, reference: reference,
        admission: admission, finished: originalFinished)
      let negativeReceipt = originalWriter!.join()
      // Ordinals only check consistency. Full body predicates/settings, nontransactional body
      // allocation, qualified normal return, deferred absence and source ordering are the oracle.
      let negativeCalls = try ownedBindCheckRefusal(
        negativeReceipt, fixture: f, stage: stage, admission: admission, memory: memory,
        invocationStart: negativeStart, expectedCalls: replacingReference ? 1 : selector!,
        bodyBefore: bodyBefore, commitBefore: commitBefore, bodyAllocations: 1)
      let bodyInverse = try ownedBindProbe(f.inspector, "body_probe")
      let commitInverse = try ownedBindProbe(f.inspector, "commit_probe")
      if replacingReference {
        // Exactly one private B-to-A mode change, after the joined refusal. No public repair,
        // installer rerun, expected-image recapture, admission change, or probe reset occurs.
        guard
          try f.inspector.execute(
            """
            UPDATE "owned_bind_stage"."mode" SET replacement=$2
            WHERE singleton=1 AND convert_to(replacement,'UTF8')=convert_to($1,'UTF8')
              AND raw_body_fault=false
            """, [replacement, reference]
          ).affected == 1
        else { throw FixtureFailure.nativeShape }
      } else {
        memory.disableSelector()
      }
      try ownedBindWriterReady(
        f, stage: stage, replacement: reference, body: bodyInverse, commit: commitInverse)
      let positiveStart = memory.calls()
      guard positiveStart == negativeStart + negativeCalls else { throw FixtureFailure.nativeShape }
      inverseWriter = ownedBindWriter(
        database: database, anchor: anchor, binding: binding, reference: reference,
        admission: admission, finished: inverseFinished)
      let positiveReceipt = inverseWriter!.join()
      // stage.expected is independently frozen S1/A, including for immutable replacement B.
      let positive = try ownedBindCheckCurrent(
        positiveReceipt, fixture: f, stage: stage, admission: admission, memory: memory,
        invocationStart: positiveStart, bodyBefore: bodyInverse, commitBefore: commitInverse)
      facts = OwnedBindPairFacts(
        rawControls: raw.count, negativeCalls: negativeCalls, positiveCalls: positive.calls,
        redemptionCalls: positive.redemption, nativeWaits: 0, normalHolders: 0, qualified: true)
    }
    guard let facts else { throw FixtureFailure.nativeShape }
    return facts
  }

  @Test(NativeDBResources()) func ownedBindRetirementAfterObservedNativePreWaitRefuses() throws {
    for kind in [OwnedBindWaitKind.advisory, .link] {
      let facts = try Self.ownedBindHeldPair(kind)
      // Only fixed primitive facts remain after target pool/inspector/physical-root teardown.
      #expect(facts.qualified)
      #expect(facts.rawControls == 4)
      #expect(facts.negativeCalls == 1)
      #expect(facts.positiveCalls == 4 && facts.redemptionCalls == 1)
      #expect(facts.nativeWaits == 2 && facts.normalHolders == 2)
    }
  }

  @Test(NativeDBResources()) func ownedBindMemoryPostAndImmediatePreCommitRefuseAfterSuccessfulBody() throws {
    for selector in [2, 3] {
      let facts = try Self.ownedBindUnheldPair(selector: selector, replacingReference: false)
      #expect(facts.qualified)
      #expect(facts.rawControls == 4)
      #expect(facts.negativeCalls == selector)
      #expect(facts.positiveCalls == 4 && facts.redemptionCalls == 1)
      #expect(facts.nativeWaits == 0 && facts.normalHolders == 0)
    }
  }

  @Test(NativeDBResources())
  func ownedBindSuccessfulReferenceReplacementRefusesPostAndSameEnabledAtoACommits() throws {
    let facts = try Self.ownedBindUnheldPair(selector: nil, replacingReference: true)
    #expect(facts.qualified)
    #expect(facts.rawControls == 4)
    #expect(facts.negativeCalls == 1)
    #expect(facts.positiveCalls == 4 && facts.redemptionCalls == 1)
    #expect(facts.nativeWaits == 0 && facts.normalHolders == 0)
  }
}

// Prospective T09 source only: each ordered unit owns its four raw controls and new target.
// Redemption compares captured lineage and fresh memory; separate native validation follows it.
extension OwnedProtocolProofWriteTests {
  private enum OwnedT09Unit {
    case object, fact, account, database, hubBase, device, joined, unlinked, callerUserOrg
    case boundUser, boundOrg, expected(String)
    case store, member, revision, missingControl, extraKey, version, noncanonicalRevision
    case nativeBase, nativeDevice, nativeJoined, missingLink, nativeReference(String), observation
    case opaque(String, mismatch: String?), maximum
  }

  private enum OwnedT09LinkColumn: String {
    case url, deviceId, joinedAt, tokenRef
  }

  // Fixed primitive facts only; no database, receipt, snapshot, image, or connection escapes.
  private struct OwnedT09Facts {
    let rawControls: Int
    let negativeCalls: Int
    let positiveCalls: Int
    let successRedemptions: Int
    let refusalRedemptions: Int
    let memoryCalls: Int
    let mutating: Bool
    let qualified: Bool
  }

  private static func ownedT09Data(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func ownedT09Object(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureFailure.nativeShape
    }
    return object
  }

  private static func ownedT09Binding(_ binding: ProtocolMembershipBinding) -> [String: Any] {
    [
      "accountID": binding.accountID, "canonicalHubBase": binding.canonicalHubBase,
      "hubUserID": binding.hubUserID, "hubOrgID": binding.hubOrgID,
      "deviceID": binding.deviceID, "databaseName": binding.databaseName,
      "linkJoinedAt": binding.linkJoinedAt,
    ]
  }

  private static func ownedT09OtherBinding(
    _ binding: ProtocolMembershipBinding, unit: OwnedT09Unit
  ) throws -> ProtocolMembershipBinding {
    var account = binding.accountID
    var database = binding.databaseName
    var hubBase = binding.canonicalHubBase
    var device = binding.deviceID
    var joined = binding.linkJoinedAt
    var user = binding.hubUserID
    var org = binding.hubOrgID
    switch unit {
    case .account: account = "OWNED_PROOF_ACCOUNT_OTHER"
    case .database: database += "_other"
    case .hubBase: hubBase = "https://example.invalid/OwnedProofOther"
    case .device: device = "OWNED_PROOF_DEVICE_OTHER"
    case .joined: joined = "2026-11-13T00:00:00.001Z"
    case .callerUserOrg:
      user = "OWNED_PROOF_USER_OTHER"
      org = "OWNED_PROOF_ORG_OTHER"
    case .boundUser: user += "_OTHER"
    case .boundOrg: org += "_OTHER"
    default: throw FixtureFailure.nativeShape
    }
    return try ProtocolMembershipBinding(
      accountID: account, canonicalHubBase: hubBase, hubUserID: user, hubOrgID: org,
      deviceID: device, databaseName: database, linkJoinedAt: joined)
  }

  private static func ownedT09Next(_ object: [String: Any]) throws -> String {
    guard let text = object["revision"] as? String, let revision = Int64(text),
      revision >= 0, equalBytes(text, String(revision))
    else { throw FixtureFailure.nativeShape }
    let (next, overflow) = revision.addingReportingOverflow(1)
    guard !overflow else { throw FixtureFailure.nativeShape }
    return String(next)
  }

  // Replace only one complete, checked settings key/value row, retaining every other row,
  // empty public table, database identity, and all three public sequence fields.
  private static func ownedT09ControlImage(
    _ image: OwnedBindImage, old: [String: Any]?, new: [String: Any]?
  ) throws -> OwnedBindImage {
    guard let settings = image.rows["settings"] else { throw FixtureFailure.nativeShape }
    var next: [Data] = []
    var found = 0
    for data in settings {
      let row = try ownedT09Object(data)
      guard Set(row.keys) == Set(["key", "value"]), let rowKey = row["key"] as? String else {
        throw FixtureFailure.nativeShape
      }
      if equalBytes(rowKey, key) {
        guard let old, data == (try ownedT09Data(["key": key, "value": old])) else {
          throw FixtureFailure.nativeShape
        }
        found += 1
      } else {
        next.append(data)
      }
    }
    guard found == (old == nil ? 0 : 1) else { throw FixtureFailure.nativeShape }
    if let new { next.append(try ownedT09Data(["key": key, "value": new])) }
    var rows = image.rows
    rows["settings"] = next.sorted { $0.lexicographicallyPrecedes($1) }
    return OwnedBindImage(database: image.database, rows: rows, sequence: image.sequence)
  }

  private static func ownedT09Bound(
    _ image: OwnedBindImage, inactive: NativeControl, binding: ProtocolMembershipBinding
  ) throws -> (image: OwnedBindImage, control: [String: Any]) {
    guard
      Set(inactive.object.keys)
        == Set([
          "version", "storeIncarnation", "membershipIncarnation", "revision",
        ]), inactive.revision == 0, equalBytes(image.database, binding.databaseName)
    else {
      throw FixtureFailure.nativeShape
    }
    var expected = inactive.object
    expected["revision"] = try ownedT09Next(inactive.object)
    expected["binding"] = ownedT09Binding(binding)
    return (try ownedT09ControlImage(image, old: inactive.object, new: expected), expected)
  }

  private static func ownedT09Link(_ image: OwnedBindImage) throws -> Data {
    guard let rows = image.rows["hubLink"], rows.count == 1 else { throw FixtureFailure.nativeShape }
    let row = try ownedT09Object(rows[0])
    guard
      Set(row.keys)
        == Set([
          "id", "url", "deviceId", "deviceName", "tokenRef", "orgSlug", "username", "cursor",
          "lastPushAt", "lastError", "joinedAt", "ownedAs",
        ]), let id = row["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
      id.stringValue == "1"
    else { throw FixtureFailure.nativeShape }
    for value in row.values {
      if let text = value as? String, text.utf8.contains(0) { throw FixtureFailure.nativeShape }
    }
    return rows[0]
  }

  private static func ownedT09LinkImage(
    _ image: OwnedBindImage, old: Data?, new: Data?
  ) throws -> OwnedBindImage {
    guard let links = image.rows["hubLink"], links == (old.map({ [$0] }) ?? []) else {
      throw FixtureFailure.nativeShape
    }
    var rows = image.rows
    rows["hubLink"] = new.map { [$0] } ?? []
    let result = OwnedBindImage(database: image.database, rows: rows, sequence: image.sequence)
    if new != nil { _ = try ownedT09Link(result) }
    return result
  }

  private static func ownedT09ChangedLink(
    _ image: OwnedBindImage, column: OwnedT09LinkColumn, value: String
  ) throws -> OwnedBindImage {
    guard !value.utf8.contains(0) else { throw FixtureFailure.nativeShape }
    let old = try ownedT09Link(image)
    var row = try ownedT09Object(old)
    guard row[column.rawValue] is String else { throw FixtureFailure.nativeShape }
    row[column.rawValue] = value
    return try ownedT09LinkImage(image, old: old, new: ownedT09Data(row))
  }

  // This adapted freezer truthfully supports chosen native A, caller binding, and bound/no-op
  // images. The seed was validated before customization, and the catalog guard precedes install.
  private static func ownedT09Freeze(
    _ f: Fixture, before: OwnedBindImage, expected: OwnedBindImage,
    expectedControl: [String: Any], reference: String
  ) throws -> OwnedBindStageFixture {
    try ownedBindCatalogGuard(f.inspector)
    let link = try ownedT09Object(ownedT09Link(before))
    guard let actualA = link["tokenRef"] as? String, equalBytes(actualA, reference),
      ProtocolCredentialReference(actualA) != nil, !actualA.utf8.contains(0),
      equalBytes(before.database, f.database.endpoint.database),
      try ownedBindImage(f.inspector) == before,
      let expectedRows = expected.rows["settings"],
      expectedRows.filter({ data in
        guard let row = try? ownedT09Object(data), let rowKey = row["key"] as? String else { return false }
        return equalBytes(rowKey, key)
      }) == [try ownedT09Data(["key": key, "value": expectedControl])],
      try ownedT09Link(expected) == ownedT09Link(before)
    else { throw FixtureFailure.nativeShape }
    let device = f.database.deviceId
    guard !device.isEmpty, !device.utf8.contains(0) else { throw FixtureFailure.nativeShape }
    return OwnedBindStageFixture(
      before: before, expected: expected,
      controlJSON: try ownedBindText(ownedT09Data(expectedControl)),
      originalReference: actualA, replacement: actualA, device: device,
      lowerWall: try ownedBindWall(f.inspector))
  }

  // Check the entire immutable private recipe before every actual writer and on both sides
  // of every post-install fixture transaction. Never rerun the zero-trigger preinstall guard.
  private static func ownedT09Recipe(_ c: PostgresConnection, stage: OwnedBindStageFixture) throws {
    try ownedBindMode(c, replacement: stage.originalReference)
    let names = try c.execute("SELECT name FROM \"owned_bind_stage\".\"names\"").rows
    var expectedRows = Dictionary(uniqueKeysWithValues: stage.expected.rows.keys.map { ($0, [Data]()) })
    var actualNames = Set<Data>()
    for row in names {
      guard let name = row.text("name"), actualNames.insert(Data(name.utf8)).inserted else {
        throw FixtureFailure.nativeShape
      }
    }
    guard actualNames == Set(stage.expected.rows.keys.map { Data($0.utf8) }) else {
      throw FixtureFailure.nativeShape
    }
    for row in try c.execute(
      "SELECT name,value::text AS value FROM \"owned_bind_stage\".\"expected\""
    ).rows {
      guard let name = row.text("name"), let value = row.text("value"), expectedRows[name] != nil else {
        throw FixtureFailure.nativeShape
      }
      expectedRows[name]!.append(try ownedBindJSON(value))
    }
    for name in Array(expectedRows.keys) { expectedRows[name]!.sort { $0.lexicographicallyPrecedes($1) } }
    guard expectedRows == stage.expected.rows else { throw FixtureFailure.nativeShape }
    let meta = try c.execute(
      "SELECT to_jsonb(m)::text AS value FROM \"owned_bind_stage\".\"meta\" m"
    ).rows
    let expectedMeta: [String: Any] = [
      "singleton": 1, "database": stage.before.database, "original_ref": stage.originalReference,
      "expected_control": try ownedT09Object(Data(stage.controlJSON.utf8)),
      "expected_sequence": try ownedT09Object(stage.before.sequence),
      "expected_device": stage.device, "lower_wall": stage.lowerWall,
    ]
    guard meta.count == 1, let text = meta[0].text("value"),
      try ownedBindJSON(text) == ownedT09Data(expectedMeta)
    else { throw FixtureFailure.nativeShape }
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
    let linkTriggers = try c.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_trigger
      WHERE tgrelid='public."hubLink"'::pg_catalog.regclass AND NOT tgisinternal
      """
    ).rows
    guard linkTriggers.count == 1, linkTriggers[0].int("n") == 0 else {
      throw FixtureFailure.nativeShape
    }
  }

  private static func ownedT09Checkpoint(
    _ f: Fixture, stage: OwnedBindStageFixture, image: OwnedBindImage,
    body: OwnedBindProbe, commit: OwnedBindProbe, allocations: Int64
  ) throws {
    try ownedT09Recipe(f.inspector, stage: stage)
    guard try ownedBindImage(f.inspector) == image,
      try ownedBindProbe(f.inspector, "body_probe").advanced(from: body, by: allocations),
      try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commit, by: allocations)
    else { throw FixtureFailure.nativeShape }
    if allocations == 0 {
      try ownedBindObservedEmpty(f.inspector)
    } else {
      guard allocations == 1 else { throw FixtureFailure.nativeShape }
      try ownedBindWriterObserved(f.inspector, stage: stage, actualDevice: f.database.deviceId)
    }
  }

  // Q01: both directions use DELETE+INSERT, never UPDATE/UPSERT. Missing control has a
  // distinct delete-only forward / insert-only restoration path. Cleanup is in place BEFORE BEGIN.
  private static func ownedT09ControlSwap(
    _ f: Fixture, stage: OwnedBindStageFixture, from: OwnedBindImage, to: OwnedBindImage,
    old: [String: Any]?, new: [String: Any]?, body: OwnedBindProbe, commit: OwnedBindProbe
  ) throws {
    guard try ownedT09ControlImage(from, old: old, new: new) == to else {
      throw FixtureFailure.nativeShape
    }
    try ownedT09Checkpoint(f, stage: stage, image: from, body: body, commit: commit, allocations: 0)
    var committed = false
    defer { if !committed { try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    if let old {
      guard
        try f.inspector.execute(
          "DELETE FROM public.settings WHERE key=$1 AND value=$2::jsonb",
          [key, try ownedBindText(ownedT09Data(old))]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    }
    if let new {
      guard
        try f.inspector.execute(
          "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)",
          [key, try ownedBindText(ownedT09Data(new))]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    }
    try f.inspector.execute("COMMIT")
    committed = true
    try ownedT09Checkpoint(f, stage: stage, image: to, body: body, commit: commit, allocations: 0)
  }

  // Only fixed quoted link columns are permitted; absent link restoration supplies all twelve
  // retained columns through the actual native row type. No schema or NOT NULL relaxation.
  private static func ownedT09LinkSwap(
    _ f: Fixture, from: OwnedBindImage, to: OwnedBindImage, column: OwnedT09LinkColumn?,
    stage: OwnedBindStageFixture?, body: OwnedBindProbe?, commit: OwnedBindProbe?
  ) throws {
    guard let oldRows = from.rows["hubLink"], let newRows = to.rows["hubLink"] else {
      throw FixtureFailure.nativeShape
    }
    let old: Data?
    let new: Data?
    if oldRows.isEmpty { old = nil } else { old = try ownedT09Link(from) }
    if newRows.isEmpty { new = nil } else { new = try ownedT09Link(to) }
    guard try ownedT09LinkImage(from, old: old, new: new) == to else {
      throw FixtureFailure.nativeShape
    }
    if let stage, let body, let commit {
      try ownedT09Checkpoint(f, stage: stage, image: from, body: body, commit: commit, allocations: 0)
    } else {
      guard stage == nil, body == nil, commit == nil,
        try ownedBindImage(f.inspector) == from
      else { throw FixtureFailure.nativeShape }
      try ownedBindCatalogGuard(f.inspector)
    }
    var committed = false
    defer { if !committed { try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    switch (old, new) {
    case (.some(let old), .some(let new)):
      guard let column,
        let value = try ownedT09Object(new)[column.rawValue] as? String,
        !value.utf8.contains(0),
        try ownedT09ChangedLink(from, column: column, value: value) == to,
        try f.inspector.execute(
          "UPDATE public.\"hubLink\" AS l SET \(Rows.quote(column.rawValue))=$1 WHERE id=1 AND to_jsonb(l)=$2::jsonb",
          [value, try ownedBindText(old)]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    case (.some(let old), nil):
      guard column == nil,
        try f.inspector.execute(
          "DELETE FROM public.\"hubLink\" AS l WHERE id=1 AND to_jsonb(l)=$1::jsonb",
          [try ownedBindText(old)]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    case (nil, .some(let new)):
      guard column == nil,
        try f.inspector.execute(
          "INSERT INTO public.\"hubLink\" SELECT (jsonb_populate_record(NULL::public.\"hubLink\",$1::jsonb)).*",
          [try ownedBindText(new)]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    default: throw FixtureFailure.nativeShape
    }
    try f.inspector.execute("COMMIT")
    committed = true
    if let stage, let body, let commit {
      try ownedT09Checkpoint(f, stage: stage, image: to, body: body, commit: commit, allocations: 0)
    } else {
      guard try ownedBindImage(f.inspector) == to else { throw FixtureFailure.nativeShape }
      try ownedBindCatalogGuard(f.inspector)
    }
  }

  private static func ownedT09NativeValidate(
    _ f: Fixture, successor: ProtocolVerificationSnapshot, binding: ProtocolMembershipBinding,
    reference: String, observation: ProtocolVerificationObservation?
  ) throws {
    guard successor.observation == observation else { throw FixtureFailure.nativeShape }
    try f.database.validateProtocolVerification(expectedSnapshot: successor)
    try f.database.compareOriginalLinkedCaptureOwner(
      expectedSnapshot: successor, accountID: binding.accountID,
      databaseName: binding.databaseName, hubBase: binding.canonicalHubBase)
    try f.database.compareOriginalLinkedCredentialReference(
      expectedSnapshot: successor, expectedTokenRef: reference)
  }

  private static func ownedT09Refused(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture, stage: OwnedBindStageFixture,
    image: OwnedBindImage, anchor: ProtocolVerificationSnapshot, reference: String,
    admission: ProtocolProofMemoryAdmission, memory: OwnedBindMemory, start: Int, calls: Int,
    body: OwnedBindProbe, commit: OwnedBindProbe
  ) throws -> Int {
    let before = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == .confirmedNoncommit,
      before - start == calls
    else { throw FixtureFailure.nativeShape }
    let successor = try? receipt.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
    guard successor == nil, memory.calls() == before else { throw FixtureFailure.nativeShape }
    try ownedT09Checkpoint(f, stage: stage, image: image, body: body, commit: commit, allocations: 0)
    return before - start
  }

  private static func ownedT09Committed(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture, stage: OwnedBindStageFixture,
    memory: OwnedBindMemory, start: Int, body: OwnedBindProbe, commit: OwnedBindProbe, mutating: Bool
  ) throws {
    guard receipt.operation == .bind, receipt.disposition == .committedCurrent,
      memory.calls() - start == 4
    else { throw FixtureFailure.nativeShape }
    try ownedT09Checkpoint(
      f, stage: stage, image: stage.expected, body: body, commit: commit,
      allocations: mutating ? 1 : 0)
  }

  private static func ownedT09Redeem(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture, stage: OwnedBindStageFixture,
    anchor: ProtocolVerificationSnapshot, binding: ProtocolMembershipBinding, reference: String,
    observation: ProtocolVerificationObservation?, admission: ProtocolProofMemoryAdmission,
    memory: OwnedBindMemory, allowed: Bool, body: OwnedBindProbe, commit: OwnedBindProbe, mutating: Bool
  ) throws {
    let before = memory.calls()
    if allowed {
      let successor = try receipt.currentSuccessor(
        expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
      guard memory.calls() == before + 1 else { throw FixtureFailure.nativeShape }
      // currentSuccessor performs no native read. These are separate, honest native comparisons.
      try ownedT09NativeValidate(
        f, successor: successor, binding: binding, reference: reference, observation: observation)
    } else {
      let successor = try? receipt.currentSuccessor(
        expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
      guard successor == nil, memory.calls() == before else { throw FixtureFailure.nativeShape }
    }
    guard receipt.operation == .bind, receipt.disposition == .committedCurrent else {
      throw FixtureFailure.nativeShape
    }
    try ownedT09Checkpoint(
      f, stage: stage, image: stage.expected, body: body, commit: commit,
      allocations: mutating ? 1 : 0)
  }

  private static func ownedT09Unit(_ unit: OwnedT09Unit) throws -> OwnedT09Facts {
    // A fresh sequencer runs here for EVERY loop element. All four fixtures have torn down
    // before withFixture constructs this unit's target; no cache or other fixture image is used.
    let raw = try ownedBindRawStageControls()
    guard raw.count == 4, raw.enumerated().allSatisfy({ $0.element.row == $0.offset && $0.element.qualified })
    else { throw FixtureFailure.nativeShape }
    var facts: OwnedT09Facts?
    try withFixture { f in
      let inactive = try validateFixture(f)
      let seed = try ownedBindImage(f.inspector)
      let originalLink = try ownedT09Link(seed)
      let originalControl = inactive.object
      let originalA = f.link.tokenRef
      guard ProtocolCredentialReference(originalA) != nil,
        !originalA.utf8.contains(0), equalBytes(seed.database, f.binding.databaseName)
      else { throw FixtureFailure.nativeShape }

      // I01's extra real object uses the exact endpoint and validated binDir. Its defer is
      // installed immediately after construction, before any writer defer or later query.
      var extra: WorkspaceDatabase?
      if case .object = unit {
        guard let binDir = f.database.endpoint.binDir, !binDir.isEmpty,
          !binDir.utf8.contains(0), try ownedBindImage(f.inspector) == seed
        else { throw FixtureFailure.nativeShape }
        extra = try WorkspaceDatabase(
          endpoint: f.database.endpoint, binDir: binDir, createIfMissing: false)
      }
      defer { if let extra { try? extra.close() } }
      guard try ownedBindImage(f.inspector) == seed else { throw FixtureFailure.nativeShape }

      var negativeAnchor = f.anchor
      var positiveAnchor = f.anchor
      var negativeBinding = f.binding
      var positiveBinding = f.binding
      var referenceA = originalA
      var negativeReference = originalA
      var before = seed
      var success = try ownedT09Bound(seed, inactive: inactive, binding: f.binding)
      var expectedObservation: ProtocolVerificationObservation?
      var mutating = true
      var single = false
      var changesControl = false
      var mutatedControl: [String: Any]?
      var changesLink = false
      var linkColumn: OwnedT09LinkColumn?
      var negativeImage: OwnedBindImage?
      var maximum = false
      var negativeDatabase = f.database

      switch unit {
      case .object:
        guard let extra else { throw FixtureFailure.nativeShape }
        negativeDatabase = extra
      case .fact, .boundUser, .boundOrg, .observation:
        // Compute B0 from retained S0 BEFORE ordinary setup, then require exact native B0.
        let bound = try f.database.prepareProtocolVerification(
          expectedSnapshot: f.anchor, expectedBinding: f.binding)
        guard try ownedBindImage(f.inspector) == success.image else { throw FixtureFailure.nativeShape }
        before = success.image
        positiveAnchor = bound
        negativeAnchor = bound
        mutating = false
        switch unit {
        case .fact:
          guard let contextFree = try f.database.readProtocolFact(expectedBinding: f.binding),
            try ownedBindImage(f.inspector) == before
          else { throw FixtureFailure.nativeShape }
          negativeAnchor = contextFree
        case .boundUser, .boundOrg:
          negativeBinding = try ownedT09OtherBinding(f.binding, unit: unit)
        case .observation:
          let observation = try ProtocolVerificationObservation(
            binding: f.binding, reportedMinimum: 2, reportedVersion: 2, healthy: true)
          var observedControl = success.control
          observedControl["revision"] = try ownedT09Next(success.control)
          observedControl["observation"] =
            [
              "binding": ownedT09Binding(f.binding), "reportedMinimum": 2,
              "reportedVersion": 2, "healthy": true,
            ] as [String: Any]
          let observedImage = try ownedT09ControlImage(
            before, old: success.control, new: observedControl)
          let observedAnchor = try f.database.commitObservedProtocolFact(
            expectedSnapshot: bound, observation: observation)
          guard observedAnchor.observation == observation,
            try ownedBindImage(f.inspector) == observedImage
          else { throw FixtureFailure.nativeShape }
          before = observedImage
          success = (observedImage, observedControl)
          positiveAnchor = observedAnchor
          negativeAnchor = observedAnchor
          expectedObservation = observation
          changesControl = true
          var changedObservation: [String: Any] = [
            "binding": ownedT09Binding(f.binding), "reportedMinimum": 2,
            "reportedVersion": 2, "healthy": true,
          ]
          changedObservation["reportedVersion"] = 3
          var drift = observedControl
          drift["observation"] = changedObservation
          mutatedControl = drift
        default: throw FixtureFailure.nativeShape
        }
        // A no-op's entire bound or observed native state is both before and expected.
        success = (before, success.control)
      case .account, .database, .hubBase, .device, .joined:
        negativeBinding = try ownedT09OtherBinding(f.binding, unit: unit)
      case .unlinked:
        let missing = try ownedT09LinkImage(seed, old: originalLink, new: nil)
        try ownedT09LinkSwap(
          f, from: seed, to: missing, column: nil, stage: nil, body: nil, commit: nil)
        negativeAnchor = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: nil)
        guard try ownedBindImage(f.inspector) == missing else { throw FixtureFailure.nativeShape }
        try ownedT09LinkSwap(
          f, from: missing, to: seed, column: nil, stage: nil, body: nil, commit: nil)
      case .callerUserOrg:
        positiveBinding = try ownedT09OtherBinding(f.binding, unit: unit)
        success = try ownedT09Bound(seed, inactive: inactive, binding: positiveBinding)
        single = true
      case .expected(let value):
        // Includes NUL only in the Swift expected argument and failed receipt comparison.
        // It never enters native SQL, JSON/meta, mode, or an error message.
        guard ProtocolCredentialReference(value) == nil else { throw FixtureFailure.nativeShape }
        negativeReference = value
      case .store, .member:
        let replacement = UUID().uuidString
        guard UUID(uuidString: replacement)?.uuidString == replacement,
          !equalBytes(replacement, inactive.store), !equalBytes(replacement, inactive.member)
        else { throw FixtureFailure.nativeShape }
        var drift = originalControl
        if case .store = unit {
          drift["storeIncarnation"] = replacement
        } else {
          drift["membershipIncarnation"] = replacement
        }
        changesControl = true
        mutatedControl = drift
      case .revision:
        var drift = originalControl
        drift["revision"] = try ownedT09Next(originalControl)
        changesControl = true
        mutatedControl = drift
      case .missingControl:
        changesControl = true
        mutatedControl = nil
      case .extraKey:
        var drift = originalControl
        guard drift["OWNED_T09_EXTRA"] == nil else { throw FixtureFailure.nativeShape }
        drift["OWNED_T09_EXTRA"] = true
        changesControl = true
        mutatedControl = drift
      case .version:
        guard let version = originalControl["version"] as? NSNumber,
          CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1"
        else { throw FixtureFailure.nativeShape }
        var drift = originalControl
        drift["version"] = 2
        changesControl = true
        mutatedControl = drift
      case .noncanonicalRevision:
        guard let revision = originalControl["revision"] as? String,
          equalBytes(revision, "0"), inactive.revision == 0
        else { throw FixtureFailure.nativeShape }
        var drift = originalControl
        drift["revision"] = "0" + revision
        changesControl = true
        mutatedControl = drift
      case .nativeBase:
        changesLink = true
        linkColumn = .url
        negativeImage = try ownedT09ChangedLink(
          seed, column: .url, value: "https://example.invalid/OwnedProofOther")
      case .nativeDevice:
        changesLink = true
        linkColumn = .deviceId
        negativeImage = try ownedT09ChangedLink(seed, column: .deviceId, value: "OWNED_PROOF_DEVICE_OTHER")
      case .nativeJoined:
        changesLink = true
        linkColumn = .joinedAt
        negativeImage = try ownedT09ChangedLink(
          seed, column: .joinedAt, value: "2026-11-13T00:00:00.001Z")
      case .missingLink:
        changesLink = true
        negativeImage = try ownedT09LinkImage(seed, old: originalLink, new: nil)
      case .nativeReference(let value):
        // N10 and the six non-NUL N11 values are native fixture literals only.
        guard !value.utf8.contains(0), !equalBytes(value, originalA) else {
          throw FixtureFailure.nativeShape
        }
        changesLink = true
        linkColumn = .tokenRef
        negativeImage = try ownedT09ChangedLink(seed, column: .tokenRef, value: value)
      case .opaque(let value, let mismatch):
        guard ProtocolCredentialReference(value) != nil, !value.utf8.contains(0) else {
          throw FixtureFailure.nativeShape
        }
        let chosen = try ownedT09ChangedLink(seed, column: .tokenRef, value: value)
        try ownedT09LinkSwap(
          f, from: seed, to: chosen, column: .tokenRef, stage: nil, body: nil, commit: nil)
        before = chosen
        referenceA = value
        negativeReference = value
        success = try ownedT09Bound(chosen, inactive: inactive, binding: f.binding)
        if let mismatch {
          // Swift canonical equivalence is deliberately insufficient for the byte contract.
          guard value == mismatch, !equalBytes(value, mismatch),
            ProtocolCredentialReference(mismatch) != nil, !mismatch.utf8.contains(0)
          else { throw FixtureFailure.nativeShape }
          negativeReference = mismatch
        } else {
          single = true
        }
      case .maximum:
        // success was derived from original S0 at ordinary revision, never from MAX.
        var drift = originalControl
        drift["revision"] = String(Int64.max)
        changesControl = true
        mutatedControl = drift
        maximum = true
      // N12 alone changes the inverse anchor from genuine MAX back to retained f.anchor.
      // positiveAnchor still holds that original capture; no recapture repairs the drift.
      }

      // Retain B0/O0's actual control independently; malformed controls are never decoded
      // to construct a passing expectation. For inactive cases this remains original S0.
      let beforeControl: [String: Any]
      if mutating { beforeControl = originalControl } else { beforeControl = success.control }
      if changesControl {
        negativeImage = try ownedT09ControlImage(before, old: beforeControl, new: mutatedControl)
      }
      let refusedImage = negativeImage ?? before
      guard try ownedBindImage(f.inspector) == before else { throw FixtureFailure.nativeShape }
      // Exactly one freeze, one installer, original A->A mode, and no later recapture/repair.
      let stage = try ownedT09Freeze(
        f, before: before, expected: success.image, expectedControl: success.control, reference: referenceA)
      try ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let body = try ownedBindProbe(f.inspector, "body_probe")
      let commit = try ownedBindProbe(f.inspector, "commit_probe")
      guard body == OwnedBindProbe(last: 1, called: false),
        commit == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      try ownedT09Checkpoint(f, stage: stage, image: before, body: body, commit: commit, allocations: 0)
      if changesControl {
        try ownedT09ControlSwap(
          f, stage: stage, from: before, to: refusedImage,
          old: beforeControl, new: mutatedControl, body: body, commit: commit)
      } else if changesLink {
        try ownedT09LinkSwap(
          f, from: before, to: refusedImage, column: linkColumn,
          stage: stage, body: body, commit: commit)
      }
      if maximum {
        let membership = try ProtocolNativeMembership(
          canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
        negativeAnchor = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: membership)
        // This is the genuine actual MAX capture; no unchecked MAX+1 expectation is formed.
        try ownedT09Checkpoint(
          f, stage: stage, image: refusedImage, body: body, commit: commit, allocations: 0)
      }

      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let firstFinished = OwnedBindFinished()
      let inverseFinished = OwnedBindFinished()
      var first: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      var inverse: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      // Existence is the sole cleanup predicate. Every assigned started handle is joined on
      // every throw, including a partially started inverse and native-validation failures.
      defer {
        if let first { _ = first.join() }
        if let inverse { _ = inverse.join() }
      }
      var negativeCalls = 0
      if !single {
        try ownedT09Checkpoint(
          f, stage: stage, image: refusedImage, body: body, commit: commit, allocations: 0)
        let start = memory.calls()
        guard start == 0 else { throw FixtureFailure.nativeShape }
        first = ownedBindWriter(
          database: negativeDatabase, anchor: negativeAnchor, binding: negativeBinding,
          reference: negativeReference, admission: admission, finished: firstFinished)
        let receipt = first!.join()
        negativeCalls = try ownedT09Refused(
          receipt, fixture: f, stage: stage, image: refusedImage,
          anchor: negativeAnchor, reference: negativeReference, admission: admission,
          memory: memory, start: start, calls: maximum ? 1 : 0, body: body, commit: commit)
        // Normal worker join precedes ALL durable reads/restoration. Only the declared
        // fixture drift is restored; retained genuine positive input stays unchanged.
        if changesControl {
          try ownedT09ControlSwap(
            f, stage: stage, from: refusedImage, to: before,
            old: mutatedControl, new: beforeControl, body: body, commit: commit)
        } else if changesLink {
          try ownedT09LinkSwap(
            f, from: refusedImage, to: before, column: linkColumn,
            stage: stage, body: body, commit: commit)
        }
      }
      try ownedT09Checkpoint(f, stage: stage, image: before, body: body, commit: commit, allocations: 0)
      let start = memory.calls()
      guard start == negativeCalls else { throw FixtureFailure.nativeShape }
      let receipt: ProtocolOwnedProofWriteReceipt
      if single {
        first = ownedBindWriter(
          database: f.database, anchor: positiveAnchor, binding: positiveBinding,
          reference: referenceA, admission: admission, finished: firstFinished)
        receipt = first!.join()
      } else {
        inverse = ownedBindWriter(
          database: f.database, anchor: positiveAnchor, binding: positiveBinding,
          reference: referenceA, admission: admission, finished: inverseFinished)
        receipt = inverse!.join()
      }
      try ownedT09Committed(
        receipt, fixture: f, stage: stage, memory: memory, start: start,
        body: body, commit: commit, mutating: mutating)
      try ownedT09Redeem(
        receipt, fixture: f, stage: stage, anchor: positiveAnchor, binding: positiveBinding,
        reference: referenceA, observation: expectedObservation, admission: admission,
        memory: memory, allowed: true, body: body, commit: commit, mutating: mutating)
      guard memory.calls() == negativeCalls + 5 else { throw FixtureFailure.nativeShape }
      if let extra { try extra.close() }
      facts = OwnedT09Facts(
        rawControls: raw.count, negativeCalls: negativeCalls, positiveCalls: 4,
        successRedemptions: 1, refusalRedemptions: single ? 0 : 1,
        memoryCalls: memory.calls(), mutating: mutating, qualified: true)
    }
    // The primary pool, inspector, and physical root have torn down before facts escape.
    guard let facts else { throw FixtureFailure.nativeShape }
    return facts
  }

  @Test(NativeDBResources()) func ownedBindPrecheckoutRejectsOnlyExactContextAndMalformedExpectedReference()
    throws
  {
    let units: [OwnedT09Unit] = [
      .object, .fact, .account, .database, .hubBase, .device, .joined, .unlinked, .callerUserOrg,
      .boundUser, .boundOrg,
      .expected(""), .expected("secret:"), .expected("Secret:x"), .expected("other:x"),
      .expected(" secret:x"), .expected("secret:\u{0301}"),
      .expected("secret:x\u{0}y"), .expected("secret:x\u{0}"),
    ]
    for (index, unit) in units.enumerated() {
      let facts = try Self.ownedT09Unit(unit)
      #expect(facts.qualified && facts.rawControls == 4)
      #expect(facts.negativeCalls == 0 && facts.positiveCalls == 4)
      #expect(facts.successRedemptions == 1 && facts.refusalRedemptions == (index == 8 ? 0 : 1))
      #expect(facts.memoryCalls == 5)
      #expect(facts.mutating == !(index == 1 || index == 9 || index == 10))
    }
  }

  @Test(NativeDBResources()) func ownedBindNativePreRejectsExactEpochTupleAndReferenceDrift() throws {
    let units: [OwnedT09Unit] = [
      .store, .member, .revision, .missingControl, .extraKey, .version, .noncanonicalRevision,
      .nativeBase, .nativeDevice, .nativeJoined, .missingLink,
      .nativeReference("secret:OWNED_T09_NATIVE_B"),
      .nativeReference(""), .nativeReference("secret:"), .nativeReference("Secret:x"),
      .nativeReference("other:x"), .nativeReference(" secret:x"), .nativeReference("secret:\u{0301}"),
      .observation,
    ]
    for (index, unit) in units.enumerated() {
      let facts = try Self.ownedT09Unit(unit)
      #expect(facts.qualified && facts.rawControls == 4)
      #expect(facts.negativeCalls == 0 && facts.positiveCalls == 4)
      #expect(facts.successRedemptions == 1 && facts.refusalRedemptions == 1)
      #expect(facts.memoryCalls == 5 && facts.mutating == (index != 18))
    }
  }

  @Test(NativeDBResources()) func ownedBindUsesOriginalOpaqueReferenceBytesThroughOwnedWriter() throws {
    let units: [OwnedT09Unit] = [
      .opaque("secret:x", mismatch: nil), .opaque("secret:not-a-uuid", mismatch: nil),
      .opaque("secret:x ", mismatch: nil), .opaque("secret:\u{96EA}", mismatch: nil),
      .opaque("secret:\u{00E9}", mismatch: nil), .opaque("secret:e\u{0301}", mismatch: nil),
      .opaque("secret:\u{00E9}", mismatch: "secret:e\u{0301}"),
      .opaque("secret:e\u{0301}", mismatch: "secret:\u{00E9}"),
    ]
    for (index, unit) in units.enumerated() {
      let facts = try Self.ownedT09Unit(unit)
      #expect(facts.qualified && facts.rawControls == 4 && facts.mutating)
      #expect(facts.negativeCalls == 0 && facts.positiveCalls == 4)
      #expect(facts.successRedemptions == 1 && facts.refusalRedemptions == (index < 6 ? 0 : 1))
      #expect(facts.memoryCalls == 5)
    }
  }

  @Test(NativeDBResources()) func ownedBindNativeMaximumRevisionRefusesBeforeBodyWithoutRepair() throws {
    let facts = try Self.ownedT09Unit(.maximum)
    #expect(facts.qualified && facts.rawControls == 4 && facts.mutating)
    #expect(facts.negativeCalls == 1 && facts.positiveCalls == 4)
    #expect(facts.successRedemptions == 1 && facts.refusalRedemptions == 1)
    #expect(facts.memoryCalls == 6)
  }

  @Test(NativeDBResources()) func ownedBindRedemptionRetainsCapturedContextWithoutSnapshotInstanceIdentity()
    throws
  {
    let raw = try Self.ownedBindRawStageControls()
    guard raw.count == 4, raw.enumerated().allSatisfy({ $0.element.row == $0.offset && $0.element.qualified })
    else { throw FixtureFailure.nativeShape }
    var facts: OwnedT09Facts?
    try Self.withFixture { f in
      let inactive = try Self.validateFixture(f)
      let seed = try Self.ownedBindImage(f.inspector)
      let expected = try Self.ownedT09Bound(seed, inactive: inactive, binding: f.binding)
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      let equalAnchor = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      guard try Self.ownedBindImage(f.inspector) == seed else { throw FixtureFailure.nativeShape }
      let otherAccountAnchor = try f.database.captureProtocolVerification(
        accountID: "OWNED_PROOF_ACCOUNT_OTHER", expectedMembership: membership)
      guard try Self.ownedBindImage(f.inspector) == seed,
        let binDir = f.database.endpoint.binDir, !binDir.isEmpty, !binDir.utf8.contains(0)
      else { throw FixtureFailure.nativeShape }
      let extra = try WorkspaceDatabase(
        endpoint: f.database.endpoint, binDir: binDir, createIfMissing: false)
      defer { try? extra.close() }
      guard try Self.ownedBindImage(f.inspector) == seed else { throw FixtureFailure.nativeShape }
      let otherObjectAnchor = try extra.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      guard try Self.ownedBindImage(f.inspector) == seed else { throw FixtureFailure.nativeShape }
      let stage = try Self.ownedT09Freeze(
        f, before: seed, expected: expected.image, expectedControl: expected.control,
        reference: f.link.tokenRef)
      try Self.ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      guard body == OwnedBindProbe(last: 1, called: false),
        commit == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let finished = OwnedBindFinished()
      var writer: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      // Installed before first start, and runs before extra.close() on every early error.
      defer { if let writer { _ = writer.join() } }
      try Self.ownedT09Checkpoint(
        f, stage: stage, image: seed, body: body, commit: commit, allocations: 0)
      guard memory.calls() == 0 else { throw FixtureFailure.nativeShape }
      writer = Self.ownedBindWriter(
        database: f.database, anchor: f.anchor, binding: f.binding, reference: f.link.tokenRef,
        admission: admission, finished: finished)
      let receipt = writer!.join()
      try Self.ownedT09Committed(
        receipt, fixture: f, stage: stage, memory: memory, start: 0,
        body: body, commit: commit, mutating: true)
      // All three additional genuine captures preceded the one writer. Equal capture values
      // redeem regardless of struct-instance identity; account/object mismatches add no memory.
      let attempts: [(ProtocolVerificationSnapshot, Bool)] = [
        (f.anchor, true), (equalAnchor, true), (otherAccountAnchor, false),
        (f.anchor, true), (otherObjectAnchor, false), (equalAnchor, true),
      ]
      for (anchor, allowed) in attempts {
        try Self.ownedT09Redeem(
          receipt, fixture: f, stage: stage, anchor: anchor, binding: f.binding,
          reference: f.link.tokenRef, observation: nil, admission: admission,
          memory: memory, allowed: allowed, body: body, commit: commit, mutating: true)
      }
      guard memory.calls() == 8 else { throw FixtureFailure.nativeShape }
      try extra.close()
      facts = OwnedT09Facts(
        rawControls: raw.count, negativeCalls: 0, positiveCalls: 4, successRedemptions: 4,
        refusalRedemptions: 2, memoryCalls: memory.calls(), mutating: true, qualified: true)
    }
    guard let facts else { throw FixtureFailure.nativeShape }
    #expect(facts.qualified && facts.rawControls == 4 && facts.mutating)
    #expect(facts.negativeCalls == 0 && facts.positiveCalls == 4)
    #expect(facts.successRedemptions == 4 && facts.refusalRedemptions == 2)
    #expect(facts.memoryCalls == 8)
  }
}

// T11: inherited session settings, clock placement at an actual advisory wait, and native
// link-before-control contention. Only normal execute-return ACKs are credited. The memory
// comparison-to-COMMIT gap remains; callback joins do not assert Thread exit or native quiescence.
extension OwnedProtocolProofWriteTests {
  private enum OwnedT11Device { case local, nonlocal }

  // T11-only entered-region diagnostics: no native values or errors are retained here.
  // Mutated only by the synchronous caller; never passed into either native worker.
  private final class OwnedT11Diagnostic {
    enum Unit {
      case local
      case nonlocal

      var label: String {
        switch self {
        case .local: return "local"
        case .nonlocal: return "nonlocal"
        }
      }
    }
    enum RawRow {
      case none
      case imageReject
      case normalA
      case bodyFault
      case normalB

      var label: String {
        switch self {
        case .none: return "none"
        case .imageReject: return "imageReject"
        case .normalA: return "normalA"
        case .bodyFault: return "bodyFault"
        case .normalB: return "normalB"
        }
      }
    }
    enum Phase {
      case rawFour
      case rawFixture
      case rawValidate
      case rawFreeze
      case rawInstall
      case rawExpectedDamage
      case rawInitialImage
      case rawDriver
      case rawTeardown
      case rawFacts
      case targetFixture
      case targetValidate
      case targetFreeze
      case setupStampIdentity
      case catalogPrecheck
      case catalogAlter
      case inheritedConstruct
      case inheritedDeviceGuard
      case anchorCapture
      case ordinaryBaseline
      case ordinaryOutside
      case ordinaryBegin
      case ordinaryWrite
      case ordinaryAfter
      case ordinaryChecks
      case targetStageInstall
      case targetStageReady
      case holderReady
      case nativeWait
      case markerAndRelease
      case joinsAndHolderAck
      case markerReadback
      case receiptImageAndCounters
      case receiptRedemption
      case receiptNativeValidation
      case ordinaryRestoration
      case finalImageRecipe
      case inheritedBodyOutcome
      case extraClose
      case catalogRestore
      case outerFixtureTeardown
      case facts

      var label: String {
        switch self {
        case .rawFour: return "rawFour"
        case .rawFixture: return "rawFixture"
        case .rawValidate: return "rawValidate"
        case .rawFreeze: return "rawFreeze"
        case .rawInstall: return "rawInstall"
        case .rawExpectedDamage: return "rawExpectedDamage"
        case .rawInitialImage: return "rawInitialImage"
        case .rawDriver: return "rawDriver"
        case .rawTeardown: return "rawTeardown"
        case .rawFacts: return "rawFacts"
        case .targetFixture: return "targetFixture"
        case .targetValidate: return "targetValidate"
        case .targetFreeze: return "targetFreeze"
        case .setupStampIdentity: return "setupStampIdentity"
        case .catalogPrecheck: return "catalogPrecheck"
        case .catalogAlter: return "catalogAlter"
        case .inheritedConstruct: return "inheritedConstruct"
        case .inheritedDeviceGuard: return "inheritedDeviceGuard"
        case .anchorCapture: return "anchorCapture"
        case .ordinaryBaseline: return "ordinaryBaseline"
        case .ordinaryOutside: return "ordinaryOutside"
        case .ordinaryBegin: return "ordinaryBegin"
        case .ordinaryWrite: return "ordinaryWrite"
        case .ordinaryAfter: return "ordinaryAfter"
        case .ordinaryChecks: return "ordinaryChecks"
        case .targetStageInstall: return "targetStageInstall"
        case .targetStageReady: return "targetStageReady"
        case .holderReady: return "holderReady"
        case .nativeWait: return "nativeWait"
        case .markerAndRelease: return "markerAndRelease"
        case .joinsAndHolderAck: return "joinsAndHolderAck"
        case .markerReadback: return "markerReadback"
        case .receiptImageAndCounters: return "receiptImageAndCounters"
        case .receiptRedemption: return "receiptRedemption"
        case .receiptNativeValidation: return "receiptNativeValidation"
        case .ordinaryRestoration: return "ordinaryRestoration"
        case .finalImageRecipe: return "finalImageRecipe"
        case .inheritedBodyOutcome: return "inheritedBodyOutcome"
        case .extraClose: return "extraClose"
        case .catalogRestore: return "catalogRestore"
        case .outerFixtureTeardown: return "outerFixtureTeardown"
        case .facts: return "facts"
        }
      }
    }
    enum Outcome {
      case notReached
      case succeeded
      case failed

      var label: String {
        switch self {
        case .notReached: return "notReached"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
      }
    }
    enum OuterScope {
      case pending
      case unwound

      var label: String {
        switch self {
        case .pending: return "pending"
        case .unwound: return "unwound"
        }
      }
    }

    let unit: Unit
    var rawRow: RawRow = .none
    var phase: Phase = .rawFour
    var firstFailure: Phase?
    var inheritedBody: Outcome = .notReached
    var extraClose: Outcome = .notReached
    var catalogRestore: Outcome = .notReached
    var outerScope: OuterScope = .pending

    init(_ device: OwnedT11Device) {
      switch device {
      case .local: unit = .local
      case .nonlocal: unit = .nonlocal
      }
    }

    func selectRawRow(_ row: OwnedBindRawControl) {
      switch row {
      case .imageReject: rawRow = .imageReject
      case .normalA: rawRow = .normalA
      case .bodyFault: rawRow = .bodyFault
      case .normalB: rawRow = .normalB
      }
    }

    func rememberFailure() {
      if firstFailure == nil { firstFailure = phase }
    }

    // This line is constructed only after the entire failing helper has unwound.
    var failureLine: String {
      "OWNED_T11_DIAGNOSTIC unit=\(unit.label) rawRow=\(rawRow.label) phase=\(phase.label) firstFailure=\((firstFailure ?? phase).label) inheritedBody=\(inheritedBody.label) extraClose=\(extraClose.label) catalogRestore=\(catalogRestore.label) outerScope=\(outerScope.label)"
    }
  }

  // Only these fixed primitive facts escape the completed outer fixture teardown.
  private struct OwnedT11Facts {
    let rawControls: Int
    let nativeWaits: Int
    let writerCalls: Int
    let redemptionCalls: Int
    let normalHolders: Int
    let normalContenders: Int
    let body: Int
    let deferred: Int
    let settingsRestored: Bool
    let qualified: Bool
  }

  private struct OwnedT11SessionSettings {
    let defaultIsolation: String
    let isolation: String
    let lock: String
    let statement: String
    let hlc: String?
    let device: String?

    var unset: Bool { (hlc == nil || hlc == "") && (device == nil || device == "") }
  }

  private static func ownedT11Settings(_ c: PostgresConnection) throws -> OwnedT11SessionSettings {
    let rows = try c.execute(
      """
      SELECT current_setting('default_transaction_isolation') AS default_isolation,
        current_setting('transaction_isolation') AS isolation,
        current_setting('lock_timeout') AS lock_budget,
        current_setting('statement_timeout') AS statement_budget,
        current_setting('b4app.hlc',true) AS hlc,
        current_setting('b4app.device_id',true) AS device
      """
    ).rows
    guard rows.count == 1, let row = rows.first,
      let defaults = row.text("default_isolation"), let isolation = row.text("isolation"),
      let lock = row.text("lock_budget"), let statement = row.text("statement_budget")
    else { throw FixtureFailure.nativeShape }
    return OwnedT11SessionSettings(
      defaultIsolation: defaults, isolation: isolation, lock: lock, statement: statement,
      hlc: row.text("hlc"), device: row.text("device"))
  }

  private static func ownedT11OrdinarySettings(
    _ database: WorkspaceDatabase, expected: OwnedT11SessionSettings? = nil,
    diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> (settings: OwnedT11SessionSettings, highWater: HLC) {
    diagnostic?.phase = .ordinaryOutside
    let outside = try database.read { try ownedT11Settings($0) }
    guard outside.defaultIsolation == "repeatable read", outside.isolation == "repeatable read",
      outside.unset
    else { throw FixtureFailure.nativeShape }
    if let expected {
      guard equalBytes(outside.lock, expected.lock), equalBytes(outside.statement, expected.statement)
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic?.phase = .ordinaryBegin
    let begun = try database.read { c in
      var beginAttempted = false
      var rollbackAcknowledged = false
      defer {
        if beginAttempted && !rollbackAcknowledged { _ = try? c.execute("ROLLBACK") }
      }
      beginAttempted = true
      try c.execute("BEGIN READ ONLY")
      let result = try ownedT11Settings(c)
      try c.execute("ROLLBACK")
      rollbackAcknowledged = true
      return result
    }
    // This is the actual ordinary write API. Its body contains only a settings SELECT.
    diagnostic?.phase = .ordinaryWrite
    let written = try database.write { try ownedT11Settings($0) }
    diagnostic?.phase = .ordinaryAfter
    let after = try database.read { try ownedT11Settings($0) }
    diagnostic?.phase = .ordinaryChecks
    for value in [begun, written, after] {
      guard value.defaultIsolation == "repeatable read", value.isolation == "repeatable read",
        equalBytes(value.lock, outside.lock), equalBytes(value.statement, outside.statement)
      else { throw FixtureFailure.nativeShape }
    }
    guard begun.unset, after.unset, let text = written.hlc, let stamp = HLC(rawValue: text),
      equalBytes(stamp.rawValue, text), equalBytes(stamp.deviceId, database.deviceId),
      equalBytes(database.clock.deviceId, database.deviceId)
    else { throw FixtureFailure.nativeShape }
    if equalBytes(database.deviceId, "local") {
      guard written.device == nil || written.device == "" else { throw FixtureFailure.nativeShape }
    } else {
      guard let device = written.device, equalBytes(device, database.deviceId) else {
        throw FixtureFailure.nativeShape
      }
    }
    return (outside, stamp)
  }

  private static func ownedT11Catalog(_ c: PostgresConnection, database: String) throws -> [Data] {
    try c.execute(
      """
      SELECT to_jsonb(s)::text AS value FROM pg_catalog.pg_db_role_setting s
      JOIN pg_catalog.pg_database d ON d.oid=s.setdatabase
      WHERE d.datname=$1 ORDER BY s.setrole
      """, [database]
    ).rows.map { row in
      guard let text = row.text("value") else { throw FixtureFailure.nativeShape }
      return try ownedBindJSON(text)
    }
  }

  // Remove ONLY the database-wide isolation member from a private comparison image. Removing
  // its last member removes that comparison row, matching RESET's actual catalog representation.
  // All role-specific rows, other keys, array order, and native database OIDs remain intact.
  private static func ownedT11WithoutIsolation(_ image: [Data], count: Int) throws -> [Data] {
    var found = 0
    var result: [Data] = []
    for data in image {
      var row = try ownedT09Object(data)
      guard let role = row["setrole"] as? String, let roleOID = UInt32(role),
        equalBytes(role, String(roleOID)), let config = row["setconfig"] as? [String]
      else { throw FixtureFailure.nativeShape }
      if equalBytes(role, "0") {
        var retained: [String] = []
        for entry in config {
          if entry.split(separator: "=", maxSplits: 1).first == "default_transaction_isolation" {
            found += 1
            guard equalBytes(entry, "default_transaction_isolation=repeatable read") else {
              throw FixtureFailure.nativeShape
            }
          } else {
            retained.append(entry)
          }
        }
        if retained.isEmpty && !config.isEmpty { continue }
        row["setconfig"] = retained
      }
      result.append(try ownedT09Data(row))
    }
    guard found == count else { throw FixtureFailure.nativeShape }
    return result
  }

  private static func ownedT11WithInheritedDatabase(
    _ f: Fixture, device: OwnedT11Device, diagnostic: OwnedT11Diagnostic? = nil,
    _ body: (WorkspaceDatabase, ProtocolVerificationSnapshot, OwnedT11SessionSettings, HLC) throws -> Void
  ) throws {
    diagnostic?.phase = .catalogPrecheck
    let endpoint = f.database.endpoint
    guard let binDir = endpoint.binDir, !binDir.isEmpty, !binDir.utf8.contains(0),
      !endpoint.database.isEmpty, !endpoint.database.utf8.contains(0),
      equalBytes(endpoint.database, f.binding.databaseName)
    else { throw FixtureFailure.nativeShape }
    let before = try ownedT11Catalog(f.inspector, database: endpoint.database)
    let absent = try f.inspector.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_db_role_setting s
      JOIN pg_catalog.pg_database d ON d.oid=s.setdatabase,
      LATERAL unnest(s.setconfig) AS v(value)
      WHERE d.datname=$1 AND s.setrole=0
        AND split_part(v.value,'=',1)='default_transaction_isolation'
      """, [endpoint.database]
    ).rows
    guard absent.count == 1, absent[0].int("n") == 0,
      try ownedT11WithoutIsolation(before, count: 0) == before
    else { throw FixtureFailure.nativeShape }
    let businessBefore = try ownedBindImage(f.inspector)
    let quoted = Rows.quote(endpoint.database)
    var alterAttempted = false
    var extra: WorkspaceDatabase?
    var settled = false
    // Registered BEFORE ALTER, including its partial-failure/ACK-uncertain path. This emergency
    // fallback never supplies positive cleanup credit, and a close error cannot skip RESET.
    defer {
      if !settled {
        if let extra { try? extra.close() }
        if alterAttempted {
          _ = try? f.inspector.execute("ALTER DATABASE \(quoted) RESET default_transaction_isolation")
          _ = try? ownedT11Catalog(f.inspector, database: endpoint.database)
        }
      }
    }
    let outcome = Result<Void, any Error> {
      diagnostic?.phase = .catalogAlter
      alterAttempted = true
      try f.inspector.execute(
        "ALTER DATABASE \(quoted) SET default_transaction_isolation TO 'repeatable read'")
      let changed = try ownedT11Catalog(f.inspector, database: endpoint.database)
      guard try ownedT11WithoutIsolation(changed, count: 1) == before else {
        throw FixtureFailure.nativeShape
      }
      // Same actual endpoint and binDir; no original-pool session is changed or replaced.
      diagnostic?.phase = .inheritedConstruct
      let actual = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, createIfMissing: false)
      extra = actual
      diagnostic?.phase = .inheritedDeviceGuard
      guard try ownedBindImage(f.inspector) == businessBefore,
        equalBytes(actual.deviceId, "local"), equalBytes(actual.clock.deviceId, "local")
      else { throw FixtureFailure.nativeShape }
      switch device {
      case .local: break
      case .nonlocal: actual.deviceId = f.link.deviceId
      }
      let expectedDevice: String
      switch device {
      case .local: expectedDevice = "local"
      case .nonlocal: expectedDevice = f.link.deviceId
      }
      guard !actual.deviceId.isEmpty, !actual.deviceId.utf8.contains(0),
        equalBytes(actual.deviceId, expectedDevice),
        equalBytes(actual.deviceId, actual.clock.deviceId)
      else { throw FixtureFailure.nativeShape }
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      // Constructor and setter call no next/observe. This genuine capture calls ordinary write
      // exactly once; existing control means no business DML. The following ordinary write's
      // observed stamp bounds that earlier stamp by HybridClock.next's strict monotonicity.
      diagnostic?.phase = .anchorCapture
      let anchor = try actual.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      guard try ownedBindImage(f.inspector) == businessBefore else { throw FixtureFailure.nativeShape }
      diagnostic?.phase = .ordinaryBaseline
      let ordinary = try ownedT11OrdinarySettings(actual, diagnostic: diagnostic)
      guard try ownedBindImage(f.inspector) == businessBefore else { throw FixtureFailure.nativeShape }
      try body(actual, anchor, ordinary.settings, ordinary.highWater)
    }
    // Freeze the first entered failure region before settlement labels can replace it.
    switch outcome {
    case .success: diagnostic?.inheritedBody = .succeeded
    case .failure:
      diagnostic?.inheritedBody = .failed
      diagnostic?.rememberFailure()
    }
    diagnostic?.phase = .inheritedBodyOutcome
    // Evaluate ALL settlements before propagating any error, even the declared close error.
    diagnostic?.phase = .extraClose
    let closeOutcome = Result<Void, any Error> { if let extra { try extra.close() } }
    switch closeOutcome {
    case .success: diagnostic?.extraClose = .succeeded
    case .failure:
      diagnostic?.extraClose = .failed
      diagnostic?.rememberFailure()
    }
    diagnostic?.phase = .catalogRestore
    let restoreOutcome = Result<Void, any Error> {
      if alterAttempted {
        try f.inspector.execute("ALTER DATABASE \(quoted) RESET default_transaction_isolation")
        guard try ownedT11Catalog(f.inspector, database: endpoint.database) == before else {
          throw FixtureFailure.nativeShape
        }
      }
    }
    switch restoreOutcome {
    case .success: diagnostic?.catalogRestore = .succeeded
    case .failure:
      diagnostic?.catalogRestore = .failed
      diagnostic?.rememberFailure()
    }
    guard case .success = closeOutcome, case .success = restoreOutcome else {
      throw FixtureFailure.redactedFailure
    }
    settled = true
    guard case .success = outcome else { throw FixtureFailure.redactedFailure }
  }

  private static func ownedT11Stage(
    _ stage: OwnedBindStageFixture, database: WorkspaceDatabase
  ) throws -> OwnedBindStageFixture {
    let device = database.deviceId
    guard !device.isEmpty, !device.utf8.contains(0), equalBytes(device, database.clock.deviceId) else {
      throw FixtureFailure.nativeShape
    }
    // Adapt only the expected transaction device; retain the independent full S0/S1 and binding.
    return OwnedBindStageFixture(
      before: stage.before, expected: stage.expected, controlJSON: stage.controlJSON,
      originalReference: stage.originalReference, replacement: stage.replacement,
      device: device, lowerWall: stage.lowerWall)
  }

  private static func ownedT11SetupStamps(_ image: OwnedBindImage) throws -> [HLC] {
    var stamps: [HLC] = []
    // These are the schema's actual stamp columns. User-content strings are never parsed as HLCs.
    for table in ["changes", "columnClocks"] {
      guard let rows = image.rows[table] else { throw FixtureFailure.nativeShape }
      for data in rows {
        let row = try ownedT09Object(data)
        guard let text = row["hlc"] as? String, let stamp = HLC(rawValue: text),
          equalBytes(stamp.rawValue, text)
        else { throw FixtureFailure.nativeShape }
        stamps.append(stamp)
      }
    }
    return stamps
  }

  private static func ownedT11MarkerObserved(
    _ c: PostgresConnection, stage: OwnedBindStageFixture, expected: HLC, marker: UInt64
  ) throws {
    let rows = try c.execute(
      "SELECT isolation,lock_budget,statement_budget,hlc,device FROM \"owned_bind_stage\".\"observed\""
    ).rows
    // Caller has joined EVERY operation before this independent native wall sample or body read.
    let upper = try ownedBindWall(c)
    guard upper < marker, expected.millis == marker, expected.counter == 1,
      rows.count == 1, let row = rows.first, let text = row.text("hlc"),
      let actual = HLC(rawValue: text), equalBytes(actual.rawValue, text),
      equalBytes(actual.rawValue, expected.rawValue), equalBytes(actual.deviceId, stage.device),
      equalBytes(expected.deviceId, stage.device), actual.millis >= stage.lowerWall,
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
  }

  private static func ownedT11Current(
    _ receipt: ProtocolOwnedProofWriteReceipt, database: WorkspaceDatabase,
    anchor: ProtocolVerificationSnapshot, binding: ProtocolMembershipBinding, reference: String,
    inspector: PostgresConnection, stage: OwnedBindStageFixture,
    admission: ProtocolProofMemoryAdmission, memory: OwnedBindMemory,
    body: OwnedBindProbe, commit: OwnedBindProbe, diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> (calls: Int, redemption: Int) {
    diagnostic?.phase = .receiptImageAndCounters
    let beforeRedemption = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == .committedCurrent,
      beforeRedemption == 4, equalBytes(reference, stage.originalReference),
      try ownedBindImage(inspector) == stage.expected,
      try ownedBindProbe(inspector, "body_probe").advanced(from: body, by: 1),
      try ownedBindProbe(inspector, "commit_probe").advanced(from: commit, by: 1)
    else { throw FixtureFailure.nativeShape }
    try ownedT09Recipe(inspector, stage: stage)
    // Redemption is sealed-context plus memory only. The following actual-object API calls
    // independently validate native facts; redemption itself makes no native-currentness claim.
    diagnostic?.phase = .receiptRedemption
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
    let afterRedemption = memory.calls()
    guard afterRedemption - beforeRedemption == 1, successor.observation == nil else {
      throw FixtureFailure.nativeShape
    }
    diagnostic?.phase = .receiptNativeValidation
    try database.validateProtocolVerification(expectedSnapshot: successor)
    try database.compareOriginalLinkedCaptureOwner(
      expectedSnapshot: successor, accountID: binding.accountID,
      databaseName: binding.databaseName, hubBase: base)
    try database.compareOriginalLinkedCredentialReference(
      expectedSnapshot: successor, expectedTokenRef: reference)
    guard try ownedBindImage(inspector) == stage.expected else { throw FixtureFailure.nativeShape }
    try ownedT09Recipe(inspector, stage: stage)
    return (beforeRedemption, afterRedemption - beforeRedemption)
  }

  private static func ownedT11RawControls(diagnostic: OwnedT11Diagnostic? = nil) throws -> Int {
    diagnostic?.phase = .rawFour
    let rows = try ownedBindRawStageControls(diagnostic: diagnostic)
    guard rows.count == 4 else { throw FixtureFailure.nativeShape }
    for (index, row) in rows.enumerated() {
      guard row.row == index, row.qualified else { throw FixtureFailure.nativeShape }
    }
    return rows.count
  }

  private static func ownedT11Identity(_ f: Fixture) throws -> (pid: Int, user: String, binDir: String) {
    let endpoint = f.database.endpoint
    let rows = try f.inspector.execute(
      "SELECT pg_catalog.pg_backend_pid() AS pid,current_database() AS database,current_user AS username"
    ).rows
    guard rows.count == 1, let pid = rows[0].int("pid"), pid > 0,
      let database = rows[0].text("database"), equalBytes(database, endpoint.database),
      let user = rows[0].text("username"), equalBytes(user, NSUserName()),
      let binDir = endpoint.binDir, !binDir.isEmpty, !binDir.utf8.contains(0), endpoint.port > 0,
      [endpoint.socketDir, endpoint.database, user].allSatisfy({ value in
        !value.isEmpty && !value.utf8.contains(0) && !value.contains(where: { $0.isWhitespace })
          && !value.contains("'") && !value.contains("\\")
      })
    else { throw FixtureFailure.nativeShape }
    return (pid, user, binDir)
  }

  private static func ownedT11SettingsUnit(
    _ device: OwnedT11Device, diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> OwnedT11Facts {
    // No prerequisite borrowing: all four fresh raw fixtures finish teardown BEFORE this target.
    let raw = try ownedT11RawControls(diagnostic: diagnostic)
    diagnostic?.rawRow = .none
    diagnostic?.phase = .targetFixture
    var facts: OwnedT11Facts?
    try withFixture { f in
      diagnostic?.phase = .targetValidate
      let predecessor = try validateFixture(f)
      diagnostic?.phase = .targetFreeze
      let frozen = try ownedBindFreeze(f, predecessor: predecessor, replacement: f.link.tokenRef)
      diagnostic?.phase = .setupStampIdentity
      let setupStamps = try ownedT11SetupStamps(frozen.before)
      let identity = try ownedT11Identity(f)
      let endpoint = f.database.endpoint
      var completed: (calls: Int, redemption: Int)?
      try ownedT11WithInheritedDatabase(f, device: device, diagnostic: diagnostic) {
        database, anchor, ordinary, highWater in
        diagnostic?.phase = .targetStageInstall
        let stage = try ownedT11Stage(frozen, database: database)
        try ownedBindInstall(f, stage: stage, rawBodyFault: false)
        let body = try ownedBindProbe(f.inspector, "body_probe")
        let commit = try ownedBindProbe(f.inspector, "commit_probe")
        guard body == OwnedBindProbe(last: 1, called: false),
          commit == OwnedBindProbe(last: 1, called: false)
        else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .targetStageReady
        try ownedT09Recipe(f.inspector, stage: stage)
        try ownedBindWriterReady(
          f, stage: stage, replacement: stage.originalReference, body: body, commit: commit)
        let memory = OwnedBindMemory(selected: nil)
        let admission = ProtocolProofMemoryAdmission { [memory] in
          let allowed = memory.compare()
          if !allowed { throw FixtureFailure.redactedFailure }
        }
        let hold = OwnedProofHold()
        let state = OwnedBindHolderState()
        let finished = OwnedBindFinished()
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        var writer: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
        // Installed before the first start. All holds release before EVERY retained join.
        defer {
          hold.release()
          if let holder { _ = holder.join() }
          if let writer { _ = writer.join() }
        }
        diagnostic?.phase = .holderReady
        let application = "owned-t11-advisory-\(UUID().uuidString)"
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        holder = ownedBindHolder(
          binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: identity.user, application: application,
          kind: .advisory, hold: hold, state: state)
        let holderPID = try ownedBindHolderReady(state, hold: hold, deadline: readiness)
        guard memory.calls() == 0 else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .nativeWait
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        writer = ownedBindWriter(
          database: database, anchor: anchor, binding: f.binding, reference: stage.originalReference,
          admission: admission, finished: finished)
        try ownedBindObserveWait(
          f.inspector, database: endpoint.database, holderPID: holderPID,
          knownOwnedPIDs: [identity.pid, holderPID], kind: .advisory, hold: hold,
          finished: finished, memory: memory, invocationStart: 0, deadline: deadline)
        diagnostic?.phase = .markerAndRelease
        let now = try ownedBindWall(f.inspector)
        let sampleEnd = DispatchTime.now().uptimeNanoseconds
        let (markerMillis, overflow) = now.addingReportingOverflow(10_000)
        guard sampleEnd <= deadline, !overflow, markerMillis <= 0xffff_ffff_ffff,
          markerMillis > highWater.millis, markerMillis > stage.lowerWall,
          setupStamps.allSatisfy({ $0.millis < markerMillis }),
          equalBytes(highWater.deviceId, stage.device), memory.calls() == 0,
          finished.pending(), hold.heldUnexpired()
        else { throw FixtureFailure.nativeShape }
        let marker = HLC(millis: markerMillis, counter: 0, deviceId: stage.device)
        let expectedBody = HLC(millis: markerMillis, counter: 1, deviceId: stage.device)
        // All prior ACTUAL extra stamps are capture's one next and the later SELECT-only
        // ordinary write's observed high water. No other extra next/observe occurs before here.
        database.clock.observe(marker)
        // No SQL, next, write, or scheduling between injection and prompt original-deadline release.
        try ownedBindReleaseObservedHold(
          hold, finished: finished, memory: memory, invocationStart: 0, retiring: false,
          deadline: deadline)
        diagnostic?.phase = .joinsAndHolderAck
        let held = holder!.join()
        let receipt = writer!.join()
        guard held.normal else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .markerReadback
        try ownedT11MarkerObserved(
          f.inspector, stage: stage, expected: expectedBody, marker: markerMillis)
        let current = try ownedT11Current(
          receipt, database: database, anchor: anchor, binding: f.binding,
          reference: stage.originalReference, inspector: f.inspector, stage: stage,
          admission: admission, memory: memory, body: body, commit: commit, diagnostic: diagnostic)
        // This new ordinary next is strictly AFTER body-marker read and genuine redemption.
        diagnostic?.phase = .ordinaryRestoration
        _ = try ownedT11OrdinarySettings(database, expected: ordinary, diagnostic: diagnostic)
        diagnostic?.phase = .finalImageRecipe
        guard try ownedBindImage(f.inspector) == stage.expected,
          try ownedBindProbe(f.inspector, "body_probe").advanced(from: body, by: 1),
          try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commit, by: 1)
        else { throw FixtureFailure.nativeShape }
        try ownedT09Recipe(f.inspector, stage: stage)
        completed = current
      }
      // The helper has checked extra-close AND exact complete catalog restoration before here.
      guard let completed else { throw FixtureFailure.nativeShape }
      facts = OwnedT11Facts(
        rawControls: raw, nativeWaits: 1, writerCalls: completed.calls,
        redemptionCalls: completed.redemption, normalHolders: 1, normalContenders: 0,
        body: 1, deferred: 1, settingsRestored: true, qualified: true)
      diagnostic?.phase = .outerFixtureTeardown
    }
    diagnostic?.phase = .facts
    guard let facts else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private final class OwnedT11ContenderState: Sendable {
    struct Facts: Sendable {
      var pid = 0
      var started = false
      var returned = false
    }
    private let facts = Mutex(Facts())
    func publish(pid: Int) {
      facts.withLock {
        $0.pid = pid
        $0.started = true
      }
    }
    func markReturned() { facts.withLock { $0.returned = true } }
    func snapshot() -> Facts { facts.withLock { $0 } }
  }

  private struct OwnedT11ContenderResult: Sendable {
    let acquired: Bool
    let rollbackAcknowledged: Bool
    var normal: Bool { acquired && rollbackAcknowledged }
    static let invalid = Self(acquired: false, rollbackAcknowledged: false)
  }

  private static func ownedT11ControlHolder(
    binDir: String, socketDir: String, port: Int, database: String, user: String,
    application: String, controlKey: String, hold: OwnedProofHold, state: OwnedBindHolderState
  ) -> OwnedProofNativeWork<OwnedBindHolderResult> {
    OwnedProofNativeWork {
      [binDir, socketDir, port, database, user, application, controlKey, hold, state] in
      do {
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: binDir),
          connectionString:
            "host=\(socketDir) port=\(port) user=\(user) dbname=\(database) application_name=\(application)")
        var beginAttempted = false
        var rollbackAcknowledged = false
        defer {
          if beginAttempted && !rollbackAcknowledged { _ = try? c.execute("ROLLBACK") }
        }
        beginAttempted = true
        try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        try c.execute("SET LOCAL lock_timeout='2s'")
        try c.execute("SET LOCAL statement_timeout='2s'")
        let identity = try c.execute("SELECT pg_catalog.pg_backend_pid() AS pid").rows
        guard identity.count == 1, let pid = identity[0].int("pid"), pid > 0 else {
          return .invalid
        }
        // ONLY the exact settings tuple. This holder takes neither advisory nor link locks.
        let rows = try c.execute(
          "SELECT key FROM public.settings WHERE key=$1 FOR UPDATE", [controlKey]
        ).rows
        guard rows.count == 1, let actual = rows[0].text("key"), equalBytes(actual, controlKey) else {
          return .invalid
        }
        state.acquired(pid: pid)
        let released = hold.wait()
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        let final = hold.snapshot()
        return OwnedBindHolderResult(
          acquired: true, released: released && final.released, expired: final.expired,
          rollbackAcknowledged: rollbackAcknowledged)
      } catch {
        return .invalid
      }
    }
  }

  private static func ownedT11LinkContender(
    binDir: String, socketDir: String, port: Int, database: String, user: String,
    application: String, state: OwnedT11ContenderState
  ) -> OwnedProofNativeWork<OwnedT11ContenderResult> {
    OwnedProofNativeWork { [binDir, socketDir, port, database, user, application, state] in
      defer { state.markReturned() }
      do {
        // This actual connection never leaves its worker or enters a captured value.
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: binDir),
          connectionString:
            "host=\(socketDir) port=\(port) user=\(user) dbname=\(database) application_name=\(application)")
        var beginAttempted = false
        var rollbackAcknowledged = false
        defer {
          if beginAttempted && !rollbackAcknowledged { _ = try? c.execute("ROLLBACK") }
        }
        beginAttempted = true
        try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        try c.execute("SET LOCAL lock_timeout='2s'")
        try c.execute("SET LOCAL statement_timeout='2s'")
        let identity = try c.execute("SELECT pg_catalog.pg_backend_pid() AS pid").rows
        guard identity.count == 1, let pid = identity[0].int("pid"), pid > 0 else {
          return .invalid
        }
        // Publish the real identity AFTER BEGIN+budgets, BEFORE the exact blocking SELECT.
        state.publish(pid: pid)
        let rows = try c.execute("SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE").rows
        guard rows.count == 1, rows[0].int("id") == 1 else { return .invalid }
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        return OwnedT11ContenderResult(acquired: true, rollbackAcknowledged: rollbackAcknowledged)
      } catch {
        return .invalid
      }
    }
  }

  // Exact composed production query after Swift multiline indentation stripping, including the
  // scalar control FOR UPDATE. Compare full equality in pg_stat_activity, never LIKE/contains.
  private static let ownedT11ControlQuery = """
    SELECT current_database() AS database,
      (SELECT value::text FROM public.settings WHERE key=$1 FOR UPDATE) AS control,
      l.id AS native_link_id, l.url, l."deviceId" AS device, l."joinedAt" AS joined,
      l."tokenRef" AS native_token_ref
    FROM (SELECT 1) singleton LEFT JOIN public."hubLink" l ON l.id=1
    """

  private static let ownedT11ControlWait = """
    SELECT a.pid::text AS pid FROM pg_catalog.pg_stat_activity a
    WHERE a.datname=$1 AND a.usename=current_user AND a.application_name='b4app'
      AND a.backend_type='client backend' AND a.pid<>pg_backend_pid()
      AND a.pid<>$2::int AND NOT(a.pid=ANY($5::int[]))
      AND a.state='active' AND a.wait_event_type='Lock' AND a.query=$4
      AND $2::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks g WHERE g.pid=a.pid
        AND g.database=(SELECT oid FROM pg_catalog.pg_database WHERE datname=$1)
        AND g.locktype='advisory' AND g.mode='ExclusiveLock' AND g.granted
        AND g.classid=0::oid AND g.objid=$3::oid AND g.objsubid=1)
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks w WHERE w.pid=a.pid AND NOT w.granted
        AND ((w.locktype='transactionid' AND w.mode='ShareLock'
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$2::int
            AND h.locktype='transactionid' AND h.mode='ExclusiveLock' AND h.granted
            AND h.transactionid=w.transactionid))
        OR (w.locktype='tuple' AND w.relation='public.settings'::pg_catalog.regclass
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$2::int
            AND h.locktype='tuple' AND h.granted AND h.database=w.database
            AND h.relation=w.relation AND h.page=w.page AND h.tuple=w.tuple))))
    """

  private static let ownedT11ContenderWait = """
    SELECT a.pid::text AS pid FROM pg_catalog.pg_stat_activity a
    WHERE a.pid=$1::int AND a.datname=$2 AND a.usename=current_user
      AND a.application_name=$3 AND a.backend_type='client backend'
      AND a.state='active' AND a.wait_event_type='Lock' AND a.query=$4
      AND $5::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks w WHERE w.pid=a.pid AND NOT w.granted
        AND ((w.locktype='transactionid' AND w.mode='ShareLock'
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$5::int
            AND h.locktype='transactionid' AND h.mode='ExclusiveLock' AND h.granted
            AND h.transactionid=w.transactionid))
        OR (w.locktype='tuple' AND w.relation='public."hubLink"'::pg_catalog.regclass
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks h WHERE h.pid=$5::int
            AND h.locktype='tuple' AND h.granted AND h.database=w.database
            AND h.relation=w.relation AND h.page=w.page AND h.tuple=w.tuple))))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_stat_activity wa
        WHERE wa.pid=$5::int AND wa.datname=$2 AND wa.usename=current_user
          AND wa.application_name='b4app' AND wa.backend_type='client backend'
          AND wa.pid<>pg_backend_pid() AND wa.pid<>$6::int
          AND NOT(wa.pid=ANY($9::int[]))
          AND wa.state='active' AND wa.wait_event_type='Lock' AND wa.query=$8
          AND $6::int=ANY(pg_catalog.pg_blocking_pids(wa.pid))
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks wg WHERE wg.pid=wa.pid
            AND wg.database=(SELECT oid FROM pg_catalog.pg_database WHERE datname=$2)
            AND wg.locktype='advisory' AND wg.mode='ExclusiveLock' AND wg.granted
            AND wg.classid=0::oid AND wg.objid=$7::oid AND wg.objsubid=1)
          AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks ww WHERE ww.pid=wa.pid AND NOT ww.granted
            AND ((ww.locktype='transactionid' AND ww.mode='ShareLock'
              AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks wh WHERE wh.pid=$6::int
                AND wh.locktype='transactionid' AND wh.mode='ExclusiveLock' AND wh.granted
                AND wh.transactionid=ww.transactionid))
            OR (ww.locktype='tuple' AND ww.relation='public.settings'::pg_catalog.regclass
              AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks wh WHERE wh.pid=$6::int
                AND wh.locktype='tuple' AND wh.granted AND wh.database=ww.database
                AND wh.relation=ww.relation AND wh.page=ww.page AND wh.tuple=ww.tuple)))))
    """

  private static func ownedT11ObserveControl(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedBindMemory, deadline: UInt64
  ) throws -> Int {
    guard holderPID > 0, knownOwnedPIDs.contains(holderPID),
      !knownOwnedPIDs.isEmpty, knownOwnedPIDs.allSatisfy({ $0 > 0 })
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard finished.pending(), hold.heldUnexpired(), memory.calls() == 0 else {
        throw FixtureFailure.nativeShape
      }
      let rows = try c.execute(
        ownedT11ControlWait,
        [
          database, String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey),
          ownedT11ControlQuery, excluded,
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(),
        hold.heldUnexpired(), memory.calls() == 0
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid)
        else { throw FixtureFailure.nativeShape }
        return pid
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedT11ContenderReady(
    _ state: OwnedT11ContenderState, hold: OwnedProofHold, finished: OwnedBindFinished,
    memory: OwnedBindMemory, deadline: UInt64
  ) throws -> Int {
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let value = state.snapshot()
      let held = hold.heldUnexpired()
      let pending = finished.pending()
      let calls = memory.calls()
      let end = DispatchTime.now().uptimeNanoseconds
      guard end <= deadline, held, pending, calls == 0, !value.returned else {
        throw FixtureFailure.nativeShape
      }
      if value.started && value.pid > 0 { return value.pid }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedT11ObserveContender(
    _ c: PostgresConnection, database: String, application: String, contenderPID: Int,
    writerPID: Int, holderPID: Int, knownOwnedPIDs: [Int], hold: OwnedProofHold,
    finished: OwnedBindFinished, contender: OwnedT11ContenderState,
    memory: OwnedBindMemory, deadline: UInt64
  ) throws {
    guard contenderPID > 0, writerPID > 0, holderPID > 0, writerPID != contenderPID,
      knownOwnedPIDs.contains(contenderPID), knownOwnedPIDs.contains(holderPID),
      !knownOwnedPIDs.contains(writerPID), knownOwnedPIDs.allSatisfy({ $0 > 0 })
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let before = contender.snapshot()
      guard before.started, before.pid == contenderPID, !before.returned,
        finished.pending(), hold.heldUnexpired(), memory.calls() == 0
      else { throw FixtureFailure.nativeShape }
      // All nine bindings match the two predicates IN THIS SAME native statement:
      // 1 contender; 2 DB; 3 private app; 4 link query; 5 actual writer; 6 holder;
      // 7 actual advisory key; 8 composed control query; 9 all known raw/inspector PIDs.
      let rows = try c.execute(
        ownedT11ContenderWait,
        [
          String(contenderPID), database, application,
          "SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE", String(writerPID),
          String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey),
          ownedT11ControlQuery, excluded,
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      let after = contender.snapshot()
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(), hold.heldUnexpired(),
        memory.calls() == 0, after.started, after.pid == contenderPID, !after.returned
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), Int(text) == contenderPID else {
          throw FixtureFailure.nativeShape
        }
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedT11OrderUnit() throws -> OwnedT11Facts {
    let raw = try ownedT11RawControls()
    var facts: OwnedT11Facts?
    try withFixture { f in
      let predecessor = try validateFixture(f)
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: f.link.tokenRef)
      try ownedBindInstall(f, stage: stage, rawBodyFault: false)
      let body = try ownedBindProbe(f.inspector, "body_probe")
      let commit = try ownedBindProbe(f.inspector, "commit_probe")
      guard body == OwnedBindProbe(last: 1, called: false),
        commit == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      try ownedT09Recipe(f.inspector, stage: stage)
      try ownedBindWriterReady(
        f, stage: stage, replacement: stage.originalReference, body: body, commit: commit)
      let identity = try ownedT11Identity(f)
      let endpoint = f.database.endpoint
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let hold = OwnedProofHold()
      let state = OwnedBindHolderState()
      let finished = OwnedBindFinished()
      let contenderState = OwnedT11ContenderState()
      var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
      var writer: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      var contender: OwnedProofNativeWork<OwnedT11ContenderResult>?
      // Every partial start is covered before the first start. Release ALL holds, then join ALL.
      defer {
        hold.release()
        if let holder { _ = holder.join() }
        if let writer { _ = writer.join() }
        if let contender { _ = contender.join() }
      }
      let holderApplication = "owned-t11-control-\(UUID().uuidString)"
      let contenderApplication = "owned-t11-link-\(UUID().uuidString)"
      let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      holder = ownedT11ControlHolder(
        binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: identity.user, application: holderApplication,
        controlKey: key, hold: hold, state: state)
      let holderPID = try ownedBindHolderReady(state, hold: hold, deadline: readiness)
      guard memory.calls() == 0 else { throw FixtureFailure.nativeShape }
      // ONE original writer window covers both observations, contender startup and release.
      let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      writer = ownedBindWriter(
        database: f.database, anchor: f.anchor, binding: f.binding, reference: stage.originalReference,
        admission: admission, finished: finished)
      let writerPID = try ownedT11ObserveControl(
        f.inspector, database: endpoint.database, holderPID: holderPID,
        knownOwnedPIDs: [identity.pid, holderPID], hold: hold,
        finished: finished, memory: memory, deadline: deadline)
      contender = ownedT11LinkContender(
        binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: identity.user, application: contenderApplication,
        state: contenderState)
      let contenderPID = try ownedT11ContenderReady(
        contenderState, hold: hold, finished: finished, memory: memory, deadline: deadline)
      guard contenderPID != identity.pid, contenderPID != holderPID, contenderPID != writerPID else {
        throw FixtureFailure.nativeShape
      }
      try ownedT11ObserveContender(
        f.inspector, database: endpoint.database, application: contenderApplication,
        contenderPID: contenderPID, writerPID: writerPID, holderPID: holderPID,
        knownOwnedPIDs: [identity.pid, holderPID, contenderPID], hold: hold,
        finished: finished, contender: contenderState, memory: memory, deadline: deadline)
      try ownedBindReleaseObservedHold(
        hold, finished: finished, memory: memory, invocationStart: 0, retiring: false,
        deadline: deadline)
      // Join EVERY operation before inspecting even the first result or any native image.
      let held = holder!.join()
      let receipt = writer!.join()
      let contended = contender!.join()
      guard held.normal, contended.normal else { throw FixtureFailure.nativeShape }
      try ownedBindWriterObserved(f.inspector, stage: stage, actualDevice: f.database.deviceId)
      let current = try ownedT11Current(
        receipt, database: f.database, anchor: f.anchor, binding: f.binding,
        reference: stage.originalReference, inspector: f.inspector, stage: stage,
        admission: admission, memory: memory, body: body, commit: commit)
      facts = OwnedT11Facts(
        rawControls: raw, nativeWaits: 2, writerCalls: current.calls,
        redemptionCalls: current.redemption, normalHolders: 1, normalContenders: 1,
        body: 1, deferred: 1, settingsRestored: true, qualified: true)
    }
    guard let facts else { throw FixtureFailure.redactedFailure }
    return facts
  }

  @Test(NativeDBResources()) func ownedBindOverridesInheritedIsolationAndSamplesClockAfterAdvisoryWait()
    throws
  {
    // Explicit local and nonlocal units, each with its own rawfour and NEW unique target DB.
    for device in [OwnedT11Device.local, .nonlocal] {
      let diagnostic = OwnedT11Diagnostic(device)
      let facts: OwnedT11Facts
      do {
        facts = try Self.ownedT11SettingsUnit(device, diagnostic: diagnostic)
      } catch {
        // The complete unit has unwound: releases/joins, extra close/reset, fixture/root defers.
        // Unwound does not claim Thread exit, native quiescence, or best-effort removal success.
        diagnostic.rememberFailure()
        diagnostic.outerScope = .unwound
        print(diagnostic.failureLine)
        throw error
      }
      #expect(facts.rawControls == 4 && facts.nativeWaits == 1)
      #expect(facts.writerCalls == 4 && facts.redemptionCalls == 1)
      #expect(facts.normalHolders == 1 && facts.normalContenders == 0)
      #expect(facts.body == 1 && facts.deferred == 1)
      #expect(facts.settingsRestored && facts.qualified)
    }
  }

  @Test(NativeDBResources()) func ownedBindLocksLinkBeforeControlWithNativeWaitEvidence() throws {
    let facts = try Self.ownedT11OrderUnit()
    #expect(facts.rawControls == 4 && facts.nativeWaits == 2)
    #expect(facts.writerCalls == 4 && facts.redemptionCalls == 1)
    #expect(facts.normalHolders == 1 && facts.normalContenders == 1)
    #expect(facts.body == 1 && facts.deferred == 1)
    #expect(facts.settingsRestored && facts.qualified)
  }
}

// Task5 qualification is test-fixture-only. Native feasibility and scheduling remain unobserved
// until the same complete candidate is exercised by the managed lane. Operation joins below
// establish operation results, not Thread exit, native quiescence, or authority.
extension OwnedProtocolProofWriteTests {
  private enum OwnedDeferredCase: Int { case stale, fault, timeout }
  private enum OwnedDeferredRawKind: Sendable, Equatable { case reject, normal, fault, timeout }

  private struct OwnedDeferredFunction: Sendable {
    let name: String
    let arguments: String
    let result: String
    let sql: String
  }

  // The two unchanged function definitions are independent expected source, never reinstalled.
  // The three approved replacements apply exclusively to newly constructed private fixtures.
  private static let ownedDeferredFunctions: [OwnedDeferredFunction] = [
    OwnedDeferredFunction(
      name: "assert_complete", arguments: "required_reference text", result: "void",
      sql: """
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
            ELSIF convert_to(t,'UTF8')=convert_to('appFolders','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."appFolders" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."appFolders" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('changes','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."changes" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."changes" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('columnClocks','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."columnClocks" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."columnClocks" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('connectionUsage','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."connectionUsage" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."connectionUsage" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('connections','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."connections" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."connections" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('devices','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."devices" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."devices" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('displayItems','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."displayItems" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."displayItems" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('drafts','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."drafts" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."drafts" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('localServers','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."localServers" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."localServers" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('projectFolders','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."projectFolders" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."projectFolders" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('projects','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."projects" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."projects" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolGrantSecrets','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolGrants','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrants" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrants" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolHistoryAnchors','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolOperations','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolOperations" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolOperations" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolPromptAnswers','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolRunSegments','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolRunSegments" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolRunSegments" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('protocolSubscriptions','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolSubscriptions" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolSubscriptions" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('runtimeRequests','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."runtimeRequests" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."runtimeRequests" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('schemaMigrations','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."schemaMigrations" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."schemaMigrations" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('settings','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."settings" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."settings" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('threadDeletes','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."threadDeletes" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."threadDeletes" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('threads','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."threads" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."threads" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('tokenUsage','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."tokenUsage" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."tokenUsage" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('turns','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."turns" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."turns" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('usageReadings','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."usageReadings" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."usageReadings" p))
                INTO mismatch;
            ELSIF convert_to(t,'UTF8')=convert_to('viewSettings','UTF8') THEN
              SELECT EXISTS((SELECT to_jsonb(p) FROM public."viewSettings" p)
                  EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
                OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                  EXCEPT ALL (SELECT to_jsonb(p) FROM public."viewSettings" p))
                INTO mismatch;
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
        """),
    OwnedDeferredFunction(
      name: "body", arguments: "", result: "trigger",
      sql: """
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
        """),
    OwnedDeferredFunction(
      name: "transaction_checked", arguments: "persist boolean", result: "void",
      sql: """
        CREATE FUNCTION "owned_bind_stage"."transaction_checked"(persist boolean)
        RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        DECLARE iso text; lb text; sb text; h text; d text; wanted text; n bigint; wanted_row jsonb;
        BEGIN
         IF (SELECT count(*) FROM "owned_bind_stage"."deferred_control")<>1
           OR (SELECT count(*) FROM "owned_bind_stage"."meta")<>1
           OR (SELECT count(*) FROM "owned_bind_stage"."mode")<>1
         THEN RAISE EXCEPTION 'OWNED_BIND_TRANSACTION_MISMATCH' USING ERRCODE='P0001'; END IF;
         SELECT observed_before INTO STRICT n FROM "owned_bind_stage"."deferred_control" WHERE singleton=1;
         SELECT expected_device INTO STRICT wanted FROM "owned_bind_stage"."meta" WHERE singleton=1;
         iso:=current_setting('transaction_isolation'); lb:=current_setting('lock_timeout');
         sb:=current_setting('statement_timeout'); h:=current_setting('b4app.hlc',true);
         d:=current_setting('b4app.device_id',true);
         IF persist IS NULL OR iso IS DISTINCT FROM 'read committed' OR lb IS DISTINCT FROM '2s'
           OR sb IS DISTINCT FROM '2s' OR h IS NULL OR h !~ '^[0-9a-f]{12}-[0-9a-f]{4}-.+$'
           OR convert_to(substring(h FROM 19),'UTF8') IS DISTINCT FROM convert_to(wanted,'UTF8')
           OR (wanted='local' AND coalesce(d,'')<>'')
           OR (wanted<>'local' AND convert_to(d,'UTF8') IS DISTINCT FROM convert_to(wanted,'UTF8'))
           OR (SELECT count(*) FROM "owned_bind_stage"."observed") <> n + (CASE WHEN persist THEN 0 ELSE 1 END)
         THEN RAISE EXCEPTION 'OWNED_BIND_TRANSACTION_MISMATCH' USING ERRCODE='P0001'; END IF;
         IF persist THEN
           INSERT INTO "owned_bind_stage"."observed"(isolation,lock_budget,statement_budget,hlc,device)
             VALUES(iso,lb,sb,h,d);
         ELSE
           wanted_row:=jsonb_build_object('isolation',iso,'lock_budget',lb,'statement_budget',sb,'hlc',h,'device',d);
           IF (SELECT count(*) FROM "owned_bind_stage"."observed" o WHERE to_jsonb(o)=wanted_row)<>1
           THEN RAISE EXCEPTION 'OWNED_BIND_TRANSACTION_MISMATCH' USING ERRCODE='P0001'; END IF;
         END IF;
        END $$;
        """),
    OwnedDeferredFunction(
      name: "assert_transaction", arguments: "", result: "void",
      sql: """
        CREATE OR REPLACE FUNCTION "owned_bind_stage"."assert_transaction"()
        RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN PERFORM "owned_bind_stage"."transaction_checked"(true); END $$;
        """),
    OwnedDeferredFunction(
      name: "commit_normal", arguments: "", result: "trigger",
      sql: """
        CREATE OR REPLACE FUNCTION "owned_bind_stage"."commit_normal"()
        RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        DECLARE m text; k bigint; a text; replacement text; fault boolean; candidate jsonb;
         native_state text; native_message text;
        BEGIN
         SELECT original_ref,expected_control INTO STRICT a,candidate
           FROM "owned_bind_stage"."meta" WHERE singleton=1;
         SELECT deferred_mode,gate_key INTO STRICT m,k
           FROM "owned_bind_stage"."deferred_control" WHERE singleton=1;
         SELECT md.replacement,md.raw_body_fault INTO STRICT replacement,fault
           FROM "owned_bind_stage"."mode" md WHERE singleton=1;
         IF TG_OP IS DISTINCT FROM 'UPDATE' OR k IS DISTINCT FROM 1647600739::bigint
           OR m IS NULL OR m NOT IN ('normal','fault','gate') OR fault IS DISTINCT FROM false
           OR convert_to(replacement,'UTF8') IS DISTINCT FROM convert_to(a,'UTF8')
           OR to_jsonb(NEW) IS DISTINCT FROM jsonb_build_object('key','__b4app_agent_protocol_activation_v1','value',candidate)
         THEN RAISE EXCEPTION 'OWNED_BIND_COMPLETE_MISMATCH' USING ERRCODE='P0001'; END IF;
         PERFORM "owned_bind_stage"."assert_complete"(a);
         PERFORM "owned_bind_stage"."transaction_checked"(false);
         PERFORM nextval('"owned_bind_stage"."commit_probe"'::regclass);
         IF m='fault' THEN
           RAISE EXCEPTION 'OWNED_BIND_ACTUAL_DEFERRED_FAULT' USING ERRCODE='23514';
         ELSIF m='gate' THEN
           BEGIN
             PERFORM pg_catalog.pg_advisory_xact_lock(k);
           EXCEPTION WHEN lock_not_available OR query_canceled THEN
             GET STACKED DIAGNOSTICS native_state=RETURNED_SQLSTATE,native_message=MESSAGE_TEXT;
             IF (native_state='55P03' AND native_message='canceling statement due to lock timeout')
               OR (native_state='57014' AND native_message='canceling statement due to statement timeout')
             THEN
               PERFORM nextval('"owned_bind_stage"."timeout_probe"'::regclass);
             END IF;
             RAISE;
           END;
         END IF;
         RETURN NEW;
        END $$;
        """),
  ]

  private struct OwnedDeferredProbes: Equatable {
    let body: OwnedBindProbe
    let commit: OwnedBindProbe
    let timeout: OwnedBindProbe

    func advanced(from old: Self, body: Int64, commit: Int64, timeout: Int64) -> Bool {
      self.body.advanced(from: old.body, by: body)
        && self.commit.advanced(from: old.commit, by: commit)
        && self.timeout.advanced(from: old.timeout, by: timeout)
    }
  }

  private struct OwnedDeferredRecipe {
    let stage: OwnedBindStageFixture
    let catalog: [Data]
  }

  private struct OwnedDeferredCheckpoint: Equatable {
    let image: OwnedBindImage
    let observations: [Data]
    let probes: OwnedDeferredProbes
  }

  private struct OwnedDeferredRawResult: Sendable {
    var valid = false
    var dmlReturned = false
    var commitSent = false
    var acknowledged = false
    var rollbackAcknowledged = false
    var predicateRejected = false
    var actualDeferredFault = false
    var actualServerTimeout = false
    var ownPredicate = false
    var ownSettings = false
    var millis: UInt64 = 0
  }

  // These are the only facts returned outside a completely closed unit or raw fixture.
  private struct OwnedDeferredFacts {
    let oldControls: Int
    let newControls: Int
    let rawAttempts: Int
    let rawHolders: Int
    let writerCalls: Int
    let redemptionCalls: Int
    let targetHolders: Int
    let targetWaits: Int
    let timeoutAllocations: Int
    let qualified: Bool
  }

  private final class OwnedDeferredWork {
    var holds: [OwnedProofHold] = []
    var holders: [OwnedProofNativeWork<OwnedBindHolderResult>] = []
    var raw: [OwnedProofNativeWork<OwnedDeferredRawResult>] = []
    var writers: [OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>] = []

    // Installed by defer before ANY child starts. Earlier joined handles stay retained.
    // All releases precede every join, and no result validation interrupts this drain.
    func releaseAndJoin() {
      for hold in holds { hold.release() }
      for work in holders { _ = work.join() }
      for work in raw { _ = work.join() }
      for work in writers { _ = work.join() }
    }
  }

  private static func ownedDeferredTimeout(_ c: PostgresConnection) throws -> OwnedBindProbe {
    // The existing two-name probe reader and its allowlist remain unchanged.
    let rows = try c.execute(
      "SELECT last_value::text AS last,is_called::text AS called FROM \"owned_bind_stage\".\"timeout_probe\""
    ).rows
    guard rows.count == 1, let text = rows[0].text("last"), let last = Int64(text), last >= 1,
      rows[0].text("called") == "true" || rows[0].text("called") == "false"
    else { throw FixtureFailure.nativeShape }
    return OwnedBindProbe(last: last, called: rows[0].text("called") == "true")
  }

  private static func ownedDeferredProbes(_ c: PostgresConnection) throws -> OwnedDeferredProbes {
    OwnedDeferredProbes(
      body: try ownedBindProbe(c, "body_probe"), commit: try ownedBindProbe(c, "commit_probe"),
      timeout: try ownedDeferredTimeout(c))
  }

  private static func ownedDeferredRows(_ c: PostgresConnection, sql: String) throws -> [Data] {
    try c.execute(sql).rows.map {
      guard let value = $0.text("value") else { throw FixtureFailure.nativeShape }
      return try ownedBindJSON(value)
    }.sorted { $0.lexicographicallyPrecedes($1) }
  }

  private static func ownedDeferredObservations(_ c: PostgresConnection) throws -> [Data] {
    try ownedDeferredRows(
      c, sql: "SELECT to_jsonb(o)::text AS value FROM \"owned_bind_stage\".\"observed\" o")
  }

  private static func ownedDeferredCatalog(_ c: PostgresConnection) throws -> [Data] {
    // Every current public/private table, column, constraint, index, trigger, function and
    // sequence definition participates, including Store16's empty protocol tables and density.
    // Mutable sequence position is checked independently, never mistaken for catalog shape.
    try ownedDeferredRows(
      c,
      sql: """
        SELECT jsonb_build_object('class',c.oid,'schema',n.nspname,'name',c.relname,
          'kind',c.relkind,'persistence',c.relpersistence,'owner',c.relowner,'am',c.relam,
          'security',c.relrowsecurity,'force',c.relforcerowsecurity,
          'replica',c.relreplident,'options',c.reloptions)::text AS value
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        UNION ALL
        SELECT jsonb_build_object('attribute',a.attrelid,'number',a.attnum,'name',a.attname,
          'type',a.atttypid,'modifier',a.atttypmod,'notnull',a.attnotnull,
          'collation',a.attcollation,'identity',a.attidentity,'generated',a.attgenerated,
          'dropped',a.attisdropped,'default',pg_get_expr(d.adbin,d.adrelid))::text
        FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid=a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE n.nspname IN ('public','owned_bind_stage') AND a.attnum>0
        UNION ALL
        SELECT jsonb_build_object('constraint',x.oid,'name',x.conname,'relation',x.conrelid,
          'definition',pg_get_constraintdef(x.oid,true),'validated',x.convalidated)::text
        FROM pg_catalog.pg_constraint x JOIN pg_catalog.pg_namespace n ON n.oid=x.connamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        UNION ALL
        SELECT jsonb_build_object('index',i.indexrelid,'definition',pg_get_indexdef(i.indexrelid),
          'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive)::text
        FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        UNION ALL
        SELECT jsonb_build_object('trigger',t.oid,'definition',pg_get_triggerdef(t.oid,true),
          'enabled',t.tgenabled,'function',t.tgfoid,'relation',t.tgrelid)::text
        FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        UNION ALL
        SELECT jsonb_build_object('function',p.oid,'definition',pg_get_functiondef(p.oid),
          'config',p.proconfig,'owner',p.proowner,'acl',p.proacl)::text
        FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        UNION ALL
        SELECT jsonb_build_object('sequence',s.seqrelid,'type',s.seqtypid,'start',s.seqstart,
          'increment',s.seqincrement,'max',s.seqmax,'min',s.seqmin,'cache',s.seqcache,
          'cycle',s.seqcycle)::text
        FROM pg_catalog.pg_sequence s JOIN pg_catalog.pg_class c ON c.oid=s.seqrelid
        JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname IN ('public','owned_bind_stage')
        """)
  }

  private static func ownedDeferredConfig(_ mode: String, baseline: Int) throws -> Data {
    guard ["normal", "fault", "gate"].contains(mode), baseline == 0 || baseline == 1 else {
      throw FixtureFailure.nativeShape
    }
    return try ownedT09Data([
      "singleton": 1, "deferred_mode": mode, "observed_before": baseline,
      "gate_key": 1647600739,
    ])
  }

  private static func ownedDeferredRecipeCheck(
    _ c: PostgresConnection, recipe: OwnedDeferredRecipe, mode: String, baseline: Int,
    diagnostic: OwnedDeferredDiagnostic
  ) throws {
    // The freezer checked the zero-trigger catalog before installation. Post-install checks
    // retain the complete recipe and catalog snapshot, including both installed triggers.
    diagnostic.enter(.recipeNamesRowsMeta)
    try ownedT09Recipe(c, stage: recipe.stage)
    diagnostic.enter(.recipeConfig)
    let config = try ownedDeferredRows(
      c, sql: "SELECT to_jsonb(d)::text AS value FROM \"owned_bind_stage\".\"deferred_control\" d")
    diagnostic.enter(.recipeCatalog)
    guard config == [try ownedDeferredConfig(mode, baseline: baseline)],
      try ownedDeferredCatalog(c) == recipe.catalog
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedDeferredInstall(
    _ f: Fixture, stage: OwnedBindStageFixture, mode: String, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredRecipe {
    diagnostic.enter(.oldInstall)
    guard WorkspaceDatabase.remoteApplyLockKey == 1647599984,
      Migrator.migrationLockKey == 7076401213980434804,
      Migrator.migrationLockKey != 1647600739,
      WorkspaceDatabase.remoteApplyLockKey != 1647600739
    else { throw FixtureFailure.nativeShape }
    // This is the ONLY old installer use in each NEW fixture, before replacing private functions.
    diagnostic.enter(.oldInstall)
    try ownedBindInstall(f, stage: stage, rawBodyFault: false)
    diagnostic.enter(.privateDDL)
    try f.inspector.execute(
      """
      CREATE SEQUENCE "owned_bind_stage"."timeout_probe"
        AS bigint START WITH 1 INCREMENT BY 1 CACHE 1 NO CYCLE;
      CREATE TABLE "owned_bind_stage"."deferred_control"(
        singleton integer PRIMARY KEY CHECK(singleton=1),
        deferred_mode text NOT NULL CHECK(deferred_mode IN ('normal','fault','gate')),
        observed_before bigint NOT NULL CHECK(observed_before>=0),
        gate_key bigint NOT NULL CHECK(gate_key=1647600739));
      """)
    diagnostic.enter(.controlInsert)
    guard
      try f.inspector.execute(
        """
        INSERT INTO "owned_bind_stage"."deferred_control"
          (singleton,deferred_mode,observed_before,gate_key) VALUES(1,$1,0,1647600739)
        """, [mode]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    diagnostic.enter(.functionCreate)
    for function in ownedDeferredFunctions.dropFirst(2) { try f.inspector.execute(function.sql) }
    diagnostic.enter(.functionCount)
    let functions = try f.inspector.execute(
      """
      SELECT p.proname AS name,p.prosrc AS source,pg_get_function_identity_arguments(p.oid) AS args,
        pg_get_function_result(p.oid) AS result,p.proconfig::text AS config,l.lanname AS language,
        p.provolatile::text AS volatility,p.proparallel::text AS parallel,
        p.prosecdef::text AS definer,p.proisstrict::text AS strict,p.proleakproof::text AS leakproof,
        p.prokind::text AS kind
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE n.nspname='owned_bind_stage'
      """
    ).rows
    guard functions.count == ownedDeferredFunctions.count else { throw FixtureFailure.nativeShape }
    for expected in ownedDeferredFunctions {
      diagnostic.enter(.functionSource)
      let rows = functions.filter { $0.text("name") == expected.name }
      let parts = expected.sql.components(separatedBy: "$$")
      diagnostic.enter(.functionSignatureAndAttributes)
      guard rows.count == 1, parts.count == 3, let row = rows.first,
        row.text("source") == parts[1], row.text("args") == expected.arguments,
        row.text("result") == expected.result, row.text("config") == "{search_path=pg_catalog}",
        row.text("language") == "plpgsql", row.text("volatility") == "v",
        row.text("parallel") == "u", row.text("definer") == "false",
        row.text("strict") == "false", row.text("leakproof") == "false", row.text("kind") == "f"
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.privateObjects)
    let privateObjects = try f.inspector.execute(
      """
      SELECT c.relname AS name,c.relkind::text AS kind,c.relpersistence::text AS persistence
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='owned_bind_stage' AND c.relkind<>'i' ORDER BY c.relname
      """
    ).rows
    let objects = [
      "body_probe": "S", "commit_probe": "S", "timeout_probe": "S", "names": "r",
      "expected": "r", "meta": "r", "mode": "r", "observed": "r", "deferred_control": "r",
    ]
    guard privateObjects.count == objects.count else { throw FixtureFailure.nativeShape }
    for row in privateObjects {
      guard let name = row.text("name"), row.text("kind") == objects[name],
        row.text("persistence") == "p"
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.columns)
    let columns = try f.inspector.execute(
      """
      SELECT a.attname AS name,format_type(a.atttypid,a.atttypmod) AS type,
        a.attnotnull::text AS required
      FROM pg_catalog.pg_attribute a WHERE a.attrelid='owned_bind_stage.deferred_control'::regclass
        AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
      """
    ).rows
    let expectedColumns = [
      ("singleton", "integer"), ("deferred_mode", "text"),
      ("observed_before", "bigint"), ("gate_key", "bigint"),
    ]
    guard columns.count == expectedColumns.count else { throw FixtureFailure.nativeShape }
    for (row, expected) in zip(columns, expectedColumns) {
      guard row.text("name") == expected.0, row.text("type") == expected.1,
        row.text("required") == "true"
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.constraints)
    let constraints = try f.inspector.execute(
      """
      SELECT conname AS name,contype::text AS kind,convalidated::text AS valid,
        condeferrable::text AS deferrable,pg_get_constraintdef(oid,true) AS definition
      FROM pg_catalog.pg_constraint WHERE conrelid='owned_bind_stage.deferred_control'::regclass
      """
    ).rows
    let expectedConstraints = [
      "deferred_control_pkey": "PRIMARY KEY (singleton)",
      "deferred_control_singleton_check": "CHECK (singleton = 1)",
      "deferred_control_deferred_mode_check":
        "CHECK (deferred_mode = ANY (ARRAY['normal'::text, 'fault'::text, 'gate'::text]))",
      "deferred_control_observed_before_check": "CHECK (observed_before >= 0)",
      "deferred_control_gate_key_check": "CHECK (gate_key = 1647600739)",
    ]
    guard constraints.count == expectedConstraints.count else { throw FixtureFailure.nativeShape }
    for row in constraints {
      guard let name = row.text("name"), row.text("definition") == expectedConstraints[name],
        row.text("valid") == "true", row.text("deferrable") == "false",
        row.text("kind") == (name == "deferred_control_pkey" ? "p" : "c")
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.sequences)
    let probes = try f.inspector.execute(
      """
      SELECT c.relname AS name,s.seqtypid='bigint'::regtype AS bigint,s.seqstart::text AS start,
        s.seqincrement::text AS increment,s.seqmin::text AS minimum,s.seqmax::text AS maximum,
        s.seqcache::text AS cache,s.seqcycle::text AS cycle
      FROM pg_catalog.pg_sequence s JOIN pg_catalog.pg_class c ON c.oid=s.seqrelid
      JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='owned_bind_stage'
      """
    ).rows
    guard probes.count == 3 else { throw FixtureFailure.nativeShape }
    for row in probes {
      guard let name = row.text("name"), ["body_probe", "commit_probe", "timeout_probe"].contains(name),
        row.text("bigint") == "t", row.text("start") == "1", row.text("increment") == "1",
        row.text("minimum") == "1", row.text("maximum") == "9223372036854775807",
        row.text("cache") == "1", row.text("cycle") == "false"
      else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.triggerDefinition)
    let triggers = try f.inspector.execute(
      """
      SELECT t.tgname AS name,pg_get_triggerdef(t.oid,true) AS definition,
        t.tgfoid=('owned_bind_stage.'||p.proname||'()')::regprocedure AS exact_function
      FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
      WHERE t.tgrelid='public.settings'::regclass AND NOT t.tgisinternal
      """
    ).rows
    let expectedTriggers = [
      "owned_bind_body":
        "CREATE TRIGGER owned_bind_body AFTER UPDATE ON public.settings FOR EACH ROW WHEN (new.key = '__b4app_agent_protocol_activation_v1'::text) EXECUTE FUNCTION owned_bind_stage.body()",
      "owned_bind_commit_normal":
        "CREATE CONSTRAINT TRIGGER owned_bind_commit_normal AFTER UPDATE ON public.settings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (new.key = '__b4app_agent_protocol_activation_v1'::text) EXECUTE FUNCTION owned_bind_stage.commit_normal()",
    ]
    diagnostic.enter(.triggerRowCount)
    guard triggers.count == 2 else { throw FixtureFailure.nativeShape }
    for row in triggers {
      diagnostic.enter(.triggerNameValue)
      guard let name = row.text("name") else { throw FixtureFailure.nativeShape }
      diagnostic.enter(.triggerDefinitionValue)
      let definition = row.text("definition")
      let expectedDefinition = expectedTriggers[name]
      // The query fixes the relation OID; pretty output may omit its schema.
      guard
        definition == expectedDefinition
          || (expectedDefinition != nil
            && definition
              == expectedDefinition?.replacingOccurrences(of: " ON public.settings ", with: " ON settings "))
      else {
        if expectedDefinition == nil {
          diagnostic.enter(.triggerNameUnknown)
        } else if definition == nil {
          diagnostic.enter(.triggerDefinitionNil)
        } else {
          diagnostic.enter(
            name == "owned_bind_body" ? .triggerBodyOtherValue : .triggerCommitOtherValue)
        }
        throw FixtureFailure.nativeShape
      }
      diagnostic.enter(.triggerFunctionIdentity)
      guard row.text("exact_function") == "t" else { throw FixtureFailure.nativeShape }
    }
    diagnostic.enter(.catalogCapture)
    let recipe = OwnedDeferredRecipe(stage: stage, catalog: try ownedDeferredCatalog(f.inspector))
    try ownedDeferredRecipeCheck(f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic)
    diagnostic.enter(.initialState)
    let initial = try ownedDeferredProbes(f.inspector)
    let fresh = OwnedBindProbe(last: 1, called: false)
    guard initial == OwnedDeferredProbes(body: fresh, commit: fresh, timeout: fresh),
      try ownedDeferredObservations(f.inspector).isEmpty,
      try ownedBindImage(f.inspector) == stage.before
    else { throw FixtureFailure.nativeShape }
    return recipe
  }

  private static func ownedDeferredCheckpointRead(
    _ c: PostgresConnection, recipe: OwnedDeferredRecipe, mode: String, baseline: Int,
    diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredCheckpoint {
    try ownedDeferredRecipeCheck(c, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
    diagnostic.enter(.imageAndProbes)
    return OwnedDeferredCheckpoint(
      image: try ownedBindImage(c), observations: try ownedDeferredObservations(c),
      probes: try ownedDeferredProbes(c))
  }

  private static func ownedDeferredAppendObservation(
    _ c: PostgresConnection, stage: OwnedBindStageFixture, old: [Data], actual: [Data],
    rawMillis: UInt64?
  ) throws {
    // Subtract a sorted MULTISET, retaining duplicate multiplicity and every prior full row.
    var added = actual
    for row in old {
      guard let index = added.firstIndex(of: row) else { throw FixtureFailure.nativeShape }
      added.remove(at: index)
    }
    guard actual.count == old.count + 1, added.count == 1,
      let row = try JSONSerialization.jsonObject(with: added[0]) as? [String: Any],
      Set(row.keys) == Set(["isolation", "lock_budget", "statement_budget", "hlc", "device"]),
      row["isolation"] as? String == "read committed", row["lock_budget"] as? String == "2s",
      row["statement_budget"] as? String == "2s", let text = row["hlc"] as? String,
      let hlc = HLC(rawValue: text), equalBytes(hlc.rawValue, text),
      equalBytes(hlc.deviceId, stage.device), hlc.millis >= stage.lowerWall,
      hlc.millis <= (try ownedBindWall(c))
    else { throw FixtureFailure.nativeShape }
    if let rawMillis {
      guard hlc.millis == rawMillis, hlc.counter == 0 else { throw FixtureFailure.nativeShape }
    }
    if equalBytes(stage.device, "local") {
      guard row["device"] is NSNull || row["device"] as? String == "" else {
        throw FixtureFailure.nativeShape
      }
    } else {
      guard let device = row["device"] as? String, equalBytes(device, stage.device) else {
        throw FixtureFailure.nativeShape
      }
    }
  }

  private static func ownedDeferredQ01(
    _ f: Fixture, recipe: OwnedDeferredRecipe, mode: String, diagnostic: OwnedDeferredDiagnostic
  ) throws {
    let before = try ownedDeferredCheckpointRead(
      f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic)
    diagnostic.enter(.q01)
    guard before.image == recipe.stage.expected, before.observations.count == 1 else {
      throw FixtureFailure.nativeShape
    }
    let old = try ownedDeferredControl(recipe.stage.expected)
    let new = try ownedDeferredControl(recipe.stage.before)
    guard try ownedT09ControlImage(recipe.stage.expected, old: old, new: new) == recipe.stage.before,
      !old.isEmpty, !new.isEmpty
    else { throw FixtureFailure.nativeShape }
    var commitSent = false
    var committed = false
    // Registered before BEGIN. A failed COMMIT is not converted to a checked rollback fact.
    defer { if !commitSent && !committed { _ = try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    guard
      try f.inspector.execute(
        "DELETE FROM public.settings WHERE key=$1 AND value=$2::jsonb",
        [key, try ownedBindText(ownedT09Data(old))]
      ).affected == 1,
      try f.inspector.execute(
        "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)",
        [key, try ownedBindText(ownedT09Data(new))]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    commitSent = true
    try f.inspector.execute("COMMIT")
    committed = true
    diagnostic.enter(.afterCheckpoint)
    let after = try ownedDeferredCheckpointRead(
      f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic)
    diagnostic.enter(.q01)
    guard after.image == recipe.stage.before, after.observations == before.observations,
      after.probes == before.probes
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedDeferredTransition(
    _ f: Fixture, recipe: OwnedDeferredRecipe, oldMode: String, oldBaseline: Int,
    newMode: String, newBaseline: Int, diagnostic: OwnedDeferredDiagnostic
  ) throws {
    diagnostic.enter(.configTransition)
    guard
      (oldMode == newMode && oldBaseline == 0 && newBaseline == 1)
        || (oldMode == "fault" && newMode == "normal" && oldBaseline == 0 && newBaseline == 0)
    else { throw FixtureFailure.nativeShape }
    let before = try ownedDeferredCheckpointRead(
      f.inspector, recipe: recipe, mode: oldMode, baseline: oldBaseline, diagnostic: diagnostic)
    diagnostic.enter(.configTransition)
    guard before.image == recipe.stage.before,
      before.observations.count == newBaseline
    else { throw FixtureFailure.nativeShape }
    let old = try ownedDeferredConfig(oldMode, baseline: oldBaseline)
    let new = try ownedDeferredConfig(newMode, baseline: newBaseline)
    var commitSent = false
    var committed = false
    defer { if !commitSent && !committed { _ = try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    let sql =
      oldMode == newMode
      ? "UPDATE \"owned_bind_stage\".\"deferred_control\" AS d SET observed_before=1 WHERE singleton=1 AND to_jsonb(d)=$1::jsonb"
      : "UPDATE \"owned_bind_stage\".\"deferred_control\" AS d SET deferred_mode='normal' WHERE singleton=1 AND to_jsonb(d)=$1::jsonb"
    guard try f.inspector.execute(sql, [try ownedBindText(old)]).affected == 1,
      try ownedDeferredRows(
        f.inspector,
        sql: "SELECT to_jsonb(d)::text AS value FROM \"owned_bind_stage\".\"deferred_control\" d") == [new]
    else { throw FixtureFailure.nativeShape }
    commitSent = true
    try f.inspector.execute("COMMIT")
    committed = true
    diagnostic.enter(.afterCheckpoint)
    let after = try ownedDeferredCheckpointRead(
      f.inspector, recipe: recipe, mode: newMode, baseline: newBaseline, diagnostic: diagnostic)
    diagnostic.enter(.configTransition)
    guard after == before else { throw FixtureFailure.nativeShape }
  }

  private static let ownedDeferredRawDML = """
    INSERT INTO public.settings(key,value)
    SELECT '__b4app_agent_protocol_activation_v1',expected_control
    FROM "owned_bind_stage"."meta" WHERE singleton=1
    ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value
    """

  private static func ownedDeferredRawWorker(
    binDir: String, socketDir: String, port: Int, database: String, user: String,
    application: String, kind: OwnedDeferredRawKind,
    state: OwnedBindHolderState, finished: OwnedBindFinished
  ) -> OwnedProofNativeWork<OwnedDeferredRawResult> {
    OwnedProofNativeWork {
      [binDir, socketDir, port, database, user, application, kind, state, finished] in
      defer { finished.markReturned() }
      do {
        // The worker creates, uses and closes its own native connection lexically. No Fixture,
        // inspector, image, JSON candidate, proof object, or externally created connection capture.
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: binDir),
          connectionString:
            "host=\(socketDir) port=\(port) user=\(user) dbname=\(database) application_name=\(application)")
        var result = OwnedDeferredRawResult()
        var began = false
        var rollbackSent = false
        defer {
          if began && !result.commitSent && !rollbackSent { _ = try? c.execute("ROLLBACK") }
        }
        let identity = try c.execute(
          """
          SELECT pg_backend_pid() AS pid,current_database() AS database,current_user AS username,
            current_setting('application_name') AS application
          """
        ).rows
        guard identity.count == 1, let pid = identity[0].int("pid"), pid > 0,
          identity[0].text("database") == database, identity[0].text("username") == user,
          identity[0].text("application") == application
        else { return result }
        state.acquired(pid: pid)
        let probes = try ownedDeferredProbes(c)
        try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        began = true
        try c.execute("SET LOCAL lock_timeout='2s'")
        try c.execute("SET LOCAL statement_timeout='2s'")
        try c.execute("SELECT pg_catalog.pg_advisory_xact_lock($1::bigint)", ["1647599984"])
        let meta = try c.execute(
          """
          SELECT expected_device,original_ref FROM "owned_bind_stage"."meta" WHERE singleton=1
          """
        ).rows
        guard meta.count == 1, let device = meta[0].text("expected_device"), !device.isEmpty,
          let reference = meta[0].text("original_ref")
        else { return result }
        let wall = try ownedBindWall(c)
        let stamp = HLC(millis: wall, counter: 0, deviceId: device)
        guard HLC(rawValue: stamp.rawValue) != nil else { return result }
        result.millis = wall
        try c.execute("SELECT pg_catalog.set_config('b4app.hlc',$1,true)", [stamp.rawValue])
        if device != "local" {
          try c.execute("SELECT pg_catalog.set_config('b4app.device_id',$1,true)", [device])
        }
        do {
          guard try c.execute(ownedDeferredRawDML).affected == 1 else { return result }
          result.dmlReturned = true
        } catch let error as PostgresError {
          result.predicateRejected =
            kind == .reject && error.sqlState == "P0001"
            && error.message.components(separatedBy: "\n").first == "ERROR:  OWNED_BIND_COMPLETE_MISMATCH"
            && equalBytes(error.sql, ownedDeferredRawDML)
          guard result.predicateRejected else { return result }
        }
        if kind == .reject {
          guard result.predicateRejected, !result.dmlReturned
          else { return result }
          rollbackSent = true
          try c.execute("ROLLBACK")
          result.rollbackAcknowledged = true
          guard try ownedDeferredProbes(c) == probes else { return result }
          result.valid = true
          return result
        }
        guard result.dmlReturned else { return result }
        try c.execute("SELECT \"owned_bind_stage\".\"assert_complete\"($1)", [reference])
        result.ownPredicate = true
        try c.execute("SELECT \"owned_bind_stage\".\"transaction_checked\"(false)")
        let seen = try c.execute(
          """
          SELECT count(*) AS n FROM "owned_bind_stage"."observed"
          WHERE hlc=$1 AND isolation='read committed' AND lock_budget='2s' AND statement_budget='2s'
            AND device IS NOT DISTINCT FROM current_setting('b4app.device_id',true)
          """, [stamp.rawValue]
        ).rows
        guard seen.count == 1, seen[0].int("n") == 1,
          try ownedDeferredProbes(c).advanced(from: probes, body: 1, commit: 0, timeout: 0)
        else { return result }
        result.ownSettings = true
        result.commitSent = true
        do {
          try c.execute("COMMIT")
          result.acknowledged = true
        } catch let error as PostgresError {
          // After actual COMMIT is sent there is NO further SQL on this lexical connection.
          let line = error.message.components(separatedBy: "\n").first
          result.actualDeferredFault =
            kind == .fault && error.sqlState == "23514"
            && line == "ERROR:  OWNED_BIND_ACTUAL_DEFERRED_FAULT" && error.sql == "COMMIT"
          result.actualServerTimeout =
            kind == .timeout && error.sql == "COMMIT"
            && ((error.sqlState == "55P03" && line == "ERROR:  canceling statement due to lock timeout")
              || (error.sqlState == "57014" && line == "ERROR:  canceling statement due to statement timeout"))
        }
        result.valid =
          result.ownPredicate && result.ownSettings
          && ((kind == .normal && result.acknowledged)
            || (kind == .fault && result.actualDeferredFault && !result.acknowledged)
            || (kind == .timeout && result.actualServerTimeout && !result.acknowledged))
        return result
      } catch {
        // Redaction follows lexical rollback/close; arbitrary diagnostics never leave the worker.
        return OwnedDeferredRawResult()
      }
    }
  }

  private static func ownedDeferredHolder(
    binDir: String, socketDir: String, port: Int, database: String, user: String,
    application: String, hold: OwnedProofHold, state: OwnedBindHolderState
  ) -> OwnedProofNativeWork<OwnedBindHolderResult> {
    OwnedProofNativeWork { [binDir, socketDir, port, database, user, application, hold, state] in
      do {
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: binDir),
          connectionString:
            "host=\(socketDir) port=\(port) user=\(user) dbname=\(database) application_name=\(application)")
        var began = false
        var rollbackAcknowledged = false
        defer { if began && !rollbackAcknowledged { _ = try? c.execute("ROLLBACK") } }
        began = true
        try c.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        try c.execute("SET LOCAL lock_timeout='2s'")
        try c.execute("SET LOCAL statement_timeout='2s'")
        let rows = try c.execute(
          """
          SELECT pg_backend_pid() AS pid,current_database() AS database,current_user AS username,
            current_setting('application_name') AS application,
            current_setting('transaction_isolation') AS isolation,
            current_setting('lock_timeout') AS lock_budget,
            current_setting('statement_timeout') AS statement_budget
          """
        ).rows
        guard rows.count == 1, let pid = rows[0].int("pid"), pid > 0,
          rows[0].text("database") == database, rows[0].text("username") == user,
          rows[0].text("application") == application, rows[0].text("isolation") == "read committed",
          rows[0].text("lock_budget") == "2s", rows[0].text("statement_budget") == "2s"
        else { return .invalid }
        try c.execute("SELECT pg_catalog.pg_advisory_xact_lock($1::bigint)", ["1647600739"])
        state.acquired(pid: pid)
        let released = hold.wait()
        try c.execute("ROLLBACK")
        rollbackAcknowledged = true
        let final = hold.snapshot()
        return OwnedBindHolderResult(
          acquired: true, released: released && final.released, expired: final.expired,
          rollbackAcknowledged: rollbackAcknowledged)
      } catch { return .invalid }
    }
  }

  private static func ownedDeferredGateClear(_ c: PostgresConnection) throws {
    let rows = try c.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_locks g
      JOIN pg_catalog.pg_database db ON db.oid=g.database
      WHERE db.datname=current_database() AND g.locktype='advisory'
        AND g.classid=0::oid AND g.objid=1647600739::oid AND g.objsubid=1
      """
    ).rows
    // Both granted and waiting resources count. A collision fails; nothing is adopted/unlocked.
    guard rows.count == 1, rows[0].int("n") == 0 else { throw FixtureFailure.nativeShape }
  }

  private static func ownedDeferredHolderReady(
    _ c: PostgresConnection, state: OwnedBindHolderState, hold: OwnedProofHold,
    database: String, application: String, deadline: UInt64
  ) throws -> Int {
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let facts = state.snapshot()
      if facts.acquired && facts.pid > 0 && hold.heldUnexpired() {
        let rows = try c.execute(
          """
          SELECT a.pid AS pid FROM pg_catalog.pg_stat_activity a
          JOIN pg_catalog.pg_database db ON db.datname=$1
          WHERE a.pid=$2::int AND a.datname=$1 AND a.usename=current_user
            AND a.application_name=$3 AND a.backend_type='client backend'
            AND a.state='idle in transaction'
            AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks g WHERE g.pid=a.pid
              AND g.locktype='advisory' AND g.mode='ExclusiveLock' AND g.granted
              AND g.database=db.oid AND g.classid=0::oid
              AND g.objid=1647600739::oid AND g.objsubid=1)
          """, [database, String(facts.pid), application]
        ).rows
        let queryEnd = DispatchTime.now().uptimeNanoseconds
        guard queryEnd <= deadline, rows.count <= 1, hold.heldUnexpired() else {
          throw FixtureFailure.nativeShape
        }
        if rows.count == 1 {
          guard rows[0].int("pid") == facts.pid else { throw FixtureFailure.nativeShape }
          return facts.pid
        }
      }
      guard DispatchTime.now().uptimeNanoseconds <= deadline else { throw FixtureFailure.nativeShape }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static let ownedDeferredCommitWait = """
    SELECT a.pid::text AS pid,
      ceil(extract(epoch FROM (clock_timestamp()-a.query_start))*1000000)::bigint::text AS age_us
    FROM pg_catalog.pg_stat_activity a
    JOIN pg_catalog.pg_database db ON db.datname=$1
    WHERE a.datname=$1 AND a.usename=current_user AND a.application_name=$6
      AND a.backend_type='client backend' AND a.pid<>pg_backend_pid() AND a.pid<>$2::int
      AND NOT(a.pid=ANY($4::int[]))
      AND a.state='active' AND a.wait_event_type='Lock' AND a.wait_event='advisory'
      AND a.query='COMMIT' AND a.query_start IS NOT NULL
      AND $2::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_stat_activity h WHERE h.pid=$2::int
        AND h.datname=$1 AND h.usename=current_user AND h.application_name=$5
        AND h.backend_type='client backend' AND h.state='idle in transaction')
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks w JOIN pg_catalog.pg_locks h
        ON h.database=w.database AND h.classid=w.classid
          AND h.objid=w.objid AND h.objsubid=w.objsubid
        WHERE w.pid=a.pid AND w.locktype='advisory' AND w.mode='ExclusiveLock' AND NOT w.granted
          AND w.database=db.oid AND w.classid=0::oid AND w.objid=$3::oid AND w.objsubid=1
          AND h.pid=$2::int AND h.locktype='advisory' AND h.mode='ExclusiveLock' AND h.granted)
      AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks g WHERE g.pid=a.pid
        AND g.locktype='advisory' AND g.mode='ExclusiveLock' AND g.granted
        AND g.database=db.oid AND g.classid=0::oid AND g.objid=$7::oid AND g.objsubid=1)
    """

  private static func ownedDeferredObserveCommit(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    holderApplication: String, candidateApplication: String, rawPID: Int?,
    hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedBindMemory?,
    invocationStart: Int, probes: OwnedDeferredProbes, deadline: UInt64
  ) throws {
    guard holderPID > 0, knownOwnedPIDs.contains(holderPID),
      knownOwnedPIDs.allSatisfy({ $0 > 0 }), WorkspaceDatabase.remoteApplyLockKey == 1647599984,
      WorkspaceDatabase.remoteApplyLockKey != 1647600739
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard hold.heldUnexpired(), finished.pending() else { throw FixtureFailure.nativeShape }
      if let memory {
        let delta = memory.calls() - invocationStart
        guard (0...3).contains(delta) else { throw FixtureFailure.nativeShape }
        if delta != 3 {
          // Waiting for entry is non-credit; no memory ordinal substitutes for native COMMIT.
          Thread.sleep(forTimeInterval: 0.005)
          continue
        }
      }
      let queryBegin = DispatchTime.now().uptimeNanoseconds
      let rows = try c.execute(
        ownedDeferredCommitWait,
        [
          database, String(holderPID), "1647600739", excluded,
          holderApplication, candidateApplication, "1647599984",
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      // Both query completion and all synchronous proof reads must fit the ORIGINAL window.
      guard queryBegin <= queryEnd, queryEnd <= deadline, rows.count <= 1,
        hold.heldUnexpired(), finished.pending(),
        memory.map({ $0.calls() - invocationStart == 3 }) ?? true
      else { throw FixtureFailure.nativeShape }
      let actualProbes = try ownedDeferredProbes(c)
      guard actualProbes.timeout == probes.timeout,
        actualProbes.body.advanced(from: probes.body, by: 0)
          || actualProbes.body.advanced(from: probes.body, by: 1),
        actualProbes.commit.advanced(from: probes.commit, by: 0)
          || actualProbes.commit.advanced(from: probes.commit, by: 1),
        DispatchTime.now().uptimeNanoseconds <= deadline,
        hold.heldUnexpired(), finished.pending(),
        memory.map({ $0.calls() - invocationStart == 3 }) ?? true
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid), rawPID.map({ $0 == pid }) ?? true,
          let ageText = rows[0].text("age_us"), let age = Int64(ageText), age >= 0,
          actualProbes.advanced(from: probes, body: 1, commit: 1, timeout: 0),
          DispatchTime.now().uptimeNanoseconds <= deadline,
          hold.heldUnexpired(), finished.pending(),
          memory.map({ $0.calls() - invocationStart == 3 }) ?? true
        else { throw FixtureFailure.nativeShape }
        // Age is a nonnegative diagnostic only, never a cause or timer reset.
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedDeferredRelease(
    _ hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedBindMemory?,
    invocationStart: Int, retire: Bool, deadline: UInt64
  ) throws {
    guard hold.heldUnexpired(), finished.pending(),
      memory.map({ $0.calls() - invocationStart == 3 }) ?? true,
      !retire || memory != nil
    else { throw FixtureFailure.nativeShape }
    if retire { memory?.setCurrent(false) }
    // The memory mutex has been released. Nothing blocking or SQL runs before release.
    let retirement = DispatchTime.now().uptimeNanoseconds
    let original = hold.snapshot()
    guard original.entered, original.held, !original.expired, !original.released,
      retirement < original.expiry, finished.pending(),
      memory.map({ $0.calls() - invocationStart == 3 }) ?? true
    else { throw FixtureFailure.nativeShape }
    let releaseStart = DispatchTime.now().uptimeNanoseconds
    hold.release()
    let releaseEnd = DispatchTime.now().uptimeNanoseconds
    let released = hold.snapshot()
    guard retirement <= releaseStart, releaseStart <= releaseEnd, releaseEnd <= deadline,
      releaseEnd < original.expiry, released.released, !released.expired
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedDeferredInspectorPID(_ c: PostgresConnection) throws -> Int {
    let rows = try c.execute("SELECT pg_backend_pid() AS pid").rows
    guard rows.count == 1, let pid = rows[0].int("pid"), pid > 0 else {
      throw FixtureFailure.nativeShape
    }
    return pid
  }

  private static func ownedDeferredControl(_ image: OwnedBindImage) throws -> [String: Any] {
    guard let settings = image.rows["settings"] else { throw FixtureFailure.nativeShape }
    let rows = try settings.map { try ownedT09Object($0) }.filter { $0["key"] as? String == key }
    guard rows.count == 1, let control = rows[0]["value"] as? [String: Any] else {
      throw FixtureFailure.nativeShape
    }
    return control
  }

  private static func ownedDeferredDamage(
    _ c: PostgresConnection, recipe: OwnedDeferredRecipe, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredRecipe {
    diagnostic.enter(.damage)
    let stage = recipe.stage
    guard let rows = stage.expected.rows["settings"] else { throw FixtureFailure.nativeShape }
    var old: Data?
    var new: Data?
    let damaged = try rows.map { data -> Data in
      var object = try ownedT09Object(data)
      if object["key"] as? String == sentinelKey {
        guard old == nil, object["value"] as? String == "OWNED_PROOF_RETAINED" else {
          throw FixtureFailure.nativeShape
        }
        old = data
        object["value"] = "OWNED_BIND_PRIVATE_IMAGE_CORRUPTION"
        let value = try ownedT09Data(object)
        new = value
        return value
      }
      return data
    }.sorted { $0.lexicographicallyPrecedes($1) }
    guard let old, let new,
      try c.execute(
        """
        UPDATE "owned_bind_stage"."expected" AS e
        SET value=pg_catalog.jsonb_set(value,'{value}',
          pg_catalog.to_jsonb('OWNED_BIND_PRIVATE_IMAGE_CORRUPTION'::text))
        WHERE name='settings' AND value=$1::jsonb
        """, [try ownedBindText(old)]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    let checked = try c.execute(
      """
      SELECT value::text AS value FROM "owned_bind_stage"."expected"
      WHERE name='settings' AND value->>'key'=$1
      """, [sentinelKey]
    ).rows
    guard checked.count == 1, let value = checked[0].text("value"),
      try ownedBindJSON(value) == new
    else { throw FixtureFailure.nativeShape }
    var expected = stage.expected.rows
    expected["settings"] = damaged
    let adapted = OwnedBindStageFixture(
      before: stage.before,
      expected: OwnedBindImage(
        database: stage.expected.database, rows: expected, sequence: stage.expected.sequence),
      controlJSON: stage.controlJSON, originalReference: stage.originalReference,
      replacement: stage.replacement, device: stage.device, lowerWall: stage.lowerWall)
    let result = OwnedDeferredRecipe(stage: adapted, catalog: recipe.catalog)
    try ownedDeferredRecipeCheck(c, recipe: result, mode: "normal", baseline: 0, diagnostic: diagnostic)
    return result
  }

  private struct OwnedDeferredControlFacts {
    let row: Int
    let attempts: Int
    let holders: Int
    let acknowledgements: Int
    let errors: Int
    let rollbacks: Int
    let bodies: Int
    let deferred: Int
    let timeouts: Int
    let restorations: Int
    let transitions: Int
    let qualified: Bool
  }

  private static func ownedDeferredRawControl(
    _ row: Int, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredControlFacts {
    diagnostic.selectRawFixture(row)
    diagnostic.attempt = .none
    guard (0...4).contains(row) else { throw FixtureFailure.nativeShape }
    var facts: OwnedDeferredControlFacts?
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      let predecessor = try validateFixture(f)
      diagnostic.enter(.freeze)
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: f.link.tokenRef)
      var mode = row == 2 ? "fault" : (row >= 3 ? "gate" : "normal")
      var baseline = 0
      diagnostic.enter(.oldInstall)
      var recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      diagnostic.enter(.damage)
      if row == 0 { recipe = try ownedDeferredDamage(f.inspector, recipe: recipe, diagnostic: diagnostic) }
      diagnostic.enter(.initialState)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let work = OwnedDeferredWork()
      // Registration precedes every holder/worker, including partially started attempts.
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var attempts = 0
      var acknowledgements = 0
      var errors = 0
      var rollbacks = 0
      var bodies = 0
      var deferred = 0
      var timeouts = 0
      var restorations = 0
      var transitions = 0
      for attempt in 0..<(row == 0 ? 1 : 2) {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        let gated = row >= 3
        let timeout = row == 4 && attempt == 0
        let kind: OwnedDeferredRawKind =
          row == 0 ? .reject : (row == 2 && attempt == 0 ? .fault : (timeout ? .timeout : .normal))
        let application = "owned-deferred-raw-\(UUID().uuidString)"
        let holderApplication = "owned-deferred-gate-\(UUID().uuidString)"
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        var holderPID = 0
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        let state = OwnedBindHolderState()
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        diagnostic.enter(.rawStart)
        let worker = ownedDeferredRawWorker(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: application,
          kind: kind, state: state, finished: finished)
        work.raw.append(worker)
        diagnostic.enter(.observeCommit)
        if gated {
          while state.snapshot().pid == 0 && finished.pending()
            && DispatchTime.now().uptimeNanoseconds <= deadline
          { Thread.sleep(forTimeInterval: 0.005) }
          let candidate = state.snapshot()
          guard candidate.acquired, candidate.pid > 0, !knownPIDs.contains(candidate.pid),
            DispatchTime.now().uptimeNanoseconds <= deadline
          else { throw FixtureFailure.nativeShape }
          try ownedDeferredObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: application, rawPID: candidate.pid, hold: hold,
            finished: finished, memory: nil, invocationStart: 0, probes: before.probes,
            deadline: deadline)
          if !timeout {
            try ownedDeferredRelease(
              hold, finished: finished, memory: nil, invocationStart: 0, retire: false,
              deadline: deadline)
          }
        }
        // The intended timeout keeps its original eight-second hold valid until actual return.
        // Capture the result/timestamp, then immediately release ALL and join ALL before guards.
        diagnostic.enter(.resultCapture)
        let result = worker.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        let rawIdentity = state.snapshot()
        diagnostic.enter(.rawResult)
        guard result.valid, finished.pending() == false, rawIdentity.acquired,
          rawIdentity.pid > 0, !knownPIDs.contains(rawIdentity.pid),
          (!gated || held?.normal == true), heldAtReturn,
          !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        knownPIDs.append(rawIdentity.pid)
        attempts += 1
        let success = kind == .normal
        let bodyCount: Int64 = row == 0 ? 0 : 1
        let commitCount: Int64 = row == 0 ? 0 : 1
        let timeoutCount: Int64 = timeout ? 1 : 0
        diagnostic.enter(.rawResult)
        guard result.dmlReturned == (row != 0), result.commitSent == (row != 0),
          result.acknowledged == success, result.rollbackAcknowledged == (row == 0),
          result.predicateRejected == (row == 0),
          result.actualDeferredFault == (kind == .fault), result.actualServerTimeout == timeout,
          result.ownPredicate == (row != 0), result.ownSettings == (row != 0)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard after.image == (success ? stage.expected : stage.before),
          after.probes.advanced(
            from: before.probes, body: bodyCount, commit: commitCount, timeout: timeoutCount)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.observations)
        if success {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations, actual: after.observations,
            rawMillis: result.millis)
          acknowledgements += 1
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
          if row == 0 { rollbacks += 1 } else { errors += 1 }
        }
        bodies += Int(bodyCount)
        deferred += Int(commitCount)
        timeouts += Int(timeoutCount)
        if attempt == 0 && (row == 1 || row == 3) {
          diagnostic.enter(.q01)
          try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
          restorations += 1
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
            diagnostic: diagnostic)
          baseline = 1
          transitions += 1
        } else if attempt == 0 && row == 2 {
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
            diagnostic: diagnostic)
          mode = "normal"
          transitions += 1
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.raw.count == (row == 0 ? 1 : 2), work.holders.count == (row >= 3 ? 2 : 0) else {
        throw FixtureFailure.nativeShape
      }
      facts = OwnedDeferredControlFacts(
        row: row, attempts: attempts, holders: work.holders.count,
        acknowledgements: acknowledgements, errors: errors, rollbacks: rollbacks,
        bodies: bodies, deferred: deferred, timeouts: timeouts,
        restorations: restorations, transitions: transitions, qualified: true)
    }
    // Complete fixture close/root teardown precedes escape of these primitive-only facts.
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private static func ownedDeferredPrerequisites(
    diagnostic: OwnedDeferredDiagnostic
  ) throws -> (
    old: Int, controls: Int, attempts: Int, holders: Int
  ) {
    diagnostic.fixture = .oldFour
    diagnostic.attempt = .none
    diagnostic.enter(.oldFour)
    let old = try ownedBindRawStageControls()
    diagnostic.enter(.oldFour)
    guard old.map({ $0.row }) == [0, 1, 2, 3], old.count == 4,
      old.allSatisfy({ $0.qualified && $0.durableImageValidated })
    else { throw FixtureFailure.nativeShape }
    // The old four have ALL torn down. Each NEW recipe row independently tears down as well.
    var rows: [OwnedDeferredControlFacts] = []
    for row in 0...4 { rows.append(try ownedDeferredRawControl(row, diagnostic: diagnostic)) }
    diagnostic.fixture = .none
    diagnostic.attempt = .none
    diagnostic.enter(.finalFacts)
    guard rows.map({ $0.row }) == [0, 1, 2, 3, 4], rows.allSatisfy({ $0.qualified }),
      rows.map({ $0.attempts }) == [1, 2, 2, 2, 2],
      rows.map({ $0.holders }) == [0, 0, 0, 2, 2],
      rows.map({ $0.acknowledgements }) == [0, 2, 1, 2, 1],
      rows.map({ $0.errors }) == [0, 0, 1, 0, 1],
      rows.map({ $0.rollbacks }) == [1, 0, 0, 0, 0],
      rows.map({ $0.bodies }) == [0, 2, 2, 2, 2],
      rows.map({ $0.deferred }) == [0, 2, 2, 2, 2],
      rows.map({ $0.timeouts }) == [0, 0, 0, 0, 1],
      rows.map({ $0.restorations }) == [0, 1, 0, 1, 0],
      rows.map({ $0.transitions }) == [0, 1, 1, 1, 0]
    else { throw FixtureFailure.nativeShape }
    return (old.count, rows.count, rows.reduce(0) { $0 + $1.attempts }, rows.reduce(0) { $0 + $1.holders })
  }

  private static func ownedDeferredRefuses(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture,
    admission: ProtocolProofMemoryAdmission, memory: OwnedBindMemory,
    disposition: ProtocolProofWriteDisposition
  ) throws {
    let before = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == disposition else {
      throw FixtureFailure.nativeShape
    }
    let refused = !validates {
      _ = try receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
    }
    guard refused, memory.calls() == before, receipt.disposition == disposition else {
      throw FixtureFailure.nativeShape
    }
    // The sealed redemption implementation refuses before its callback and contains no SQL.
    // Inspector S0 is never used to upgrade an unknown receipt to continuation evidence.
  }

  private static func ownedDeferredTarget(
    _ unit: OwnedDeferredCase, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredFacts {
    // Every call owns ALL prerequisites; no cache, earlier test, or previously qualified run.
    let prerequisites = try ownedDeferredPrerequisites(diagnostic: diagnostic)
    var facts: OwnedDeferredFacts?
    diagnostic.fixture = .target
    diagnostic.attempt = .none
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      let predecessor = try validateFixture(f)
      let reference = f.link.tokenRef
      guard ProtocolCredentialReference(reference) != nil,
        reference.utf8.allSatisfy({ $0 > 0 && $0 < 128 })
      else { throw FixtureFailure.nativeShape }
      diagnostic.enter(.freeze)
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: reference)
      var mode = unit == .fault ? "fault" : "gate"
      var baseline = 0
      diagnostic.enter(.oldInstall)
      let recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      diagnostic.enter(.initialState)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var original: ProtocolOwnedProofWriteReceipt?
      var writerCalls = 0
      var redemptions = 0
      var waits = 0
      var timeoutAllocations = 0
      for attempt in 0..<2 {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        diagnostic.enter(.targetWrite)
        let invocationStart = memory.calls()
        let expectedStart = attempt == 0 ? 0 : (unit == .stale ? 4 : 3)
        guard invocationStart == expectedStart else { throw FixtureFailure.nativeShape }
        let gated = unit != .fault
        let timeout = unit == .timeout && attempt == 0
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        let holderApplication = "owned-deferred-target-gate-\(UUID().uuidString)"
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        var holderPID = 0
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        diagnostic.enter(.targetWrite)
        guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        // Literal same original database/anchor/binding/reference/admission for both invocations.
        diagnostic.enter(.targetWrite)
        let writer = ownedBindWriter(
          database: f.database, anchor: f.anchor, binding: f.binding, reference: reference,
          admission: admission, finished: finished)
        work.writers.append(writer)
        if gated {
          diagnostic.enter(.observeCommit)
          try ownedDeferredObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: "b4app", rawPID: nil, hold: hold, finished: finished,
            memory: memory, invocationStart: invocationStart, probes: before.probes,
            deadline: deadline)
          waits += 1
          if !timeout {
            try ownedDeferredRelease(
              hold, finished: finished, memory: memory, invocationStart: invocationStart,
              retire: unit == .stale && attempt == 0, deadline: deadline)
          }
        }
        // No throwing assertion, inspector image, or receipt validation may intervene here.
        // In the timeout branch actual receipt capture occurs while the original hold is valid;
        // immediately release ALL and join ALL before validating any result, including this fact.
        diagnostic.enter(.resultCapture)
        let receipt = writer.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        guard !finished.pending(), !gated || held?.normal == true,
          heldAtReturn, !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        let committed = unit == .stale || attempt == 1
        let expectedCalls = committed ? 4 : 3
        let delta = memory.calls() - invocationStart
        diagnostic.enter(.targetReceipt)
        guard receipt.operation == .bind, delta == expectedCalls,
          after.image == (committed ? stage.expected : stage.before),
          after.probes.advanced(from: before.probes, body: 1, commit: 1, timeout: timeout ? 1 : 0)
        else { throw FixtureFailure.nativeShape }
        writerCalls += delta
        if timeout { timeoutAllocations += 1 }
        diagnostic.enter(.observations)
        if committed {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations,
            actual: after.observations, rawMillis: nil)
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
        }
        if attempt == 0 {
          original = receipt
          let disposition: ProtocolProofWriteDisposition = unit == .stale ? .committedStale : .unknown
          diagnostic.enter(.targetRefusal)
          try ownedDeferredRefuses(
            receipt, fixture: f, admission: admission, memory: memory, disposition: disposition)
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
          if unit == .stale {
            // Genuine acknowledged stale S1 and its original refusal were checked BEFORE Q01.
            // This fixture-only restoration is never a rollback or repair by the product API.
            diagnostic.enter(.q01)
            try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
              diagnostic: diagnostic)
            baseline = 1
            memory.setCurrent(true)
          } else if unit == .fault {
            // Exact native 23514/canary/COMMIT was directly qualified by this unit's R2.
            // Target fault/stage/source attribution is explicitly INFERENCE from the immutable
            // full recipe, body/deferred relative probes, genuine unknown and reviewed writer
            // COMMIT-sent catch; the sealed target receipt exports no native diagnostic.
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
              diagnostic: diagnostic)
            mode = "normal"
          }
          // T07's ONLY timeout allocation is inside its actual deferred gate handler, after
          // exact COMMIT/blocker/resource observation. Own R4 qualified original native rethrow.
          // An infeasible handler fails prerequisites; elapsed+unknown+S0 supplies no substitute.
        } else {
          guard receipt.disposition == .committedCurrent else { throw FixtureFailure.nativeShape }
          diagnostic.enter(.targetRedemption)
          let beforeRedemption = memory.calls()
          let successor = try receipt.currentSuccessor(
            expectedSnapshot: f.anchor, expectedTokenRef: reference, memoryAdmission: admission)
          let afterRedemption = memory.calls()
          guard afterRedemption - beforeRedemption == 1 else { throw FixtureFailure.nativeShape }
          redemptions += afterRedemption - beforeRedemption
          diagnostic.enter(.successorValidation)
          try validateSuccessor(f, successor)
          diagnostic.enter(.originalRefusal)
          guard let original else { throw FixtureFailure.nativeShape }
          try ownedDeferredRefuses(
            original, fixture: f, admission: admission, memory: memory,
            disposition: unit == .stale ? .committedStale : .unknown)
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.writers.count == 2, work.raw.isEmpty,
        work.holders.count == (unit == .fault ? 0 : 2),
        writerCalls == (unit == .stale ? 8 : 7), redemptions == 1,
        memory.calls() == writerCalls + redemptions, waits == (unit == .fault ? 0 : 2),
        timeoutAllocations == (unit == .timeout ? 1 : 0)
      else { throw FixtureFailure.nativeShape }
      facts = OwnedDeferredFacts(
        oldControls: prerequisites.old, newControls: prerequisites.controls,
        rawAttempts: prerequisites.attempts, rawHolders: prerequisites.holders,
        writerCalls: writerCalls, redemptionCalls: redemptions, targetHolders: work.holders.count,
        targetWaits: waits, timeoutAllocations: timeoutAllocations, qualified: true)
    }
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  @Test(NativeDBResources()) func ownedBindRetirementDuringRealSuccessfulCommitIsStale() throws {
    let facts = try Self.ownedDeferredDiagnosedTarget(.stale)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.writerCalls == 8 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 2 && facts.targetWaits == 2)
    #expect(facts.timeoutAllocations == 0 && facts.qualified)
  }

  @Test(NativeDBResources()) func ownedBindActualDeferredFaultAndSameInputAllow() throws {
    let facts = try Self.ownedDeferredDiagnosedTarget(.fault)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.writerCalls == 7 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 0 && facts.targetWaits == 0)
    #expect(facts.timeoutAllocations == 0 && facts.qualified)
  }

  @Test(NativeDBResources()) func ownedBindActualCommitServerTimeoutIsUnknown() throws {
    let facts = try Self.ownedDeferredDiagnosedTarget(.timeout)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.writerCalls == 7 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 2 && facts.targetWaits == 2)
    #expect(facts.timeoutAllocations == 1 && facts.qualified)
  }

  // Synchronous coordinator context only: entered regions never attest native completion/cause.
  // State retains only finite enums, never errors, fixtures, connections, images or identifiers.
  private final class OwnedDeferredDiagnostic {
    enum FixtureRegion: String {
      case none, oldFour, r0 = "R0", r1 = "R1", r2 = "R2", r3 = "R3", r4 = "R4", target
    }
    enum Attempt: String { case none, first, second }
    enum Phase: String {
      case oldFour, fixtureConstruct, fixtureValidate, freeze, oldInstall, privateDDL
      case controlInsert, functionCreate, functionCount, functionSource, functionSignatureAndAttributes
      case privateObjects, columns, constraints, sequences, triggerDefinition
      case triggerRowCount, triggerNameValue, triggerDefinitionValue, triggerFunctionIdentity, catalogCapture
      case triggerNameUnknown, triggerDefinitionNil
      case triggerBodyOtherValue, triggerCommitOtherValue
      case recipeNamesRowsMeta, recipeConfig, recipeCatalog, initialState, damage, beforeCheckpoint
      case gateClear, holderStart, holderReady, rawStart, observeCommit, resultCapture, drainReturned
      case rawResult, afterCheckpoint, imageAndProbes, observations, q01 = "Q01", configTransition
      case targetWrite, targetReceipt, targetRefusal, targetRedemption, successorValidation
      case originalRefusal, finalFacts, fixtureBodyReturned, fixtureReturned
    }
    enum Category: String { case guardMismatch, postgresError, otherError, fixtureBoundaryError }
    enum Unwind: String { case returned }
    private struct Failure {
      let fixture: FixtureRegion
      let attempt: Attempt
      let phase: Phase
      let category: Category
    }
    private let unit: OwnedDeferredCase
    var fixture: FixtureRegion = .none
    var attempt: Attempt = .none
    private var phase: Phase = .oldFour
    private var failure: Failure?

    init(unit: OwnedDeferredCase) { self.unit = unit }
    func enter(_ phase: Phase) { self.phase = phase }
    func selectRawFixture(_ row: Int) {
      switch row {
      case 0: fixture = .r0
      case 1: fixture = .r1
      case 2: fixture = .r2
      case 3: fixture = .r3
      case 4: fixture = .r4
      default: fixture = .none
      }
    }
    func selectAttempt(_ index: Int) {
      switch index {
      case 0: attempt = .first
      case 1: attempt = .second
      default: attempt = .none
      }
    }
    func freeze(_ error: any Error) {
      if failure != nil { return }
      let category: Category
      if error is PostgresError {
        category = .postgresError
      } else if let fixed = error as? FixtureFailure {
        switch fixed {
        case .nativeShape: category = .guardMismatch
        case .redactedFailure: category = .fixtureBoundaryError
        }
      } else {
        category = .otherError
      }
      failure = Failure(fixture: fixture, attempt: attempt, phase: phase, category: category)
    }
    func freezeBoundary() {
      if failure != nil { return }
      failure = Failure(fixture: fixture, attempt: attempt, phase: phase, category: .fixtureBoundaryError)
    }
    private var unitLiteral: String {
      switch unit {
      case .stale: return "stale"
      case .fault: return "fault"
      case .timeout: return "timeout"
      }
    }
    var failureLine: String {
      let value = failure ?? Failure(fixture: fixture, attempt: attempt, phase: phase, category: .otherError)
      return "TASK5_DIAG_V1 unit=" + unitLiteral + " fixture=" + value.fixture.rawValue
        + " attempt=" + value.attempt.rawValue + " enteredPhase=" + value.phase.rawValue
        + " category=" + value.category.rawValue + " unwind=" + Unwind.returned.rawValue
    }
  }

  // Calls the original fixture wrapper. Existing body release/join defers run before this
  // nonescaping catch freezes primitives; the original wrapper still owns close/redaction.
  private static func ownedDeferredWithFixture(
    _ diagnostic: OwnedDeferredDiagnostic, _ body: (Fixture) throws -> Void
  ) throws {
    diagnostic.enter(.fixtureConstruct)
    do {
      try withFixture { f in
        do {
          try body(f)
          diagnostic.enter(.fixtureBodyReturned)
        } catch {
          diagnostic.freeze(error)
          throw error
        }
      }
      diagnostic.enter(.fixtureReturned)
    } catch {
      diagnostic.freezeBoundary()
      throw error
    }
  }

  private static func ownedDeferredDiagnosedTarget(_ unit: OwnedDeferredCase) throws -> OwnedDeferredFacts {
    let diagnostic = OwnedDeferredDiagnostic(unit: unit)
    do {
      return try ownedDeferredTarget(unit, diagnostic: diagnostic)
    } catch {
      // All owned target/helper/fixture scopes have returned or unwound before this one line.
      // Returned is scope ordering only, never cleanup success or physical quiescence.
      diagnostic.freeze(error)
      print(diagnostic.failureLine)
      throw error
    }
  }
}

extension OwnedProtocolProofWriteTests {
  private enum OwnedT12Outcome: Equatable {
    case current, stale, noncommit, commitTimeoutUnknown

    var disposition: ProtocolProofWriteDisposition {
      switch self {
      case .current: return .committedCurrent
      case .stale: return .committedStale
      case .noncommit: return .confirmedNoncommit
      case .commitTimeoutUnknown: return .unknown
      }
    }
    var committed: Bool { self == .current || self == .stale }
    var calls: Int { self == .noncommit ? 1 : (self == .commitTimeoutUnknown ? 3 : 4) }
  }

  private enum OwnedT12Mode: Equatable { case openDisposal, closingLease }

  // Coordinator-local primitive identity. It contains no native handle or proof capability.
  private struct OwnedT12BackendIdentity {
    let socketDir: String
    let port: Int
    let database: String
    let user: String
    let application: String
    let pid: Int
    let backendStart: String
  }

  private struct OwnedT12Ordinary {
    let alias: PostgresConnection
    let identity: OwnedT12BackendIdentity
  }

  // Only these fixed primitive facts leave a fully unwound fixture.
  private struct OwnedT12UnitFacts {
    let admittedWriters: Int
    let writerCalls: Int
    let redemptionCalls: Int
    let nativeWaits: Int
    let normalHolders: Int
    let openAbsences: Int
    let laterOrdinary: Int
    let busyClose: Int
    let drainedClose: Int
    let closedRefusals: Int
    let timeoutAllocations: Int
    let qualified: Bool
  }

  private struct OwnedT12Facts {
    let oldControls: Int
    let newControls: Int
    let rawAttempts: Int
    let rawHolders: Int
    let units: Int
    let admittedWriters: Int
    let publicEntries: Int
    let writerCalls: Int
    let redemptionCalls: Int
    let nativeWaits: Int
    let normalHolders: Int
    let openAbsences: Int
    let laterOrdinary: Int
    let busyClose: Int
    let drainedClose: Int
    let closedRefusals: Int
    let timeoutAllocations: Int
    let qualified: Bool
  }

  private static let ownedT12IdentityColumns = """
    SELECT a.pid::text AS pid,a.backend_start::text AS backend_start,
      a.datname AS database,a.usename::text AS username,a.application_name AS application,
      pg_catalog.current_database() AS observer_database,current_user::text AS observer_user
    FROM pg_catalog.pg_stat_activity a
    """

  private static func ownedT12Identity(
    _ rows: [Row], fixture f: Fixture
  ) throws -> OwnedT12BackendIdentity {
    let endpoint = f.database.endpoint
    guard rows.count == 1, let row = rows.first, let pid = row.int("pid"), pid > 0,
      let start = row.text("backend_start"), !start.isEmpty,
      let database = row.text("database"), equalBytes(database, endpoint.database),
      let user = row.text("username"), equalBytes(user, NSUserName()),
      let application = row.text("application"), equalBytes(application, "b4app"),
      row.text("observer_database").map({ equalBytes($0, endpoint.database) }) == true,
      row.text("observer_user").map({ equalBytes($0, user) }) == true
    else { throw FixtureFailure.nativeShape }
    return OwnedT12BackendIdentity(
      socketDir: endpoint.socketDir, port: endpoint.port, database: database, user: user,
      application: application, pid: pid, backendStart: start)
  }

  private static func ownedT12SameSession(
    _ a: OwnedT12BackendIdentity, _ b: OwnedT12BackendIdentity
  ) -> Bool {
    a.port == b.port && a.pid == b.pid && equalBytes(a.socketDir, b.socketDir)
      && equalBytes(a.database, b.database) && equalBytes(a.user, b.user)
      && equalBytes(a.application, b.application) && equalBytes(a.backendStart, b.backendStart)
  }

  private static func ownedT12OrdinaryProbe(_ f: Fixture) throws -> OwnedT12Ordinary {
    try f.database.read { c in
      let rows = try c.execute(
        ownedT12IdentityColumns
          + " WHERE a.pid=pg_catalog.pg_backend_pid() AND a.backend_type='client backend'"
      ).rows
      return OwnedT12Ordinary(alias: c, identity: try ownedT12Identity(rows, fixture: f))
    }
  }

  private static func ownedT12AdvisoryHolderReady(
    _ f: Fixture, state: OwnedBindHolderState, hold: OwnedProofHold,
    application: String, deadline: UInt64
  ) throws -> Int {
    let pid = try ownedBindHolderReady(state, hold: hold, deadline: deadline)
    let rows = try f.inspector.execute(
      """
      SELECT h.pid::text AS pid FROM pg_catalog.pg_stat_activity h
      JOIN pg_catalog.pg_database db ON db.datname=$1
      WHERE h.pid=$2::int AND h.datname=$1 AND h.usename=current_user
        AND h.application_name=$3 AND h.backend_type='client backend'
        AND h.state='idle in transaction'
        AND EXISTS(SELECT 1 FROM pg_catalog.pg_locks g WHERE g.pid=h.pid
          AND g.locktype='advisory' AND g.mode='ExclusiveLock' AND g.granted
          AND g.database=db.oid AND g.classid=0::oid AND g.objid=$4::oid AND g.objsubid=1)
      """,
      [f.database.endpoint.database, String(pid), application, String(WorkspaceDatabase.remoteApplyLockKey)]
    ).rows
    let queryEnd = DispatchTime.now().uptimeNanoseconds
    guard queryEnd <= deadline, rows.count == 1, rows[0].int("pid") == pid,
      hold.heldUnexpired(), state.snapshot().acquired, state.snapshot().pid == pid
    else { throw FixtureFailure.nativeShape }
    return pid
  }

  private static func ownedT12ObserveWriter(
    _ f: Fixture, outcome: OwnedT12Outcome, holderPID: Int, knownPIDs: [Int],
    holderApplication: String, hold: OwnedProofHold, finished: OwnedBindFinished,
    memory: OwnedBindMemory, invocationStart: Int, probes: OwnedDeferredProbes,
    deadline: UInt64
  ) throws -> OwnedT12BackendIdentity {
    let advisory = outcome == .noncommit
    let expectedCalls = advisory ? 0 : 3
    if advisory {
      try ownedBindObserveWait(
        f.inspector, database: f.database.endpoint.database, holderPID: holderPID,
        knownOwnedPIDs: knownPIDs, kind: .advisory, hold: hold, finished: finished,
        memory: memory, invocationStart: invocationStart, deadline: deadline)
    } else {
      try ownedDeferredObserveCommit(
        f.inspector, database: f.database.endpoint.database, holderPID: holderPID,
        knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
        candidateApplication: "b4app", rawPID: nil, hold: hold, finished: finished,
        memory: memory, invocationStart: invocationStart, probes: probes, deadline: deadline)
    }
    // Reuse the SAME protected query and parameters, inside that SAME original window.
    let excluded = "{" + knownPIDs.map(String.init).joined(separator: ",") + "}"
    let sql = advisory ? ownedBindAdvisoryWait : ownedDeferredCommitWait
    let parameters: [String?] =
      advisory
      ? [
        f.database.endpoint.database, String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey),
        "SELECT pg_advisory_xact_lock($1::bigint)", excluded,
      ]
      : [
        f.database.endpoint.database, String(holderPID), "1647600739", excluded,
        holderApplication, "b4app", "1647599984",
      ]
    func pendingWithinWindow() -> Bool {
      DispatchTime.now().uptimeNanoseconds <= deadline && hold.heldUnexpired()
        && finished.pending() && memory.calls() - invocationStart == expectedCalls
    }
    guard pendingWithinWindow() else { throw FixtureFailure.nativeShape }
    let selected = try f.inspector.execute(sql, parameters).rows
    let selectedEnd = DispatchTime.now().uptimeNanoseconds
    guard selectedEnd <= deadline, selected.count == 1, let pid = selected[0].int("pid"),
      pid > 0, !knownPIDs.contains(pid), pendingWithinWindow()
    else { throw FixtureFailure.nativeShape }
    if !advisory {
      guard let age = selected[0].text("age_us").flatMap(Int64.init), age >= 0 else {
        throw FixtureFailure.nativeShape
      }
    }
    let identitySQL =
      ownedT12IdentityColumns
      + " WHERE a.pid=$1::int AND a.datname=$2 AND a.usename=current_user"
      + " AND a.application_name='b4app' AND a.backend_type='client backend'"
      + " AND a.backend_start IS NOT NULL"
    let identityParameters: [String?] = [String(pid), f.database.endpoint.database]
    let scoped = try f.inspector.execute(identitySQL, identityParameters).rows
    let identityEnd = DispatchTime.now().uptimeNanoseconds
    guard identityEnd <= deadline, pendingWithinWindow() else { throw FixtureFailure.nativeShape }
    let identity = try ownedT12Identity(scoped, fixture: f)
    guard identity.pid == pid else { throw FixtureFailure.nativeShape }
    // Identity is never accepted after release or timeout. The exact owned wait must still exist.
    let revalidated = try f.inspector.execute(sql, parameters).rows
    let revalidatedEnd = DispatchTime.now().uptimeNanoseconds
    guard revalidatedEnd <= deadline, revalidated.count == 1,
      revalidated[0].int("pid") == pid, pendingWithinWindow()
    else { throw FixtureFailure.nativeShape }
    if !advisory {
      guard let age = revalidated[0].text("age_us").flatMap(Int64.init), age >= 0 else {
        throw FixtureFailure.nativeShape
      }
    }
    let sameIdentityRows = try f.inspector.execute(identitySQL, identityParameters).rows
    let sameIdentityEnd = DispatchTime.now().uptimeNanoseconds
    guard sameIdentityEnd <= deadline, pendingWithinWindow(),
      ownedT12SameSession(try ownedT12Identity(sameIdentityRows, fixture: f), identity)
    else { throw FixtureFailure.nativeShape }
    let actualProbes = try ownedDeferredProbes(f.inspector)
    let probesEnd = DispatchTime.now().uptimeNanoseconds
    guard probesEnd <= deadline, pendingWithinWindow(),
      actualProbes.advanced(from: probes, body: advisory ? 0 : 1, commit: advisory ? 0 : 1, timeout: 0)
    else { throw FixtureFailure.nativeShape }
    return identity
  }

  private static func ownedT12Absent(
    _ f: Fixture, identity: OwnedT12BackendIdentity
  ) throws {
    let endpoint = f.database.endpoint
    guard equalBytes(identity.socketDir, endpoint.socketDir), identity.port == endpoint.port,
      equalBytes(identity.database, endpoint.database), equalBytes(identity.user, NSUserName()),
      equalBytes(identity.application, "b4app")
    else { throw FixtureFailure.nativeShape }
    let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      // Do not filter scope here: a same pid/start row with wrong scope must FAIL, not look absent.
      let rows = try f.inspector.execute(
        ownedT12IdentityColumns + " WHERE a.pid=$1::int AND a.backend_start::text=$2",
        [String(identity.pid), identity.backendStart]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      guard queryEnd <= deadline, rows.count <= 1 else { throw FixtureFailure.nativeShape }
      if rows.isEmpty { return }
      let present = try ownedT12Identity(rows, fixture: f)
      guard ownedT12SameSession(present, identity) else { throw FixtureFailure.nativeShape }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedT12Unchanged(
    _ f: Fixture, recipe: OwnedDeferredRecipe, baseline: Int,
    diagnostic: OwnedDeferredDiagnostic, checkpoint: OwnedDeferredCheckpoint
  ) throws {
    guard
      try ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "gate", baseline: baseline, diagnostic: diagnostic) == checkpoint
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedT12Redemptions(
    _ receipt: ProtocolOwnedProofWriteReceipt, outcome: OwnedT12Outcome,
    fixture f: Fixture, recipe: OwnedDeferredRecipe, baseline: Int,
    diagnostic: OwnedDeferredDiagnostic, checkpoint: OwnedDeferredCheckpoint,
    admission: ProtocolProofMemoryAdmission, memory: OwnedBindMemory, mode: OwnedT12Mode
  ) throws -> Int {
    let before = memory.calls()
    guard receipt.operation == .bind, receipt.disposition == outcome.disposition else {
      throw FixtureFailure.nativeShape
    }
    if outcome != .current {
      // Also checked before the inverse control; the original sealed disposition never upgrades.
      try ownedDeferredRefuses(
        receipt, fixture: f, admission: admission, memory: memory, disposition: outcome.disposition)
      try ownedT12Unchanged(
        f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: checkpoint)
      return 0
    }
    let wrongReference = "secret:OWNED_T12_DIFFERENT_REFERENCE"
    let otherMemory = OwnedBindMemory(selected: nil)
    let otherAdmission = ProtocolProofMemoryAdmission { [otherMemory] in
      let allowed = otherMemory.compare()
      if !allowed { throw FixtureFailure.redactedFailure }
    }
    guard ProtocolCredentialReference(wrongReference) != nil,
      !equalBytes(wrongReference, f.link.tokenRef)
    else { throw FixtureFailure.nativeShape }
    let wrongReferenceRefused = !validates {
      _ = try receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: wrongReference, memoryAdmission: admission)
    }
    guard wrongReferenceRefused, memory.calls() == before else { throw FixtureFailure.nativeShape }
    try ownedT12Unchanged(
      f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: checkpoint)
    let otherAdmissionRefused = !validates {
      _ = try receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: otherAdmission)
    }
    guard otherAdmissionRefused, memory.calls() == before, otherMemory.calls() == 0 else {
      throw FixtureFailure.nativeShape
    }
    try ownedT12Unchanged(
      f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: checkpoint)
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
    guard memory.calls() == before + 1, successor.observation == nil else {
      throw FixtureFailure.nativeShape
    }
    // Closed-pool redemption is comparison only. Never perform an ordinary checkout after close.
    if mode == .openDisposal { try validateSuccessor(f, successor) }
    try ownedT12Unchanged(
      f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: checkpoint)
    memory.setCurrent(false)
    let retiredRefused = !validates {
      _ = try receipt.currentSuccessor(
        expectedSnapshot: f.anchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
    }
    memory.setCurrent(true)
    guard retiredRefused, memory.calls() == before + 2,
      receipt.disposition == .committedCurrent, otherMemory.calls() == 0
    else { throw FixtureFailure.nativeShape }
    try ownedT12Unchanged(
      f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: checkpoint)
    return memory.calls() - before
  }

  private static func ownedT12Unit(
    _ target: OwnedT12Outcome, mode: OwnedT12Mode, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedT12UnitFacts {
    var facts: OwnedT12UnitFacts?
    try withFixture { f in
      let predecessor = try validateFixture(f)
      let reference = f.link.tokenRef
      guard ProtocolCredentialReference(reference) != nil,
        reference.utf8.allSatisfy({ $0 > 0 && $0 < 128 })
      else { throw FixtureFailure.nativeShape }
      let stage = try ownedBindFreeze(f, predecessor: predecessor, replacement: reference)
      let recipe = try ownedDeferredInstall(f, stage: stage, mode: "gate", diagnostic: diagnostic)
      let initial = try ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "gate", baseline: 0, diagnostic: diagnostic)
      let zero = OwnedBindProbe(last: 1, called: false)
      guard initial.image == stage.before, initial.observations.isEmpty,
        initial.probes == OwnedDeferredProbes(body: zero, commit: zero, timeout: zero)
      else { throw FixtureFailure.nativeShape }
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        let allowed = memory.compare()
        if !allowed { throw FixtureFailure.redactedFailure }
      }
      let work = OwnedDeferredWork()
      // This cleanup exists BEFORE the first child, including any partially started attempt.
      defer { work.releaseAndJoin() }
      var aliases: [OwnedT12Ordinary] = []
      var receipts: [ProtocolOwnedProofWriteReceipt] = []
      var knownPIDs = [inspectorPID]
      var baseline = 0
      var writerCalls = 0
      var openAbsences = 0
      var laterOrdinary = 0
      var busyClose = 0
      var drainedClose = 0
      var closedRefusals = 0
      var timeoutAllocations = 0
      let outcomes: [OwnedT12Outcome] = mode == .openDisposal ? [target, .current] : [.current, target]
      for (attempt, outcome) in outcomes.enumerated() {
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: "gate", baseline: baseline, diagnostic: diagnostic)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        memory.setCurrent(true)
        let invocationStart = memory.calls()
        // Setup and all ordinary calls are sequential. Only this one candidate is idle here.
        // Retained aliases are never used for SQL while any actual writer can be using them.
        let old = try ownedT12OrdinaryProbe(f)
        aliases.append(old)
        if !knownPIDs.contains(old.identity.pid) { knownPIDs.append(old.identity.pid) }
        let hold = OwnedProofHold()
        let state = OwnedBindHolderState()
        let holderApplication = "owned-t12-gate-\(UUID().uuidString)"
        work.holds.append(hold)
        try ownedDeferredGateClear(f.inspector)
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let holder: OwnedProofNativeWork<OwnedBindHolderResult>
        let holderPID: Int
        if outcome == .noncommit {
          holder = ownedBindHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            kind: .advisory, hold: hold, state: state)
          work.holders.append(holder)
          holderPID = try ownedT12AdvisoryHolderReady(
            f, state: state, hold: hold, application: holderApplication, deadline: readiness)
        } else {
          holder = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: state)
          work.holders.append(holder)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: state, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
        }
        guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
        knownPIDs.append(holderPID)
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        // Both admitted attempts keep literal ORIGINAL S0/A/binding and the SAME admission.
        let writer = ownedBindWriter(
          database: f.database, anchor: f.anchor, binding: f.binding, reference: reference,
          admission: admission, finished: finished)
        work.writers.append(writer)
        let identity = try ownedT12ObserveWriter(
          f, outcome: outcome, holderPID: holderPID, knownPIDs: knownPIDs,
          holderApplication: holderApplication, hold: hold, finished: finished,
          memory: memory, invocationStart: invocationStart, probes: before.probes, deadline: deadline)
        var closeReturned: Bool?
        var closeAt: UInt64 = 0
        var heldAtClose: OwnedProofHold.Facts?
        var pendingAtClose = false
        var callsAtClose = 0
        if mode == .closingLease && attempt == 1 {
          // Native wait was directly observed under the original deadline. Close only admission.
          closeReturned = f.database.closeForMigration(timeout: .zero)
          closeAt = DispatchTime.now().uptimeNanoseconds
          heldAtClose = hold.snapshot()
          pendingAtClose = finished.pending()
          callsAtClose = memory.calls() - invocationStart
        }
        if outcome == .noncommit {
          try ownedBindReleaseObservedHold(
            hold, finished: finished, memory: memory, invocationStart: invocationStart,
            retiring: true, deadline: deadline)
        } else if outcome != .commitTimeoutUnknown {
          try ownedDeferredRelease(
            hold, finished: finished, memory: memory, invocationStart: invocationStart,
            retire: outcome == .stale, deadline: deadline)
        }
        // Timeout alone deliberately retains the SAME original eight-second hold until return.
        // Capture primitives, immediately release ALL, then join ALL before ANY result guard/image.
        let receipt = writer.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = hold.snapshot()
        work.releaseAndJoin()
        let held = holder.join()
        guard !finished.pending(), held.normal, receipt.operation == .bind,
          receipt.disposition == outcome.disposition,
          memory.calls() - invocationStart == outcome.calls
        else { throw FixtureFailure.nativeShape }
        if outcome == .commitTimeoutUnknown {
          // Exact native timeout/rethrow is independently qualified by this method's raw R4.
          // Target cause is inference from that immutable recipe, held actual COMMIT, relative
          // timeout allocation and sealed unknown; the receipt exports no native SQLSTATE.
          guard heldAtReturn.entered, heldAtReturn.held, !heldAtReturn.expired,
            !heldAtReturn.released, receiptAt < heldAtReturn.expiry
          else { throw FixtureFailure.nativeShape }
          timeoutAllocations += 1
        }
        if mode == .closingLease && attempt == 1 {
          guard closeReturned == false, let snapshot = heldAtClose,
            snapshot.entered, snapshot.held, !snapshot.expired, !snapshot.released,
            closeAt < snapshot.expiry, closeAt <= deadline, pendingAtClose,
            callsAtClose == (outcome == .noncommit ? 0 : 3)
          else { throw FixtureFailure.nativeShape }
          busyClose += 1
        }
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: "gate", baseline: baseline, diagnostic: diagnostic)
        guard after.image == (outcome.committed ? stage.expected : stage.before),
          after.probes.advanced(
            from: before.probes, body: outcome == .noncommit ? 0 : 1,
            commit: outcome == .noncommit ? 0 : 1,
            timeout: outcome == .commitTimeoutUnknown ? 1 : 0)
        else { throw FixtureFailure.nativeShape }
        if outcome.committed {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations, actual: after.observations,
            rawMillis: nil)
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
        }
        writerCalls += memory.calls() - invocationStart
        receipts.append(receipt)
        if mode == .openDisposal {
          // No close/drain/fixture teardown precedes this bounded disappearance observation.
          // Actual receipts and every legitimate ordinary alias remain alive across both checks.
          let later = try withExtendedLifetime((aliases, receipts)) {
            try ownedT12Absent(f, identity: identity)
            let probe = try ownedT12OrdinaryProbe(f)
            guard !ownedT12SameSession(probe.identity, identity),
              aliases.allSatisfy({ !ownedT12SameSession(probe.identity, $0.identity) })
            else { throw FixtureFailure.nativeShape }
            return probe
          }
          aliases.append(later)
          if !knownPIDs.contains(later.identity.pid) { knownPIDs.append(later.identity.pid) }
          openAbsences += 1
          laterOrdinary += 1
        }
        if !knownPIDs.contains(identity.pid) { knownPIDs.append(identity.pid) }
        if outcome != .current {
          try ownedDeferredRefuses(
            receipt, fixture: f, admission: admission, memory: memory,
            disposition: outcome.disposition)
          try ownedT12Unchanged(
            f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: after)
        }
        if attempt == 0 && outcome.committed {
          // S1 was fully checked FIRST. Q01 changes ONLY the public control; probes stay consumed.
          try ownedDeferredQ01(f, recipe: recipe, mode: "gate", diagnostic: diagnostic)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: "gate", oldBaseline: 0,
            newMode: "gate", newBaseline: 1, diagnostic: diagnostic)
          baseline = 1
        }
        // A noncommit/unknown first target already retained S0/baseline0: no reset/transition.
      }
      let finalCheckpoint = try ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "gate", baseline: baseline, diagnostic: diagnostic)
      if mode == .closingLease {
        guard f.database.closeForMigration(timeout: .zero) else { throw FixtureFailure.nativeShape }
        drainedClose += 1
        memory.setCurrent(true)
        let invocationStart = memory.calls()
        let finished = OwnedBindFinished()
        // Additional public entry is a CLOSED pre-BEGIN refusal, not an admitted target/control.
        let closedWriter = ownedBindWriter(
          database: f.database, anchor: f.anchor, binding: f.binding, reference: reference,
          admission: admission, finished: finished)
        work.writers.append(closedWriter)
        let closedReceipt = closedWriter.join()
        let closedReceiptAt = DispatchTime.now().uptimeNanoseconds
        work.releaseAndJoin()
        guard !finished.pending(), closedReceiptAt > 0, closedReceipt.operation == .bind,
          closedReceipt.disposition == .confirmedNoncommit, memory.calls() == invocationStart
        else { throw FixtureFailure.nativeShape }
        try ownedDeferredRefuses(
          closedReceipt, fixture: f, admission: admission, memory: memory,
          disposition: .confirmedNoncommit)
        try ownedT12Unchanged(
          f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: finalCheckpoint)
        receipts.append(closedReceipt)
        closedRefusals += 1
      }
      // Restoration is test memory only. Sealed stale/noncommit/unknown receipts remain refused.
      memory.setCurrent(true)
      var redemptionCalls = 0
      for (receipt, outcome) in zip(receipts.prefix(2), outcomes) {
        redemptionCalls += try ownedT12Redemptions(
          receipt, outcome: outcome, fixture: f, recipe: recipe, baseline: baseline,
          diagnostic: diagnostic, checkpoint: finalCheckpoint,
          admission: admission, memory: memory, mode: mode)
      }
      // In the closing order the noncurrent target follows its current control's inverses.
      // Recheck every noncurrent original after ALL current comparisons, in both orders.
      for (receipt, outcome) in zip(receipts.prefix(2), outcomes) where outcome != .current {
        try ownedDeferredRefuses(
          receipt, fixture: f, admission: admission, memory: memory, disposition: outcome.disposition)
        try ownedT12Unchanged(
          f, recipe: recipe, baseline: baseline, diagnostic: diagnostic, checkpoint: finalCheckpoint)
      }
      let expectedRedemptions = target == .current ? 4 : 2
      guard work.holders.count == 2, work.holds.count == 2, work.raw.isEmpty,
        work.writers.count == (mode == .closingLease ? 3 : 2),
        receipts.count == work.writers.count, writerCalls == target.calls + 4,
        redemptionCalls == expectedRedemptions, memory.calls() == writerCalls + redemptionCalls,
        receipts[0].disposition == outcomes[0].disposition,
        receipts[1].disposition == outcomes[1].disposition,
        openAbsences == (mode == .openDisposal ? 2 : 0), laterOrdinary == openAbsences,
        busyClose == (mode == .closingLease ? 1 : 0), drainedClose == busyClose,
        closedRefusals == busyClose,
        timeoutAllocations == (target == .commitTimeoutUnknown ? 1 : 0)
      else { throw FixtureFailure.nativeShape }
      // Bounded absence is not PQfinish/ARC quiescence. Group joins are not OS-thread exit.
      // Unchanged helper -> lease.leave -> slot.signal and no-idle/no-result-capture source
      // ordering complements these observations; one checkout does not prove all permits.
      withExtendedLifetime((aliases, receipts)) {}
      facts = OwnedT12UnitFacts(
        admittedWriters: 2, writerCalls: writerCalls, redemptionCalls: redemptionCalls,
        nativeWaits: 2, normalHolders: 2, openAbsences: openAbsences, laterOrdinary: laterOrdinary,
        busyClose: busyClose, drainedClose: drainedClose, closedRefusals: closedRefusals,
        timeoutAllocations: timeoutAllocations, qualified: true)
    }
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private static func ownedT12Run(_ outcome: OwnedT12Outcome) throws -> OwnedT12Facts {
    do {
      // Scratch context only. Never emit its old six-field TASK5 diagnostic as a T12 identity.
      let diagnostic = OwnedDeferredDiagnostic(unit: .stale)
      let prerequisites = try ownedDeferredPrerequisites(diagnostic: diagnostic)
      let open = try ownedT12Unit(outcome, mode: .openDisposal, diagnostic: diagnostic)
      let closing = try ownedT12Unit(outcome, mode: .closingLease, diagnostic: diagnostic)
      return OwnedT12Facts(
        oldControls: prerequisites.old, newControls: prerequisites.controls,
        rawAttempts: prerequisites.attempts, rawHolders: prerequisites.holders, units: 2,
        admittedWriters: open.admittedWriters + closing.admittedWriters,
        publicEntries: open.admittedWriters + closing.admittedWriters + closing.closedRefusals,
        writerCalls: open.writerCalls + closing.writerCalls,
        redemptionCalls: open.redemptionCalls + closing.redemptionCalls,
        nativeWaits: open.nativeWaits + closing.nativeWaits,
        normalHolders: open.normalHolders + closing.normalHolders,
        openAbsences: open.openAbsences + closing.openAbsences,
        laterOrdinary: open.laterOrdinary + closing.laterOrdinary,
        busyClose: open.busyClose + closing.busyClose,
        drainedClose: open.drainedClose + closing.drainedClose,
        closedRefusals: open.closedRefusals + closing.closedRefusals,
        timeoutAllocations: open.timeoutAllocations + closing.timeoutAllocations,
        qualified: open.qualified && closing.qualified)
    } catch {
      // Every owned child drain and fixture unwind precedes this ONLY fixed failure marker.
      print("LATE_T12_FAILURE")
      throw FixtureFailure.redactedFailure
    }
  }

  @Test(NativeDBResources()) func ownedBindIntegratedCurrentDisposalAndLease() throws {
    let facts = try Self.ownedT12Run(.current)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.units == 2 && facts.admittedWriters == 4 && facts.publicEntries == 5)
    #expect(facts.writerCalls == 16 && facts.redemptionCalls == 8)
    #expect(facts.nativeWaits == 4 && facts.normalHolders == 4)
    #expect(facts.openAbsences == 2 && facts.laterOrdinary == 2)
    #expect(facts.busyClose == 1 && facts.drainedClose == 1 && facts.closedRefusals == 1)
    #expect(facts.timeoutAllocations == 0 && facts.qualified)
  }

  @Test(NativeDBResources()) func ownedBindIntegratedStaleDisposalAndLease() throws {
    let facts = try Self.ownedT12Run(.stale)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.units == 2 && facts.admittedWriters == 4 && facts.publicEntries == 5)
    #expect(facts.writerCalls == 16 && facts.redemptionCalls == 4)
    #expect(facts.nativeWaits == 4 && facts.normalHolders == 4)
    #expect(facts.openAbsences == 2 && facts.laterOrdinary == 2)
    #expect(facts.busyClose == 1 && facts.drainedClose == 1 && facts.closedRefusals == 1)
    #expect(facts.timeoutAllocations == 0 && facts.qualified)
  }

  @Test(NativeDBResources()) func ownedBindIntegratedNoncommitDisposalAndLease() throws {
    let facts = try Self.ownedT12Run(.noncommit)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.units == 2 && facts.admittedWriters == 4 && facts.publicEntries == 5)
    #expect(facts.writerCalls == 10 && facts.redemptionCalls == 4)
    #expect(facts.nativeWaits == 4 && facts.normalHolders == 4)
    #expect(facts.openAbsences == 2 && facts.laterOrdinary == 2)
    #expect(facts.busyClose == 1 && facts.drainedClose == 1 && facts.closedRefusals == 1)
    #expect(facts.timeoutAllocations == 0 && facts.qualified)
  }

  @Test(NativeDBResources()) func ownedBindIntegratedCommitUnknownDisposalAndLease() throws {
    let facts = try Self.ownedT12Run(.commitTimeoutUnknown)
    #expect(facts.oldControls == 4 && facts.newControls == 5)
    #expect(facts.rawAttempts == 9 && facts.rawHolders == 4)
    #expect(facts.units == 2 && facts.admittedWriters == 4 && facts.publicEntries == 5)
    #expect(facts.writerCalls == 14 && facts.redemptionCalls == 4)
    #expect(facts.nativeWaits == 4 && facts.normalHolders == 4)
    #expect(facts.openAbsences == 2 && facts.laterOrdinary == 2)
    #expect(facts.busyClose == 1 && facts.drainedClose == 1 && facts.closedRefusals == 1)
    #expect(facts.timeoutAllocations == 2 && facts.qualified)
  }
}

// Dormant B2: independent native S1→S2 oracles and actual owned invocations only.
// Every group locally qualifies its recipe before opening its target fixtures. These tests
// assert comparison evidence, never HTTP authentication, owner admission or native quiescence.
extension OwnedProtocolProofWriteTests {
  private final class OwnedPositiveCountedMemory: Sendable {
    private struct State: Sendable {
      var current = true
      var calls = 0
      var selected: Int? = nil
    }
    private let state = Mutex(State())
    func compare() -> Bool {
      state.withLock {
        $0.calls += 1
        return $0.current && $0.selected != $0.calls
      }
    }
    func calls() -> Int { state.withLock { $0.calls } }
    func setCurrent(_ current: Bool) { state.withLock { $0.current = current } }
    func disableSelector() { state.withLock { $0.selected = nil } }
    func armSelector(baseline: Int, localOrdinal: Int) throws {
      let armed = state.withLock { value -> Bool in
        guard (1...4).contains(localOrdinal), baseline >= 0, value.current,
          value.selected == nil, value.calls == baseline
        else { return false }
        let (selected, overflow) = baseline.addingReportingOverflow(localOrdinal)
        guard !overflow else { return false }
        value.selected = selected
        return true
      }
      if !armed { throw FixtureFailure.redactedFailure }
    }
  }

  private struct OwnedPositiveParent {
    let receipt: ProtocolOwnedProofWriteReceipt
    let anchor: ProtocolVerificationSnapshot
    let image: OwnedBindImage
  }

  private static func ownedPositiveObservation(
    _ binding: ProtocolMembershipBinding, version: Int = 7
  ) throws -> ProtocolVerificationObservation {
    try ProtocolVerificationObservation(
      binding: binding, reportedMinimum: 2, reportedVersion: version, healthy: true)
  }

  private static func ownedPositiveObservationObject(
    _ observation: ProtocolVerificationObservation
  ) -> [String: Any] {
    [
      "binding": ownedT09Binding(observation.binding), "reportedMinimum": observation.reportedMinimum,
      "reportedVersion": observation.reportedVersion, "healthy": observation.healthy,
    ]
  }

  // Expected JSON is authored from the frozen native predecessor; never from receipt payloads,
  // the legacy positive API, a current recapture or a product-produced candidate.
  private static func ownedPositiveStage(
    _ f: Fixture, observation: ProtocolVerificationObservation
  ) throws -> OwnedBindStageFixture {
    let before = try ownedBindImage(f.inspector)
    let predecessor = try ownedDeferredControl(before)
    guard let binding = predecessor["binding"] as? [String: Any],
      try ownedT09Data(binding) == ownedT09Data(ownedT09Binding(observation.binding))
    else { throw FixtureFailure.nativeShape }
    var expected = predecessor
    expected["revision"] = try ownedT09Next(predecessor)
    expected["observation"] = ownedPositiveObservationObject(observation)
    let image = try ownedT09ControlImage(before, old: predecessor, new: expected)
    let link = try ownedT09Object(ownedT09Link(before))
    guard let reference = link["tokenRef"] as? String else { throw FixtureFailure.nativeShape }
    return try ownedT09Freeze(
      f, before: before, expected: image, expectedControl: expected, reference: reference)
  }

  private static func ownedPositiveEstablishParent(
    _ f: Fixture, anchor: ProtocolVerificationSnapshot, reference: String,
    admission: ProtocolProofMemoryAdmission, calls: () -> Int
  ) throws -> OwnedPositiveParent {
    let before = try ownedBindImage(f.inspector)
    let control = try ownedDeferredControl(before)
    var wanted = control
    if control["binding"] == nil {
      wanted["revision"] = try ownedT09Next(control)
      wanted["binding"] = ownedT09Binding(f.binding)
    } else {
      guard let binding = control["binding"] as? [String: Any],
        try ownedT09Data(binding) == ownedT09Data(ownedT09Binding(f.binding))
      else { throw FixtureFailure.nativeShape }
    }
    let expected = try ownedT09ControlImage(before, old: control, new: wanted)
    let start = calls()
    let receipt = f.database.prepareProtocolVerification(
      expectedSnapshot: anchor, expectedBinding: f.binding, expectedTokenRef: reference,
      memoryAdmission: admission)
    guard receipt.operation == .bind, receipt.disposition == .committedCurrent,
      calls() - start == 4, try ownedBindImage(f.inspector) == expected
    else { throw FixtureFailure.nativeShape }
    // Explicit setup redemption is separate from the four actual bind-writer checks.
    let redeemStart = calls()
    let s1 = try receipt.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
    guard calls() - redeemStart == 1 else { throw FixtureFailure.nativeShape }
    try ownedT09NativeValidate(
      f, successor: s1, binding: f.binding, reference: reference, observation: anchor.observation)
    guard try ownedBindImage(f.inspector) == expected else { throw FixtureFailure.nativeShape }
    return OwnedPositiveParent(receipt: receipt, anchor: s1, image: expected)
  }

  private static func ownedPositiveParent(
    _ f: Fixture, anchor: ProtocolVerificationSnapshot, reference: String,
    admission: ProtocolProofMemoryAdmission, memory: OwnedBindMemory
  ) throws -> OwnedPositiveParent {
    try ownedPositiveEstablishParent(
      f, anchor: anchor, reference: reference, admission: admission, calls: { memory.calls() })
  }

  // P05 has its own concretely typed checker; old OwnedBindMemory remains init-only.
  private static func ownedPositiveParent(
    _ f: Fixture, anchor: ProtocolVerificationSnapshot, reference: String,
    admission: ProtocolProofMemoryAdmission, memory: OwnedPositiveCountedMemory
  ) throws -> OwnedPositiveParent {
    try ownedPositiveEstablishParent(
      f, anchor: anchor, reference: reference, admission: admission, calls: { memory.calls() })
  }

  private static func ownedPositiveWriter(
    database: WorkspaceDatabase, anchor: ProtocolVerificationSnapshot,
    parent: ProtocolOwnedProofWriteReceipt, observation: ProtocolVerificationObservation,
    reference: String, admission: ProtocolProofMemoryAdmission, finished: OwnedBindFinished
  ) -> OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt> {
    OwnedProofNativeWork { [database, anchor, parent, observation, reference, admission, finished] in
      let receipt = database.commitObservedProtocolFact(
        expectedSnapshot: anchor, expectedBindingReceipt: parent, observation: observation,
        expectedTokenRef: reference, memoryAdmission: admission)
      finished.markReturned()
      return receipt
    }
  }

  private static func ownedPositiveWrite(
    _ f: Fixture, parent: OwnedPositiveParent, observation: ProtocolVerificationObservation,
    reference: String, admission: ProtocolProofMemoryAdmission
  ) -> ProtocolOwnedProofWriteReceipt {
    f.database.commitObservedProtocolFact(
      expectedSnapshot: parent.anchor, expectedBindingReceipt: parent.receipt,
      observation: observation, expectedTokenRef: reference, memoryAdmission: admission)
  }

  private static func ownedPositiveRefuses(
    _ receipt: ProtocolOwnedProofWriteReceipt, anchor: ProtocolVerificationSnapshot,
    reference: String, admission: ProtocolProofMemoryAdmission, calls: () -> Int,
    disposition: ProtocolProofWriteDisposition = .confirmedNoncommit
  ) throws {
    let before = calls()
    guard receipt.operation == .positive, receipt.disposition == disposition,
      !validates({
        _ = try receipt.currentSuccessor(
          expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
      }), calls() == before, receipt.disposition == disposition
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedPositiveRedeem(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture,
    parent: OwnedPositiveParent, observation: ProtocolVerificationObservation,
    reference: String, admission: ProtocolProofMemoryAdmission, calls: () -> Int
  ) throws -> ProtocolVerificationSnapshot {
    let before = calls()
    guard receipt.operation == .positive, receipt.disposition == .committedCurrent else {
      throw FixtureFailure.nativeShape
    }
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: parent.anchor, expectedTokenRef: reference, memoryAdmission: admission)
    guard calls() - before == 1, successor.observation == observation else {
      throw FixtureFailure.nativeShape
    }
    // Independent native checks are outside currentSuccessor's memory-only authority.
    try ownedT09NativeValidate(
      f, successor: successor, binding: observation.binding, reference: reference,
      observation: observation)
    return successor
  }

  private struct OwnedPositiveBodyRecipe {
    let stage: OwnedBindStageFixture
    let catalog: [Data]
  }

  private static let ownedPositiveBodySources: [String: String] = [
    "assert_complete": "\n" + """
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
          ELSIF convert_to(t,'UTF8')=convert_to('appFolders','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."appFolders" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."appFolders" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('changes','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."changes" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."changes" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('columnClocks','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."columnClocks" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."columnClocks" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('connectionUsage','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."connectionUsage" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."connectionUsage" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('connections','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."connections" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."connections" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('devices','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."devices" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."devices" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('displayItems','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."displayItems" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."displayItems" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('drafts','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."drafts" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."drafts" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('localServers','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."localServers" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."localServers" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('projectFolders','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."projectFolders" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."projectFolders" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('projects','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."projects" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."projects" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolGrantSecrets','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrantSecrets" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolGrants','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolGrants" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolGrants" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolHistoryAnchors','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolHistoryAnchors" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolOperations','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolOperations" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolOperations" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolPromptAnswers','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolPromptAnswers" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolRunSegments','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolRunSegments" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolRunSegments" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('protocolSubscriptions','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."protocolSubscriptions" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."protocolSubscriptions" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('runtimeRequests','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."runtimeRequests" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."runtimeRequests" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('schemaMigrations','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."schemaMigrations" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."schemaMigrations" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('settings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."settings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."settings" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('threadDeletes','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."threadDeletes" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."threadDeletes" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('threads','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."threads" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."threads" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('tokenUsage','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."tokenUsage" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."tokenUsage" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('turns','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."turns" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."turns" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('usageReadings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."usageReadings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."usageReadings" p))
              INTO mismatch;
          ELSIF convert_to(t,'UTF8')=convert_to('viewSettings','UTF8') THEN
            SELECT EXISTS((SELECT to_jsonb(p) FROM public."viewSettings" p)
                EXCEPT ALL (SELECT value FROM "owned_bind_stage"."expected" WHERE name=t))
              OR EXISTS((SELECT value FROM "owned_bind_stage"."expected" WHERE name=t)
                EXCEPT ALL (SELECT to_jsonb(p) FROM public."viewSettings" p))
              INTO mismatch;
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
      END
      """ + " ",
    "assert_transaction": "\n" + """
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
      END
      """ + " ",
    "body": "\n" + """
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
      END
      """ + " ",
    "commit_normal": "\n" + """
      DECLARE replacement text;
      BEGIN
        SELECT m.replacement INTO STRICT replacement FROM "owned_bind_stage"."mode" m WHERE singleton=1;
        PERFORM "owned_bind_stage"."assert_complete"(replacement);
        PERFORM nextval('"owned_bind_stage"."commit_probe"'::regclass);
        RETURN NEW;
      END
      """ + " ",
  ]

  private static func ownedPositiveBodyShape(
    _ c: PostgresConnection, stage: OwnedBindStageFixture, replacement: String, fault: Bool
  ) throws {
    let mode = try c.execute(
      "SELECT replacement,raw_body_fault::text AS fault FROM \"owned_bind_stage\".\"mode\" WHERE singleton=1"
    ).rows
    guard mode.count == 1, let actual = mode[0].text("replacement"), equalBytes(actual, replacement),
      mode[0].text("fault") == (fault ? "true" : "false")
    else { throw FixtureFailure.nativeShape }
    let sources = try c.execute(
      """
      SELECT p.proname AS name,p.prosrc AS source,pg_get_function_identity_arguments(p.oid) AS args,
        pg_get_function_result(p.oid) AS result,p.proconfig::text AS config,l.lanname AS language,
        p.provolatile::text AS volatility,p.proparallel::text AS parallel,
        p.prosecdef::text AS definer,p.proisstrict::text AS strict,p.proleakproof::text AS leakproof,
        p.prokind::text AS kind
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
      JOIN pg_catalog.pg_language l ON l.oid=p.prolang WHERE n.nspname='owned_bind_stage'
      """
    ).rows
    guard sources.count == ownedPositiveBodySources.count else { throw FixtureFailure.nativeShape }
    for row in sources {
      guard let name = row.text("name"), let expected = ownedPositiveBodySources[name],
        let actual = row.text("source"), equalBytes(actual, expected),
        row.text("args") == (name == "assert_complete" ? "required_reference text" : ""),
        row.text("result") == ((name == "body" || name == "commit_normal") ? "trigger" : "void"),
        row.text("config") == "{search_path=pg_catalog}", row.text("language") == "plpgsql",
        row.text("volatility") == "v", row.text("parallel") == "u",
        row.text("definer") == "false", row.text("strict") == "false",
        row.text("leakproof") == "false", row.text("kind") == "f"
      else { throw FixtureFailure.nativeShape }
    }
    let names = try c.execute("SELECT name FROM \"owned_bind_stage\".\"names\"").rows
    var expectedRows = Dictionary(uniqueKeysWithValues: stage.expected.rows.keys.map { ($0, [Data]()) })
    var actualNames = Set<Data>()
    for row in names {
      guard let name = row.text("name"), actualNames.insert(Data(name.utf8)).inserted else {
        throw FixtureFailure.nativeShape
      }
    }
    guard actualNames == Set(stage.expected.rows.keys.map { Data($0.utf8) }) else {
      throw FixtureFailure.nativeShape
    }
    for row in try c.execute(
      "SELECT name,value::text AS value FROM \"owned_bind_stage\".\"expected\""
    ).rows {
      guard let name = row.text("name"), let value = row.text("value"), expectedRows[name] != nil else {
        throw FixtureFailure.nativeShape
      }
      expectedRows[name]!.append(try ownedBindJSON(value))
    }
    for name in Array(expectedRows.keys) { expectedRows[name]!.sort { $0.lexicographicallyPrecedes($1) } }
    guard expectedRows == stage.expected.rows else { throw FixtureFailure.nativeShape }
    let meta = try c.execute(
      "SELECT to_jsonb(m)::text AS value FROM \"owned_bind_stage\".\"meta\" m"
    ).rows
    let expectedMeta: [String: Any] = [
      "singleton": 1, "database": stage.before.database, "original_ref": stage.originalReference,
      "expected_control": try ownedT09Object(Data(stage.controlJSON.utf8)),
      "expected_sequence": try ownedT09Object(stage.before.sequence),
      "expected_device": stage.device, "lower_wall": stage.lowerWall,
    ]
    guard meta.count == 1, let text = meta[0].text("value"),
      try ownedBindJSON(text) == ownedT09Data(expectedMeta)
    else { throw FixtureFailure.nativeShape }
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
    let linkTriggers = try c.execute(
      """
      SELECT count(*) AS n FROM pg_catalog.pg_trigger
      WHERE tgrelid='public."hubLink"'::pg_catalog.regclass AND NOT tgisinternal
      """
    ).rows
    guard linkTriggers.count == 1, linkTriggers[0].int("n") == 0 else {
      throw FixtureFailure.nativeShape
    }
  }

  private static func ownedPositiveRawControls(
    diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> [OwnedBindRawFacts] {
    var results: [OwnedBindRawFacts] = []
    var databases = Set<Data>()
    for row in OwnedBindRawControl.allCases {
      diagnostic?.selectRawRow(row)
      diagnostic?.phase = .rawFixture
      var observed: OwnedBindRawFacts?
      try withFixture { f in
        diagnostic?.phase = .rawValidate
        _ = try validateFixture(f)
        let memory = OwnedBindMemory(selected: nil)
        let admission = ProtocolProofMemoryAdmission { [memory] in
          if !memory.compare() { throw FixtureFailure.redactedFailure }
        }
        let parent = try ownedPositiveParent(
          f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
        let observation = try ownedPositiveObservation(f.binding)
        let replacement = row == .normalB ? "secret:OWNED_BIND_RAW_REFERENCE_B" : f.link.tokenRef
        diagnostic?.phase = .rawFreeze
        let frozen = try ownedPositiveStage(f, observation: observation)
        guard frozen.before == parent.image else { throw FixtureFailure.nativeShape }
        let stage = OwnedBindStageFixture(
          before: frozen.before, expected: frozen.expected, controlJSON: frozen.controlJSON,
          originalReference: frozen.originalReference, replacement: replacement,
          device: frozen.device, lowerWall: frozen.lowerWall)
        guard databases.insert(Data(stage.before.database.utf8)).inserted else {
          throw FixtureFailure.nativeShape
        }
        // Every row gets a distinct endpoint/database, genuine owned-bind S1, independent
        // exact S2, and the identical two enabled UPDATE-only functions/triggers.
        diagnostic?.phase = .rawInstall
        try ownedBindInstall(f, stage: stage, rawBodyFault: row == .bodyFault)
        let catalog = try ownedDeferredCatalog(f.inspector)
        try ownedPositiveBodyShape(
          f.inspector, stage: stage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawExpectedDamage
        var checkedStage = stage
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
          guard let settings = stage.expected.rows["settings"] else { throw FixtureFailure.nativeShape }
          var replacements = 0
          let damaged = try settings.map { data -> Data in
            var object = try ownedT09Object(data)
            if object["key"] as? String == sentinelKey {
              guard object["value"] as? String == "OWNED_PROOF_RETAINED" else {
                throw FixtureFailure.nativeShape
              }
              object["value"] = "OWNED_BIND_PRIVATE_IMAGE_CORRUPTION"
              replacements += 1
            }
            return try ownedT09Data(object)
          }.sorted { $0.lexicographicallyPrecedes($1) }
          guard replacements == 1 else { throw FixtureFailure.nativeShape }
          var expectedRows = stage.expected.rows
          expectedRows["settings"] = damaged
          checkedStage = OwnedBindStageFixture(
            before: stage.before,
            expected: OwnedBindImage(
              database: stage.expected.database, rows: expectedRows, sequence: stage.expected.sequence),
            controlJSON: stage.controlJSON, originalReference: stage.originalReference,
            replacement: stage.replacement, device: stage.device, lowerWall: stage.lowerWall)
        }
        try ownedPositiveBodyShape(
          f.inspector, stage: checkedStage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawInitialImage
        guard try ownedBindImage(f.inspector) == stage.before else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .rawDriver
        observed = try ownedBindRawDriver(f, stage: stage, row: row, family: .positive)
        guard try ownedDeferredCatalog(f.inspector) == catalog else { throw FixtureFailure.nativeShape }
        try ownedPositiveBodyShape(
          f.inspector, stage: checkedStage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawTeardown
      }
      // withFixture has closed its database and relinquished its inspector/physical root first.
      diagnostic?.phase = .rawFacts
      guard let observed, observed.qualified else { throw FixtureFailure.nativeShape }
      results.append(observed)
    }
    guard results.count == 4 else { throw FixtureFailure.nativeShape }
    return results
  }

  private static func ownedPositiveDeferredRawControl(
    _ row: Int, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredControlFacts {
    diagnostic.selectRawFixture(row)
    diagnostic.attempt = .none
    guard (0...4).contains(row) else { throw FixtureFailure.nativeShape }
    var facts: OwnedDeferredControlFacts?
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      _ = try validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try ownedPositiveObservation(f.binding)
      diagnostic.enter(.freeze)
      let stage = try ownedPositiveStage(f, observation: observation)
      guard stage.before == parent.image else { throw FixtureFailure.nativeShape }
      var mode = row == 2 ? "fault" : (row >= 3 ? "gate" : "normal")
      var baseline = 0
      diagnostic.enter(.oldInstall)
      var recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      diagnostic.enter(.damage)
      if row == 0 { recipe = try ownedDeferredDamage(f.inspector, recipe: recipe, diagnostic: diagnostic) }
      diagnostic.enter(.initialState)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let work = OwnedDeferredWork()
      // Registration precedes every holder/worker, including partially started attempts.
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var attempts = 0
      var acknowledgements = 0
      var errors = 0
      var rollbacks = 0
      var bodies = 0
      var deferred = 0
      var timeouts = 0
      var restorations = 0
      var transitions = 0
      for attempt in 0..<(row == 0 ? 1 : 2) {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        let gated = row >= 3
        let timeout = row == 4 && attempt == 0
        let kind: OwnedDeferredRawKind =
          row == 0 ? .reject : (row == 2 && attempt == 0 ? .fault : (timeout ? .timeout : .normal))
        let application = "owned-deferred-raw-\(UUID().uuidString)"
        let holderApplication = "owned-deferred-gate-\(UUID().uuidString)"
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        var holderPID = 0
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        let state = OwnedBindHolderState()
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        diagnostic.enter(.rawStart)
        let worker = ownedDeferredRawWorker(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: application,
          kind: kind, state: state, finished: finished)
        work.raw.append(worker)
        diagnostic.enter(.observeCommit)
        if gated {
          while state.snapshot().pid == 0 && finished.pending()
            && DispatchTime.now().uptimeNanoseconds <= deadline
          { Thread.sleep(forTimeInterval: 0.005) }
          let candidate = state.snapshot()
          guard candidate.acquired, candidate.pid > 0, !knownPIDs.contains(candidate.pid),
            DispatchTime.now().uptimeNanoseconds <= deadline
          else { throw FixtureFailure.nativeShape }
          try ownedDeferredObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: application, rawPID: candidate.pid, hold: hold,
            finished: finished, memory: nil, invocationStart: 0, probes: before.probes,
            deadline: deadline)
          if !timeout {
            try ownedDeferredRelease(
              hold, finished: finished, memory: nil, invocationStart: 0, retire: false,
              deadline: deadline)
          }
        }
        // The intended timeout keeps its original eight-second hold valid until actual return.
        // Capture the result/timestamp, then immediately release ALL and join ALL before guards.
        diagnostic.enter(.resultCapture)
        let result = worker.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        let rawIdentity = state.snapshot()
        diagnostic.enter(.rawResult)
        guard result.valid, finished.pending() == false, rawIdentity.acquired,
          rawIdentity.pid > 0, !knownPIDs.contains(rawIdentity.pid),
          (!gated || held?.normal == true), heldAtReturn,
          !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        knownPIDs.append(rawIdentity.pid)
        attempts += 1
        let success = kind == .normal
        let bodyCount: Int64 = row == 0 ? 0 : 1
        let commitCount: Int64 = row == 0 ? 0 : 1
        let timeoutCount: Int64 = timeout ? 1 : 0
        diagnostic.enter(.rawResult)
        guard result.dmlReturned == (row != 0), result.commitSent == (row != 0),
          result.acknowledged == success, result.rollbackAcknowledged == (row == 0),
          result.predicateRejected == (row == 0),
          result.actualDeferredFault == (kind == .fault), result.actualServerTimeout == timeout,
          result.ownPredicate == (row != 0), result.ownSettings == (row != 0)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard after.image == (success ? stage.expected : stage.before),
          after.probes.advanced(
            from: before.probes, body: bodyCount, commit: commitCount, timeout: timeoutCount)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.observations)
        if success {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations, actual: after.observations,
            rawMillis: result.millis)
          acknowledgements += 1
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
          if row == 0 { rollbacks += 1 } else { errors += 1 }
        }
        bodies += Int(bodyCount)
        deferred += Int(commitCount)
        timeouts += Int(timeoutCount)
        if attempt == 0 && (row == 1 || row == 3) {
          diagnostic.enter(.q01)
          try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
          restorations += 1
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
            diagnostic: diagnostic)
          baseline = 1
          transitions += 1
        } else if attempt == 0 && row == 2 {
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
            diagnostic: diagnostic)
          mode = "normal"
          transitions += 1
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.raw.count == (row == 0 ? 1 : 2), work.holders.count == (row >= 3 ? 2 : 0) else {
        throw FixtureFailure.nativeShape
      }
      facts = OwnedDeferredControlFacts(
        row: row, attempts: attempts, holders: work.holders.count,
        acknowledgements: acknowledgements, errors: errors, rollbacks: rollbacks,
        bodies: bodies, deferred: deferred, timeouts: timeouts,
        restorations: restorations, transitions: transitions, qualified: true)
    }
    // Complete fixture close/root teardown precedes escape of these primitive-only facts.
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private static func ownedPositiveDeferredPrerequisites(
    diagnostic: OwnedDeferredDiagnostic
  ) throws -> (
    old: Int, controls: Int, attempts: Int, holders: Int
  ) {
    diagnostic.fixture = .oldFour
    diagnostic.attempt = .none
    diagnostic.enter(.oldFour)
    let old = try ownedPositiveRawControls()
    diagnostic.enter(.oldFour)
    guard old.map({ $0.row }) == [0, 1, 2, 3], old.count == 4,
      old.allSatisfy({ $0.qualified && $0.durableImageValidated })
    else { throw FixtureFailure.nativeShape }
    // The old four have ALL torn down. Each NEW recipe row independently tears down as well.
    var rows: [OwnedDeferredControlFacts] = []
    for row in 0...4 { rows.append(try ownedPositiveDeferredRawControl(row, diagnostic: diagnostic)) }
    diagnostic.fixture = .none
    diagnostic.attempt = .none
    diagnostic.enter(.finalFacts)
    guard rows.map({ $0.row }) == [0, 1, 2, 3, 4], rows.allSatisfy({ $0.qualified }),
      rows.map({ $0.attempts }) == [1, 2, 2, 2, 2],
      rows.map({ $0.holders }) == [0, 0, 0, 2, 2],
      rows.map({ $0.acknowledgements }) == [0, 2, 1, 2, 1],
      rows.map({ $0.errors }) == [0, 0, 1, 0, 1],
      rows.map({ $0.rollbacks }) == [1, 0, 0, 0, 0],
      rows.map({ $0.bodies }) == [0, 2, 2, 2, 2],
      rows.map({ $0.deferred }) == [0, 2, 2, 2, 2],
      rows.map({ $0.timeouts }) == [0, 0, 0, 0, 1],
      rows.map({ $0.restorations }) == [0, 1, 0, 1, 0],
      rows.map({ $0.transitions }) == [0, 1, 1, 1, 0]
    else { throw FixtureFailure.nativeShape }
    return (old.count, rows.count, rows.reduce(0) { $0 + $1.attempts }, rows.reduce(0) { $0 + $1.holders })
  }

  private static func ownedPositiveInstallBody(
    _ f: Fixture, stage: OwnedBindStageFixture, replacement: String, fault: Bool
  ) throws -> OwnedPositiveBodyRecipe {
    let adapted = OwnedBindStageFixture(
      before: stage.before, expected: stage.expected, controlJSON: stage.controlJSON,
      originalReference: stage.originalReference, replacement: replacement,
      device: stage.device, lowerWall: stage.lowerWall)
    try ownedBindInstall(f, stage: adapted, rawBodyFault: fault)
    try ownedPositiveBodyShape(f.inspector, stage: stage, replacement: replacement, fault: fault)
    return OwnedPositiveBodyRecipe(stage: stage, catalog: try ownedDeferredCatalog(f.inspector))
  }

  private static func ownedPositiveBodyCheckpoint(
    _ f: Fixture, recipe: OwnedPositiveBodyRecipe, replacement: String, fault: Bool,
    image: OwnedBindImage, body: OwnedBindProbe, commit: OwnedBindProbe,
    bodies: Int64, commits: Int64
  ) throws {
    try ownedPositiveBodyShape(
      f.inspector, stage: recipe.stage, replacement: replacement, fault: fault)
    guard try ownedDeferredCatalog(f.inspector) == recipe.catalog,
      try ownedBindImage(f.inspector) == image,
      try ownedBindProbe(f.inspector, "body_probe").advanced(from: body, by: bodies),
      try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commit, by: commits)
    else { throw FixtureFailure.nativeShape }
    if commits == 0 {
      try ownedBindObservedEmpty(f.inspector)
    } else {
      guard commits == 1 else { throw FixtureFailure.nativeShape }
      try ownedBindWriterObserved(f.inspector, stage: recipe.stage, actualDevice: f.database.deviceId)
    }
  }

  private static func ownedPositiveBodyMode(
    _ f: Fixture, recipe: OwnedPositiveBodyRecipe, oldReference: String, oldFault: Bool,
    newReference: String, newFault: Bool
  ) throws {
    try ownedPositiveBodyShape(
      f.inspector, stage: recipe.stage, replacement: oldReference, fault: oldFault)
    let image = try ownedBindImage(f.inspector)
    let body = try ownedBindProbe(f.inspector, "body_probe")
    let commit = try ownedBindProbe(f.inspector, "commit_probe")
    let observed = try ownedDeferredObservations(f.inspector)
    guard
      try f.inspector.execute(
        "UPDATE \"owned_bind_stage\".\"mode\" SET replacement=$1,raw_body_fault=$2::boolean WHERE singleton=1 AND convert_to(replacement,'UTF8')=convert_to($3,'UTF8') AND raw_body_fault=$4::boolean",
        [newReference, newFault ? "true" : "false", oldReference, oldFault ? "true" : "false"]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    try ownedPositiveBodyShape(
      f.inspector, stage: recipe.stage, replacement: newReference, fault: newFault)
    guard try ownedDeferredCatalog(f.inspector) == recipe.catalog,
      try ownedBindImage(f.inspector) == image,
      try ownedBindProbe(f.inspector, "body_probe") == body,
      try ownedBindProbe(f.inspector, "commit_probe") == commit,
      try ownedDeferredObservations(f.inspector) == observed
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedPositiveRequireCoreControls() throws {
    let rows = try ownedPositiveRawControls()
    guard rows.map({ $0.row }) == [0, 1, 2, 3], rows.allSatisfy({ $0.qualified }) else {
      throw FixtureFailure.nativeShape
    }
  }

  // P01a real mutating parent; P01b an additional actual equal-binding no-op parent.
  @Test(NativeDBResources(), arguments: [false, true])
  func ownedPositiveCommitsExactObservationAndSingleRevisionFromOwnedBind(noopParent: Bool) throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      var parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      if noopParent {
        let previous = parent.image
        parent = try Self.ownedPositiveParent(
          f, anchor: parent.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
        guard parent.image == previous else { throw FixtureFailure.nativeShape }
      }
      let observation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let start = memory.calls()
      let receipt = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard receipt.operation == .positive, receipt.disposition == .committedCurrent,
        memory.calls() - start == 4, parent.receipt.operation == .bind,
        parent.receipt.disposition == .committedCurrent
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      _ = try Self.ownedPositiveRedeem(
        receipt, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      #expect(memory.calls() - start == 5)
    }
  }

  // P05's typed checker deliberately cannot accept the old init-only selector helper.
  private static func ownedPositiveP05Refused(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture, parent: OwnedPositiveParent,
    recipe: OwnedPositiveBodyRecipe, admission: ProtocolProofMemoryAdmission,
    memory: OwnedPositiveCountedMemory, start: Int, ordinal: Int,
    body: OwnedBindProbe, commit: OwnedBindProbe
  ) throws {
    guard memory.calls() - start == ordinal else { throw FixtureFailure.nativeShape }
    try ownedPositiveRefuses(
      receipt, anchor: parent.anchor, reference: f.link.tokenRef,
      admission: admission, calls: { memory.calls() })
    try ownedPositiveBodyCheckpoint(
      f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: parent.image,
      body: body, commit: commit, bodies: ordinal == 1 ? 0 : 1, commits: 0)
  }

  @Test(NativeDBResources(), arguments: [1, 2, 3])
  func ownedPositiveCountsMemoryChecksAtPREPOSTAndImmediatePreCommit(ordinal: Int) throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedPositiveCountedMemory()
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let invocationStart = memory.calls()
      try memory.armSelector(baseline: invocationStart, localOrdinal: ordinal)
      guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
      let refused = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      try Self.ownedPositiveP05Refused(
        refused, fixture: f, parent: parent, recipe: recipe, admission: admission, memory: memory,
        start: invocationStart, ordinal: ordinal, body: body, commit: commit)
      let beforeDisable = memory.calls()
      memory.disableSelector()
      guard memory.calls() == beforeDisable, try Self.ownedBindImage(f.inspector) == parent.image else {
        throw FixtureFailure.nativeShape
      }
      let inverseBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let inverseCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let inverseStart = memory.calls()
      let allowed = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard allowed.operation == .positive, allowed.disposition == .committedCurrent,
        memory.calls() - inverseStart == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      _ = try Self.ownedPositiveRedeem(
        allowed, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveRefuses(
        refused, anchor: parent.anchor, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      guard memory.calls() - inverseStart == 5 else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      #expect(memory.calls() - invocationStart == ordinal + 5)
    }
  }

  @Test(NativeDBResources(), arguments: [false, true])
  func ownedPositiveRefusesSuccessfulBodyReferenceReplacementAndBodyFault(bodyFault: Bool) throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let replacement = bodyFault ? f.link.tokenRef : "secret:OWNED_POSITIVE_REFERENCE_B"
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: replacement, fault: bodyFault)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let start = memory.calls()
      let refused = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard memory.calls() - start == 1 else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveRefuses(
        refused, anchor: parent.anchor, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: replacement, fault: bodyFault, image: parent.image,
        body: body, commit: commit, bodies: 1, commits: 0)
      try Self.ownedPositiveBodyMode(
        f, recipe: recipe, oldReference: replacement, oldFault: bodyFault,
        newReference: f.link.tokenRef, newFault: false)
      let inverseBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let inverseCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let inverseStart = memory.calls()
      let allowed = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard allowed.operation == .positive, allowed.disposition == .committedCurrent,
        memory.calls() - inverseStart == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      _ = try Self.ownedPositiveRedeem(
        allowed, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveRefuses(
        refused, anchor: parent.anchor, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      #expect(memory.calls() - start == 6)
    }
  }

  @Test(NativeDBResources(), arguments: [0, 1])
  func ownedPositiveRechecksMemoryAfterActualNativeWait(kindValue: Int) throws {
    try Self.ownedPositiveRequireCoreControls()
    let kind: OwnedBindWaitKind = kindValue == 0 ? .advisory : .link
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      var knownPIDs = [try Self.ownedDeferredInspectorPID(f.inspector)]
      var original: ProtocolOwnedProofWriteReceipt?
      for attempt in 0..<2 {
        memory.setCurrent(true)
        let body = try Self.ownedBindProbe(f.inspector, "body_probe")
        let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
        let start = memory.calls()
        let hold = OwnedProofHold()
        let state = OwnedBindHolderState()
        work.holds.append(hold)
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let holder = Self.ownedBindHolder(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: "owned-positive-pre-\(UUID())",
          kind: kind, hold: hold, state: state)
        work.holders.append(holder)
        let pid = try Self.ownedBindHolderReady(state, hold: hold, deadline: readiness)
        guard !knownPIDs.contains(pid) else { throw FixtureFailure.nativeShape }
        knownPIDs.append(pid)
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let writer = Self.ownedPositiveWriter(
          database: f.database, anchor: parent.anchor, parent: parent.receipt,
          observation: observation, reference: f.link.tokenRef, admission: admission, finished: finished)
        work.writers.append(writer)
        try Self.ownedBindObserveWait(
          f.inspector, database: endpoint.database, holderPID: pid, knownOwnedPIDs: knownPIDs,
          kind: kind, hold: hold, finished: finished, memory: memory,
          invocationStart: start, deadline: deadline)
        guard try Self.ownedBindProbe(f.inspector, "body_probe") == body,
          try Self.ownedBindProbe(f.inspector, "commit_probe") == commit
        else { throw FixtureFailure.nativeShape }
        try Self.ownedBindReleaseObservedHold(
          hold, finished: finished, memory: memory, invocationStart: start,
          retiring: attempt == 0, deadline: deadline)
        let receipt = writer.join()
        work.releaseAndJoin()
        let held = holder.join()
        guard held.normal, !finished.pending(), memory.calls() - start == (attempt == 0 ? 1 : 4) else {
          throw FixtureFailure.nativeShape
        }
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
          image: attempt == 0 ? parent.image : stage.expected, body: body, commit: commit,
          bodies: attempt == 0 ? 0 : 1, commits: attempt == 0 ? 0 : 1)
        if attempt == 0 {
          original = receipt
          try Self.ownedPositiveRefuses(
            receipt, anchor: parent.anchor, reference: f.link.tokenRef,
            admission: admission, calls: { memory.calls() })
        } else {
          _ = try Self.ownedPositiveRedeem(
            receipt, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
            admission: admission, calls: { memory.calls() })
          guard let original else { throw FixtureFailure.nativeShape }
          try Self.ownedPositiveRefuses(
            original, anchor: parent.anchor, reference: f.link.tokenRef,
            admission: admission, calls: { memory.calls() })
          try Self.ownedPositiveBodyCheckpoint(
            f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
            image: stage.expected, body: body, commit: commit, bodies: 1, commits: 1)
        }
      }
      #expect(work.holders.count == 2 && work.writers.count == 2)
    }
  }

  private static func ownedPositiveDeferredTarget(
    _ unit: OwnedDeferredCase, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredFacts {
    // Every call owns ALL prerequisites; no cache, earlier test, or previously qualified run.
    let prerequisites = try ownedPositiveDeferredPrerequisites(diagnostic: diagnostic)
    var facts: OwnedDeferredFacts?
    diagnostic.fixture = .target
    diagnostic.attempt = .none
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      _ = try validateFixture(f)
      let reference = f.link.tokenRef
      guard ProtocolCredentialReference(reference) != nil,
        reference.utf8.allSatisfy({ $0 > 0 && $0 < 128 })
      else { throw FixtureFailure.nativeShape }
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try ownedPositiveParent(
        f, anchor: f.anchor, reference: reference, admission: admission, memory: memory)
      let setupCalls = memory.calls()
      let observation = try ownedPositiveObservation(f.binding)
      let stage = try ownedPositiveStage(f, observation: observation)
      guard stage.before == parent.image else { throw FixtureFailure.nativeShape }
      var mode = unit == .fault ? "fault" : "gate"
      var baseline = 0
      let recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var original: ProtocolOwnedProofWriteReceipt?
      var writerCalls = 0
      var redemptions = 0
      var waits = 0
      var timeoutAllocations = 0
      for attempt in 0..<2 {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        diagnostic.enter(.targetWrite)
        let invocationStart = memory.calls()
        let expectedStart = setupCalls + (attempt == 0 ? 0 : (unit == .stale ? 4 : 3))
        guard invocationStart == expectedStart else { throw FixtureFailure.nativeShape }
        let gated = unit != .fault
        let timeout = unit == .timeout && attempt == 0
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        let holderApplication = "owned-deferred-target-gate-\(UUID().uuidString)"
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        var holderPID = 0
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        diagnostic.enter(.targetWrite)
        guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        // Literal same original database/anchor/binding/reference/admission for both invocations.
        diagnostic.enter(.targetWrite)
        let writer = ownedPositiveWriter(
          database: f.database, anchor: parent.anchor, parent: parent.receipt,
          observation: observation, reference: reference,
          admission: admission, finished: finished)
        work.writers.append(writer)
        if gated {
          diagnostic.enter(.observeCommit)
          try ownedDeferredObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: "b4app", rawPID: nil, hold: hold, finished: finished,
            memory: memory, invocationStart: invocationStart, probes: before.probes,
            deadline: deadline)
          waits += 1
          if !timeout {
            try ownedDeferredRelease(
              hold, finished: finished, memory: memory, invocationStart: invocationStart,
              retire: unit == .stale && attempt == 0, deadline: deadline)
          }
        }
        // No throwing assertion, inspector image, or receipt validation may intervene here.
        // In the timeout branch actual receipt capture occurs while the original hold is valid;
        // immediately release ALL and join ALL before validating any result, including this fact.
        diagnostic.enter(.resultCapture)
        let receipt = writer.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        guard !finished.pending(), !gated || held?.normal == true,
          heldAtReturn, !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        let committed = unit == .stale || attempt == 1
        let expectedCalls = committed ? 4 : 3
        let delta = memory.calls() - invocationStart
        diagnostic.enter(.targetReceipt)
        guard receipt.operation == .positive, delta == expectedCalls,
          after.image == (committed ? stage.expected : stage.before),
          after.probes.advanced(from: before.probes, body: 1, commit: 1, timeout: timeout ? 1 : 0)
        else { throw FixtureFailure.nativeShape }
        writerCalls += delta
        if timeout { timeoutAllocations += 1 }
        diagnostic.enter(.observations)
        if committed {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations,
            actual: after.observations, rawMillis: nil)
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
        }
        if attempt == 0 {
          original = receipt
          let disposition: ProtocolProofWriteDisposition = unit == .stale ? .committedStale : .unknown
          diagnostic.enter(.targetRefusal)
          try ownedPositiveRefuses(
            receipt, anchor: parent.anchor, reference: reference, admission: admission,
            calls: { memory.calls() }, disposition: disposition)
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
          if unit == .stale {
            // Genuine acknowledged stale S2 and its original refusal were checked BEFORE Q01.
            // This fixture-only restoration is never a rollback or repair by the product API.
            diagnostic.enter(.q01)
            try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
              diagnostic: diagnostic)
            baseline = 1
            memory.setCurrent(true)
          } else if unit == .fault {
            // Exact native 23514/canary/COMMIT was directly qualified by this unit's R2.
            // Target fault/stage/source attribution is explicitly INFERENCE from the immutable
            // full recipe, body/deferred relative probes, genuine unknown and reviewed writer
            // COMMIT-sent catch; the sealed target receipt exports no native diagnostic.
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
              diagnostic: diagnostic)
            mode = "normal"
          }
          // T07's ONLY timeout allocation is inside its actual deferred gate handler, after
          // exact COMMIT/blocker/resource observation. Own R4 qualified original native rethrow.
          // An infeasible handler fails prerequisites; elapsed+unknown+S1 supplies no substitute.
        } else {
          guard receipt.disposition == .committedCurrent else { throw FixtureFailure.nativeShape }
          diagnostic.enter(.targetRedemption)
          let beforeRedemption = memory.calls()
          let successor = try receipt.currentSuccessor(
            expectedSnapshot: parent.anchor, expectedTokenRef: reference, memoryAdmission: admission)
          let afterRedemption = memory.calls()
          guard afterRedemption - beforeRedemption == 1 else { throw FixtureFailure.nativeShape }
          redemptions += afterRedemption - beforeRedemption
          diagnostic.enter(.successorValidation)
          try ownedT09NativeValidate(
            f, successor: successor, binding: f.binding, reference: reference, observation: observation)
          diagnostic.enter(.originalRefusal)
          guard let original else { throw FixtureFailure.nativeShape }
          try ownedPositiveRefuses(
            original, anchor: parent.anchor, reference: reference, admission: admission,
            calls: { memory.calls() },
            disposition: unit == .stale ? .committedStale : .unknown)
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.writers.count == 2, work.raw.isEmpty,
        work.holders.count == (unit == .fault ? 0 : 2),
        writerCalls == (unit == .stale ? 8 : 7), redemptions == 1,
        memory.calls() - setupCalls == writerCalls + redemptions, waits == (unit == .fault ? 0 : 2),
        timeoutAllocations == (unit == .timeout ? 1 : 0)
      else { throw FixtureFailure.nativeShape }
      facts = OwnedDeferredFacts(
        oldControls: prerequisites.old, newControls: prerequisites.controls,
        rawAttempts: prerequisites.attempts, rawHolders: prerequisites.holders,
        writerCalls: writerCalls, redemptionCalls: redemptions, targetHolders: work.holders.count,
        targetWaits: waits, timeoutAllocations: timeoutAllocations, qualified: true)
    }
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  @Test(NativeDBResources()) func ownedPositiveActualSuccessfulCommitRetirementIsStale() throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: .stale)
    let facts = try Self.ownedPositiveDeferredTarget(.stale, diagnostic: diagnostic)
    #expect(facts.oldControls == 4 && facts.newControls == 5 && facts.rawAttempts == 9)
    #expect(facts.writerCalls == 8 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 2 && facts.targetWaits == 2 && facts.timeoutAllocations == 0)
    #expect(facts.qualified)
  }

  @Test(NativeDBResources()) func ownedPositiveActualDeferredCommitFaultRemainsUnknown() throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: .fault)
    let facts = try Self.ownedPositiveDeferredTarget(.fault, diagnostic: diagnostic)
    #expect(facts.oldControls == 4 && facts.newControls == 5 && facts.rawAttempts == 9)
    #expect(facts.writerCalls == 7 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 0 && facts.targetWaits == 0 && facts.timeoutAllocations == 0)
    #expect(facts.qualified)
  }

  @Test(NativeDBResources()) func ownedPositiveActualCommitServerTimeoutIsUnknown() throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: .timeout)
    let facts = try Self.ownedPositiveDeferredTarget(.timeout, diagnostic: diagnostic)
    #expect(facts.oldControls == 4 && facts.newControls == 5 && facts.rawAttempts == 9)
    #expect(facts.writerCalls == 7 && facts.redemptionCalls == 1)
    #expect(facts.targetHolders == 2 && facts.targetWaits == 2 && facts.timeoutAllocations == 1)
    #expect(facts.qualified)
  }

  // A fixture-only DELETE/INSERT never fires either UPDATE-only positive recipe trigger.
  private static func ownedPositiveReplaceControl(
    _ f: Fixture, old: [String: Any], new: [String: Any]?
  ) throws {
    var acknowledged = false
    defer { if !acknowledged { _ = try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    guard
      try f.inspector.execute(
        "DELETE FROM public.settings WHERE key=$1 AND value=$2::jsonb",
        [key, try ownedBindText(ownedT09Data(old))]
      ).affected == 1
    else { throw FixtureFailure.nativeShape }
    if let new {
      guard
        try f.inspector.execute(
          "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)",
          [key, try ownedBindText(ownedT09Data(new))]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    }
    try f.inspector.execute("COMMIT")
    acknowledged = true
  }

  @Test(
    NativeDBResources(),
    arguments: [
      "store", "member", "revision", "binding", "observation", "missingControl", "malformedControl",
      "missingLink", "base", "device", "joined", "referenceB", "referenceEmpty", "referenceMalformed",
      "allow", "maximum",
    ])
  func ownedPositiveComparesExactNativeS1AndRefusesExhaustion(row: String) throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      let inactive = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      var bindAnchor = f.anchor
      if row == "maximum" {
        var maximumSeed = inactive.object
        maximumSeed["revision"] = String(Int64.max - 1)
        let before = try Self.ownedBindImage(f.inspector)
        let seeded = try Self.ownedT09ControlImage(before, old: inactive.object, new: maximumSeed)
        try Self.ownedPositiveReplaceControl(f, old: inactive.object, new: maximumSeed)
        guard try Self.ownedBindImage(f.inspector) == seeded else { throw FixtureFailure.nativeShape }
        let membership = try ProtocolNativeMembership(
          canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
        bindAnchor = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: membership)
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: bindAnchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      if row == "maximum" {
        let native = try Self.control(f)
        guard native.revision == Int64.max else { throw FixtureFailure.nativeShape }
        let start = memory.calls()
        let receipt = Self.ownedPositiveWrite(
          f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
        guard memory.calls() - start == 1, try Self.ownedBindImage(f.inspector) == parent.image else {
          throw FixtureFailure.nativeShape
        }
        try Self.ownedPositiveRefuses(
          receipt, anchor: parent.anchor, reference: f.link.tokenRef,
          admission: admission, calls: { memory.calls() })
        // No S2 can be authored: dedicated body/COMMIT probes are N/A, never observed zero.
        try Self.ownedBindCatalogGuard(f.inspector)
        #expect(receipt.disposition == .confirmedNoncommit)
        return
      }
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let original = try Self.ownedDeferredControl(parent.image)
      var expectedImage = parent.image
      if ["store", "member", "revision", "binding", "observation", "missingControl", "malformedControl"]
        .contains(row)
      {
        var changed = original
        switch row {
        case "store": changed["storeIncarnation"] = UUID().uuidString
        case "member": changed["membershipIncarnation"] = UUID().uuidString
        case "revision": changed["revision"] = try Self.ownedT09Next(original)
        case "binding":
          let other = try Self.ownedT09OtherBinding(f.binding, unit: .boundUser)
          changed["binding"] = Self.ownedT09Binding(other)
        case "observation": changed["observation"] = Self.ownedPositiveObservationObject(observation)
        case "malformedControl": changed["unexpected"] = "OWNED_POSITIVE_MALFORMED"
        default: break
        }
        let next: [String: Any]? = row == "missingControl" ? nil : changed
        expectedImage = try Self.ownedT09ControlImage(parent.image, old: original, new: next)
        try Self.ownedPositiveReplaceControl(f, old: original, new: next)
      } else if row != "allow" {
        let column: OwnedT09LinkColumn?
        let value: String?
        switch row {
        case "missingLink": column = nil; value = nil
        case "base": column = .url; value = "https://example.invalid/OwnedPositiveOther"
        case "device": column = .deviceId; value = "OWNED_POSITIVE_DEVICE_OTHER"
        case "joined": column = .joinedAt; value = "2026-11-13T00:00:00.001Z"
        case "referenceB": column = .tokenRef; value = "secret:OWNED_POSITIVE_NATIVE_B"
        case "referenceEmpty": column = .tokenRef; value = ""
        case "referenceMalformed": column = .tokenRef; value = "other:OWNED_POSITIVE_MALFORMED"
        default: throw FixtureFailure.nativeShape
        }
        if let column, let value {
          expectedImage = try Self.ownedT09ChangedLink(parent.image, column: column, value: value)
        } else {
          expectedImage = try Self.ownedT09LinkImage(
            parent.image, old: Self.ownedT09Link(parent.image), new: nil)
        }
        try Self.ownedT09LinkSwap(
          f, from: parent.image, to: expectedImage, column: column,
          stage: stage, body: body, commit: commit)
      }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: expectedImage,
        body: body, commit: commit, bodies: 0, commits: 0)
      let start = memory.calls()
      let receipt = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      if row == "allow" {
        guard memory.calls() - start == 4 else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
          body: body, commit: commit, bodies: 1, commits: 1)
        _ = try Self.ownedPositiveRedeem(
          receipt, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
          admission: admission, calls: { memory.calls() })
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
          body: body, commit: commit, bodies: 1, commits: 1)
      } else {
        guard memory.calls() == start else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveRefuses(
          receipt, anchor: parent.anchor, reference: f.link.tokenRef,
          admission: admission, calls: { memory.calls() })
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: expectedImage,
          body: body, commit: commit, bodies: 0, commits: 0)
      }
      #expect(receipt.operation == .positive)
    }
  }

  private static func ownedPositiveUnchangedBody(
    _ f: Fixture, recipe: OwnedPositiveBodyRecipe, image: OwnedBindImage,
    body: OwnedBindProbe, commit: OwnedBindProbe, observations: [Data]
  ) throws {
    try ownedPositiveBodyShape(
      f.inspector, stage: recipe.stage, replacement: recipe.stage.originalReference, fault: false)
    guard try ownedDeferredCatalog(f.inspector) == recipe.catalog,
      try ownedBindImage(f.inspector) == image,
      try ownedBindProbe(f.inspector, "body_probe") == body,
      try ownedBindProbe(f.inspector, "commit_probe") == commit,
      try ownedDeferredObservations(f.inspector) == observations
    else { throw FixtureFailure.nativeShape }
  }

  // These two P02 rows construct actual B1 outcomes under locally qualified B1 recipes.
  // The later positive invocation is preflight refusal only; no counterfeit B2 parent is made.
  private static func ownedPositiveUnusableBindParent(stale: Bool) throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: stale ? .stale : .fault)
    _ = try ownedDeferredPrerequisites(diagnostic: diagnostic)
    try withFixture { f in
      let inactive = try validateFixture(f)
      let stage = try ownedBindFreeze(f, predecessor: inactive, replacement: f.link.tokenRef)
      let mode = stale ? "gate" : "fault"
      let recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      let before = try ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let hold = OwnedProofHold()
      let holderState = OwnedBindHolderState()
      let application = "owned-positive-bad-parent-\(UUID())"
      var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
      var holderPID = 0
      if stale {
        work.holds.append(hold)
        try ownedDeferredGateClear(f.inspector)
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let started = ownedDeferredHolder(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: application,
          hold: hold, state: holderState)
        work.holders.append(started)
        holder = started
        holderPID = try ownedDeferredHolderReady(
          f.inspector, state: holderState, hold: hold, database: endpoint.database,
          application: application, deadline: readiness)
      }
      let finished = OwnedBindFinished()
      let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      let start = memory.calls()
      let writer = ownedBindWriter(
        database: f.database, anchor: f.anchor, binding: f.binding, reference: f.link.tokenRef,
        admission: admission, finished: finished)
      work.writers.append(writer)
      if stale {
        try ownedDeferredObserveCommit(
          f.inspector, database: endpoint.database, holderPID: holderPID,
          knownOwnedPIDs: [inspectorPID, holderPID], holderApplication: application,
          candidateApplication: "b4app", rawPID: nil, hold: hold, finished: finished,
          memory: memory, invocationStart: start, probes: before.probes, deadline: deadline)
        try ownedDeferredRelease(
          hold, finished: finished, memory: memory, invocationStart: start, retire: true,
          deadline: deadline)
      }
      let parent = writer.join()
      work.releaseAndJoin()
      let held = holder?.join()
      guard !finished.pending(), !stale || held?.normal == true,
        parent.operation == .bind, parent.disposition == (stale ? .committedStale : .unknown),
        memory.calls() - start == (stale ? 4 : 3)
      else { throw FixtureFailure.nativeShape }
      let checkpoint = try ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic)
      guard checkpoint.image == (stale ? stage.expected : stage.before),
        checkpoint.probes.advanced(from: before.probes, body: 1, commit: 1, timeout: 0)
      else { throw FixtureFailure.nativeShape }
      if stale {
        try ownedDeferredAppendObservation(
          f.inspector, stage: stage, old: before.observations,
          actual: checkpoint.observations, rawMillis: nil)
      } else {
        guard checkpoint.observations == before.observations else { throw FixtureFailure.nativeShape }
      }
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      // A comparison capture is deliberately a negative input, never a provenance substitute.
      let negativeAnchor = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      let positiveStart = memory.calls()
      let receipt = f.database.commitObservedProtocolFact(
        expectedSnapshot: negativeAnchor, expectedBindingReceipt: parent,
        observation: try ownedPositiveObservation(f.binding), expectedTokenRef: f.link.tokenRef,
        memoryAdmission: admission)
      guard memory.calls() == positiveStart else { throw FixtureFailure.nativeShape }
      try ownedPositiveRefuses(
        receipt, anchor: negativeAnchor, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      guard
        try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: 0, diagnostic: diagnostic) == checkpoint,
        parent.disposition == (stale ? .committedStale : .unknown)
      else { throw FixtureFailure.nativeShape }
    }
  }

  @Test(
    NativeDBResources(),
    arguments: [
      "S0", "fact", "account", "object", "empty", "prefixOnly", "wrongPrefix", "nul",
      "differentRef", "unicodeComposed", "unicodeDecomposed", "admission", "observationAccount",
      "observationUser", "observationOrg", "observationBase", "observationDevice",
      "observationDatabase", "observationJoined", "noncommitParent", "unknownParent", "staleParent",
      "positiveParent",
    ])
  func ownedPositiveRequiresExactGenuineCurrentBindParentBeforeSQL(row: String) throws {
    try Self.ownedPositiveRequireCoreControls()
    if row == "unknownParent" || row == "staleParent" {
      try Self.ownedPositiveUnusableBindParent(stale: row == "staleParent")
      return
    }
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let otherMemory = OwnedBindMemory(selected: nil)
      let otherAdmission = ProtocolProofMemoryAdmission { [otherMemory] in
        if !otherMemory.compare() { throw FixtureFailure.redactedFailure }
      }
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      let wrongAccount = try f.database.captureProtocolVerification(
        accountID: "OWNED_POSITIVE_ACCOUNT_OTHER", expectedMembership: membership)
      var reference = f.link.tokenRef
      if row == "unicodeComposed" || row == "unicodeDecomposed" {
        reference = row == "unicodeComposed" ? "secret:\u{00E9}" : "secret:e\u{0301}"
        let before = try Self.ownedBindImage(f.inspector)
        let changed = try Self.ownedT09ChangedLink(before, column: .tokenRef, value: reference)
        try Self.ownedT09LinkSwap(
          f, from: before, to: changed, column: .tokenRef, stage: nil, body: nil, commit: nil)
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: reference, admission: admission, memory: memory)
      var anchor = parent.anchor
      var parentReceipt = parent.receipt
      var suppliedRef = reference
      var suppliedAdmission = admission
      var observation = try Self.ownedPositiveObservation(f.binding)
      var extra: WorkspaceDatabase?
      defer { if let extra { try? extra.close() } }
      switch row {
      case "S0": anchor = f.anchor
      case "fact":
        anchor = try #require(try f.database.readProtocolFact(expectedBinding: f.binding))
      case "account": anchor = wrongAccount
      case "object":
        let endpoint = f.database.endpoint
        let database = try WorkspaceDatabase(
          endpoint: endpoint, binDir: endpoint.binDir!, createIfMissing: false)
        extra = database
        anchor = try database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: membership)
      case "empty": suppliedRef = ""
      case "prefixOnly": suppliedRef = "secret:"
      case "wrongPrefix": suppliedRef = "other:OWNED_POSITIVE"
      case "nul": suppliedRef = "secret:x\u{0}y"
      case "differentRef": suppliedRef = "secret:OWNED_POSITIVE_DIFFERENT"
      case "unicodeComposed": suppliedRef = "secret:e\u{0301}"
      case "unicodeDecomposed": suppliedRef = "secret:\u{00E9}"
      case "admission": suppliedAdmission = otherAdmission
      case "observationAccount", "observationUser", "observationOrg", "observationBase",
        "observationDevice", "observationDatabase", "observationJoined":
        let unit: OwnedT09Unit
        switch row {
        case "observationAccount": unit = .account
        case "observationUser": unit = .boundUser
        case "observationOrg": unit = .boundOrg
        case "observationBase": unit = .hubBase
        case "observationDevice": unit = .device
        case "observationDatabase": unit = .database
        default: unit = .joined
        }
        observation = try Self.ownedPositiveObservation(Self.ownedT09OtherBinding(f.binding, unit: unit))
      case "noncommitParent":
        let start = memory.calls()
        parentReceipt = f.database.prepareProtocolVerification(
          expectedSnapshot: f.anchor, expectedBinding: f.binding, expectedTokenRef: "",
          memoryAdmission: admission)
        guard parentReceipt.operation == .bind, parentReceipt.disposition == .confirmedNoncommit,
          memory.calls() == start
        else { throw FixtureFailure.nativeShape }
      default: break
      }
      // Oracle always describes valid original binding even when the supplied observation differs.
      let validObservation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: validObservation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: reference, fault: false)
      if row == "positiveParent" {
        let start = memory.calls()
        parentReceipt = Self.ownedPositiveWrite(
          f, parent: parent, observation: validObservation, reference: reference, admission: admission)
        guard parentReceipt.operation == .positive, parentReceipt.disposition == .committedCurrent,
          memory.calls() - start == 4, try Self.ownedBindImage(f.inspector) == stage.expected
        else { throw FixtureFailure.nativeShape }
        anchor = try Self.ownedPositiveRedeem(
          parentReceipt, fixture: f, parent: parent, observation: validObservation,
          reference: reference, admission: admission, calls: { memory.calls() })
      }
      let image = try Self.ownedBindImage(f.inspector)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let observations = try Self.ownedDeferredObservations(f.inspector)
      let start = memory.calls()
      let otherStart = otherMemory.calls()
      let receipt = f.database.commitObservedProtocolFact(
        expectedSnapshot: anchor, expectedBindingReceipt: parentReceipt, observation: observation,
        expectedTokenRef: suppliedRef, memoryAdmission: suppliedAdmission)
      guard memory.calls() == start, otherMemory.calls() == otherStart else {
        throw FixtureFailure.nativeShape
      }
      try Self.ownedPositiveRefuses(
        receipt, anchor: anchor, reference: suppliedRef,
        admission: suppliedAdmission, calls: { memory.calls() })
      guard otherMemory.calls() == otherStart else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: image, body: body, commit: commit, observations: observations)
      // Precheckout reachability is additionally established by the fixed writer's source gate;
      // zero callbacks/probes alone are not evidence about a transient pool checkout.
      #expect(receipt.operation == .positive && receipt.disposition == .confirmedNoncommit)
    }
  }

  @Test(NativeDBResources()) func ownedPositiveRedemptionRequiresS1ReferenceAdmissionAndFreshMemory() throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let otherMemory = OwnedBindMemory(selected: nil)
      let otherAdmission = ProtocolProofMemoryAdmission { [otherMemory] in
        if !otherMemory.compare() { throw FixtureFailure.redactedFailure }
      }
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      let wrongAccount = try f.database.captureProtocolVerification(
        accountID: "OWNED_POSITIVE_REDEMPTION_OTHER", expectedMembership: membership)
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let writeStart = memory.calls()
      let receipt = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard receipt.operation == .positive, receipt.disposition == .committedCurrent,
        memory.calls() - writeStart == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      let frozenBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let frozenCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let observations = try Self.ownedDeferredObservations(f.inspector)
      // P10.write ends with ZERO redemptions. Expected S2 JSON is not a snapshot getter.
      guard memory.calls() - writeStart == 4 else { throw FixtureFailure.nativeShape }
      let redemptionStart = memory.calls()
      var deltas: [Int] = []
      let equalS1 = parent.anchor
      let firstStart = memory.calls()
      // FIRST redemption obtains the actual S2 snapshot. No recapture or private initializer.
      let actualS2 = try receipt.currentSuccessor(
        expectedSnapshot: equalS1, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      deltas.append(memory.calls() - firstStart)
      guard deltas == [1], actualS2.observation == observation else { throw FixtureFailure.nativeShape }
      try Self.ownedT09NativeValidate(
        f, successor: actualS2, binding: f.binding, reference: f.link.tokenRef, observation: observation)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      for wrongAnchor in [f.anchor, actualS2] {
        let before = memory.calls()
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: wrongAnchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
          })
        else { throw FixtureFailure.nativeShape }
        deltas.append(memory.calls() - before)
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let extra = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, createIfMissing: false)
      defer { try? extra.close() }
      let otherObjectAnchor = try extra.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      let noContext = try #require(try f.database.readProtocolFact(expectedBinding: f.binding))
      let contextStart = memory.calls()
      for wrongAnchor in [wrongAccount, noContext, otherObjectAnchor] {
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: wrongAnchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
          }), memory.calls() == contextStart
        else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      deltas.append(memory.calls() - contextStart)
      let referenceStart = memory.calls()
      for wrongRef in ["", "secret:", "other:x", "secret:x\u{0}y", "secret:OWNED_POSITIVE_OTHER"] {
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: equalS1, expectedTokenRef: wrongRef, memoryAdmission: admission)
          }), memory.calls() == referenceStart
        else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      deltas.append(memory.calls() - referenceStart)
      let admissionStart = memory.calls()
      guard
        !Self.validates({
          _ = try receipt.currentSuccessor(
            expectedSnapshot: equalS1, expectedTokenRef: f.link.tokenRef, memoryAdmission: otherAdmission)
        }), otherMemory.calls() == 0
      else { throw FixtureFailure.nativeShape }
      deltas.append(memory.calls() - admissionStart)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      let retirementStart = memory.calls()
      memory.setCurrent(false)
      guard memory.calls() == retirementStart,
        !Self.validates({
          _ = try receipt.currentSuccessor(
            expectedSnapshot: equalS1, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
        }), receipt.disposition == .committedCurrent
      else { throw FixtureFailure.nativeShape }
      deltas.append(memory.calls() - retirementStart)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      let recoveryStart = memory.calls()
      memory.setCurrent(true)
      guard memory.calls() == recoveryStart else { throw FixtureFailure.nativeShape }
      let recovered = try receipt.currentSuccessor(
        expectedSnapshot: equalS1, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      deltas.append(memory.calls() - recoveryStart)
      guard receipt.disposition == .committedCurrent, recovered.observation == actualS2.observation,
        otherMemory.calls() == 0, deltas == [1, 0, 0, 0, 0, 0, 1, 1],
        memory.calls() - redemptionStart == 3
      else { throw FixtureFailure.nativeShape }
      // Both actual returned values must independently equal the SAME frozen native S2 facts.
      try Self.ownedT09NativeValidate(
        f, successor: recovered, binding: f.binding, reference: f.link.tokenRef, observation: observation)
      try Self.ownedT09NativeValidate(
        f, successor: actualS2, binding: f.binding, reference: f.link.tokenRef, observation: observation)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      #expect(deltas == [1, 0, 0, 0, 0, 0, 1, 1])
    }
  }

  @Test(NativeDBResources())
  func ownedPositiveAlwaysAdvancesForAlreadyEqualObservationWithNewGenuineBindParent() throws {
    try Self.ownedPositiveRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let memory = OwnedBindMemory(selected: nil)
      let admission = ProtocolProofMemoryAdmission { [memory] in
        if !memory.compare() { throw FixtureFailure.redactedFailure }
      }
      let parent = try Self.ownedPositiveParent(
        f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
      let observation = try Self.ownedPositiveObservation(f.binding)
      let firstStage = try Self.ownedPositiveStage(f, observation: observation)
      let firstStart = memory.calls()
      let first = Self.ownedPositiveWrite(
        f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard first.operation == .positive, first.disposition == .committedCurrent,
        memory.calls() - firstStart == 4, try Self.ownedBindImage(f.inspector) == firstStage.expected
      else { throw FixtureFailure.nativeShape }
      let actualS2 = try Self.ownedPositiveRedeem(
        first, fixture: f, parent: parent, observation: observation, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      // P11.first preparation probes N/A: no recipe installed. Actual B1 no-op setup adds 4+1.
      let newParent = try Self.ownedPositiveParent(
        f, anchor: actualS2, reference: f.link.tokenRef, admission: admission, memory: memory)
      guard newParent.image == firstStage.expected else { throw FixtureFailure.nativeShape }
      let stage = try Self.ownedPositiveStage(f, observation: observation)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let start = memory.calls()
      let equal = Self.ownedPositiveWrite(
        f, parent: newParent, observation: observation, reference: f.link.tokenRef, admission: admission)
      guard equal.operation == .positive, equal.disposition == .committedCurrent,
        memory.calls() - start == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      _ = try Self.ownedPositiveRedeem(
        equal, fixture: f, parent: newParent, observation: observation, reference: f.link.tokenRef,
        admission: admission, calls: { memory.calls() })
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      #expect(memory.calls() - start == 5)
    }
  }
}

// Dormant B3 fence comparisons. All fixture oracles below are independent native images.
// No snapshot fabrication, receipt reconstruction, HTTP authority or runtime admission follows.
extension OwnedProtocolProofWriteTests {
  private struct OwnedFenceChain {
    let original: ProtocolVerificationSnapshot
    let parent: OwnedPositiveParent
    let positiveReceipt: ProtocolOwnedProofWriteReceipt
    let positive: ProtocolVerificationSnapshot
    let image: OwnedBindImage
    let memory: OwnedPositiveCountedMemory
    let admission: ProtocolProofMemoryAdmission
  }

  private static func ownedFenceChain(
    _ f: Fixture, validatedSeed: Bool = false
  ) throws -> OwnedFenceChain {
    if !validatedSeed { _ = try validateFixture(f) }
    try ownedBindCatalogGuard(f.inspector)
    let memory = OwnedPositiveCountedMemory()
    let admission = ProtocolProofMemoryAdmission { [memory] in
      if !memory.compare() { throw FixtureFailure.redactedFailure }
    }
    let b1Start = memory.calls()
    let parent = try ownedPositiveParent(
      f, anchor: f.anchor, reference: f.link.tokenRef, admission: admission, memory: memory)
    guard memory.calls() - b1Start == 5 else { throw FixtureFailure.nativeShape }
    let observation = try ownedPositiveObservation(f.binding)
    let expected = try ownedPositiveStage(f, observation: observation)
    guard expected.before == parent.image else { throw FixtureFailure.nativeShape }
    let b2Start = memory.calls()
    let positiveReceipt = ownedPositiveWrite(
      f, parent: parent, observation: observation, reference: f.link.tokenRef, admission: admission)
    guard positiveReceipt.operation == .positive, positiveReceipt.disposition == .committedCurrent,
      memory.calls() - b2Start == 4, try ownedBindImage(f.inspector) == expected.expected
    else { throw FixtureFailure.nativeShape }
    let redemptionStart = memory.calls()
    let positive = try ownedPositiveRedeem(
      positiveReceipt, fixture: f, parent: parent, observation: observation,
      reference: f.link.tokenRef, admission: admission, calls: { memory.calls() })
    guard memory.calls() - redemptionStart == 1,
      try ownedBindImage(f.inspector) == expected.expected
    else { throw FixtureFailure.nativeShape }
    try ownedBindCatalogGuard(f.inspector)
    return OwnedFenceChain(
      original: f.anchor, parent: parent, positiveReceipt: positiveReceipt,
      positive: positive, image: expected.expected, memory: memory, admission: admission)
  }

  private static func ownedFenceStage(_ f: Fixture) throws -> OwnedBindStageFixture {
    let before = try ownedBindImage(f.inspector)
    let original = try ownedDeferredControl(before)
    var expected = original
    expected["revision"] = try ownedT09Next(original)
    expected.removeValue(forKey: "observation")
    let image = try ownedT09ControlImage(before, old: original, new: expected)
    // Exact native JSON is an oracle only; the successor comes from counted redemption.
    return try ownedT09Freeze(
      f, before: before, expected: image, expectedControl: expected, reference: f.link.tokenRef)
  }

  private static func ownedFenceWrite(
    _ f: Fixture, anchor: ProtocolVerificationSnapshot, binding: ProtocolMembershipBinding,
    reference: String, admission: ProtocolProofMemoryAdmission
  ) -> ProtocolOwnedProofWriteReceipt {
    f.database.fenceProtocolVerification(
      expectedSnapshot: anchor, expectedBinding: binding,
      expectedTokenRef: reference, memoryAdmission: admission)
  }

  private static func ownedFenceWriter(
    database: WorkspaceDatabase, anchor: ProtocolVerificationSnapshot,
    binding: ProtocolMembershipBinding, reference: String,
    admission: ProtocolProofMemoryAdmission, finished: OwnedBindFinished
  ) -> OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt> {
    OwnedProofNativeWork { [database, anchor, binding, reference, admission, finished] in
      let receipt = database.fenceProtocolVerification(
        expectedSnapshot: anchor, expectedBinding: binding,
        expectedTokenRef: reference, memoryAdmission: admission)
      finished.markReturned()
      return receipt
    }
  }

  private static func ownedFenceRefuses(
    _ receipt: ProtocolOwnedProofWriteReceipt, anchor: ProtocolVerificationSnapshot,
    reference: String, admission: ProtocolProofMemoryAdmission,
    memory: OwnedPositiveCountedMemory,
    disposition: ProtocolProofWriteDisposition = .confirmedNoncommit
  ) throws {
    let start = memory.calls()
    guard receipt.operation == .fence, receipt.disposition == disposition,
      !validates({
        _ = try receipt.currentSuccessor(
          expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
      }), memory.calls() == start, receipt.disposition == disposition
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedFenceRedeem(
    _ receipt: ProtocolOwnedProofWriteReceipt, fixture f: Fixture,
    anchor: ProtocolVerificationSnapshot, reference: String,
    admission: ProtocolProofMemoryAdmission, memory: OwnedPositiveCountedMemory
  ) throws -> ProtocolVerificationSnapshot {
    let start = memory.calls()
    guard receipt.operation == .fence, receipt.disposition == .committedCurrent else {
      throw FixtureFailure.nativeShape
    }
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
    guard memory.calls() - start == 1, successor.observation == nil else {
      throw FixtureFailure.nativeShape
    }
    try ownedT09NativeValidate(
      f, successor: successor, binding: f.binding, reference: reference, observation: nil)
    return successor
  }

  private static func ownedFenceAllow(
    _ f: Fixture, chain: OwnedFenceChain, anchor: ProtocolVerificationSnapshot,
    recipe: OwnedPositiveBodyRecipe, body: OwnedBindProbe, commit: OwnedBindProbe
  ) throws -> ProtocolVerificationSnapshot {
    let start = chain.memory.calls()
    let receipt = ownedFenceWrite(
      f, anchor: anchor, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
    guard chain.memory.calls() - start == 4 else { throw FixtureFailure.nativeShape }
    try ownedPositiveBodyCheckpoint(
      f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
      image: recipe.stage.expected, body: body, commit: commit, bodies: 1, commits: 1)
    let successor = try ownedFenceRedeem(
      receipt, fixture: f, anchor: anchor, reference: f.link.tokenRef,
      admission: chain.admission, memory: chain.memory)
    try ownedPositiveBodyCheckpoint(
      f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
      image: recipe.stage.expected, body: body, commit: commit, bodies: 1, commits: 1)
    return successor
  }

  private static func ownedFenceRequireCoreControls() throws {
    let rows = try ownedFenceRawControls()
    guard rows.map({ $0.row }) == [0, 1, 2, 3], rows.count == 4,
      rows.allSatisfy({ $0.qualified && $0.durableImageValidated })
    else { throw FixtureFailure.nativeShape }
  }

  // F01a/F01b: O=S0 or saved genuine S1, actual PRE is genuine S2.
  // F01 matrix: F01a, F01b
  @Test(NativeDBResources(), arguments: [false, true])
  func ownedFenceOriginalAnchorClearsActualLaterPositivePreservingPrincipal(boundOriginal: Bool) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let original = boundOriginal ? chain.parent.anchor : chain.original
      let stage = try Self.ownedFenceStage(f)
      guard stage.before == chain.image else { throw FixtureFailure.nativeShape }
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      _ = try Self.ownedFenceAllow(
        f, chain: chain, anchor: original, recipe: recipe, body: body, commit: commit)
    }
  }

  // F02a/F02b: first clear is extra uninstrumented setup; lawful unbound has B1/B2 N/A.
  // F02 matrix: F02a, F02b
  @Test(NativeDBResources(), arguments: [false, true])
  func ownedFenceDenialOnlyAlreadyClearAndLawfulUnbound(unbound: Bool) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      if unbound {
        _ = try Self.validateFixture(f)
        let memory = OwnedPositiveCountedMemory()
        let admission = ProtocolProofMemoryAdmission { [memory] in
          if !memory.compare() { throw FixtureFailure.redactedFailure }
        }
        let stage = try Self.ownedFenceStage(f)
        guard try Self.ownedDeferredControl(stage.before)["binding"] == nil else {
          throw FixtureFailure.nativeShape
        }
        let recipe = try Self.ownedPositiveInstallBody(
          f, stage: stage, replacement: f.link.tokenRef, fault: false)
        let body = try Self.ownedBindProbe(f.inspector, "body_probe")
        let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
        let start = memory.calls()
        let receipt = Self.ownedFenceWrite(
          f, anchor: f.anchor, binding: f.binding, reference: f.link.tokenRef, admission: admission)
        guard memory.calls() - start == 4 else { throw FixtureFailure.nativeShape }
        _ = try Self.ownedFenceRedeem(
          receipt, fixture: f, anchor: f.anchor, reference: f.link.tokenRef,
          admission: admission, memory: memory)
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
          body: body, commit: commit, bodies: 1, commits: 1)
        guard try Self.ownedDeferredControl(stage.expected)["binding"] == nil else {
          throw FixtureFailure.nativeShape
        }
      } else {
        let chain = try Self.ownedFenceChain(f)
        let firstStage = try Self.ownedFenceStage(f)
        let start = chain.memory.calls()
        let first = Self.ownedFenceWrite(
          f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef,
          admission: chain.admission)
        guard chain.memory.calls() - start == 4,
          try Self.ownedBindImage(f.inspector) == firstStage.expected
        else { throw FixtureFailure.nativeShape }
        let actualS3 = try Self.ownedFenceRedeem(
          first, fixture: f, anchor: chain.original, reference: f.link.tokenRef,
          admission: chain.admission, memory: chain.memory)
        guard actualS3.observation == nil, chain.memory.calls() - start == 5 else {
          throw FixtureFailure.nativeShape
        }
        let stage = try Self.ownedFenceStage(f)
        guard stage.before == firstStage.expected else { throw FixtureFailure.nativeShape }
        let recipe = try Self.ownedPositiveInstallBody(
          f, stage: stage, replacement: f.link.tokenRef, fault: false)
        let body = try Self.ownedBindProbe(f.inspector, "body_probe")
        let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
        _ = try Self.ownedFenceAllow(
          f, chain: chain, anchor: chain.original, recipe: recipe, body: body, commit: commit)
      }
    }
  }

  private enum OwnedFenceInput: String, CaseIterable, Sendable {
    case databaseObject, missingContext, missingLinkedMembership, contextAccount, databaseName
    case nativeHub, nativeDevice, nativeJoined, anchorHubUser, anchorHubOrg, anchorAccount
    case emptyRef, prefixOnlyRef, wrongPrefixRef, nulRef
  }

  // F03 matrix: F03.databaseObject, F03.missingContext, F03.missingLinkedMembership, F03.contextAccount, F03.databaseName, F03.nativeHub, F03.nativeDevice, F03.nativeJoined, F03.anchorHubUser, F03.anchorHubOrg, F03.anchorAccount, F03.emptyRef, F03.prefixOnlyRef, F03.wrongPrefixRef, F03.nulRef
  @Test(NativeDBResources(), arguments: OwnedFenceInput.allCases)
  private func ownedFencePrecheckoutRejectsInvalidOriginalContextPrincipalReference(
    row: OwnedFenceInput
  ) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let seed = try Self.ownedBindImage(f.inspector)
      var unlinked: ProtocolVerificationSnapshot?
      if row == .missingLinkedMembership {
        let absent = try Self.ownedT09LinkImage(seed, old: Self.ownedT09Link(seed), new: nil)
        try Self.ownedT09LinkSwap(
          f, from: seed, to: absent, column: nil, stage: nil, body: nil, commit: nil)
        unlinked = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: nil)
        guard try Self.ownedBindImage(f.inspector) == absent else { throw FixtureFailure.nativeShape }
        try Self.ownedT09LinkSwap(
          f, from: absent, to: seed, column: nil, stage: nil, body: nil, commit: nil)
      }
      let chain = try Self.ownedFenceChain(f)
      var anchor = chain.original
      var binding = f.binding
      var reference = f.link.tokenRef
      let endpoint = f.database.endpoint
      var extra: WorkspaceDatabase?
      defer { if let extra { try? extra.close() } }
      switch row {
      case .databaseObject:
        guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
        let actual = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, createIfMissing: false)
        extra = actual
        let membership = try ProtocolNativeMembership(
          canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
        anchor = try actual.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: membership)
      case .missingContext:
        anchor = try #require(try f.database.readProtocolFact(expectedBinding: f.binding))
      case .missingLinkedMembership: anchor = try #require(unlinked)
      case .contextAccount, .anchorAccount:
        binding = try Self.ownedT09OtherBinding(binding, unit: .account)
        if row == .anchorAccount { anchor = chain.parent.anchor }
      case .databaseName: binding = try Self.ownedT09OtherBinding(binding, unit: .database)
      case .nativeHub: binding = try Self.ownedT09OtherBinding(binding, unit: .hubBase)
      case .nativeDevice: binding = try Self.ownedT09OtherBinding(binding, unit: .device)
      case .nativeJoined: binding = try Self.ownedT09OtherBinding(binding, unit: .joined)
      case .anchorHubUser:
        anchor = chain.parent.anchor; binding = try Self.ownedT09OtherBinding(binding, unit: .boundUser)
      case .anchorHubOrg:
        anchor = chain.parent.anchor; binding = try Self.ownedT09OtherBinding(binding, unit: .boundOrg)
      case .emptyRef: reference = ""
      case .prefixOnlyRef: reference = "secret:"
      case .wrongPrefixRef: reference = "other:FENCE"
      case .nulRef: reference = "secret:FENCE\u{0}NEGATIVE"
      }
      guard try Self.ownedBindImage(f.inspector) == chain.image else { throw FixtureFailure.nativeShape }
      let start = chain.memory.calls()
      let receipt = Self.ownedFenceWrite(
        f, anchor: anchor, binding: binding, reference: reference, admission: chain.admission)
      guard chain.memory.calls() == start, try Self.ownedBindImage(f.inspector) == chain.image else {
        throw FixtureFailure.nativeShape
      }
      try Self.ownedFenceRefuses(
        receipt, anchor: anchor, reference: reference, admission: chain.admission, memory: chain.memory)
      try Self.ownedBindCatalogGuard(f.inspector)
      // No target recipe or probe exists: body/commit/timeout measurements are N/A.
    }
  }

  private enum OwnedFenceNative: String, CaseIterable, Sendable {
    case controlMissing, controlMalformed, controlVersion, storeEpoch, memberEpoch, lowerRevision
    case nativeMissing, nativeHub, nativeDevice, nativeJoined, refMissing, refMalformed, refReplaced
    case currentAccount, currentHubUser, currentHubOrg
  }

  private static func ownedFenceReplaceControl(
    _ f: Fixture, before: OwnedBindImage, old: [String: Any]?, new: [String: Any]?
  ) throws -> OwnedBindImage {
    try ownedBindCatalogGuard(f.inspector)
    let after = try ownedT09ControlImage(before, old: old, new: new)
    guard try ownedBindImage(f.inspector) == before else { throw FixtureFailure.nativeShape }
    var acknowledged = false
    defer { if !acknowledged { _ = try? f.inspector.execute("ROLLBACK") } }
    try f.inspector.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
    try f.inspector.execute("SET LOCAL lock_timeout='2s'")
    try f.inspector.execute("SET LOCAL statement_timeout='2s'")
    if let old {
      guard
        try f.inspector.execute(
          "DELETE FROM public.settings WHERE key=$1 AND value=$2::jsonb",
          [key, try ownedBindText(ownedT09Data(old))]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    }
    if let new {
      guard
        try f.inspector.execute(
          "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)",
          [key, try ownedBindText(ownedT09Data(new))]
        ).affected == 1
      else { throw FixtureFailure.nativeShape }
    }
    try f.inspector.execute("COMMIT")
    acknowledged = true
    guard try ownedBindImage(f.inspector) == after else { throw FixtureFailure.nativeShape }
    try ownedBindCatalogGuard(f.inspector)
    return after
  }

  // F04 matrix: F04.controlMissing, F04.controlMalformed, F04.controlVersion, F04.storeEpoch, F04.memberEpoch, F04.lowerRevision, F04.nativeMissing, F04.nativeHub, F04.nativeDevice, F04.nativeJoined, F04.refMissing, F04.refMalformed, F04.refReplaced, F04.currentAccount, F04.currentHubUser, F04.currentHubOrg
  @Test(NativeDBResources(), arguments: OwnedFenceNative.allCases)
  private func ownedFenceNativePreRejectsEpochPrincipalAndReferenceDriftBeforeMemory(
    row: OwnedFenceNative
  ) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let original = row == .lowerRevision ? chain.parent.anchor : chain.original
      let genuine = try Self.ownedDeferredControl(chain.image)
      var changed = genuine
      var damaged: OwnedBindImage
      var column: OwnedT09LinkColumn?
      let changesLink = [
        .nativeMissing, .nativeHub, .nativeDevice, .nativeJoined,
        .refMissing, .refMalformed, .refReplaced,
      ].contains(row)
      if changesLink {
        let value: String?
        switch row {
        case .nativeMissing: column = nil; value = nil
        case .nativeHub: column = .url; value = "https://example.invalid/FenceOther"
        case .nativeDevice: column = .deviceId; value = "FENCE_NATIVE_OTHER"
        case .nativeJoined: column = .joinedAt; value = "2026-11-13T00:00:00.001Z"
        case .refMissing: column = .tokenRef; value = ""
        case .refMalformed: column = .tokenRef; value = "other:FENCE_NATIVE"
        case .refReplaced: column = .tokenRef; value = "secret:FENCE_NATIVE_B"
        default: throw FixtureFailure.nativeShape
        }
        if let column, let value {
          damaged = try Self.ownedT09ChangedLink(chain.image, column: column, value: value)
        } else {
          damaged = try Self.ownedT09LinkImage(chain.image, old: Self.ownedT09Link(chain.image), new: nil)
        }
        try Self.ownedT09LinkSwap(
          f, from: chain.image, to: damaged, column: column, stage: nil, body: nil, commit: nil)
      } else {
        switch row {
        case .controlMissing: break
        case .controlMalformed: changed["unexpected"] = "FENCE_MALFORMED"
        case .controlVersion: changed["version"] = 2
        case .storeEpoch: changed["storeIncarnation"] = UUID().uuidString
        case .memberEpoch: changed["membershipIncarnation"] = UUID().uuidString
        case .lowerRevision: changed["revision"] = "0"
        case .currentAccount, .currentHubUser, .currentHubOrg:
          let unit: OwnedT09Unit =
            row == .currentAccount ? .account : (row == .currentHubUser ? .boundUser : .boundOrg)
          let binding = try Self.ownedT09OtherBinding(f.binding, unit: unit)
          changed["binding"] = Self.ownedT09Binding(binding)
          var observation = try #require(changed["observation"] as? [String: Any])
          observation["binding"] = Self.ownedT09Binding(binding)
          changed["observation"] = observation
        default: throw FixtureFailure.nativeShape
        }
        damaged = try Self.ownedFenceReplaceControl(
          f, before: chain.image, old: genuine, new: row == .controlMissing ? nil : changed)
      }
      let start = chain.memory.calls()
      let receipt = Self.ownedFenceWrite(
        f, anchor: original, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
      guard chain.memory.calls() == start, try Self.ownedBindImage(f.inspector) == damaged else {
        throw FixtureFailure.nativeShape
      }
      try Self.ownedFenceRefuses(
        receipt, anchor: original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
      try Self.ownedBindCatalogGuard(f.inspector)
      // No target recipe/probes during damaged native PRE; all probe measurements N/A.
      if changesLink {
        try Self.ownedT09LinkSwap(
          f, from: damaged, to: chain.image, column: column, stage: nil, body: nil, commit: nil)
      } else {
        let restored = try Self.ownedFenceReplaceControl(
          f, before: damaged, old: row == .controlMissing ? nil : changed, new: genuine)
        guard restored == chain.image else { throw FixtureFailure.nativeShape }
      }
      try Self.ownedFenceRefuses(
        receipt, anchor: original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      _ = try Self.ownedFenceAllow(
        f, chain: chain, anchor: original, recipe: recipe, body: body, commit: commit)
      try Self.ownedFenceRefuses(
        receipt, anchor: original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
    }
  }

  // F05 matrix: F05.pre, F05.post, F05.preCommit
  @Test(NativeDBResources(), arguments: [1, 2, 3])
  func ownedFenceMemoryPrePostImmediatePreCommitRefuseAndSameInputAllows(ordinal: Int) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let start = chain.memory.calls()
      try chain.memory.armSelector(baseline: start, localOrdinal: ordinal)
      let receipt = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
      guard chain.memory.calls() - start == ordinal else { throw FixtureFailure.nativeShape }
      try Self.ownedFenceRefuses(
        receipt, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: chain.image,
        body: body, commit: commit, bodies: ordinal == 1 ? 0 : 1, commits: 0)
      let recoveryStart = chain.memory.calls()
      chain.memory.disableSelector()
      guard chain.memory.calls() == recoveryStart else { throw FixtureFailure.nativeShape }
      try Self.ownedFenceRefuses(
        receipt, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
      let inverseBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let inverseCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      _ = try Self.ownedFenceAllow(
        f, chain: chain, anchor: chain.original, recipe: recipe, body: inverseBody, commit: inverseCommit)
      try Self.ownedFenceRefuses(
        receipt, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
    }
  }
}

extension OwnedProtocolProofWriteTests {
  private static func ownedFenceObserveWait(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    kind: OwnedBindWaitKind, hold: OwnedProofHold, finished: OwnedBindFinished,
    memory: OwnedPositiveCountedMemory, invocationStart: Int, deadline: UInt64
  ) throws {
    guard holderPID > 0, !knownOwnedPIDs.isEmpty,
      knownOwnedPIDs.allSatisfy({ $0 > 0 }), knownOwnedPIDs.contains(holderPID)
    else { throw FixtureFailure.nativeShape }
    let query =
      kind == .advisory
      ? "SELECT pg_advisory_xact_lock($1::bigint)"
      : "SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE"
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    let sql = kind == .advisory ? ownedBindAdvisoryWait : ownedBindLinkWait
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard finished.pending(), hold.heldUnexpired(), memory.calls() == invocationStart else {
        throw FixtureFailure.nativeShape
      }
      let rows = try c.execute(
        sql, [database, String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey), query, excluded]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      // A truthy result after the original deadline is invalid, including the final query.
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(),
        hold.heldUnexpired(), memory.calls() == invocationStart
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid)
        else { throw FixtureFailure.nativeShape }
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedFenceReleasePreHold(
    _ hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedPositiveCountedMemory,
    invocationStart: Int, retiring: Bool, deadline: UInt64
  ) throws {
    guard hold.heldUnexpired(), finished.pending(), memory.calls() == invocationStart else {
      throw FixtureFailure.nativeShape
    }
    if retiring { memory.setCurrent(false) }
    // Retirement's mutex is released before this monotonic sample or any release operation.
    let retirement = DispatchTime.now().uptimeNanoseconds
    let original = hold.snapshot()
    guard original.entered, original.held, !original.expired, !original.released,
      retirement < original.expiry, finished.pending(), memory.calls() == invocationStart
    else { throw FixtureFailure.nativeShape }
    let releaseStart = DispatchTime.now().uptimeNanoseconds
    hold.release()
    let releaseEnd = DispatchTime.now().uptimeNanoseconds
    let released = hold.snapshot()
    // No SQL or scheduling is interposed between the retirement and prompt release.
    guard retirement <= releaseStart, releaseStart <= releaseEnd,
      releaseEnd < original.expiry, releaseEnd <= deadline, released.released, !released.expired
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedFenceObserveCommit(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    holderApplication: String, candidateApplication: String, rawPID: Int?,
    hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedPositiveCountedMemory?,
    invocationStart: Int, probes: OwnedDeferredProbes, deadline: UInt64
  ) throws {
    guard holderPID > 0, knownOwnedPIDs.contains(holderPID),
      knownOwnedPIDs.allSatisfy({ $0 > 0 }), WorkspaceDatabase.remoteApplyLockKey == 1647599984,
      WorkspaceDatabase.remoteApplyLockKey != 1647600739
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard hold.heldUnexpired(), finished.pending() else { throw FixtureFailure.nativeShape }
      if let memory {
        let delta = memory.calls() - invocationStart
        guard (0...3).contains(delta) else { throw FixtureFailure.nativeShape }
        if delta != 3 {
          // Waiting for entry is non-credit; no memory ordinal substitutes for native COMMIT.
          Thread.sleep(forTimeInterval: 0.005)
          continue
        }
      }
      let queryBegin = DispatchTime.now().uptimeNanoseconds
      let rows = try c.execute(
        ownedDeferredCommitWait,
        [
          database, String(holderPID), "1647600739", excluded,
          holderApplication, candidateApplication, "1647599984",
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      // Both query completion and all synchronous proof reads must fit the ORIGINAL window.
      guard queryBegin <= queryEnd, queryEnd <= deadline, rows.count <= 1,
        hold.heldUnexpired(), finished.pending(),
        memory.map({ $0.calls() - invocationStart == 3 }) ?? true
      else { throw FixtureFailure.nativeShape }
      let actualProbes = try ownedDeferredProbes(c)
      guard actualProbes.timeout == probes.timeout,
        actualProbes.body.advanced(from: probes.body, by: 0)
          || actualProbes.body.advanced(from: probes.body, by: 1),
        actualProbes.commit.advanced(from: probes.commit, by: 0)
          || actualProbes.commit.advanced(from: probes.commit, by: 1),
        DispatchTime.now().uptimeNanoseconds <= deadline,
        hold.heldUnexpired(), finished.pending(),
        memory.map({ $0.calls() - invocationStart == 3 }) ?? true
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid), rawPID.map({ $0 == pid }) ?? true,
          let ageText = rows[0].text("age_us"), let age = Int64(ageText), age >= 0,
          actualProbes.advanced(from: probes, body: 1, commit: 1, timeout: 0),
          DispatchTime.now().uptimeNanoseconds <= deadline,
          hold.heldUnexpired(), finished.pending(),
          memory.map({ $0.calls() - invocationStart == 3 }) ?? true
        else { throw FixtureFailure.nativeShape }
        // Age is a nonnegative diagnostic only, never a cause or timer reset.
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedFenceReleaseCommit(
    _ hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedPositiveCountedMemory?,
    invocationStart: Int, retire: Bool, deadline: UInt64
  ) throws {
    guard hold.heldUnexpired(), finished.pending(),
      memory.map({ $0.calls() - invocationStart == 3 }) ?? true,
      !retire || memory != nil
    else { throw FixtureFailure.nativeShape }
    if retire { memory?.setCurrent(false) }
    // The memory mutex has been released. Nothing blocking or SQL runs before release.
    let retirement = DispatchTime.now().uptimeNanoseconds
    let original = hold.snapshot()
    guard original.entered, original.held, !original.expired, !original.released,
      retirement < original.expiry, finished.pending(),
      memory.map({ $0.calls() - invocationStart == 3 }) ?? true
    else { throw FixtureFailure.nativeShape }
    let releaseStart = DispatchTime.now().uptimeNanoseconds
    hold.release()
    let releaseEnd = DispatchTime.now().uptimeNanoseconds
    let released = hold.snapshot()
    guard retirement <= releaseStart, releaseStart <= releaseEnd, releaseEnd <= deadline,
      releaseEnd < original.expiry, released.released, !released.expired
    else { throw FixtureFailure.nativeShape }
  }

  private static func ownedFenceObserveControl(
    _ c: PostgresConnection, database: String, holderPID: Int, knownOwnedPIDs: [Int],
    hold: OwnedProofHold, finished: OwnedBindFinished, memory: OwnedPositiveCountedMemory,
    invocationStart: Int, deadline: UInt64
  ) throws -> Int {
    guard holderPID > 0, knownOwnedPIDs.contains(holderPID),
      !knownOwnedPIDs.isEmpty, knownOwnedPIDs.allSatisfy({ $0 > 0 })
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      guard finished.pending(), hold.heldUnexpired(), memory.calls() == invocationStart else {
        throw FixtureFailure.nativeShape
      }
      let rows = try c.execute(
        ownedT11ControlWait,
        [
          database, String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey),
          ownedT11ControlQuery, excluded,
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(),
        hold.heldUnexpired(), memory.calls() == invocationStart
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), let pid = Int(text), pid > 0,
          !knownOwnedPIDs.contains(pid)
        else { throw FixtureFailure.nativeShape }
        return pid
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedFenceContenderReady(
    _ state: OwnedT11ContenderState, hold: OwnedProofHold, finished: OwnedBindFinished,
    memory: OwnedPositiveCountedMemory, invocationStart: Int, deadline: UInt64
  ) throws -> Int {
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let value = state.snapshot()
      let held = hold.heldUnexpired()
      let pending = finished.pending()
      let calls = memory.calls()
      let end = DispatchTime.now().uptimeNanoseconds
      guard end <= deadline, held, pending, calls == invocationStart, !value.returned else {
        throw FixtureFailure.nativeShape
      }
      if value.started && value.pid > 0 { return value.pid }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedFenceObserveContender(
    _ c: PostgresConnection, database: String, application: String, contenderPID: Int,
    writerPID: Int, holderPID: Int, knownOwnedPIDs: [Int], hold: OwnedProofHold,
    finished: OwnedBindFinished, contender: OwnedT11ContenderState,
    memory: OwnedPositiveCountedMemory, invocationStart: Int, deadline: UInt64
  ) throws {
    guard contenderPID > 0, writerPID > 0, holderPID > 0, writerPID != contenderPID,
      knownOwnedPIDs.contains(contenderPID), knownOwnedPIDs.contains(holderPID),
      !knownOwnedPIDs.contains(writerPID), knownOwnedPIDs.allSatisfy({ $0 > 0 })
    else { throw FixtureFailure.nativeShape }
    let excluded = "{" + knownOwnedPIDs.map(String.init).joined(separator: ",") + "}"
    while DispatchTime.now().uptimeNanoseconds <= deadline {
      let before = contender.snapshot()
      guard before.started, before.pid == contenderPID, !before.returned,
        finished.pending(), hold.heldUnexpired(), memory.calls() == invocationStart
      else { throw FixtureFailure.nativeShape }
      // All nine bindings match the two predicates IN THIS SAME native statement:
      // 1 contender; 2 DB; 3 private app; 4 link query; 5 actual writer; 6 holder;
      // 7 actual advisory key; 8 composed control query; 9 all known raw/inspector PIDs.
      let rows = try c.execute(
        ownedT11ContenderWait,
        [
          String(contenderPID), database, application,
          "SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE", String(writerPID),
          String(holderPID), String(WorkspaceDatabase.remoteApplyLockKey),
          ownedT11ControlQuery, excluded,
        ]
      ).rows
      let queryEnd = DispatchTime.now().uptimeNanoseconds
      let after = contender.snapshot()
      guard queryEnd <= deadline, rows.count <= 1, finished.pending(), hold.heldUnexpired(),
        memory.calls() == invocationStart, after.started, after.pid == contenderPID, !after.returned
      else { throw FixtureFailure.nativeShape }
      if rows.count == 1 {
        guard let text = rows[0].text("pid"), Int(text) == contenderPID else {
          throw FixtureFailure.nativeShape
        }
        return
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw FixtureFailure.nativeShape
  }

  private static func ownedFenceRawControls(
    diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> [OwnedBindRawFacts] {
    var results: [OwnedBindRawFacts] = []
    var databases = Set<Data>()
    for row in OwnedBindRawControl.allCases {
      diagnostic?.selectRawRow(row)
      diagnostic?.phase = .rawFixture
      var observed: OwnedBindRawFacts?
      try withFixture { f in
        diagnostic?.phase = .rawValidate
        let chain = try ownedFenceChain(f)
        let replacement = row == .normalB ? "secret:OWNED_FENCE_RAW_B" : f.link.tokenRef
        diagnostic?.phase = .rawFreeze
        let frozen = try ownedFenceStage(f)
        guard frozen.before == chain.image else { throw FixtureFailure.nativeShape }
        let stage = OwnedBindStageFixture(
          before: frozen.before, expected: frozen.expected, controlJSON: frozen.controlJSON,
          originalReference: frozen.originalReference, replacement: replacement,
          device: frozen.device, lowerWall: frozen.lowerWall)
        guard databases.insert(Data(stage.before.database.utf8)).inserted else {
          throw FixtureFailure.nativeShape
        }
        // Every row gets a distinct endpoint/database, genuine owned B1/B2 S2, independent
        // exact fenced S3, and the identical two enabled UPDATE-only functions/triggers.
        diagnostic?.phase = .rawInstall
        try ownedBindInstall(f, stage: stage, rawBodyFault: row == .bodyFault)
        let catalog = try ownedDeferredCatalog(f.inspector)
        try ownedPositiveBodyShape(
          f.inspector, stage: stage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawExpectedDamage
        var checkedStage = stage
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
          guard let settings = stage.expected.rows["settings"] else { throw FixtureFailure.nativeShape }
          var replacements = 0
          let damaged = try settings.map { data -> Data in
            var object = try ownedT09Object(data)
            if object["key"] as? String == sentinelKey {
              guard object["value"] as? String == "OWNED_PROOF_RETAINED" else {
                throw FixtureFailure.nativeShape
              }
              object["value"] = "OWNED_BIND_PRIVATE_IMAGE_CORRUPTION"
              replacements += 1
            }
            return try ownedT09Data(object)
          }.sorted { $0.lexicographicallyPrecedes($1) }
          guard replacements == 1 else { throw FixtureFailure.nativeShape }
          var expectedRows = stage.expected.rows
          expectedRows["settings"] = damaged
          checkedStage = OwnedBindStageFixture(
            before: stage.before,
            expected: OwnedBindImage(
              database: stage.expected.database, rows: expectedRows, sequence: stage.expected.sequence),
            controlJSON: stage.controlJSON, originalReference: stage.originalReference,
            replacement: stage.replacement, device: stage.device, lowerWall: stage.lowerWall)
        }
        try ownedPositiveBodyShape(
          f.inspector, stage: checkedStage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawInitialImage
        guard try ownedBindImage(f.inspector) == stage.before else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .rawDriver
        observed = try ownedBindRawDriver(f, stage: stage, row: row, family: .fence)
        guard try ownedDeferredCatalog(f.inspector) == catalog else { throw FixtureFailure.nativeShape }
        try ownedPositiveBodyShape(
          f.inspector, stage: checkedStage, replacement: replacement, fault: row == .bodyFault)
        diagnostic?.phase = .rawTeardown
      }
      // withFixture has closed its database and relinquished its inspector/physical root first.
      diagnostic?.phase = .rawFacts
      guard let observed, observed.qualified else { throw FixtureFailure.nativeShape }
      results.append(observed)
    }
    guard results.count == 4 else { throw FixtureFailure.nativeShape }
    return results
  }

  private static func ownedFenceDeferredRawControl(
    _ row: Int, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredControlFacts {
    diagnostic.selectRawFixture(row)
    diagnostic.attempt = .none
    guard (0...4).contains(row) else { throw FixtureFailure.nativeShape }
    var facts: OwnedDeferredControlFacts?
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      let chain = try ownedFenceChain(f)
      diagnostic.enter(.freeze)
      let stage = try ownedFenceStage(f)
      guard stage.before == chain.image else { throw FixtureFailure.nativeShape }
      var mode = row == 2 ? "fault" : (row >= 3 ? "gate" : "normal")
      var baseline = 0
      diagnostic.enter(.oldInstall)
      var recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      diagnostic.enter(.damage)
      if row == 0 { recipe = try ownedDeferredDamage(f.inspector, recipe: recipe, diagnostic: diagnostic) }
      diagnostic.enter(.initialState)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let work = OwnedDeferredWork()
      // Registration precedes every holder/worker, including partially started attempts.
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var attempts = 0
      var acknowledgements = 0
      var errors = 0
      var rollbacks = 0
      var bodies = 0
      var deferred = 0
      var timeouts = 0
      var restorations = 0
      var transitions = 0
      for attempt in 0..<(row == 0 ? 1 : 2) {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        let gated = row >= 3
        let timeout = row == 4 && attempt == 0
        let kind: OwnedDeferredRawKind =
          row == 0 ? .reject : (row == 2 && attempt == 0 ? .fault : (timeout ? .timeout : .normal))
        let application = "owned-fence-raw-\(UUID().uuidString)"
        let holderApplication = "owned-fence-gate-\(UUID().uuidString)"
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        var holderPID = 0
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        let state = OwnedBindHolderState()
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        diagnostic.enter(.rawStart)
        let worker = ownedDeferredRawWorker(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: application,
          kind: kind, state: state, finished: finished)
        work.raw.append(worker)
        diagnostic.enter(.observeCommit)
        if gated {
          while state.snapshot().pid == 0 && finished.pending()
            && DispatchTime.now().uptimeNanoseconds <= deadline
          { Thread.sleep(forTimeInterval: 0.005) }
          let candidate = state.snapshot()
          guard candidate.acquired, candidate.pid > 0, !knownPIDs.contains(candidate.pid),
            DispatchTime.now().uptimeNanoseconds <= deadline
          else { throw FixtureFailure.nativeShape }
          try ownedDeferredObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: application, rawPID: candidate.pid, hold: hold,
            finished: finished, memory: nil, invocationStart: 0, probes: before.probes,
            deadline: deadline)
          if !timeout {
            try ownedDeferredRelease(
              hold, finished: finished, memory: nil, invocationStart: 0, retire: false,
              deadline: deadline)
          }
        }
        // The intended timeout keeps its original eight-second hold valid until actual return.
        // Capture the result/timestamp, then immediately release ALL and join ALL before guards.
        diagnostic.enter(.resultCapture)
        let result = worker.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        let rawIdentity = state.snapshot()
        diagnostic.enter(.rawResult)
        guard result.valid, finished.pending() == false, rawIdentity.acquired,
          rawIdentity.pid > 0, !knownPIDs.contains(rawIdentity.pid),
          (!gated || held?.normal == true), heldAtReturn,
          !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        knownPIDs.append(rawIdentity.pid)
        attempts += 1
        let success = kind == .normal
        let bodyCount: Int64 = row == 0 ? 0 : 1
        let commitCount: Int64 = row == 0 ? 0 : 1
        let timeoutCount: Int64 = timeout ? 1 : 0
        diagnostic.enter(.rawResult)
        guard result.dmlReturned == (row != 0), result.commitSent == (row != 0),
          result.acknowledged == success, result.rollbackAcknowledged == (row == 0),
          result.predicateRejected == (row == 0),
          result.actualDeferredFault == (kind == .fault), result.actualServerTimeout == timeout,
          result.ownPredicate == (row != 0), result.ownSettings == (row != 0)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard after.image == (success ? stage.expected : stage.before),
          after.probes.advanced(
            from: before.probes, body: bodyCount, commit: commitCount, timeout: timeoutCount)
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.observations)
        if success {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations, actual: after.observations,
            rawMillis: result.millis)
          acknowledgements += 1
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
          if row == 0 { rollbacks += 1 } else { errors += 1 }
        }
        bodies += Int(bodyCount)
        deferred += Int(commitCount)
        timeouts += Int(timeoutCount)
        if attempt == 0 && (row == 1 || row == 3) {
          diagnostic.enter(.q01)
          try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
          restorations += 1
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
            diagnostic: diagnostic)
          baseline = 1
          transitions += 1
        } else if attempt == 0 && row == 2 {
          diagnostic.enter(.configTransition)
          try ownedDeferredTransition(
            f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
            diagnostic: diagnostic)
          mode = "normal"
          transitions += 1
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.raw.count == (row == 0 ? 1 : 2), work.holders.count == (row >= 3 ? 2 : 0) else {
        throw FixtureFailure.nativeShape
      }
      facts = OwnedDeferredControlFacts(
        row: row, attempts: attempts, holders: work.holders.count,
        acknowledgements: acknowledgements, errors: errors, rollbacks: rollbacks,
        bodies: bodies, deferred: deferred, timeouts: timeouts,
        restorations: restorations, transitions: transitions, qualified: true)
    }
    // Complete fixture close/root teardown precedes escape of these primitive-only facts.
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private static func ownedFenceDeferredPrerequisites(
    diagnostic: OwnedDeferredDiagnostic
  ) throws -> (
    old: Int, controls: Int, attempts: Int, holders: Int
  ) {
    diagnostic.fixture = .oldFour
    diagnostic.attempt = .none
    diagnostic.enter(.oldFour)
    let old = try ownedFenceRawControls()
    diagnostic.enter(.oldFour)
    guard old.map({ $0.row }) == [0, 1, 2, 3], old.count == 4,
      old.allSatisfy({ $0.qualified && $0.durableImageValidated })
    else { throw FixtureFailure.nativeShape }
    // The old four have ALL torn down. Each NEW recipe row independently tears down as well.
    var rows: [OwnedDeferredControlFacts] = []
    for row in 0...4 { rows.append(try ownedFenceDeferredRawControl(row, diagnostic: diagnostic)) }
    diagnostic.fixture = .none
    diagnostic.attempt = .none
    diagnostic.enter(.finalFacts)
    guard rows.map({ $0.row }) == [0, 1, 2, 3, 4], rows.allSatisfy({ $0.qualified }),
      rows.map({ $0.attempts }) == [1, 2, 2, 2, 2],
      rows.map({ $0.holders }) == [0, 0, 0, 2, 2],
      rows.map({ $0.acknowledgements }) == [0, 2, 1, 2, 1],
      rows.map({ $0.errors }) == [0, 0, 1, 0, 1],
      rows.map({ $0.rollbacks }) == [1, 0, 0, 0, 0],
      rows.map({ $0.bodies }) == [0, 2, 2, 2, 2],
      rows.map({ $0.deferred }) == [0, 2, 2, 2, 2],
      rows.map({ $0.timeouts }) == [0, 0, 0, 0, 1],
      rows.map({ $0.restorations }) == [0, 1, 0, 1, 0],
      rows.map({ $0.transitions }) == [0, 1, 1, 1, 0]
    else { throw FixtureFailure.nativeShape }
    return (old.count, rows.count, rows.reduce(0) { $0 + $1.attempts }, rows.reduce(0) { $0 + $1.holders })
  }
}

extension OwnedProtocolProofWriteTests {
  // F06 matrix: F06.advisory, F06.link
  @Test(NativeDBResources(), arguments: [0, 1])
  func ownedFenceRetirementAfterActualAdvisoryOrLinkPreWaitRefuses(kindValue: Int) throws {
    try Self.ownedFenceRequireCoreControls()
    let kind: OwnedBindWaitKind = kindValue == 0 ? .advisory : .link
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let memory = chain.memory
      let admission = chain.admission
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      var knownPIDs = [try Self.ownedDeferredInspectorPID(f.inspector)]
      var original: ProtocolOwnedProofWriteReceipt?
      for attempt in 0..<2 {
        memory.setCurrent(true)
        let body = try Self.ownedBindProbe(f.inspector, "body_probe")
        let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
        let start = memory.calls()
        let hold = OwnedProofHold()
        let state = OwnedBindHolderState()
        work.holds.append(hold)
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let holder = Self.ownedBindHolder(
          binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: NSUserName(), application: "owned-fence-pre-\(UUID())",
          kind: kind, hold: hold, state: state)
        work.holders.append(holder)
        let pid = try Self.ownedBindHolderReady(state, hold: hold, deadline: readiness)
        guard !knownPIDs.contains(pid) else { throw FixtureFailure.nativeShape }
        knownPIDs.append(pid)
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        let writer = Self.ownedFenceWriter(
          database: f.database, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef,
          admission: admission, finished: finished)
        work.writers.append(writer)
        try Self.ownedFenceObserveWait(
          f.inspector, database: endpoint.database, holderPID: pid, knownOwnedPIDs: knownPIDs,
          kind: kind, hold: hold, finished: finished, memory: memory,
          invocationStart: start, deadline: deadline)
        guard try Self.ownedBindProbe(f.inspector, "body_probe") == body,
          try Self.ownedBindProbe(f.inspector, "commit_probe") == commit
        else { throw FixtureFailure.nativeShape }
        try Self.ownedFenceReleasePreHold(
          hold, finished: finished, memory: memory, invocationStart: start,
          retiring: attempt == 0, deadline: deadline)
        let receipt = writer.join()
        work.releaseAndJoin()
        let held = holder.join()
        guard held.normal, !finished.pending(), memory.calls() - start == (attempt == 0 ? 1 : 4) else {
          throw FixtureFailure.nativeShape
        }
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
          image: attempt == 0 ? chain.image : stage.expected, body: body, commit: commit,
          bodies: attempt == 0 ? 0 : 1, commits: attempt == 0 ? 0 : 1)
        if attempt == 0 {
          original = receipt
          try Self.ownedFenceRefuses(
            receipt, anchor: chain.original, reference: f.link.tokenRef,
            admission: admission, memory: memory)
        } else {
          _ = try Self.ownedFenceRedeem(
            receipt, fixture: f, anchor: chain.original, reference: f.link.tokenRef,
            admission: admission, memory: memory)
          guard let original else { throw FixtureFailure.nativeShape }
          try Self.ownedFenceRefuses(
            original, anchor: chain.original, reference: f.link.tokenRef,
            admission: admission, memory: memory)
          try Self.ownedPositiveBodyCheckpoint(
            f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
            image: stage.expected, body: body, commit: commit, bodies: 1, commits: 1)
        }
      }
      #expect(work.holders.count == 2 && work.writers.count == 2)
    }
  }
}

extension OwnedProtocolProofWriteTests {
  // F07 matrix: F07.bodyFault, F07.reference
  @Test(NativeDBResources(), arguments: [false, true])
  func ownedFenceActualBodyFaultOrReferenceReplacementNeverCreatesContinuation(bodyFault: Bool) throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let memory = chain.memory
      let admission = chain.admission
      let stage = try Self.ownedFenceStage(f)
      let replacement = bodyFault ? f.link.tokenRef : "secret:OWNED_FENCE_REFERENCE_B"
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: replacement, fault: bodyFault)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let start = memory.calls()
      let refused = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: admission)
      guard memory.calls() - start == 1 else { throw FixtureFailure.nativeShape }
      try Self.ownedFenceRefuses(
        refused, anchor: chain.original, reference: f.link.tokenRef,
        admission: admission, memory: memory)
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: replacement, fault: bodyFault, image: chain.image,
        body: body, commit: commit, bodies: 1, commits: 0)
      try Self.ownedPositiveBodyMode(
        f, recipe: recipe, oldReference: replacement, oldFault: bodyFault,
        newReference: f.link.tokenRef, newFault: false)
      let inverseBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let inverseCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let inverseStart = memory.calls()
      let allowed = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: admission)
      guard allowed.operation == .fence, allowed.disposition == .committedCurrent,
        memory.calls() - inverseStart == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      _ = try Self.ownedFenceRedeem(
        allowed, fixture: f, anchor: chain.original, reference: f.link.tokenRef,
        admission: admission, memory: memory)
      try Self.ownedFenceRefuses(
        refused, anchor: chain.original, reference: f.link.tokenRef,
        admission: admission, memory: memory)
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: inverseBody, commit: inverseCommit, bodies: 1, commits: 1)
      #expect(memory.calls() - start == 6)
    }
  }

  // F10 matrix: F10.write, F10.redemptions
  @Test(NativeDBResources()) func ownedFenceCurrentReceiptRedeemsOriginalAnchorOnlyAndFreshMemory() throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      _ = try Self.validateFixture(f)
      let otherMemory = OwnedBindMemory(selected: nil)
      let otherAdmission = ProtocolProofMemoryAdmission { [otherMemory] in
        if !otherMemory.compare() { throw FixtureFailure.redactedFailure }
      }
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      let wrongAccount = try f.database.captureProtocolVerification(
        accountID: "OWNED_FENCE_REDEMPTION_OTHER", expectedMembership: membership)
      let chain = try Self.ownedFenceChain(f)
      let memory = chain.memory
      let admission = chain.admission
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      let body = try Self.ownedBindProbe(f.inspector, "body_probe")
      let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let writeStart = memory.calls()
      let receipt = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: admission)
      guard receipt.operation == .fence, receipt.disposition == .committedCurrent,
        memory.calls() - writeStart == 4
      else { throw FixtureFailure.nativeShape }
      try Self.ownedPositiveBodyCheckpoint(
        f, recipe: recipe, replacement: f.link.tokenRef, fault: false, image: stage.expected,
        body: body, commit: commit, bodies: 1, commits: 1)
      let frozenBody = try Self.ownedBindProbe(f.inspector, "body_probe")
      let frozenCommit = try Self.ownedBindProbe(f.inspector, "commit_probe")
      let observations = try Self.ownedDeferredObservations(f.inspector)
      // F10.write ends with ZERO redemptions. Expected S3 JSON is not a snapshot getter.
      guard memory.calls() - writeStart == 4 else { throw FixtureFailure.nativeShape }
      let redemptionStart = memory.calls()
      var deltas: [Int] = []
      let equalOriginal = chain.original
      let firstStart = memory.calls()
      // FIRST redemption obtains the actual S3 snapshot. No recapture or private initializer.
      let actualS3 = try receipt.currentSuccessor(
        expectedSnapshot: equalOriginal, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      deltas.append(memory.calls() - firstStart)
      guard deltas == [1], actualS3.observation == nil else { throw FixtureFailure.nativeShape }
      try Self.ownedT09NativeValidate(
        f, successor: actualS3, binding: f.binding, reference: f.link.tokenRef, observation: nil)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      for wrongAnchor in [chain.positive, actualS3, chain.parent.anchor] {
        let before = memory.calls()
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: wrongAnchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
          })
        else { throw FixtureFailure.nativeShape }
        deltas.append(memory.calls() - before)
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let extra = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, createIfMissing: false)
      defer { try? extra.close() }
      let otherObjectAnchor = try extra.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      let noContext = try #require(try f.database.readProtocolFact(expectedBinding: f.binding))
      let contextStart = memory.calls()
      for wrongAnchor in [wrongAccount, noContext, otherObjectAnchor] {
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: wrongAnchor, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
          }), memory.calls() == contextStart
        else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      deltas.append(memory.calls() - contextStart)
      let referenceStart = memory.calls()
      for wrongRef in ["", "secret:", "other:x", "secret:x\u{0}y", "secret:OWNED_FENCE_OTHER"] {
        guard
          !Self.validates({
            _ = try receipt.currentSuccessor(
              expectedSnapshot: equalOriginal, expectedTokenRef: wrongRef, memoryAdmission: admission)
          }), memory.calls() == referenceStart
        else { throw FixtureFailure.nativeShape }
        try Self.ownedPositiveUnchangedBody(
          f, recipe: recipe, image: stage.expected, body: frozenBody,
          commit: frozenCommit, observations: observations)
      }
      deltas.append(memory.calls() - referenceStart)
      let admissionStart = memory.calls()
      guard
        !Self.validates({
          _ = try receipt.currentSuccessor(
            expectedSnapshot: equalOriginal, expectedTokenRef: f.link.tokenRef,
            memoryAdmission: otherAdmission)
        }), otherMemory.calls() == 0
      else { throw FixtureFailure.nativeShape }
      deltas.append(memory.calls() - admissionStart)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      let retirementStart = memory.calls()
      memory.setCurrent(false)
      guard memory.calls() == retirementStart,
        !Self.validates({
          _ = try receipt.currentSuccessor(
            expectedSnapshot: equalOriginal, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
        }), receipt.disposition == .committedCurrent
      else { throw FixtureFailure.nativeShape }
      deltas.append(memory.calls() - retirementStart)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      let recoveryStart = memory.calls()
      memory.setCurrent(true)
      guard memory.calls() == recoveryStart else { throw FixtureFailure.nativeShape }
      let recovered = try receipt.currentSuccessor(
        expectedSnapshot: equalOriginal, expectedTokenRef: f.link.tokenRef, memoryAdmission: admission)
      deltas.append(memory.calls() - recoveryStart)
      guard receipt.disposition == .committedCurrent, recovered.observation == actualS3.observation,
        otherMemory.calls() == 0, deltas == [1, 0, 0, 0, 0, 0, 0, 1, 1],
        memory.calls() - redemptionStart == 3
      else { throw FixtureFailure.nativeShape }
      // Both actual returned values must independently equal the SAME frozen native S3 facts.
      try Self.ownedT09NativeValidate(
        f, successor: recovered, binding: f.binding, reference: f.link.tokenRef, observation: nil)
      try Self.ownedT09NativeValidate(
        f, successor: actualS3, binding: f.binding, reference: f.link.tokenRef, observation: nil)
      try Self.ownedPositiveUnchangedBody(
        f, recipe: recipe, image: stage.expected, body: frozenBody,
        commit: frozenCommit, observations: observations)
      #expect(deltas == [1, 0, 0, 0, 0, 0, 0, 1, 1])
    }
  }
}

extension OwnedProtocolProofWriteTests {
  // F08 matrix: F08.max
  @Test(NativeDBResources()) func ownedFenceActualLatestRevisionOverflowNeverRepairsOrWraps() throws {
    try Self.ownedFenceRequireCoreControls()
    try Self.withFixture { f in
      let inactive = try Self.validateFixture(f)
      let before = try Self.ownedBindImage(f.inspector)
      var seed = inactive.object
      seed["revision"] = String(Int64.max - 2)
      let seeded = try Self.ownedFenceReplaceControl(f, before: before, old: inactive.object, new: seed)
      let membership = try ProtocolNativeMembership(
        canonicalHubBase: f.link.url, deviceID: f.link.deviceId, linkJoinedAt: f.link.joinedAt)
      let original = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: membership)
      guard try Self.ownedBindImage(f.inspector) == seeded else { throw FixtureFailure.nativeShape }
      let actual = Fixture(
        database: f.database, inspector: f.inspector, link: f.link, binding: f.binding, anchor: original)
      let chain = try Self.ownedFenceChain(actual, validatedSeed: true)
      let latest = try Self.control(actual)
      let bound = try Self.ownedDeferredControl(chain.parent.image)
      guard latest.revision == Int64.max, bound["revision"] as? String == String(Int64.max - 1) else {
        throw FixtureFailure.nativeShape
      }
      let start = chain.memory.calls()
      let receipt = Self.ownedFenceWrite(
        actual, anchor: original, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
      guard chain.memory.calls() - start == 1, try Self.ownedBindImage(f.inspector) == chain.image else {
        throw FixtureFailure.nativeShape
      }
      try Self.ownedFenceRefuses(
        receipt, anchor: original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory)
      try Self.ownedBindCatalogGuard(f.inspector)
      // No representable S3, target recipe, or target probe: all measurements N/A.
    }
    // This independent fresh allow has a different original and is not a same-input inverse.
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedPositiveInstallBody(
        f, stage: stage, replacement: f.link.tokenRef, fault: false)
      _ = try Self.ownedFenceAllow(
        f, chain: chain, anchor: chain.original, recipe: recipe,
        body: Self.ownedBindProbe(f.inspector, "body_probe"),
        commit: Self.ownedBindProbe(f.inspector, "commit_probe"))
    }
  }

  // F09 matrix: F09.selector4
  @Test(NativeDBResources()) func ownedFencePostAckMemoryFailureIsCommittedStale() throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: .stale)
    let prerequisites = try Self.ownedFenceDeferredPrerequisites(diagnostic: diagnostic)
    guard prerequisites.old == 4, prerequisites.controls == 5,
      prerequisites.attempts == 9, prerequisites.holders == 4
    else { throw FixtureFailure.nativeShape }
    try Self.withFixture { f in
      let chain = try Self.ownedFenceChain(f)
      let stage = try Self.ownedFenceStage(f)
      let recipe = try Self.ownedDeferredInstall(f, stage: stage, mode: "normal", diagnostic: diagnostic)
      let before = try Self.ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "normal", baseline: 0, diagnostic: diagnostic)
      guard before.image == chain.image, before.observations.isEmpty else { throw FixtureFailure.nativeShape }
      let start = chain.memory.calls()
      try chain.memory.armSelector(baseline: start, localOrdinal: 4)
      let stale = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
      guard chain.memory.calls() - start == 4 else { throw FixtureFailure.nativeShape }
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      let first = try Self.ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "normal", baseline: 0, diagnostic: diagnostic)
      guard first.image == stage.expected, first.observations.count == 1,
        first.probes.advanced(from: before.probes, body: 1, commit: 1, timeout: 0)
      else { throw FixtureFailure.nativeShape }
      try Self.ownedDeferredAppendObservation(
        f.inspector, stage: stage, old: before.observations, actual: first.observations, rawMillis: nil)
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      // Existing NORMAL baseline0/count1 Q01 retains the complete history and all three probes.
      try Self.ownedDeferredQ01(f, recipe: recipe, mode: "normal", diagnostic: diagnostic)
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      let restored = try Self.ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "normal", baseline: 0, diagnostic: diagnostic)
      guard restored.image == stage.before, restored.probes == first.probes,
        restored.observations == first.observations
      else { throw FixtureFailure.nativeShape }
      try Self.ownedDeferredTransition(
        f, recipe: recipe, oldMode: "normal", oldBaseline: 0, newMode: "normal", newBaseline: 1,
        diagnostic: diagnostic)
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      let recovery = chain.memory.calls()
      chain.memory.disableSelector()
      chain.memory.setCurrent(true)
      guard chain.memory.calls() == recovery else { throw FixtureFailure.nativeShape }
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      let allowed = Self.ownedFenceWrite(
        f, anchor: chain.original, binding: f.binding, reference: f.link.tokenRef, admission: chain.admission)
      guard chain.memory.calls() - recovery == 4, allowed.disposition == .committedCurrent else {
        throw FixtureFailure.nativeShape
      }
      let second = try Self.ownedDeferredCheckpointRead(
        f.inspector, recipe: recipe, mode: "normal", baseline: 1, diagnostic: diagnostic)
      guard second.image == stage.expected, second.observations.count == 2,
        second.probes.advanced(from: before.probes, body: 2, commit: 2, timeout: 0)
      else { throw FixtureFailure.nativeShape }
      try Self.ownedDeferredAppendObservation(
        f.inspector, stage: stage, old: first.observations, actual: second.observations, rawMillis: nil)
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      _ = try Self.ownedFenceRedeem(
        allowed, fixture: f, anchor: chain.original, reference: f.link.tokenRef,
        admission: chain.admission, memory: chain.memory)
      try Self.ownedFenceRefuses(
        stale, anchor: chain.original, reference: f.link.tokenRef, admission: chain.admission,
        memory: chain.memory, disposition: .committedStale)
      guard chain.memory.calls() - start == 9,
        try Self.ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: "normal", baseline: 1, diagnostic: diagnostic) == second
      else { throw FixtureFailure.nativeShape }
      // The native recipe itself reaches checked COMMIT; no target holder or wait is used.
    }
  }
}

extension OwnedProtocolProofWriteTests {
  private static func ownedFenceDeferredTarget(
    _ unit: String, diagnostic: OwnedDeferredDiagnostic
  ) throws -> OwnedDeferredFacts {
    // Every call owns ALL prerequisites; no cache, earlier test, or previously qualified run.
    let prerequisites = try ownedFenceDeferredPrerequisites(diagnostic: diagnostic)
    var facts: OwnedDeferredFacts?
    diagnostic.fixture = .target
    diagnostic.attempt = .none
    try ownedDeferredWithFixture(diagnostic) { f in
      diagnostic.enter(.fixtureValidate)
      let chain = try ownedFenceChain(f)
      let reference = f.link.tokenRef
      let memory = chain.memory
      let admission = chain.admission
      let setupCalls = memory.calls()
      let stage = try ownedFenceStage(f)
      guard stage.before == chain.image else { throw FixtureFailure.nativeShape }
      var mode = unit == "fault" ? "fault" : "gate"
      var baseline = 0
      let recipe = try ownedDeferredInstall(f, stage: stage, mode: mode, diagnostic: diagnostic)
      let endpoint = f.database.endpoint
      guard let binDir = endpoint.binDir else { throw FixtureFailure.nativeShape }
      let inspectorPID = try ownedDeferredInspectorPID(f.inspector)
      let work = OwnedDeferredWork()
      defer { work.releaseAndJoin() }
      var knownPIDs = [inspectorPID]
      var original: ProtocolOwnedProofWriteReceipt?
      var writerCalls = 0
      var redemptions = 0
      var waits = 0
      var timeoutAllocations = 0
      for attempt in 0..<(unit == "current" ? 1 : 2) {
        diagnostic.selectAttempt(attempt)
        diagnostic.enter(.beforeCheckpoint)
        let before = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        diagnostic.enter(.imageAndProbes)
        guard before.image == stage.before, before.observations.count == baseline else {
          throw FixtureFailure.nativeShape
        }
        diagnostic.enter(.targetWrite)
        let invocationStart = memory.calls()
        let expectedStart = setupCalls + (attempt == 0 ? 0 : (unit == "stale" ? 4 : 3))
        guard invocationStart == expectedStart else { throw FixtureFailure.nativeShape }
        let gated = unit != "fault"
        let timeout = unit == "timeout" && attempt == 0
        let hold = OwnedProofHold()
        let holderState = OwnedBindHolderState()
        let holderApplication = "owned-fence-commit-\(UUID().uuidString)"
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        var holderPID = 0
        if gated {
          work.holds.append(hold)
          diagnostic.enter(.gateClear)
          try ownedDeferredGateClear(f.inspector)
          let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
          diagnostic.enter(.holderStart)
          let started = ownedDeferredHolder(
            binDir: binDir, socketDir: endpoint.socketDir, port: endpoint.port,
            database: endpoint.database, user: NSUserName(), application: holderApplication,
            hold: hold, state: holderState)
          work.holders.append(started)
          holder = started
          diagnostic.enter(.holderReady)
          holderPID = try ownedDeferredHolderReady(
            f.inspector, state: holderState, hold: hold, database: endpoint.database,
            application: holderApplication, deadline: readiness)
          guard !knownPIDs.contains(holderPID) else { throw FixtureFailure.nativeShape }
          knownPIDs.append(holderPID)
        }
        diagnostic.enter(.targetWrite)
        guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
        let finished = OwnedBindFinished()
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        // Literal same original database/anchor/binding/reference/admission for both invocations.
        diagnostic.enter(.targetWrite)
        let writer = ownedFenceWriter(
          database: f.database, anchor: chain.original, binding: f.binding, reference: reference,
          admission: admission, finished: finished)
        work.writers.append(writer)
        if gated {
          diagnostic.enter(.observeCommit)
          try ownedFenceObserveCommit(
            f.inspector, database: endpoint.database, holderPID: holderPID,
            knownOwnedPIDs: knownPIDs, holderApplication: holderApplication,
            candidateApplication: "b4app", rawPID: nil, hold: hold, finished: finished,
            memory: memory, invocationStart: invocationStart, probes: before.probes,
            deadline: deadline)
          waits += 1
          if !timeout {
            try ownedFenceReleaseCommit(
              hold, finished: finished, memory: memory, invocationStart: invocationStart,
              retire: unit == "stale" && attempt == 0, deadline: deadline)
          }
        }
        // No throwing assertion, inspector image, or receipt validation may intervene here.
        // In the timeout branch actual receipt capture occurs while the original hold is valid;
        // immediately release ALL and join ALL before validating any result, including this fact.
        diagnostic.enter(.resultCapture)
        let receipt = writer.join()
        let receiptAt = DispatchTime.now().uptimeNanoseconds
        let heldAtReturn = !timeout || hold.heldUnexpired()
        work.releaseAndJoin()
        let held = holder?.join()
        diagnostic.enter(.drainReturned)
        guard !finished.pending(), !gated || held?.normal == true,
          heldAtReturn, !timeout || receiptAt < hold.snapshot().expiry
        else { throw FixtureFailure.nativeShape }
        diagnostic.enter(.afterCheckpoint)
        let after = try ownedDeferredCheckpointRead(
          f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic)
        let committed = unit == "current" || unit == "stale" || attempt == 1
        let expectedCalls = committed ? 4 : 3
        let delta = memory.calls() - invocationStart
        diagnostic.enter(.targetReceipt)
        guard receipt.operation == .fence, delta == expectedCalls,
          after.image == (committed ? stage.expected : stage.before),
          after.probes.advanced(from: before.probes, body: 1, commit: 1, timeout: timeout ? 1 : 0)
        else { throw FixtureFailure.nativeShape }
        writerCalls += delta
        if timeout { timeoutAllocations += 1 }
        diagnostic.enter(.observations)
        if committed {
          try ownedDeferredAppendObservation(
            f.inspector, stage: stage, old: before.observations,
            actual: after.observations, rawMillis: nil)
        } else {
          guard after.observations == before.observations else { throw FixtureFailure.nativeShape }
        }
        if attempt == 0 && unit != "current" {
          original = receipt
          let disposition: ProtocolProofWriteDisposition = unit == "stale" ? .committedStale : .unknown
          diagnostic.enter(.targetRefusal)
          try ownedFenceRefuses(
            receipt, anchor: chain.original, reference: reference, admission: admission,
            memory: memory, disposition: disposition)
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
          if unit == "stale" {
            // Genuine acknowledged stale S2 and its original refusal were checked BEFORE Q01.
            // This fixture-only restoration is never a rollback or repair by the product API.
            diagnostic.enter(.q01)
            try ownedDeferredQ01(f, recipe: recipe, mode: mode, diagnostic: diagnostic)
            try ownedFenceRefuses(
              receipt, anchor: chain.original, reference: reference, admission: admission,
              memory: memory, disposition: .committedStale)
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: mode, oldBaseline: 0, newMode: mode, newBaseline: 1,
              diagnostic: diagnostic)
            baseline = 1
            try ownedFenceRefuses(
              receipt, anchor: chain.original, reference: reference, admission: admission,
              memory: memory, disposition: .committedStale)
            memory.setCurrent(true)
            try ownedFenceRefuses(
              receipt, anchor: chain.original, reference: reference, admission: admission,
              memory: memory, disposition: .committedStale)
          } else if unit == "fault" {
            // Exact native 23514/canary/COMMIT was directly qualified by this unit's R2.
            // Target fault/stage/source attribution is explicitly INFERENCE from the immutable
            // full recipe, body/deferred relative probes, genuine unknown and reviewed writer
            // COMMIT-sent catch; the sealed target receipt exports no native diagnostic.
            diagnostic.enter(.configTransition)
            try ownedDeferredTransition(
              f, recipe: recipe, oldMode: "fault", oldBaseline: 0, newMode: "normal", newBaseline: 0,
              diagnostic: diagnostic)
            mode = "normal"
          }
          // T07's ONLY timeout allocation is inside its actual deferred gate handler, after
          // exact COMMIT/blocker/resource observation. Own R4 qualified original native rethrow.
          // An infeasible handler fails prerequisites; elapsed+unknown+S1 supplies no substitute.
        } else {
          guard receipt.disposition == .committedCurrent else { throw FixtureFailure.nativeShape }
          diagnostic.enter(.targetRedemption)
          let beforeRedemption = memory.calls()
          let successor = try receipt.currentSuccessor(
            expectedSnapshot: chain.original, expectedTokenRef: reference, memoryAdmission: admission)
          let afterRedemption = memory.calls()
          guard afterRedemption - beforeRedemption == 1 else { throw FixtureFailure.nativeShape }
          redemptions += afterRedemption - beforeRedemption
          diagnostic.enter(.successorValidation)
          try ownedT09NativeValidate(
            f, successor: successor, binding: f.binding, reference: reference, observation: nil)
          if unit != "current" {
            diagnostic.enter(.originalRefusal)
            guard let original else { throw FixtureFailure.nativeShape }
            try ownedFenceRefuses(
              original, anchor: chain.original, reference: reference, admission: admission,
              memory: memory,
              disposition: unit == "stale" ? .committedStale : .unknown)
          }
          guard
            try ownedDeferredCheckpointRead(
              f.inspector, recipe: recipe, mode: mode, baseline: baseline, diagnostic: diagnostic) == after
          else { throw FixtureFailure.nativeShape }
        }
      }
      diagnostic.enter(.finalFacts)
      guard work.writers.count == (unit == "current" ? 1 : 2), work.raw.isEmpty,
        work.holders.count == (unit == "fault" ? 0 : (unit == "current" ? 1 : 2)),
        writerCalls == (unit == "current" ? 4 : (unit == "stale" ? 8 : 7)), redemptions == 1,
        memory.calls() - setupCalls == writerCalls + redemptions,
        waits == (unit == "fault" ? 0 : (unit == "current" ? 1 : 2)),
        timeoutAllocations == (unit == "timeout" ? 1 : 0)
      else { throw FixtureFailure.nativeShape }
      facts = OwnedDeferredFacts(
        oldControls: prerequisites.old, newControls: prerequisites.controls,
        rawAttempts: prerequisites.attempts, rawHolders: prerequisites.holders,
        writerCalls: writerCalls, redemptionCalls: redemptions, targetHolders: work.holders.count,
        targetWaits: waits, timeoutAllocations: timeoutAllocations, qualified: true)
    }
    diagnostic.enter(.finalFacts)
    guard let facts, facts.qualified else { throw FixtureFailure.redactedFailure }
    return facts
  }

  // F11 matrix: F11.current, F11.stale, F11.fault, F11.timeout
  @Test(NativeDBResources(), arguments: ["current", "stale", "fault", "timeout"])
  func ownedFenceObservedActualCommitCurrentStaleFaultAndTimeoutInverses(row: String) throws {
    guard ["current", "stale", "fault", "timeout"].contains(row) else { throw FixtureFailure.nativeShape }
    let diagnostic = OwnedDeferredDiagnostic(
      unit: row == "fault" ? .fault : (row == "timeout" ? .timeout : .stale))
    let facts = try Self.ownedFenceDeferredTarget(row, diagnostic: diagnostic)
    guard facts.qualified, facts.oldControls == 4, facts.newControls == 5,
      facts.rawAttempts == 9, facts.rawHolders == 4
    else { throw FixtureFailure.nativeShape }
  }
}

extension OwnedProtocolProofWriteTests {
  private static func ownedFenceCurrent(
    _ receipt: ProtocolOwnedProofWriteReceipt, database: WorkspaceDatabase,
    anchor: ProtocolVerificationSnapshot, binding: ProtocolMembershipBinding, reference: String,
    inspector: PostgresConnection, stage: OwnedBindStageFixture,
    admission: ProtocolProofMemoryAdmission, memory: OwnedPositiveCountedMemory,
    body: OwnedBindProbe, commit: OwnedBindProbe, recipe: OwnedPositiveBodyRecipe,
    invocationStart: Int, diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> (calls: Int, redemption: Int) {
    diagnostic?.phase = .receiptImageAndCounters
    let beforeRedemption = memory.calls()
    guard receipt.operation == .fence, receipt.disposition == .committedCurrent,
      beforeRedemption - invocationStart == 4, equalBytes(reference, stage.originalReference),
      try ownedBindImage(inspector) == stage.expected,
      try ownedBindProbe(inspector, "body_probe").advanced(from: body, by: 1),
      try ownedBindProbe(inspector, "commit_probe").advanced(from: commit, by: 1)
    else { throw FixtureFailure.nativeShape }
    try ownedPositiveBodyShape(inspector, stage: stage, replacement: reference, fault: false)
    guard try ownedDeferredCatalog(inspector) == recipe.catalog else { throw FixtureFailure.nativeShape }
    // Redemption is sealed-context plus memory only. The following actual-object API calls
    // independently validate native facts; redemption itself makes no native-currentness claim.
    diagnostic?.phase = .receiptRedemption
    let successor = try receipt.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: reference, memoryAdmission: admission)
    let afterRedemption = memory.calls()
    guard afterRedemption - beforeRedemption == 1, successor.observation == nil else {
      throw FixtureFailure.nativeShape
    }
    diagnostic?.phase = .receiptNativeValidation
    try database.validateProtocolVerification(expectedSnapshot: successor)
    try database.compareOriginalLinkedCaptureOwner(
      expectedSnapshot: successor, accountID: binding.accountID,
      databaseName: binding.databaseName, hubBase: base)
    try database.compareOriginalLinkedCredentialReference(
      expectedSnapshot: successor, expectedTokenRef: reference)
    guard try ownedBindImage(inspector) == stage.expected else { throw FixtureFailure.nativeShape }
    try ownedPositiveBodyShape(inspector, stage: stage, replacement: reference, fault: false)
    guard try ownedDeferredCatalog(inspector) == recipe.catalog else { throw FixtureFailure.nativeShape }
    return (beforeRedemption - invocationStart, afterRedemption - beforeRedemption)
  }

  private static func ownedFenceSettingsUnit(
    _ device: OwnedT11Device, diagnostic: OwnedT11Diagnostic? = nil
  ) throws -> OwnedT11Facts {
    // No prerequisite borrowing: all four fresh raw fixtures finish teardown BEFORE this target.
    let rawRows = try ownedFenceRawControls(diagnostic: diagnostic)
    let raw = rawRows.count
    guard raw == 4, rawRows.allSatisfy({ $0.qualified }) else { throw FixtureFailure.nativeShape }
    diagnostic?.rawRow = .none
    diagnostic?.phase = .targetFixture
    var facts: OwnedT11Facts?
    try withFixture { f in
      diagnostic?.phase = .targetValidate
      _ = try validateFixture(f)
      let identity = try ownedT11Identity(f)
      let endpoint = f.database.endpoint
      var completed: (calls: Int, redemption: Int)?
      try ownedT11WithInheritedDatabase(f, device: device, diagnostic: diagnostic) {
        database, anchor, inheritedSettings, initialHighWater in
        let f = Fixture(
          database: database, inspector: f.inspector, link: f.link, binding: f.binding, anchor: anchor)
        let chain = try ownedFenceChain(f)
        let memory = chain.memory
        let admission = chain.admission
        let invocationStart = memory.calls()
        let ordinary = try ownedT11OrdinarySettings(
          database, expected: inheritedSettings, diagnostic: diagnostic)
        let highWater = ordinary.highWater
        guard highWater > initialHighWater else { throw FixtureFailure.nativeShape }
        let stage = try ownedFenceStage(f)
        guard stage.before == chain.image else { throw FixtureFailure.nativeShape }
        let setupStamps = try ownedT11SetupStamps(stage.before)
        let recipe = try ownedPositiveInstallBody(
          f, stage: stage, replacement: stage.originalReference, fault: false)
        let body = try ownedBindProbe(f.inspector, "body_probe")
        let commit = try ownedBindProbe(f.inspector, "commit_probe")
        guard body == OwnedBindProbe(last: 1, called: false),
          commit == OwnedBindProbe(last: 1, called: false)
        else { throw FixtureFailure.nativeShape }
        try ownedPositiveBodyShape(
          f.inspector, stage: stage, replacement: stage.originalReference, fault: false)
        try ownedBindWriterReady(
          f, stage: stage, replacement: stage.originalReference, body: body, commit: commit)
        let hold = OwnedProofHold()
        let state = OwnedBindHolderState()
        let finished = OwnedBindFinished()
        var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
        var writer: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
        // Installed before the first start. All holds release before EVERY retained join.
        defer {
          hold.release()
          if let holder { _ = holder.join() }
          if let writer { _ = writer.join() }
        }
        diagnostic?.phase = .holderReady
        let application = "owned-fence-clock-\(UUID().uuidString)"
        let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        holder = ownedBindHolder(
          binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
          database: endpoint.database, user: identity.user, application: application,
          kind: .advisory, hold: hold, state: state)
        let holderPID = try ownedBindHolderReady(state, hold: hold, deadline: readiness)
        guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .nativeWait
        let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
        writer = ownedFenceWriter(
          database: database, anchor: anchor, binding: f.binding, reference: stage.originalReference,
          admission: admission, finished: finished)
        try ownedFenceObserveWait(
          f.inspector, database: endpoint.database, holderPID: holderPID,
          knownOwnedPIDs: [identity.pid, holderPID], kind: .advisory, hold: hold,
          finished: finished, memory: memory, invocationStart: invocationStart, deadline: deadline)
        diagnostic?.phase = .markerAndRelease
        let now = try ownedBindWall(f.inspector)
        let sampleEnd = DispatchTime.now().uptimeNanoseconds
        let (markerMillis, overflow) = now.addingReportingOverflow(10_000)
        guard sampleEnd <= deadline, !overflow, markerMillis <= 0xffff_ffff_ffff,
          markerMillis > highWater.millis, markerMillis > stage.lowerWall,
          setupStamps.allSatisfy({ $0.millis < markerMillis }),
          equalBytes(highWater.deviceId, stage.device), memory.calls() == invocationStart,
          finished.pending(), hold.heldUnexpired()
        else { throw FixtureFailure.nativeShape }
        let marker = HLC(millis: markerMillis, counter: 0, deviceId: stage.device)
        let expectedBody = HLC(millis: markerMillis, counter: 1, deviceId: stage.device)
        // The actual B1/B2 chain and every preceding setup stamp are below the
        // separately sampled post-chain ordinary high water and this future marker.
        database.clock.observe(marker)
        // No SQL, next, write, or scheduling between injection and prompt original-deadline release.
        try ownedFenceReleasePreHold(
          hold, finished: finished, memory: memory, invocationStart: invocationStart, retiring: false,
          deadline: deadline)
        diagnostic?.phase = .joinsAndHolderAck
        let held = holder!.join()
        let receipt = writer!.join()
        guard held.normal else { throw FixtureFailure.nativeShape }
        diagnostic?.phase = .markerReadback
        try ownedT11MarkerObserved(
          f.inspector, stage: stage, expected: expectedBody, marker: markerMillis)
        let current = try ownedFenceCurrent(
          receipt, database: database, anchor: anchor, binding: f.binding,
          reference: stage.originalReference, inspector: f.inspector, stage: stage,
          admission: admission, memory: memory, body: body, commit: commit, recipe: recipe,
          invocationStart: invocationStart, diagnostic: diagnostic)
        // This new ordinary next is strictly AFTER body-marker read and genuine redemption.
        diagnostic?.phase = .ordinaryRestoration
        _ = try ownedT11OrdinarySettings(database, expected: ordinary.settings, diagnostic: diagnostic)
        diagnostic?.phase = .finalImageRecipe
        guard try ownedBindImage(f.inspector) == stage.expected,
          try ownedBindProbe(f.inspector, "body_probe").advanced(from: body, by: 1),
          try ownedBindProbe(f.inspector, "commit_probe").advanced(from: commit, by: 1)
        else { throw FixtureFailure.nativeShape }
        try ownedPositiveBodyShape(
          f.inspector, stage: stage, replacement: stage.originalReference, fault: false)
        guard try ownedDeferredCatalog(f.inspector) == recipe.catalog else {
          throw FixtureFailure.nativeShape
        }
        completed = current
      }
      // The helper has checked extra-close AND exact complete catalog restoration before here.
      guard let completed else { throw FixtureFailure.nativeShape }
      facts = OwnedT11Facts(
        rawControls: raw, nativeWaits: 1, writerCalls: completed.calls,
        redemptionCalls: completed.redemption, normalHolders: 1, normalContenders: 0,
        body: 1, deferred: 1, settingsRestored: true, qualified: true)
      diagnostic?.phase = .outerFixtureTeardown
    }
    diagnostic?.phase = .facts
    guard let facts else { throw FixtureFailure.redactedFailure }
    return facts
  }

  private static func ownedFenceOrderUnit() throws -> OwnedT11Facts {
    let rawRows = try ownedFenceRawControls()
    let raw = rawRows.count
    guard raw == 4, rawRows.allSatisfy({ $0.qualified }) else { throw FixtureFailure.nativeShape }
    var facts: OwnedT11Facts?
    try withFixture { f in
      let chain = try ownedFenceChain(f)
      let memory = chain.memory
      let admission = chain.admission
      let invocationStart = memory.calls()
      let stage = try ownedFenceStage(f)
      let recipe = try ownedPositiveInstallBody(
        f, stage: stage, replacement: stage.originalReference, fault: false)
      let body = try ownedBindProbe(f.inspector, "body_probe")
      let commit = try ownedBindProbe(f.inspector, "commit_probe")
      guard body == OwnedBindProbe(last: 1, called: false),
        commit == OwnedBindProbe(last: 1, called: false)
      else { throw FixtureFailure.nativeShape }
      try ownedPositiveBodyShape(
        f.inspector, stage: stage, replacement: stage.originalReference, fault: false)
      guard try ownedDeferredCatalog(f.inspector) == recipe.catalog else { throw FixtureFailure.nativeShape }
      try ownedBindWriterReady(
        f, stage: stage, replacement: stage.originalReference, body: body, commit: commit)
      let identity = try ownedT11Identity(f)
      let endpoint = f.database.endpoint
      let hold = OwnedProofHold()
      let state = OwnedBindHolderState()
      let finished = OwnedBindFinished()
      let contenderState = OwnedT11ContenderState()
      var holder: OwnedProofNativeWork<OwnedBindHolderResult>?
      var writer: OwnedProofNativeWork<ProtocolOwnedProofWriteReceipt>?
      var contender: OwnedProofNativeWork<OwnedT11ContenderResult>?
      // Every partial start is covered before the first start. Release ALL holds, then join ALL.
      defer {
        hold.release()
        if let holder { _ = holder.join() }
        if let writer { _ = writer.join() }
        if let contender { _ = contender.join() }
      }
      let holderApplication = "owned-fence-control-\(UUID().uuidString)"
      let contenderApplication = "owned-fence-link-\(UUID().uuidString)"
      let readiness = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      holder = ownedT11ControlHolder(
        binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: identity.user, application: holderApplication,
        controlKey: key, hold: hold, state: state)
      let holderPID = try ownedBindHolderReady(state, hold: hold, deadline: readiness)
      guard memory.calls() == invocationStart else { throw FixtureFailure.nativeShape }
      // ONE original writer window covers both observations, contender startup and release.
      let deadline = (DispatchTime.now() + .seconds(2)).uptimeNanoseconds
      writer = ownedFenceWriter(
        database: f.database, anchor: f.anchor, binding: f.binding, reference: stage.originalReference,
        admission: admission, finished: finished)
      let writerPID = try ownedFenceObserveControl(
        f.inspector, database: endpoint.database, holderPID: holderPID,
        knownOwnedPIDs: [identity.pid, holderPID], hold: hold,
        finished: finished, memory: memory, invocationStart: invocationStart, deadline: deadline)
      contender = ownedT11LinkContender(
        binDir: identity.binDir, socketDir: endpoint.socketDir, port: endpoint.port,
        database: endpoint.database, user: identity.user, application: contenderApplication,
        state: contenderState)
      let contenderPID = try ownedFenceContenderReady(
        contenderState, hold: hold, finished: finished, memory: memory, invocationStart: invocationStart,
        deadline: deadline)
      guard contenderPID != identity.pid, contenderPID != holderPID, contenderPID != writerPID else {
        throw FixtureFailure.nativeShape
      }
      try ownedFenceObserveContender(
        f.inspector, database: endpoint.database, application: contenderApplication,
        contenderPID: contenderPID, writerPID: writerPID, holderPID: holderPID,
        knownOwnedPIDs: [identity.pid, holderPID, contenderPID], hold: hold,
        finished: finished, contender: contenderState, memory: memory, invocationStart: invocationStart,
        deadline: deadline)
      try ownedFenceReleasePreHold(
        hold, finished: finished, memory: memory, invocationStart: invocationStart, retiring: false,
        deadline: deadline)
      // Join EVERY operation before inspecting even the first result or any native image.
      let held = holder!.join()
      let receipt = writer!.join()
      let contended = contender!.join()
      guard held.normal, contended.normal else { throw FixtureFailure.nativeShape }
      try ownedBindWriterObserved(f.inspector, stage: stage, actualDevice: f.database.deviceId)
      let current = try ownedFenceCurrent(
        receipt, database: f.database, anchor: f.anchor, binding: f.binding,
        reference: stage.originalReference, inspector: f.inspector, stage: stage,
        admission: admission, memory: memory, body: body, commit: commit, recipe: recipe,
        invocationStart: invocationStart)
      facts = OwnedT11Facts(
        rawControls: raw, nativeWaits: 2, writerCalls: current.calls,
        redemptionCalls: current.redemption, normalHolders: 1, normalContenders: 1,
        body: 1, deferred: 1, settingsRestored: true, qualified: true)
    }
    guard let facts else { throw FixtureFailure.redactedFailure }
    return facts
  }

  // F12 matrix: F12.isolation, F12.clock, F12.device, F12.local, F12.order
  @Test(NativeDBResources(), arguments: ["isolation", "clock", "device", "local", "order"])
  func ownedFenceSessionSettingsClockAndLinkBeforeControlRemainFixed(row: String) throws {
    if row == "order" {
      let facts = try Self.ownedFenceOrderUnit()
      guard facts.qualified, facts.rawControls == 4, facts.nativeWaits == 2,
        facts.writerCalls == 4, facts.redemptionCalls == 1,
        facts.normalHolders == 1, facts.normalContenders == 1
      else { throw FixtureFailure.nativeShape }
    } else {
      guard ["isolation", "clock", "device", "local"].contains(row) else { throw FixtureFailure.nativeShape }
      let facts = try Self.ownedFenceSettingsUnit(row == "local" ? .local : .nonlocal)
      guard facts.qualified, facts.rawControls == 4, facts.nativeWaits == 1,
        facts.writerCalls == 4, facts.redemptionCalls == 1, facts.settingsRestored,
        facts.normalHolders == 1, facts.normalContenders == 0
      else { throw FixtureFailure.nativeShape }
    }
  }
}

extension OwnedProtocolProofWriteTests {
  // Recorded cleanup gates validate fixture admissibility only. They neither simulate native
  // lost ACKs nor excuse release/join. Every native fixture below has already fully unwound.
  private struct OwnedFenceCleanupFacts {
    let holderNotExpired: Bool
    let holderRollbackAcknowledged: Bool
    let observedWithinOriginalDeadline: Bool
    let exactNativeIdentity: Bool
    let allHoldsReleased: Bool
    let allWorkersJoined: Bool
  }

  private static func ownedFenceCleanupCheck(_ facts: OwnedFenceCleanupFacts) throws {
    guard facts.holderNotExpired, facts.holderRollbackAcknowledged,
      facts.observedWithinOriginalDeadline, facts.exactNativeIdentity,
      facts.allHoldsReleased, facts.allWorkersJoined
    else { throw FixtureFailure.nativeShape }
  }

  // F13 matrix: F13.catalog, F13.cleanup
  @Test(NativeDBResources()) func ownedFenceRecipeCatalogAndCleanupFailuresInvalidateFixtures() throws {
    let diagnostic = OwnedDeferredDiagnostic(unit: .stale)
    let prerequisites = try Self.ownedFenceDeferredPrerequisites(diagnostic: diagnostic)
    guard prerequisites.old == 4, prerequisites.controls == 5,
      prerequisites.attempts == 9, prerequisites.holders == 4
    else { throw FixtureFailure.nativeShape }
    let variants = [
      "publicObject", "publicTrigger", "functionBody", "triggerDeferrability", "triggerEnabled",
      "sentinel", "databaseMeta", "deviceMeta", "referenceMeta", "publicTableList", "sequenceMeta",
    ]
    for variant in variants {
      var rejected = false
      try Self.withFixture { f in
        let chain = try Self.ownedFenceChain(f)
        let stage = try Self.ownedFenceStage(f)
        guard stage.before == chain.image else { throw FixtureFailure.nativeShape }
        let recipe = try Self.ownedPositiveInstallBody(
          f, stage: stage, replacement: f.link.tokenRef, fault: false)
        let body = try Self.ownedBindProbe(f.inspector, "body_probe")
        let commit = try Self.ownedBindProbe(f.inspector, "commit_probe")
        try Self.ownedPositiveBodyCheckpoint(
          f, recipe: recipe, replacement: f.link.tokenRef, fault: false,
          image: stage.before, body: body, commit: commit, bodies: 0, commits: 0)
        switch variant {
        case "publicObject":
          try f.inspector.execute("CREATE TABLE public.owned_fence_unexpected(value text)")
        case "publicTrigger":
          try f.inspector.execute(
            "CREATE TRIGGER owned_fence_unexpected AFTER UPDATE ON public.connections FOR EACH ROW EXECUTE FUNCTION \"owned_bind_stage\".\"body\"()"
          )
        case "functionBody":
          try f.inspector.execute(
            "CREATE OR REPLACE FUNCTION \"owned_bind_stage\".\"body\"() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $owned_fence$ BEGIN RETURN NEW; END $owned_fence$"
          )
        case "triggerDeferrability":
          try f.inspector.execute("DROP TRIGGER owned_bind_commit_normal ON public.settings")
          try f.inspector.execute(
            "CREATE CONSTRAINT TRIGGER owned_bind_commit_normal AFTER UPDATE ON public.settings DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION \"owned_bind_stage\".\"commit_normal\"()"
          )
        case "triggerEnabled":
          try f.inspector.execute("ALTER TABLE public.settings DISABLE TRIGGER owned_bind_body")
        case "sentinel":
          guard
            try f.inspector.execute(
              "UPDATE \"owned_bind_stage\".\"expected\" SET value=jsonb_set(value,'{value}',to_jsonb('FENCE_PRIVATE_DAMAGE'::text)) WHERE name='settings' AND value->>'key'=$1",
              [Self.sentinelKey]
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        case "databaseMeta":
          guard
            try f.inspector.execute(
              "UPDATE \"owned_bind_stage\".\"meta\" SET database=database||'_other' WHERE singleton=1"
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        case "deviceMeta":
          guard
            try f.inspector.execute(
              "UPDATE \"owned_bind_stage\".\"meta\" SET expected_device='FENCE_PRIVATE_OTHER' WHERE singleton=1"
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        case "referenceMeta":
          guard
            try f.inspector.execute(
              "UPDATE \"owned_bind_stage\".\"meta\" SET original_ref='secret:FENCE_PRIVATE_OTHER' WHERE singleton=1"
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        case "publicTableList":
          guard
            try f.inspector.execute("DELETE FROM \"owned_bind_stage\".\"names\" WHERE name='connections'")
              .affected == 1
          else { throw FixtureFailure.nativeShape }
        case "sequenceMeta":
          guard
            try f.inspector.execute(
              "UPDATE \"owned_bind_stage\".\"meta\" SET expected_sequence=jsonb_set(expected_sequence,'{last_value}','777'::jsonb) WHERE singleton=1"
            ).affected == 1
          else { throw FixtureFailure.nativeShape }
        default: throw FixtureFailure.nativeShape
        }
        rejected = !Self.validates {
          try Self.ownedPositiveBodyShape(
            f.inspector, stage: stage, replacement: f.link.tokenRef, fault: false)
          guard try Self.ownedDeferredCatalog(f.inspector) == recipe.catalog else {
            throw FixtureFailure.nativeShape
          }
        }
        // Actual fixture has body+commit probes. There is no owned product target to credit;
        // these are fixture-integrity failures, not fence denials or physical absence claims.
        guard try Self.ownedBindProbe(f.inspector, "body_probe") == body,
          try Self.ownedBindProbe(f.inspector, "commit_probe") == commit,
          try Self.ownedDeferredObservations(f.inspector).isEmpty
        else { throw FixtureFailure.nativeShape }
      }
      guard rejected else { throw FixtureFailure.nativeShape }
    }
    // Pure recorded-fact variants, evaluated after all isolated fixtures have unwound.
    // No live holder is deliberately expired, no release/join is omitted, and no native lost
    // rollback ACK is injected. This validates structural gates only, with no receipt credit.
    let valid = OwnedFenceCleanupFacts(
      holderNotExpired: true, holderRollbackAcknowledged: true,
      observedWithinOriginalDeadline: true, exactNativeIdentity: true,
      allHoldsReleased: true, allWorkersJoined: true)
    try Self.ownedFenceCleanupCheck(valid)
    for variant in [
      "autoexpiredHolder", "missingRollbackACK", "observationDeadline",
      "identityMismatch", "guardBeforeFullDrain",
    ] {
      let invalid = OwnedFenceCleanupFacts(
        holderNotExpired: variant != "autoexpiredHolder",
        holderRollbackAcknowledged: variant != "missingRollbackACK",
        observedWithinOriginalDeadline: variant != "observationDeadline",
        exactNativeIdentity: variant != "identityMismatch",
        allHoldsReleased: variant != "guardBeforeFullDrain",
        allWorkersJoined: variant != "guardBeforeFullDrain")
      guard !Self.validates({ try Self.ownedFenceCleanupCheck(invalid) }) else {
        throw FixtureFailure.nativeShape
      }
    }
  }
}
