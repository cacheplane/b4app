import CoreFoundation
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

struct ProtocolActivationStoreTests {
  private static let key = "__b4app_agent_protocol_activation_v1"

  private static let message = "The protocol verification comparison could not be completed."

  private static let base = "https://example.invalid/Deployment"

  private static let stamp = "2026-11-12T00:00:00.000Z"

  private enum FixtureFailure: Error { case nativeShape, barrierTimeout, unexpectedFailure }

  private struct Fixture: Sendable {
    let database: WorkspaceDatabase
    let raw: PostgresConnection
    let endpoint: PostgresEndpoint
    let root: String
    let link: WorkspaceDatabase.HubLink
    let binding: ProtocolMembershipBinding
    func reopen() throws -> WorkspaceDatabase {
      try WorkspaceDatabase(
        endpoint: endpoint, binDir: endpoint.binDir!, createIfMissing: false,
        backupDirectory: root + "/backups")
    }
  }

  private struct NativeState: Equatable {
    let rows: [String: [Data]]
    let sequence: Data
  }

  private static func binding(
    accountID: String = "ACTIVATION_ACCOUNT_SENTINEL", canonicalHubBase: String = base,
    hubUserID: String = "ACTIVATION_USER_SENTINEL", hubOrgID: String = "ACTIVATION_ORG_SENTINEL",
    deviceID: String = "ACTIVATION_DEVICE_SENTINEL", databaseName: String = "fixture-database",
    linkJoinedAt: String = stamp
  ) throws -> ProtocolMembershipBinding {
    try ProtocolMembershipBinding(
      accountID: accountID, canonicalHubBase: canonicalHubBase, hubUserID: hubUserID,
      hubOrgID: hubOrgID, deviceID: deviceID, databaseName: databaseName, linkJoinedAt: linkJoinedAt)
  }

  private static func observation(
    _ binding: ProtocolMembershipBinding, version: Int = 2
  ) throws -> ProtocolVerificationObservation {
    try ProtocolVerificationObservation(
      binding: binding, reportedMinimum: 2, reportedVersion: version, healthy: true)
  }

  private static func withFixture(_ body: @Sendable (Fixture) async throws -> Void) async throws {
    let endpoint = try EphemeralPostgres.endpoint()
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "activation-store-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let database = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
    defer { try? database.close() }
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    let link = WorkspaceDatabase.HubLink(
      url: base, deviceId: "ACTIVATION_DEVICE_SENTINEL", deviceName: "fixture", tokenRef: "secret:fixture",
      orgSlug: "not-principal-proof", username: "not-principal-proof", joinedAt: stamp)
    try database.saveHubLink(link)
    try database.setSetting(key: "activation-unrelated", value: .string("retained"))
    let f = Fixture(
      database: database, raw: raw, endpoint: endpoint, root: root, link: link,
      binding: try binding(databaseName: endpoint.database))
    var primary: (any Error)?
    do { try await body(f) } catch { primary = Self.unexpectedError(error) }
    do { try database.close() } catch { if primary == nil { primary = Self.unexpectedError(error) } }
    if let primary { throw primary }
  }

  private static func unexpectedError(_ error: any Error) -> any Error {
    if error is FixtureFailure { return error }
    if let safe = error as? WorkspaceError, safe.code == .internalError,
      safe.message == message, safe.details == nil,
      (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    {
      return error
    }
    Issue.record("The dormant storage test operation failed; private details were suppressed.")
    return FixtureFailure.unexpectedFailure
  }

  private static func equalBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

  private static func recordText(_ f: Fixture) throws -> String? {
    try f.raw.execute(#"SELECT value::text AS value FROM public.settings WHERE key=$1"#, [key])
      .rows.first?.text("value")
  }

  private static func object(_ text: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
      throw FixtureFailure.nativeShape
    }
    return value
  }

  private static func nativeRecord(_ f: Fixture) throws -> [String: Any] {
    guard let text = try recordText(f) else { throw FixtureFailure.nativeShape }
    return try object(text)
  }

  private static func state(_ f: Fixture) throws -> NativeState {
    var rows: [String: [Data]] = [:]
    for row in try f.raw.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      guard let table = row.text("tablename") else { throw FixtureFailure.nativeShape }
      rows[table] = try f.raw.execute("SELECT to_jsonb(t)::text AS value FROM \(Rows.quote(table)) t").rows
        .map {
          guard let value = $0.text("value") else { throw FixtureFailure.nativeShape }
          return Data(value.utf8)
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    guard
      let sequence = try f.raw.execute(
        "SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value FROM public.changes_seq_seq"
      ).rows.first?.text("value")
    else { throw FixtureFailure.nativeShape }
    return NativeState(rows: rows, sequence: Data(sequence.utf8))
  }

  private static func expectUnchanged(_ f: Fixture, _ before: NativeState) throws {
    let unchanged = try state(f) == before
    #expect(unchanged)  // Never print a raw private control record on mismatch.
  }

  private static func expectSafe(_ body: () throws -> Void) {
    let result = Result<Void, any Error> { try body() }
    guard case .failure(let error) = result else {
      Issue.record("Expected the fixed dormant-comparison refusal."); return
    }
    let fixed =
      (error as? WorkspaceError).map {
        $0.code == .internalError && $0.message == message && $0.details == nil
      } ?? false
    let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    let redacted =
      !String(reflecting: error).contains("ACTIVATION_")
      && !String(describing: error).contains("ACTIVATION_")
    #expect(fixed); #expect(noCause); #expect(redacted)
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let parsed = Int64(number.stringValue), equalBytes(String(parsed), number.stringValue)
    else { return nil }
    return parsed
  }

  private static func expectedBinding(_ b: ProtocolMembershipBinding) -> [String: String] {
    [
      "accountID": b.accountID, "canonicalHubBase": b.canonicalHubBase, "hubUserID": b.hubUserID,
      "hubOrgID": b.hubOrgID, "deviceID": b.deviceID, "databaseName": b.databaseName,
      "linkJoinedAt": b.linkJoinedAt,
    ]
  }

  private static func expectBinding(_ value: Any?, _ b: ProtocolMembershipBinding) throws {
    guard let actual = value as? [String: Any] else { throw FixtureFailure.nativeShape }
    let expected = expectedBinding(b)
    let exactKeys = Set(actual.keys) == Set(expected.keys)
    #expect(exactKeys)
    for (key, value) in expected {
      let bytesMatch = (actual[key] as? String).map { equalBytes($0, value) } ?? false
      #expect(bytesMatch)
    }
  }

  private static func expectRecord(
    _ f: Fixture, revision: String, binding: ProtocolMembershipBinding?, observedVersion: Int? = nil
  ) throws -> [String: Any] {
    let actual = try nativeRecord(f)
    var keys: Set<String> = ["version", "storeIncarnation", "membershipIncarnation", "revision"]
    if binding != nil { keys.insert("binding") }
    if observedVersion != nil { keys.insert("observation") }
    let exactKeys = Set(actual.keys) == keys
    let correctVersion = integer(actual["version"]) == 1
    let exactRevision =
      (actual["revision"] as? String).map { text in
        guard let parsed = Int64(text), parsed >= 0 else { return false }
        return equalBytes(text, revision) && equalBytes(String(parsed), text)
      } ?? false
    #expect(exactKeys); #expect(correctVersion); #expect(exactRevision)
    for field in ["storeIncarnation", "membershipIncarnation"] {
      let canonical =
        (actual[field] as? String).map { text in
          UUID(uuidString: text).map { equalBytes($0.uuidString, text) } ?? false
        } ?? false
      #expect(canonical)
    }
    if let binding { try expectBinding(actual["binding"], binding) }
    if let observedVersion {
      guard let observation = actual["observation"] as? [String: Any] else {
        throw FixtureFailure.nativeShape
      }
      let exactObservationKeys =
        Set(observation.keys) == Set(["binding", "reportedMinimum", "reportedVersion", "healthy"])
      let minimum = integer(observation["reportedMinimum"]) == 2
      let version = integer(observation["reportedVersion"]) == Int64(observedVersion)
      let healthy =
        (observation["healthy"] as? NSNumber).map {
          CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } ?? false
      #expect(exactObservationKeys); #expect(minimum); #expect(version); #expect(healthy)
      guard let binding else { throw FixtureFailure.nativeShape }
      try expectBinding(observation["binding"], binding)
    }
    return actual
  }

  @Test func prepareReadAndCommitPersistOnlyClosedDormantComparisonFacts() async throws {
    try await Self.withFixture { f in
      #expect(try Self.recordText(f) == nil)
      #expect(try f.database.readProtocolFact(expectedBinding: f.binding) == nil)
      #expect(try Self.recordText(f) == nil)
      try f.database.clearHubLink()
      #expect(try Self.recordText(f) == nil)
      try f.database.saveHubLink(f.link)
      #expect(try Self.recordText(f) == nil)
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let first = try Self.expectRecord(f, revision: "0", binding: f.binding)
      #expect(prepared.observation == nil)
      let observed = try Self.observation(f.binding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: prepared, observation: observed)
      #expect(committed.observation == observed)
      let second = try Self.expectRecord(f, revision: "1", binding: f.binding, observedVersion: 2)
      for field in ["storeIncarnation", "membershipIncarnation"] {
        let preserved =
          (first[field] as? String).flatMap { a in (second[field] as? String).map { Self.equalBytes(a, $0) } }
          ?? false
        #expect(preserved)
      }
      #expect(try f.database.readProtocolFact(expectedBinding: f.binding)?.observation == observed)
      let before = try Self.recordText(f)
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let unchanged = try Self.recordText(f) == before
      #expect(unchanged)
      for text in [
        String(describing: prepared), String(reflecting: prepared), String(describing: observed),
        String(reflecting: observed), String(describing: f.binding), String(reflecting: f.binding),
      ] {
        let redacted = !text.contains("ACTIVATION_") && !text.contains("Deployment")
        #expect(redacted)
      }
      let bindingMirrorEmpty = Mirror(reflecting: f.binding).children.isEmpty
      let observationMirrorEmpty = Mirror(reflecting: observed).children.isEmpty
      let snapshotMirrorEmpty = Mirror(reflecting: prepared).children.isEmpty
      #expect(bindingMirrorEmpty); #expect(observationMirrorEmpty); #expect(snapshotMirrorEmpty)
    }
  }

  private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      Thread { continuation.resume(returning: body()) }.start()
    }
  }

  private static func membershipConnection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static let witnessConnection = "capture-witness-c"

  private static let witnessThread = "capture-witness-t"

  private static let witnessTurn = "capture-witness-turn"

  private static let protocolColumns = [
    "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt", "protocolRetiredReason",
  ]

  private static let privateProtocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  private static func nativeMembership(_ link: WorkspaceDatabase.HubLink) throws -> ProtocolNativeMembership {
    try ProtocolNativeMembership(
      canonicalHubBase: link.url, deviceID: link.deviceId, linkJoinedAt: link.joinedAt)
  }

  private static func capture(_ f: Fixture) throws -> ProtocolVerificationSnapshot {
    try f.database.captureProtocolVerification(
      accountID: f.binding.accountID, expectedMembership: nativeMembership(f.link))
  }

  private static func capturedBinding(_ f: Fixture) throws -> ProtocolVerificationSnapshot {
    try f.database.prepareProtocolVerification(expectedSnapshot: capture(f), expectedBinding: f.binding)
  }

  private static func expectRequirement(_ f: Fixture, _ expected: ProtocolSyncRequirement) throws {
    let before = try state(f)
    let correct = try f.database.protocolSyncRequirement() == expected
    #expect(correct)
    try expectUnchanged(f, before)
  }

  private static func seedLegacyWitnesses(_ f: Fixture) throws {
    _ = try f.database.insertConnection(
      Connection(id: witnessConnection, kind: .codex, label: "Legacy witness", target: "/fixture/codex"))
    _ = try f.database.insertThread(
      ConversationThread(
        id: witnessThread, connectionId: witnessConnection, nativeThreadId: "native-witness",
        context: "/fixture/local"))
    _ = try f.database.insertTurn(
      Turn(id: witnessTurn, threadId: witnessThread, operationId: "capture-witness-operation"))
  }

  private static func insertLogWitness(
    _ f: Fixture, table: String, op: String, column: String? = nil, value: String? = nil,
    synced: Bool = false
  ) throws -> Int {
    guard
      let seq = try f.raw.execute(
        """
        INSERT INTO public.changes("deviceId",wall,"table","rowId",op,"column",value,hlc,synced)
        VALUES('local',0,$1,'retained-witness',$2,$3,$4::jsonb,'000000000000-0000-local',$5::boolean)
        RETURNING seq
        """, [table, op, column, value, synced ? "true" : "false"]
      ).rows.first?.int("seq")
    else { throw FixtureFailure.nativeShape }
    return seq
  }

  @Test func nativeMembershipComparisonIsOrgFreeByteExactAndRedacted() throws {
    let valid = try ProtocolNativeMembership(
      canonicalHubBase: Self.base, deviceID: "ACTIVATION_NATIVE_DEVICE", linkJoinedAt: Self.stamp)
    let original = [Self.base, "ACTIVATION_NATIVE_DEVICE", Self.stamp]
    for index in original.indices {
      for bad in ["", "ACTIVATION_BAD\0suffix"] {
        var fields = original; fields[index] = bad
        Self.expectSafe {
          _ = try ProtocolNativeMembership(
            canonicalHubBase: fields[0], deviceID: fields[1], linkJoinedAt: fields[2])
        }
      }
    }
    let a = try ProtocolNativeMembership(
      canonicalHubBase: Self.base, deviceID: "e\u{301}", linkJoinedAt: Self.stamp)
    let b = try ProtocolNativeMembership(canonicalHubBase: Self.base, deviceID: "é", linkJoinedAt: Self.stamp)
    #expect(a != b)
    let canonical = try ProtocolNativeMembership(
      canonicalHubBase: "HTTPS://EXAMPLE.INVALID/Deployment/", deviceID: "ACTIVATION_NATIVE_DEVICE",
      linkJoinedAt: Self.stamp)
    #expect(canonical == valid)
    for bad in [
      "https://user@example.invalid/Deployment", "https://example.invalid/Deployment?",
      "https://example.invalid/Deployment#",
    ] {
      Self.expectSafe {
        _ = try ProtocolNativeMembership(
          canonicalHubBase: bad, deviceID: original[1], linkJoinedAt: Self.stamp)
      }
    }
    let description = String(describing: valid), debugDescription = String(reflecting: valid)
    let fixedDescription = description == "ProtocolNativeMembership(redacted)"
    let fixedDebugDescription = debugDescription == "ProtocolNativeMembership(redacted)"
    let noMemberInEitherRendering = original.allSatisfy {
      !description.contains($0) && !debugDescription.contains($0)
    }
    let emptyMirror = Mirror(reflecting: valid).children.isEmpty
    #expect(fixedDescription); #expect(fixedDebugDescription)
    #expect(noMemberInEitherRendering); #expect(emptyMirror)
  }

  private static func expectReadOnlyValidation(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, sync: Bool, refuses: Bool = false,
    database: WorkspaceDatabase? = nil
  ) throws {
    let database = database ?? f.database
    let before = try state(f)
    let operation: () throws -> Void = {
      if sync {
        try database.validateProtocolSync(expectedSnapshot: snapshot)
      } else {
        try database.validateProtocolVerification(expectedSnapshot: snapshot)
      }
    }
    if refuses {
      expectSafe(operation)
      try expectUnchanged(f, before)
    } else {
      let outcome = Result { try operation() }
      // A wrongly thrown positive still gets a native after-check before propagating its failure.
      try expectUnchanged(f, before)
      try outcome.get()
    }
  }

  private static func seedReadOnlyModernProfile(_ f: Fixture) throws {
    _ = try f.database.insertConnection(
      Connection(
        id: "readonly-modern", kind: .agentProtocol, label: "Stored modern profile",
        target: "https://example.invalid/agent", nativeScope: "native-readonly",
        peerProfile: .agentProtocol, agentId: "agent", authMode: ConnectionAuthMode.none))
  }

  @Test func readOnlyValidatorsDoNotAdoptSameLookingReplaceClearOrSuccessfulRestore()
    async throws
  {
    try await Self.withFixture { f in
      let original = try Self.capture(f)
      try f.database.saveHubLink(f.link, membershipChange: .replace)
      try Self.expectReadOnlyValidation(f, snapshot: original, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: original, sync: true, refuses: true)
      let replacement = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: replacement, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: replacement, sync: true)
      try f.database.clearHubLink()
      try Self.expectReadOnlyValidation(f, snapshot: replacement, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: replacement, sync: true, refuses: true)
      let absent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      let path = f.root + "/readonly-before-restore.jsonl"
      try f.database.export(to: path)
      try f.database.restore(from: path, replace: true)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: true, refuses: true)
      let restored = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      try Self.expectReadOnlyValidation(f, snapshot: restored, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: restored, sync: true, refuses: true)
    }
  }

  private static func guardMarkPrefix(_ f: Fixture) throws -> (through: Int, later: Int) {
    try seedLegacyWitnesses(f)
    let rows = try f.raw.execute("SELECT seq FROM public.changes ORDER BY seq DESC LIMIT 2").rows
    guard rows.count == 2, let later = rows[0].int("seq"), let through = rows[1].int("seq"),
      later > through
    else { throw FixtureFailure.nativeShape }
    return (through, later)
  }

  /// Independent expected projection: only the synced bit of the accepted prefix changes.
  private static func expectedGuardMark(_ f: Fixture, through: Int) throws -> NativeState {
    let before = try state(f)
    var rows = before.rows
    rows["changes"] = try f.raw.execute(
      """
      SELECT (to_jsonb(c) || jsonb_build_object('synced',CASE WHEN seq <= $1::bigint THEN true ELSE synced END))::text AS value
      FROM public.changes c
      """, [String(through)]
    ).rows.map {
      guard let text = $0.text("value") else { throw FixtureFailure.nativeShape }
      return Data(text.utf8)
    }.sorted { $0.lexicographicallyPrecedes($1) }
    return NativeState(rows: rows, sequence: before.sequence)
  }

  private static func expectGuardMark(
    _ f: Fixture, through: Int, snapshot: ProtocolVerificationSnapshot, refuses: Bool = false
  ) throws {
    let before = try state(f)
    if refuses {
      expectSafe { try f.database.markSynced(through: through, expectedProtocolSnapshot: snapshot) }
      try expectUnchanged(f, before)
    } else {
      let expected = try expectedGuardMark(f, through: through)
      let outcome = Result { try f.database.markSynced(through: through, expectedProtocolSnapshot: snapshot) }
      let exact = try state(f) == expected
      #expect(exact)
      try outcome.get()
    }
  }

  private static func healthyGuardMarkSnapshot(_ f: Fixture) throws -> ProtocolVerificationSnapshot {
    let prepared = try capturedBinding(f)
    return try f.database.commitObservedProtocolFact(
      expectedSnapshot: prepared, observation: observation(f.binding))
  }

  @Test func guardedMarkChangesOnlyAcceptedPrefixForLegacyAndHealthyModernStores()
    async throws
  {
    try await Self.withFixture { f in
      let prefix = try Self.guardMarkPrefix(f)
      let inactive = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectGuardMark(f, through: prefix.through, snapshot: inactive)
      let retained = try f.raw.execute(
        "SELECT synced::text AS synced FROM public.changes WHERE seq=$1::bigint", [String(prefix.later)]
      ).rows
      #expect(retained.count == 1 && retained.first?.text("synced") == "false")
      // Already synced still validates.
      try Self.expectGuardMark(f, through: prefix.through, snapshot: inactive)
      try Self.seedReadOnlyModernProfile(f)
      let healthy = try Self.healthyGuardMarkSnapshot(f)
      try Self.expectRequirement(f, .protocolTwo)
      try Self.expectGuardMark(f, through: prefix.later, snapshot: healthy)
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy)
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy)
      try f.raw.execute("DELETE FROM public.changes")
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy)  // Empty UPDATE still validates.
    }
  }

  private static let applyStamp = "000000000100-0000-guard-phone"

  private static let applyTitle = "ACTIVATION_GUARDED_APPLY_TITLE"

  /// Explicit replay setup avoids wall-derived defaults, local log allocations and inferred clocks.
  /// Existing fixture/migration allocations, if any, remain visible in every complete native snapshot.
  private static func seedGuardApply(_ f: Fixture) throws {
    try f.raw.execute("BEGIN")
    do {
      try f.raw.execute("SET LOCAL b4app.replaying='on'")
      try f.raw.execute(
        """
        INSERT INTO public.connections(id,kind,label,enabled,"profileRevision",target,"routeKey","b4Mode",
          "localServerId","authReference","nativeScope",capabilities,status,"authStatus","createdAt","updatedAt",
          "environmentId",models,"peerProfile","agentId","authMode","authHeaderName","protocolRetiredAt","protocolRetiredReason")
          VALUES('guard-connection','codex','Private local profile',true,7,'/private/guard-executable',NULL,NULL,
            NULL,'secret:guard-private','/private/native-scope','{}'::jsonb,'ready','ready',
            '2026-11-12T00:00:00.000Z','2026-11-12T00:00:00.000Z',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
        INSERT INTO public.environments(id,name,manual,"createdAt","updatedAt")
          VALUES('guard-environment','Before environment',true,'2026-11-12T00:00:00.000Z','2026-11-12T00:00:00.000Z');
        INSERT INTO public.threads(id,"connectionId","nativeThreadId","nativeScope",title,context,pinned,archived,
          continuity,"createdAt","updatedAt","environmentId","readTurnId","userDeletedAt",model,permission)
          VALUES('guard-thread','guard-connection','private-native-thread','/private/thread-scope','Before title',
            '/private/context',false,false,'available','2026-11-12T00:00:00.000Z','2026-11-12T00:00:00.000Z',
            'guard-environment',NULL,NULL,'private-model','private-permission');
        INSERT INTO public.drafts("threadId",text,"updatedAt")
          VALUES('guard-thread','Before draft','2026-11-12T00:00:00.000Z');
        INSERT INTO public."viewSettings"(id,arrangement,"quietThreads","showArchived","updatedAt")
          VALUES('view','needsYouFirst','small',false,'2026-11-12T00:00:00.000Z');
        INSERT INTO public."columnClocks"("table","rowId","column",hlc) VALUES
          ('threads','guard-thread','title','000000000010-0000-guard-phone'),
          ('threads','guard-thread','pinned','000000000010-0000-guard-phone'),
          ('threads','guard-thread','archived','000000000010-0000-guard-phone'),
          ('environments','guard-environment','name','000000000010-0000-guard-phone'),
          ('drafts','guard-thread','text','000000000010-0000-guard-phone'),
          ('viewSettings','view','quietThreads','000000000010-0000-guard-phone');
        """)
      try f.raw.execute("COMMIT")
    } catch {
      _ = try? f.raw.execute("ROLLBACK")
      throw error
    }
  }

  private static func guardApplyChange(
    _ table: String, _ row: String, _ column: String, _ value: JSONValue,
    at: String = applyStamp, device: String = "guard-phone"
  ) -> RemoteChange {
    RemoteChange(
      deviceId: device, hlc: at, table: table, rowId: row, op: "update", column: column, value: value)
  }

  /// The oracle edits explicit fixture fields in a BEFORE image. It never calls merge, old apply,
  /// production clock advancement or a production expected-value helper. PostgreSQL only normalizes
  /// the JSON text representation used by state(); it does not execute the proposed business edits.
  private static func guardApplyJSON(_ f: Fixture, _ value: [String: Any]) throws -> Data {
    let encoded = String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    let text = try #require(
      f.raw.execute("SELECT $1::jsonb::text AS value", [encoded]).rows.first?.text("value"))
    return Data(text.utf8)
  }

  private static func expectedGuardApply(
    _ f: Fixture, before: NativeState, cursor: Int,
    edits: [(table: String, key: String, id: String, values: [String: Any])] = [],
    clocks: [(table: String, row: String, column: String, stamp: String)] = [],
    extraClocks: [[String: Any]] = []
  ) throws -> NativeState {
    var rows = before.rows
    for edit in edits + [(table: "hubLink", key: "id", id: "1", values: ["cursor": cursor])] {
      var matches = 0
      rows[edit.table] = try (rows[edit.table] ?? []).map { bytes in
        var row = try object(String(decoding: bytes, as: UTF8.self))
        let identity = (row[edit.key] as? String) ?? (row[edit.key] as? NSNumber)?.stringValue
        guard identity == edit.id else { return bytes }
        matches += 1
        for (column, value) in edit.values { row[column] = value }
        return try guardApplyJSON(f, row)
      }.sorted { $0.lexicographicallyPrecedes($1) }
      try #require(matches == 1)
    }
    for clock in clocks {
      var matches = 0
      rows["columnClocks"] = try (rows["columnClocks"] ?? []).map { bytes in
        var row = try object(String(decoding: bytes, as: UTF8.self))
        guard row["table"] as? String == clock.table, row["rowId"] as? String == clock.row,
          row["column"] as? String == clock.column
        else { return bytes }
        matches += 1; row["hlc"] = clock.stamp
        return try guardApplyJSON(f, row)
      }
      try #require(matches == 1)
    }
    for clock in extraClocks { rows["columnClocks", default: []].append(try guardApplyJSON(f, clock)) }
    rows["columnClocks"]?.sort { $0.lexicographicallyPrecedes($1) }
    // All three fields of changes_seq_seq must remain exactly equal. Probe sequences are separate.
    return NativeState(rows: rows, sequence: before.sequence)
  }

  private static func expectGuardApply(
    _ f: Fixture, changes: [RemoteChange], cursor: Int, snapshot: ProtocolVerificationSnapshot,
    expected: NativeState, result: RemoteApplied
  ) throws {
    let outcome = Result {
      try f.database.applyRemote(
        changes, ownDeviceId: f.link.deviceId, macDeviceIds: ["guard-other-mac"],
        cursor: cursor, expectedProtocolSnapshot: snapshot)
    }
    let exact = try state(f) == expected
    #expect(exact)  // Includes every public table, native/private/control/link/log rows and sequence.
    let actual = try outcome.get()
    #expect(actual == result)
  }

  private static func expectGuardApplyRefusal(
    _ f: Fixture, changes: [RemoteChange], cursor: Int, snapshot: ProtocolVerificationSnapshot,
    database: WorkspaceDatabase? = nil
  ) throws {
    let before = try state(f)
    expectSafe {
      _ = try (database ?? f.database).applyRemote(
        changes, ownDeviceId: f.link.deviceId,
        macDeviceIds: ["guard-other-mac"], cursor: cursor, expectedProtocolSnapshot: snapshot)
    }
    try expectUnchanged(f, before)  // Before ANY subsequent restoration, probe query or mutation.
  }

  private static func expectGuardApplyProbe(_ f: Fixture, _ name: String, _ expected: Int) throws {
    let row = try f.raw.execute("SELECT last_value::text AS n,is_called::text AS called FROM \(name)").rows
      .first
    #expect(row?.text("n") == String(expected) && row?.text("called") == "true")
  }

  @Test
  func guardedApplyActualDeferredCommitFailureRollsBackBatchCursorAndDurableClocksThenRecovers()
    async throws
  {
    try await Self.withFixture { f in
      try Self.seedGuardApply(f)
      let snapshot = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_apply_commit;
        CREATE SEQUENCE guard_apply_commit.probe;
        CREATE TABLE guard_apply_commit.expected AS SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1';
        CREATE FUNCTION guard_apply_commit.refuse_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF NEW.cursor <> 611 OR NOT EXISTS(SELECT 1 FROM public."hubLink" WHERE id=1 AND cursor=611)
            OR NOT EXISTS(SELECT 1 FROM public.threads WHERE id='guard-thread' AND title='ACTIVATION_GUARDED_APPLY_TITLE')
            OR NOT EXISTS(SELECT 1 FROM public.environments WHERE id='guard-environment' AND name='After environment')
            OR NOT EXISTS(SELECT 1 FROM public."columnClocks" WHERE "table"='threads' AND "rowId"='guard-thread'
              AND "column"='title' AND hlc='000000000100-0000-guard-phone')
            OR NOT EXISTS(SELECT 1 FROM public."columnClocks" WHERE "table"='environments' AND "rowId"='guard-environment'
              AND "column"='name' AND hlc='000000000100-0000-guard-phone')
            OR (SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1')
              IS DISTINCT FROM (SELECT value FROM guard_apply_commit.expected)
          THEN RAISE EXCEPTION 'ACTIVATION_GUARDED_APPLY_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('guard_apply_commit.probe');
          RAISE EXCEPTION 'ACTIVATION_GUARDED_APPLY_PRIVATE_CANARY'
            USING ERRCODE='23514',DETAIL='ACTIVATION_GUARDED_APPLY_SECRET';
        END $$;
        CREATE CONSTRAINT TRIGGER guard_apply_commit AFTER UPDATE ON public."hubLink" DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW WHEN(NEW.id=1 AND NEW.cursor=611) EXECUTE FUNCTION guard_apply_commit.refuse_commit();
        """)
      let beforeNative = try Self.state(f)
      var bodyReturned = false, commitAttempted = false, knownConstraint = false
      do {
        try f.raw.execute("BEGIN")
        try f.raw.execute("SET LOCAL b4app.replaying='on'")
        try f.raw.execute(
          """
          UPDATE public.threads SET title='ACTIVATION_GUARDED_APPLY_TITLE' WHERE id='guard-thread';
          UPDATE public.environments SET name='After environment' WHERE id='guard-environment';
          UPDATE public."columnClocks" SET hlc='000000000100-0000-guard-phone'
            WHERE ("table"='threads' AND "rowId"='guard-thread' AND "column"='title')
               OR ("table"='environments' AND "rowId"='guard-environment' AND "column"='name');
          UPDATE public."hubLink" SET cursor=611 WHERE id=1;
          """)
        bodyReturned = true
        commitAttempted = true
        try f.raw.execute("COMMIT")
      } catch {
        knownConstraint = (error as? PostgresError)?.sqlState == "23514"
        _ = try? f.raw.execute("ROLLBACK")
      }
      try Self.expectUnchanged(f, beforeNative)
      try #require(bodyReturned && commitAttempted && knownConstraint)
      try Self.expectGuardApplyProbe(f, "guard_apply_commit.probe", 1)
      let batch = [
        Self.guardApplyChange("threads", "guard-thread", "title", .string(Self.applyTitle)),
        Self.guardApplyChange("threads", "guard-thread", "archived", "not-a-boolean"),
        Self.guardApplyChange("environments", "guard-environment", "name", "After environment"),
      ]
      // Reaching this SAME deferred probe requires returning through both guards and attempting
      // actual COMMIT. No SET CONSTRAINTS, synthetic throw or savepoint-only fault is used.
      try Self.expectGuardApplyRefusal(f, changes: batch, cursor: 611, snapshot: snapshot)
      try Self.expectGuardApplyProbe(f, "guard_apply_commit.probe", 2)
      try Self.expectRequirement(f, .legacyOnly)
      try f.raw.execute("DROP TRIGGER guard_apply_commit ON public.\"hubLink\"")
      let beforeRecovery = try Self.state(f)
      let expected = try Self.expectedGuardApply(
        f, before: beforeRecovery, cursor: 611,
        edits: [
          ("threads", "id", "guard-thread", ["title": Self.applyTitle]),
          ("environments", "id", "guard-environment", ["name": "After environment"]),
        ],
        clocks: [
          ("threads", "guard-thread", "title", Self.applyStamp),
          ("environments", "guard-environment", "name", Self.applyStamp),
        ])
      try Self.expectGuardApply(
        f, changes: batch, cursor: 611, snapshot: snapshot, expected: expected,
        result: RemoteApplied(
          touchedThreadIds: ["guard-thread"], touchedEnvironmentIds: ["guard-environment"], applied: 2,
          skipped: 1))
      try Self.expectGuardApplyProbe(f, "guard_apply_commit.probe", 2)
      // Known 23514 rollback is established here; unknown COMMIT outcomes are not classified.
    }
  }

  private struct FinalEffectSequence {
    let last: Int64
    let log: Int64
    let called: Bool
  }

  private static func finalEffectSequence(_ bytes: Data) throws -> FinalEffectSequence {
    let value = try object(String(decoding: bytes, as: UTF8.self))
    guard Set(value.keys) == Set(["last_value", "log_cnt", "is_called"]),
      let last = integer(value["last_value"]), let log = integer(value["log_cnt"]),
      let called = value["is_called"] as? NSNumber,
      CFGetTypeID(called) == CFBooleanGetTypeID()
    else { throw FixtureFailure.nativeShape }
    return FinalEffectSequence(last: last, log: log, called: called.boolValue)
  }

  /// Private sequences are deliberately outside public NativeState. Read all three fields and
  /// never reset them; initial (1,false) is distinguishable from allocated (1,true).
  private static func finalEffectProbe(_ f: Fixture, _ name: String) throws -> Data {
    guard
      let text = try f.raw.execute(
        "SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value FROM \(name)"
      ).rows.first?.text("value")
    else { throw FixtureFailure.nativeShape }
    return Data(text.utf8)
  }

  private static func expectFinalEffectAllocation(
    _ f: Fixture, name: String, before: Data, after: Data, count: Int
  ) throws {
    if count == 0 {
      let exact = before == after
      #expect(exact)
      return
    }
    let properties = try f.raw.execute(
      "SELECT seqincrement::text AS step,seqcache::text AS cache FROM pg_catalog.pg_sequence WHERE seqrelid=$1::regclass",
      [name]
    ).rows.first
    let unitUncached = properties?.text("step") == "1" && properties?.text("cache") == "1"
    try #require(unitUncached)
    let old = try finalEffectSequence(before), new = try finalEffectSequence(after)
    let expectedLast = old.last + Int64(count) - (old.called ? 0 : 1)
    let exactAllocation = count > 0 && new.last == expectedLast && new.called
    // PostgreSQL's WAL preallocation log_cnt is not transactional and may refill after a
    // checkpoint. Retain its actual value, constrain its native CACHE 1 range, never mask it.
    let nativeLogRange = old.log >= 0 && old.log <= 32 && new.log >= 0 && new.log <= 32
    let honestAllocation = exactAllocation && nativeLogRange
    try #require(honestAllocation)
  }

  private static func installFinalEffectRowProbe(_ f: Fixture) throws {
    try f.raw.execute(
      """
      CREATE SCHEMA guard_effect_probe;
      CREATE SEQUENCE guard_effect_probe.updates;
      CREATE FUNCTION guard_effect_probe.row_updated() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN PERFORM nextval('guard_effect_probe.updates'); RETURN NEW; END $$;
      CREATE TRIGGER guard_effect_probe AFTER UPDATE ON public."hubLink" FOR EACH ROW
        WHEN(NEW.id=1) EXECUTE FUNCTION guard_effect_probe.row_updated();
      """)
  }

  private static func seedFinalEffectLinkSentinels(_ f: Fixture) throws {
    // Identity tuple (url, deviceId, joinedAt) stays the fixture's original tuple.
    try f.raw.execute(
      """
      UPDATE public."hubLink" SET cursor=701,"tokenRef"='secret:ACTIVATION_STATUS_PRIVATE',
        "deviceName"='ACTIVATION_STATUS_LABEL',"orgSlug"='ACTIVATION_STATUS_ORG',
        username='ACTIVATION_STATUS_USER',"ownedAs"='ACTIVATION_PREVIOUS_OWNER',
        "lastPushAt"='ACTIVATION_PREVIOUS_TIME',"lastError"='ACTIVATION_PREVIOUS_ERROR' WHERE id=1
      """)
  }

  private static func seedFinalEffectOwnedRows(_ f: Fixture) throws {
    try seedGuardApply(f)
    try f.raw.execute("BEGIN")
    do {
      try f.raw.execute("SET LOCAL b4app.replaying='on'")
      try f.raw.execute(
        """
        INSERT INTO public.environments(id,name,manual,"createdAt","updatedAt")
          VALUES('guard-second-environment','ACTIVATION_SECOND_LOCAL_ENVIRONMENT',false,
            '2026-11-12T00:00:00.000Z','2026-11-12T00:00:00.000Z')
        """)
      try f.raw.execute("COMMIT")
    } catch {
      _ = try? f.raw.execute("ROLLBACK")
      throw error
    }
  }

  /// Modify explicit fields in the BEFORE image only. JSON normalization uses a read-only
  /// cast, not a production effect or expected-value helper. No existing helper is modified.
  private static func finalEffectExpectedRows(
    _ f: Fixture, before: NativeState, link: [String: Any] = [:], markers: [String] = []
  ) throws -> [String: [Data]] {
    var rows = before.rows
    if !link.isEmpty {
      var matches = 0
      rows["hubLink"] = try (rows["hubLink"] ?? []).map { bytes in
        var row = try object(String(decoding: bytes, as: UTF8.self))
        guard integer(row["id"]) == 1 else { return bytes }
        matches += 1
        for (field, value) in link { row[field] = value }
        return try guardApplyJSON(f, row)
      }.sorted { $0.lexicographicallyPrecedes($1) }
      let exactlyOneLink = matches == 1
      try #require(exactlyOneLink)
    }
    for id in markers {
      let row: [String: Any] = [
        "table": "connections", "rowId": id, "column": "authMode",
        "hlc": "000000000000-0000-local",
      ]
      rows["columnClocks", default: []].append(try guardApplyJSON(f, row))
    }
    rows["columnClocks"]?.sort { $0.lexicographicallyPrecedes($1) }
    return rows
  }

  private static func expectFinalEffectPositive(
    _ f: Fixture, link: [String: Any], markers: [String] = [],
    probes: [(name: String, count: Int)] = [], body: () throws -> Void
  ) throws {
    let before = try state(f)
    let probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    let expected = NativeState(
      rows: try finalEffectExpectedRows(f, before: before, link: link, markers: markers),
      sequence: before.sequence)
    let outcome = Result { try body() }
    let after = try state(f)
    let exact = after == expected
    #expect(exact)
    for (index, probe) in probes.enumerated() {
      try expectFinalEffectAllocation(
        f, name: probe.name, before: probeBefore[index], after: finalEffectProbe(f, probe.name),
        count: probe.count)
    }
    try outcome.get()
  }

  private static func finalEffectOwnedRows(_ before: NativeState) throws -> [String: Data] {
    var result: [String: Data] = [:]
    // Independent fixed contract; do not consume WorkspaceDatabase.ownedTables here.
    for table in ["connections", "environments", "threads"] {
      for bytes in before.rows[table] ?? [] {
        let row = try object(String(decoding: bytes, as: UTF8.self))
        guard let id = row["id"] as? String else { throw FixtureFailure.nativeShape }
        let identity = table + "\0" + id
        guard result.updateValue(bytes, forKey: identity) == nil else { throw FixtureFailure.nativeShape }
      }
    }
    return result
  }

  /// An independent append oracle: full BEFORE-owned values, each identity exactly once, a
  /// known count of contiguous unique allocations, one wall bounded by real before/after time.
  /// SQL INSERT SELECT has no ORDER BY: identity-to-seq mapping is deliberately unconstrained.
  private static func expectFinalEffectClaim(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, count: Int, updatesOwnedAs: Bool,
    markers: [String] = [], probes: [(name: String, count: Int)] = []
  ) throws {
    let before = try state(f)
    let owned = try finalEffectOwnedRows(before)
    let probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    var expectedRows = try finalEffectExpectedRows(
      f, before: before, link: updatesOwnedAs ? ["ownedAs": f.link.deviceId] : [:], markers: markers)
    let lowerWall = Int64(Date().timeIntervalSince1970 * 1000)
    let outcome = Result { try f.database.claimOwnedRows(expectedProtocolSnapshot: snapshot) }
    let upperWall = Int64(Date().timeIntervalSince1970 * 1000)
    let after = try state(f)
    if count == 0 {
      let exact = after == NativeState(rows: expectedRows, sequence: before.sequence)
      #expect(exact)
    } else {
      let nativeBefore = try finalEffectSequence(before.sequence)
      // The positive append fixtures all first insert an independently synced witness.
      let knownAppendFixture = nativeBefore.called && count == owned.count
      try #require(knownAppendFixture)
      let first = nativeBefore.last + 1
      let expectedSequences = Set((0..<count).map { first + Int64($0) })
      var additions: [(row: [String: Any], identity: String, seq: Int64, wall: Int64)] = []
      var retained: [Data] = []
      for bytes in after.rows["changes"] ?? [] {
        let row = try object(String(decoding: bytes, as: UTF8.self))
        guard let seq = integer(row["seq"]) else { throw FixtureFailure.nativeShape }
        if seq <= nativeBefore.last { retained.append(bytes); continue }
        guard let table = row["table"] as? String, let id = row["rowId"] as? String,
          let wall = integer(row["wall"])
        else { throw FixtureFailure.nativeShape }
        additions.append((row, table + "\0" + id, seq, wall))
      }
      let originalLogExact =
        retained.sorted { $0.lexicographicallyPrecedes($1) } == (before.rows["changes"] ?? [])
      #expect(originalLogExact)
      let identityExact =
        additions.count == count
        && Set(additions.map(\.identity)) == Set(owned.keys)
        && Set(additions.map(\.seq)) == expectedSequences
      let boundedSingleWall =
        Set(additions.map(\.wall)).count == 1
        && additions.allSatisfy { $0.wall >= lowerWall && $0.wall <= upperWall }
      let independentlyValidAppend = identityExact && boundedSingleWall
      try #require(independentlyValidAppend)
      try expectFinalEffectAllocation(
        f, name: "public.changes_seq_seq", before: before.sequence, after: after.sequence, count: count)
      // Only after the independent count/identity/range/wall/native-sequence checks may the
      // observed dynamic seq/wall enter an exact JSON projection. They cannot hide a failure.
      for addition in additions {
        guard let nativeValue = owned[addition.identity],
          let table = addition.row["table"] as? String, let id = addition.row["rowId"] as? String
        else { throw FixtureFailure.nativeShape }
        let fullValue = try object(String(decoding: nativeValue, as: UTF8.self))
        let expected: [String: Any] = [
          "seq": addition.seq, "deviceId": f.link.deviceId, "wall": addition.wall,
          "table": table, "rowId": id, "op": "insert", "column": NSNull(), "value": fullValue,
          "synced": false, "hlc": "000000000000-0000-" + f.link.deviceId,
        ]
        expectedRows["changes", default: []].append(try guardApplyJSON(f, expected))
      }
      expectedRows["changes"]?.sort { $0.lexicographicallyPrecedes($1) }
      let exact = after == NativeState(rows: expectedRows, sequence: after.sequence)
      #expect(exact)
    }
    for (index, probe) in probes.enumerated() {
      try expectFinalEffectAllocation(
        f, name: probe.name, before: probeBefore[index], after: finalEffectProbe(f, probe.name),
        count: probe.count)
    }
    let actual = try outcome.get()
    let exactReturn = actual == count
    #expect(exactReturn)
  }

  @Test
  func guardedClaimPreservesLegacyAndHealthyEarlyReturnsAndReannouncesEveryNativeOwnedRow()
    async throws
  {
    for modern in [false, true] {
      try await Self.withFixture { f in
        try Self.seedFinalEffectOwnedRows(f)
        try Self.seedFinalEffectLinkSentinels(f)
        if modern { try Self.seedReadOnlyModernProfile(f) }
        let snapshot = try (modern ? Self.healthyGuardMarkSnapshot(f) : Self.capture(f))
        try Self.installFinalEffectRowProbe(f)
        // No synced history: the early return writes ONLY ownedAs, with no log allocations.
        let noneSynced =
          try f.raw.execute("SELECT count(*) AS n FROM public.changes WHERE synced")
          .rows.first?.int("n") == 0
        try #require(noneSynced)
        try Self.expectFinalEffectClaim(
          f, snapshot: snapshot, count: 0, updatesOwnedAs: true,
          probes: [("guard_effect_probe.updates", 1)])
        // Already-owned is a true no-write return, including no row-trigger execution.
        try Self.expectFinalEffectClaim(
          f, snapshot: snapshot, count: 0, updatesOwnedAs: false,
          probes: [("guard_effect_probe.updates", 0)])
        _ = try Self.insertLogWitness(
          f, table: "threads", op: "update", column: "title",
          value: #""ACTIVATION_PRIOR_SYNCED_LOG""#, synced: true)
        try f.raw.execute("UPDATE public.\"hubLink\" SET \"ownedAs\"='ACTIVATION_PREVIOUS_OWNER' WHERE id=1")
        // Four fixed native rows, plus the modern profile's own connection when present.
        // Counting three tables or ignoring that modern helper row is observably wrong.
        let count = modern ? 5 : 4
        let before = try Self.state(f)
        let independentlyCounted = try Self.finalEffectOwnedRows(before).count == count
        try #require(independentlyCounted)
        try Self.expectFinalEffectClaim(
          f, snapshot: snapshot, count: count, updatesOwnedAs: true,
          probes: [("guard_effect_probe.updates", 1)])
        try Self.expectFinalEffectClaim(
          f, snapshot: snapshot, count: 0, updatesOwnedAs: false,
          probes: [("guard_effect_probe.updates", 0)])
      }
    }
  }

  @Test
  func guardedStatusesChangeOnlyExactFieldsAndPullNilActuallyAvoidsNonmatchingRowUpdates()
    async throws
  {
    for modern in [false, true] {
      try await Self.withFixture { f in
        try Self.seedFinalEffectOwnedRows(f)
        try Self.seedFinalEffectLinkSentinels(f)
        if modern { try Self.seedReadOnlyModernProfile(f) }
        let snapshot = try (modern ? Self.healthyGuardMarkSnapshot(f) : Self.capture(f))
        try Self.installFinalEffectRowProbe(f)
        let errors: [String?] = [nil, "ACTIVATION_PUSH_ERROR", ""]
        let timestamps: [String?] = [nil, "2026-11-12T01:02:03.004Z", ""]
        for error in errors {
          for timestamp in timestamps {
            var expected: [String: Any] = ["lastError": error.map { $0 as Any } ?? NSNull()]
            if let timestamp { expected["lastPushAt"] = timestamp }
            try Self.expectFinalEffectPositive(
              f, link: expected, probes: [("guard_effect_probe.updates", 1)]
            ) {
              try f.database.recordHubPushResult(
                error: error, pushedAt: timestamp, expectedProtocolSnapshot: snapshot)
            }
          }
        }
        for error in ["ACTIVATION_PULL_ERROR", "", "Pull: nested"] {
          try Self.expectFinalEffectPositive(
            f, link: ["lastError": "Pull: " + error], probes: [("guard_effect_probe.updates", 1)]
          ) {
            try f.database.recordHubPullResult(error: error, expectedProtocolSnapshot: snapshot)
          }
        }
        for previous in ["Pull: ", "Pull: nested"] {
          try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"=$1 WHERE id=1", [previous])
          try Self.expectFinalEffectPositive(
            f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
          ) {
            try f.database.recordHubPullResult(error: nil, expectedProtocolSnapshot: snapshot)
          }
        }
        let nonmatches: [String?] = [nil, "", "pull: x", "Pull:x", "XPull: x", "Pull:"]
        for previous in nonmatches {
          try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"=$1 WHERE id=1", [previous])
          try Self.expectFinalEffectPositive(
            f, link: [:], probes: [("guard_effect_probe.updates", 0)]
          ) {
            try f.database.recordHubPullResult(error: nil, expectedProtocolSnapshot: snapshot)
          }
        }
        // Same-valued nonnil pull is the positive falsifier for the STILL ENABLED row probe.
        // Comparing rows alone cannot distinguish it from an incorrect no-row UPDATE oracle.
        try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"='Pull: repeat' WHERE id=1")
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": "Pull: repeat"], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPullResult(error: "repeat", expectedProtocolSnapshot: snapshot)
        }
      }
    }
  }

  private static func setNativeReference(_ f: Fixture, _ reference: String?) throws {
    try f.raw.execute("UPDATE public.\"hubLink\" SET \"tokenRef\"=$1 WHERE id=1", [reference])
  }

  private static let effectReferenceA = "secret:ACTIVATION_REFERENCE_EFFECT_A"

  private static let effectReferenceB = "secret:ACTIVATION_REFERENCE_EFFECT_B"

  private enum RefEffect: Int, CaseIterable, Sendable {
    case mark, apply, claimAppend, claimZero, push, pull, pullClear
    var claim: Bool { self == .claimAppend || self == .claimZero }
    var triggerTable: String { self == .mark ? "changes" : "hubLink" }
    var triggerColumns: String {
      switch self {
      case .mark: return "synced"
      case .apply: return "cursor"
      case .claimAppend, .claimZero: return "\"ownedAs\""
      case .push: return "\"lastError\",\"lastPushAt\""
      case .pull, .pullClear: return "\"lastError\""
      }
    }
  }

  private struct RefEffectInput: Sendable {
    let route: RefEffect
    let through: Int
    let ownedCount: Int
    func batch(ownDeviceId: String) throws -> [RemoteChange] {
      let title = ProtocolActivationStoreTests.guardApplyChange(
        "threads", "guard-thread", "title", .string(ProtocolActivationStoreTests.applyTitle))
      let echo = ProtocolActivationStoreTests.guardApplyChange(
        "threads", "guard-thread", "title", "Filtered own echo",
        at: "000000000101-0000-guard-phone", device: ownDeviceId)
      // The actual own-device field must be the only filter discriminator. A newer valid
      // remote-device stamp rules out equal/stale-clock skips and the stamp-device filter.
      guard ProtocolActivationStoreTests.equalBytes(echo.deviceId, ownDeviceId),
        let titleClock = HLC(rawValue: title.hlc), let echoClock = HLC(rawValue: echo.hlc),
        echoClock > titleClock,
        !ProtocolActivationStoreTests.equalBytes(echoClock.deviceId, ownDeviceId)
      else { throw ProtocolActivationStoreTests.FixtureFailure.nativeShape }
      return [
        title,
        // A genuine ordinary 22P02 must skip its row; the later valid row and cursor still finish.
        ProtocolActivationStoreTests.guardApplyChange("threads", "guard-thread", "archived", "not-a-boolean"),
        ProtocolActivationStoreTests.guardApplyChange(
          "environments", "guard-environment", "name", "After environment"),
        echo,
      ]
    }
    var applied: RemoteApplied {
      RemoteApplied(
        touchedThreadIds: ["guard-thread"], touchedEnvironmentIds: ["guard-environment"],
        applied: 2, skipped: 2)
    }
  }

  private static func prepareRefEffect(
    _ f: Fixture, route: RefEffect, modern: Bool = false
  ) throws -> (RefEffectInput, ProtocolVerificationSnapshot) {
    try seedFinalEffectOwnedRows(f)
    try seedFinalEffectLinkSentinels(f)
    try setNativeReference(f, effectReferenceA)
    var through = 0
    if route == .mark {
      through = try insertLogWitness(f, table: "threads", op: "update", column: "title", value: #""prefix""#)
      _ = try insertLogWitness(f, table: "threads", op: "update", column: "title", value: #""later""#)
    } else if route == .claimAppend {
      _ = try insertLogWitness(
        f, table: "threads", op: "update", column: "title", value: #""synced-before""#, synced: true)
    }
    if route == .claimZero {
      let noneSynced =
        try f.raw.execute("SELECT count(*) AS n FROM public.changes WHERE synced").rows.first?.int("n") == 0
      try #require(noneSynced)
    }
    if route == .pullClear {
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"='Pull: before clear' WHERE id=1")
    }
    if modern { try seedReadOnlyModernProfile(f) }
    let snapshot = try (modern ? healthyGuardMarkSnapshot(f) : capture(f))
    try expectRequirement(f, modern ? .protocolTwo : .legacyOnly)
    let count = try finalEffectOwnedRows(state(f)).count
    return (RefEffectInput(route: route, through: through, ownedCount: count), snapshot)
  }

  private static func expectedRefEffect(
    _ f: Fixture, input: RefEffectInput, before: NativeState
  ) throws -> NativeState {
    switch input.route {
    case .mark: return try expectedGuardMark(f, through: input.through)
    case .apply:
      return try expectedGuardApply(
        f, before: before, cursor: 811,
        edits: [
          ("threads", "id", "guard-thread", ["title": applyTitle]),
          ("environments", "id", "guard-environment", ["name": "After environment"]),
        ],
        clocks: [
          ("threads", "guard-thread", "title", applyStamp),
          ("environments", "guard-environment", "name", applyStamp),
        ])
    case .claimAppend, .claimZero:
      return NativeState(
        rows: try finalEffectExpectedRows(f, before: before, link: ["ownedAs": f.link.deviceId]),
        sequence: before.sequence)
    case .push:
      return NativeState(
        rows: try finalEffectExpectedRows(
          f, before: before,
          link: ["lastError": "ACTIVATION_REFERENCE_PUSH", "lastPushAt": "2026-11-12T07:08:09.010Z"]),
        sequence: before.sequence)
    case .pull, .pullClear:
      return NativeState(
        rows: try finalEffectExpectedRows(
          f, before: before,
          link: ["lastError": input.route == .pull ? "Pull: ACTIVATION_REFERENCE_PULL" as Any : NSNull()]),
        sequence: before.sequence)
    }
  }

  /// Freeze an independent intended public image in a PRIVATE schema. The trigger checks every
  /// table, including empty tables and all classifier inputs, full control and native tuple.
  /// Only claim append's independently checked dynamic seq/wall fields need a separate oracle.
  private static func installRefEffectStageImage(_ f: Fixture, input: RefEffectInput) throws {
    let before = try state(f), expected = try expectedRefEffect(f, input: input, before: before)
    try f.raw.execute(
      """
      CREATE SCHEMA ref_effect_stage;
      CREATE TABLE ref_effect_stage.tables(name text PRIMARY KEY);
      CREATE TABLE ref_effect_stage.expected(name text NOT NULL,value jsonb NOT NULL);
      CREATE TABLE ref_effect_stage.mode(reference text NOT NULL);
      INSERT INTO ref_effect_stage.mode VALUES('secret:ACTIVATION_REFERENCE_EFFECT_B');
      CREATE SEQUENCE ref_effect_stage.probe;
      CREATE TABLE ref_effect_stage.prior_log AS SELECT seq,to_jsonb(c) AS value FROM public.changes c;
      CREATE TABLE ref_effect_stage.owned AS
        SELECT 'connections'::text AS name,t.id AS id,to_jsonb(t) AS value FROM public.connections t
        UNION ALL SELECT 'environments',t.id,to_jsonb(t) FROM public.environments t
        UNION ALL SELECT 'threads',t.id,to_jsonb(t) FROM public.threads t;
      CREATE TABLE ref_effect_stage.time AS SELECT floor(extract(epoch FROM clock_timestamp())*1000)::bigint AS lower_wall;
      """)
    for (table, rows) in expected.rows {
      try f.raw.execute("INSERT INTO ref_effect_stage.tables VALUES($1)", [table])
      for row in rows {
        try f.raw.execute(
          "INSERT INTO ref_effect_stage.expected VALUES($1,$2::jsonb)",
          [table, String(decoding: row, as: UTF8.self)])
      }
    }
    let columns = "ARRAY[" + protocolColumns.map { "'" + $0 + "'" }.joined(separator: ",") + "]::text[]"
    let tables = "ARRAY[" + privateProtocolTables.map { "'" + $0 + "'" }.joined(separator: ",") + "]::text[]"
    let live = protocolColumns.map { "c." + Rows.quote($0) + " IS NOT NULL" }.joined(separator: " OR ")
    let retained = privateProtocolTables.map { "EXISTS(SELECT 1 FROM public." + Rows.quote($0) + ")" }.joined(
      separator: " OR ")
    let classifier = """
      EXISTS(SELECT 1 FROM public.connections c WHERE c.kind='agentProtocol' OR \(live))
      OR \(retained)
      OR EXISTS(SELECT 1 FROM public.changes ch WHERE ch."table"=ANY(\(tables))
        OR (ch."table"='connections' AND (
          (ch.op='insert' AND jsonb_typeof(ch.value)='object' AND (
            ch.value->'kind'='"agentProtocol"'::jsonb OR EXISTS(
              SELECT 1 FROM unnest(\(columns)) AS k(name) WHERE ch.value ? k.name
                AND (ch.value->k.name) IS NOT NULL AND ch.value->k.name<>'null'::jsonb)))
          OR (ch.op='update' AND (ch."column"=ANY(\(columns))
            OR (ch."column"='kind' AND ch.value='"agentProtocol"'::jsonb))))))
      OR EXISTS(SELECT 1 FROM public."columnClocks" cl WHERE cl."table"='connections'
        AND cl."column"=ANY(\(columns)))
      """
    let append = input.route == .claimAppend
    try f.raw.execute(
      """
      CREATE FUNCTION ref_effect_stage.assert_complete(required_reference text) RETURNS void
        LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE t text; mismatch boolean; projection text; n bigint; first_seq bigint; last_seq bigint;
      BEGIN
        IF (\(classifier)) THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_CLASSIFIER_STAGE_NOT_REACHED'; END IF;
        IF (SELECT convert_to("tokenRef",'UTF8') FROM public."hubLink" WHERE id=1)
          IS DISTINCT FROM convert_to(required_reference,'UTF8')
        THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_ACTUAL_STORED_STAGE_NOT_REACHED'; END IF;
        IF EXISTS((SELECT tablename::text FROM pg_tables WHERE schemaname='public')
            EXCEPT SELECT name FROM ref_effect_stage.tables)
          OR EXISTS((SELECT name FROM ref_effect_stage.tables)
            EXCEPT SELECT tablename::text FROM pg_tables WHERE schemaname='public')
        THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_CATALOG_STAGE_NOT_REACHED'; END IF;
        FOR t IN SELECT name FROM ref_effect_stage.tables LOOP
          IF t='changes' AND \(append ? "true" : "false") THEN CONTINUE; END IF;
          projection := CASE WHEN t='hubLink'
            THEN 'to_jsonb(p)||jsonb_build_object(''tokenRef'',''secret:ACTIVATION_REFERENCE_EFFECT_A'')'
            ELSE 'to_jsonb(p)' END;
          EXECUTE format('SELECT EXISTS((SELECT %s FROM public.%I p) EXCEPT ALL '
              '(SELECT value FROM ref_effect_stage.expected WHERE name=$1)) '
            'OR EXISTS((SELECT value FROM ref_effect_stage.expected WHERE name=$1) '
              'EXCEPT ALL (SELECT %s FROM public.%I p))',projection,t,projection,t)
            INTO mismatch USING t;
          IF mismatch THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_COMPLETE_STAGE_NOT_REACHED'; END IF;
        END LOOP;
        IF \(append ? "true" : "false") THEN
          SELECT count(*),min(c.seq),max(c.seq) INTO n,first_seq,last_seq FROM public.changes c
            WHERE NOT EXISTS(SELECT 1 FROM ref_effect_stage.prior_log e WHERE e.seq=c.seq);
          IF n<>\(input.ownedCount) OR last_seq-first_seq+1<>n
            OR first_seq<=(SELECT max(seq) FROM ref_effect_stage.prior_log)
            OR (SELECT count(*) FROM public.changes)<>(SELECT count(*) FROM ref_effect_stage.prior_log)+n
            OR EXISTS(SELECT 1 FROM ref_effect_stage.prior_log e LEFT JOIN public.changes c ON e.seq=c.seq
              WHERE c.seq IS NULL OR to_jsonb(c) IS DISTINCT FROM e.value)
            OR EXISTS(SELECT 1 FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM ref_effect_stage.prior_log e WHERE e.seq=c.seq)
              AND (c."deviceId" IS DISTINCT FROM 'ACTIVATION_DEVICE_SENTINEL' OR c.op IS DISTINCT FROM 'insert'
                OR c."column" IS NOT NULL OR c.synced IS DISTINCT FROM false
                OR c.hlc IS DISTINCT FROM '000000000000-0000-ACTIVATION_DEVICE_SENTINEL'
                OR c.wall<(SELECT lower_wall FROM ref_effect_stage.time)
                OR c.wall>floor(extract(epoch FROM clock_timestamp())*1000)::bigint))
            OR (SELECT count(DISTINCT c.wall) FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM ref_effect_stage.prior_log e WHERE e.seq=c.seq))<>1
            OR EXISTS((SELECT c."table",c."rowId",c.value FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM ref_effect_stage.prior_log e WHERE e.seq=c.seq))
              EXCEPT ALL SELECT name,id,value FROM ref_effect_stage.owned)
            OR EXISTS((SELECT name,id,value FROM ref_effect_stage.owned) EXCEPT ALL
              SELECT c."table",c."rowId",c.value FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM ref_effect_stage.prior_log e WHERE e.seq=c.seq))
          THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_APPEND_STAGE_NOT_REACHED'; END IF;
        END IF;
      END $$;
      """)
  }

  private static let refEffectCommitGate: Int64 = 0x6234_7265_6663_6d74

  private struct RefEffectRetentionFacts: Sendable {
    let pausedAtCommit: Bool, writerBlocked: Bool, exclusiveRetained: Bool
    let released: Bool, effectJoined: Bool, writerJoined: Bool
    let beforeWriterRows: [String: [Data]]?, beforeWriterSequence: Data?
    let controller: Result<Void, any Error>, effect: Result<Void, any Error>, writer: Result<Void, any Error>
  }

  /// No product hook: an actual INITIALLY DEFERRED constraint runs at real COMMIT, after POST.
  /// Both actual operations are joined after every cleanup path, even when a stage check fails.
  private static func refEffectRetentionController(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot
  ) async -> RefEffectRetentionFacts {
    await onThread {
      let effectResult = Mutex<Result<Void, any Error>?>(nil),
        writerResult = Mutex<Result<Void, any Error>?>(nil)
      let writerPID = Mutex<Int?>(nil)
      let beforeWriter = Mutex<([String: [Data]], Data)?>(nil)
      let effectDone = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0)
      var effectThread: Thread?, writerThread: Thread?, controller: PostgresConnection?
      var ownsGate = false, paused = false, blocked = false, retained = false, released = false
      var failure: (any Error)?
      do {
        let c = try membershipConnection(f.endpoint); controller = c
        guard let controlPID = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"),
          controlPID > 0
        else { throw FixtureFailure.nativeShape }
        try c.execute("SELECT pg_advisory_lock($1::bigint)", [String(refEffectCommitGate)]); ownsGate = true
        effectThread = Thread {
          let outcome = Result<Void, any Error> {
            try f.database.recordHubPushResult(
              error: "ACTIVATION_REFERENCE_PUSH", pushedAt: "2026-11-12T07:08:09.010Z",
              expectedProtocolSnapshot: snapshot, expectedTokenRef: effectReferenceA)
          }
          effectResult.withLock { $0 = outcome }; effectDone.signal()
        }
        effectThread?.start()
        var effectPID: Int?
        let pauseDeadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < pauseDeadline {
          let rows = try c.execute(
            """
            SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
            WHERE a.datname=$1 AND a.application_name='b4app' AND l.locktype='advisory'
              AND NOT l.granted AND $2::int=ANY(pg_blocking_pids(a.pid))
            """, [f.endpoint.database, String(controlPID)]
          ).rows
          let completed = ContinuousClock.now
          if completed <= pauseDeadline, rows.count == 1, let pid = rows.first?.int("pid"), pid > 0 {
            effectPID = pid; paused = true; break
          }
          guard completed < pauseDeadline, !effectResult.withLock({ $0 != nil }) else { break }
          Thread.sleep(forTimeInterval: 0.005)
        }
        guard let effectPID, paused else { throw FixtureFailure.barrierTimeout }
        // A waiting deferred function has already checked full intended body/A/control/tuple and
        // incremented its private probe. The transaction still owns the exclusive advisory lock.
        retained =
          try c.execute(
            """
            SELECT 1 FROM pg_locks WHERE pid=$1::int AND locktype='advisory' AND granted
              AND mode='ExclusiveLock' AND classid=0::oid AND objid=$2::oid AND objsubid=1
            """, [String(effectPID), String(0x6234_6170)]
          ).rows.count == 1
        guard retained else { throw FixtureFailure.nativeShape }
        writerThread = Thread {
          let outcome = Result<Void, any Error> {
            let raw = try membershipConnection(f.endpoint)
            guard let pid = try raw.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"), pid > 0
            else { throw FixtureFailure.nativeShape }
            writerPID.withLock { $0 = pid }
            try raw.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            do {
              try raw.execute("SET LOCAL lock_timeout='6s'")
              // Same permitted advisory-first convention, followed by link and control row locks.
              try raw.execute("SELECT pg_advisory_xact_lock_shared($1::bigint)", [String(0x6234_6170)])
              try raw.execute("SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE")
              try raw.execute("SELECT key FROM public.settings WHERE key=$1 FOR UPDATE", [key])
              let own = Fixture(
                database: f.database, raw: raw, endpoint: f.endpoint, root: f.root, link: f.link,
                binding: f.binding)
              let visible = try state(own)
              beforeWriter.withLock { $0 = (visible.rows, visible.sequence) }
              try raw.execute("UPDATE public.\"hubLink\" SET \"tokenRef\"=$1 WHERE id=1", [effectReferenceB])
              try raw.execute("COMMIT")
            } catch { _ = try? raw.execute("ROLLBACK"); throw error }
          }
          writerResult.withLock { $0 = outcome }; writerDone.signal()
        }
        writerThread?.start()
        let blockDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < blockDeadline {
          if let pid = writerPID.withLock({ $0 }) {
            let rows = try c.execute(
              """
              SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
              WHERE a.datname=$1 AND a.pid=$2::int AND l.locktype='advisory' AND NOT l.granted
                AND l.mode='ShareLock' AND l.classid=0::oid AND l.objid=$4::oid AND l.objsubid=1
                AND $3::int=ANY(pg_blocking_pids(a.pid))
              """, [f.endpoint.database, String(pid), String(effectPID), String(0x6234_6170)]
            ).rows
            let completed = ContinuousClock.now
            if completed <= blockDeadline, rows.count == 1 { blocked = true; break }
            guard completed < blockDeadline else { break }
          }
          if writerResult.withLock({ $0 != nil }) { break }
          Thread.sleep(forTimeInterval: 0.005)
        }
        guard blocked else { throw FixtureFailure.barrierTimeout }
      } catch { failure = error }
      if ownsGate {
        do {
          guard let c = controller,
            try c.execute(
              "SELECT pg_advisory_unlock($1::bigint)::text AS released", [String(refEffectCommitGate)]
            )
            .rows.first?.text("released") == "true"
          else { throw FixtureFailure.nativeShape }
          released = true
        } catch { if failure == nil { failure = error } }
      }
      controller = nil  // Sole retained native owner closes before joins if unlock failed.
      var effectJoined = false, writerJoined = false
      withExtendedLifetime((effectThread, writerThread)) {
        if effectThread != nil { effectDone.wait(); effectJoined = true }
        if writerThread != nil { writerDone.wait(); writerJoined = true }
      }
      return RefEffectRetentionFacts(
        pausedAtCommit: paused, writerBlocked: blocked, exclusiveRetained: retained,
        released: released, effectJoined: effectJoined, writerJoined: writerJoined,
        beforeWriterRows: beforeWriter.withLock { $0?.0 },
        beforeWriterSequence: beforeWriter.withLock { $0?.1 },
        controller: failure.map { .failure($0) } ?? .success(()),
        effect: effectResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape),
        writer: writerResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape))
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1"))
  func requiredReferenceLocksRetainCompetingReferenceWriterUntilActualCommitOrRollback() async throws {
    for rollback in [false, true] {
      try await Self.withFixture { f in
        let (input, snapshot) = try Self.prepareRefEffect(f, route: .push)
        let before = try Self.state(f)
        let intended = try Self.expectedRefEffect(f, input: input, before: before)
        try Self.installRefEffectStageImage(f, input: input)
        try f.raw.execute(
          """
          CREATE FUNCTION ref_effect_stage.pause_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
          BEGIN
            PERFORM ref_effect_stage.assert_complete('secret:ACTIVATION_REFERENCE_EFFECT_A');
            PERFORM nextval('ref_effect_stage.probe');
            PERFORM set_config('lock_timeout','12s',true);
            PERFORM pg_advisory_xact_lock(\(Self.refEffectCommitGate)::bigint);
            IF \(rollback ? "true" : "false") THEN
              RAISE EXCEPTION 'ACTIVATION_REFERENCE_RETENTION_COMMIT_CANARY'
                USING ERRCODE='23514',DETAIL='ACTIVATION_REFERENCE_RETENTION_COMMIT_DETAIL';
            END IF;
            RETURN NEW;
          END $$;
          CREATE CONSTRAINT TRIGGER ref_effect_retention AFTER UPDATE OF "lastError","lastPushAt"
            ON public."hubLink" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.id=1)
            EXECUTE FUNCTION ref_effect_stage.pause_commit();
          """)
        let probeBefore = try Self.finalEffectProbe(f, "ref_effect_stage.probe")
        let facts = await Self.refEffectRetentionController(f, snapshot: snapshot)
        // Observe whole native state and all sequence fields immediately after both actual joins.
        let after = try Self.state(f)
        let visibleAfterRelease = rollback ? before : intended
        let expectedAfter = NativeState(
          rows: try Self.finalEffectExpectedRows(
            f, before: visibleAfterRelease, link: ["tokenRef": Self.effectReferenceB]),
          sequence: before.sequence)
        let exactRows = after == expectedAfter
        #expect(exactRows)
        try Self.expectFinalEffectAllocation(
          f, name: "ref_effect_stage.probe", before: probeBefore,
          after: Self.finalEffectProbe(f, "ref_effect_stage.probe"), count: 1)
        let stages =
          facts.pausedAtCommit && facts.writerBlocked && facts.exclusiveRetained
          && facts.released && facts.effectJoined && facts.writerJoined
        #expect(stages)
        let writerSawOnlyReleasedState =
          facts.beforeWriterRows == visibleAfterRelease.rows
          && facts.beforeWriterSequence == visibleAfterRelease.sequence
        #expect(writerSawOnlyReleasedState)
        try facts.controller.get(); try facts.writer.get()
        if rollback { Self.expectRefEffectSafe { try facts.effect.get() } } else { try facts.effect.get() }
      }
    }
  }

  private static func expectRefEffectSafe(_ body: () throws -> Void) {
    let result = Result<Void, any Error> { try body() }
    guard case .failure(let error) = result else {
      Issue.record("Expected the fixed original-reference storage refusal."); return
    }
    let fixed =
      (error as? WorkspaceError).map {
        $0.code == .internalError && $0.message == message && $0.details == nil
      } ?? false
    let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    var dumped = ""; dump(error, to: &dumped)
    let text = String(describing: error) + String(reflecting: error) + dumped
    let forbidden = ["ACTIVATION_", "secret:", "23514", "22P02", "22000", "SQLSTATE", "DETAIL:"]
    let redacted = forbidden.allSatisfy { !text.contains($0) }
    #expect(fixed); #expect(noCause); #expect(redacted)
    // Only booleans enter assertions; no raw reference/status/SQL error is interpolated there.
  }
}
