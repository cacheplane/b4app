import CoreFoundation
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Dormant comparison facts only. Native fixtures are not authenticated Hub observations, an
/// account lease, an adapter admission, or permission to activate Agent Protocol.
@Suite struct ProtocolActivationStoreTests {
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
    let endpoint = try AgentProtocolResourceFixture.endpoint()
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
  private static func putRecord(_ f: Fixture, _ value: [String: Any]) throws {
    let text = String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    try f.raw.execute(
      "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value",
      [key, text])
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
  private static func makeBinding(_ values: [String: String]) throws -> ProtocolMembershipBinding {
    guard let account = values["accountID"], let base = values["canonicalHubBase"],
      let user = values["hubUserID"], let org = values["hubOrgID"], let device = values["deviceID"],
      let database = values["databaseName"], let joined = values["linkJoinedAt"]
    else { throw FixtureFailure.nativeShape }
    return try ProtocolMembershipBinding(
      accountID: account, canonicalHubBase: base, hubUserID: user, hubOrgID: org,
      deviceID: device, databaseName: database, linkJoinedAt: joined)
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

  @Test func typedFactsRequireCompleteNulFreeIdentityAndHealthyExactMinimumTwo() throws {
    let valid = try Self.binding()
    for field in [
      "accountID", "canonicalHubBase", "hubUserID", "hubOrgID", "deviceID", "databaseName", "linkJoinedAt",
    ] {
      for bad in ["", "ACTIVATION_BAD\0SUFFIX"] {
        var values = Self.expectedBinding(valid); values[field] = bad
        Self.expectSafe {
          _ = try Self.makeBinding(values)
        }
      }
    }
    for minimum in [0, 1, 3] {
      Self.expectSafe {
        _ = try ProtocolVerificationObservation(
          binding: valid, reportedMinimum: minimum, reportedVersion: 2, healthy: true)
      }
    }
    for version in [0, 1] {
      Self.expectSafe {
        _ = try ProtocolVerificationObservation(
          binding: valid, reportedMinimum: 2, reportedVersion: version, healthy: true)
      }
    }
    Self.expectSafe {
      _ = try ProtocolVerificationObservation(
        binding: valid, reportedMinimum: 2, reportedVersion: 2, healthy: false)
    }
    _ = try Self.observation(valid, version: 3)
    for field in ["accountID", "hubUserID", "hubOrgID", "deviceID", "databaseName", "linkJoinedAt"] {
      var left = Self.expectedBinding(valid), right = left
      left[field] = "e\u{301}"; right[field] = "é"
      let distinct = try Self.makeBinding(left) != Self.makeBinding(right)
      #expect(distinct)
    }
  }

  @Test func canonicalDeploymentBasesPreservePathAndRefuseUnsafeOrAmbiguousInput() throws {
    let ordinary = try Self.binding(canonicalHubBase: "HTTPS://EXAMPLE.INVALID/Deployment/")
    let same = Self.equalBytes(ordinary.canonicalHubBase, "https://example.invalid/Deployment")
    #expect(same)
    for bad in [
      "https://user@example.invalid/Deployment", "https://@example.invalid/Deployment",
      "https://:pw@example.invalid/Deployment",
      "https://example.invalid/Deployment?", "https://example.invalid/Deployment?q=1",
      "https://example.invalid/Deployment#", "https://example.invalid/Deployment#fragment",
      "https://example.invalid/\0x",
    ] {
      Self.expectSafe { _ = try Self.binding(canonicalHubBase: bad) }
    }
    let deployment = "https://example.invalid/Deployment/Case"
    let plain = try Self.binding(canonicalHubBase: deployment)
    let plainPreserved = Self.equalBytes(plain.canonicalHubBase, deployment)
    #expect(plainPreserved)
    for base in [
      "https://example.invalid/Deployment%2FCase", "https://example.invalid/Deployment%2fCase",
      "https://example.invalid/deployment%2FCase", "https://example.invalid/Deployment%252FCase",
      "https://example.invalid:443/Deployment%2FCase",
    ] {
      // This independent existing helper runs only in managed tests, never a local URL probe.
      let existing = Result { try HubURL.canonical(base) }
      let existingPreserves: Bool
      if case .success(let canonical) = existing {
        existingPreserves = Self.equalBytes(canonical, base)
      } else {
        existingPreserves = false
      }
      if existingPreserves {
        let binding = try Self.binding(canonicalHubBase: base)
        let preserved = Self.equalBytes(binding.canonicalHubBase, base)
        #expect(preserved)
      } else {
        // Only independently demonstrated unpreservable spelling may receive safe refusal.
        Self.expectSafe { _ = try Self.binding(canonicalHubBase: base) }
      }
    }
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

  @Test func everyStableBindingAndNativeMembershipMismatchRefusesWithoutMutation() async throws {
    try await Self.withFixture { f in
      let snapshot = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let before = try Self.state(f)
      for field in [
        "accountID", "canonicalHubBase", "hubUserID", "hubOrgID", "deviceID", "databaseName", "linkJoinedAt",
      ] {
        var values = Self.expectedBinding(f.binding)
        values[field] = field == "canonicalHubBase" ? "https://other.invalid/Deployment" : "ACTIVATION_OTHER"
        let mismatch = try Self.makeBinding(values)
        let mismatchObservation = try Self.observation(mismatch)
        Self.expectSafe { _ = try f.database.readProtocolFact(expectedBinding: mismatch) }
        Self.expectSafe { _ = try f.database.prepareProtocolVerification(expectedBinding: mismatch) }
        Self.expectSafe {
          _ = try f.database.commitObservedProtocolFact(
            expectedSnapshot: snapshot, observation: mismatchObservation)
        }
        try Self.expectUnchanged(f, before)
      }
      let observed = try Self.observation(f.binding)
      for column in ["url", "deviceId", "joinedAt"] {
        let replacement =
          column == "url" ? "https://example.invalid/AnotherDeployment" : "ACTIVATION_NATIVE_OTHER"
        try f.raw.execute("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1", [replacement])
        let nativeMismatch = try Self.state(f)
        Self.expectSafe { _ = try f.database.readProtocolFact(expectedBinding: f.binding) }
        Self.expectSafe { _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding) }
        Self.expectSafe {
          _ = try f.database.commitObservedProtocolFact(expectedSnapshot: snapshot, observation: observed)
        }
        try Self.expectUnchanged(f, nativeMismatch)
        try f.raw.execute(
          "UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1",
          [column == "url" ? f.link.url : (column == "deviceId" ? f.link.deviceId : f.link.joinedAt)])
      }
      var decomposedLink = f.link
      decomposedLink.deviceId = "e\u{301}"
      try f.database.saveHubLink(decomposedLink)
      let decomposed = try Self.binding(deviceID: "e\u{301}", databaseName: f.endpoint.database)
      let unicodeSnapshot = try f.database.prepareProtocolVerification(expectedBinding: decomposed)
      let unicodeObservation = try Self.observation(decomposed)
      // Swift String == considers these equal; actual-link admission must compare UTF-8 bytes.
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"deviceId\"=$1 WHERE id=1", ["é"])
      let unicodeMismatch = try Self.state(f)
      Self.expectSafe { _ = try f.database.readProtocolFact(expectedBinding: decomposed) }
      Self.expectSafe { _ = try f.database.prepareProtocolVerification(expectedBinding: decomposed) }
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(
          expectedSnapshot: unicodeSnapshot, observation: unicodeObservation)
      }
      try Self.expectUnchanged(f, unicodeMismatch)
    }
  }

  @Test func snapshotsRetainActualDatabaseAndCannotRedeemOnAnotherOrClosedObject() async throws {
    try await Self.withFixture { f in
      var original: WorkspaceDatabase? = try f.reopen()
      weak var weakOriginal = original
      defer { try? weakOriginal?.close() }
      let observed = try Self.observation(f.binding)
      var retained: ProtocolVerificationSnapshot? = try original?.prepareProtocolVerification(
        expectedBinding: f.binding)
      original = nil
      let heldStrongly = weakOriginal != nil
      #expect(heldStrongly)
      guard let snapshot = retained else { throw FixtureFailure.nativeShape }
      let before = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(expectedSnapshot: snapshot, observation: observed)
      }
      try Self.expectUnchanged(f, before)
      // Scope close still closes admission although a comparison snapshot keeps the object alive.
      try weakOriginal?.close()
      Self.expectSafe {
        guard let database = weakOriginal else { throw FixtureFailure.nativeShape }
        _ = try database.commitObservedProtocolFact(expectedSnapshot: snapshot, observation: observed)
      }
      let reopened = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let firstCommitted = try f.database.commitObservedProtocolFact(
        expectedSnapshot: reopened, observation: observed)
      let afterCommit = try f.reopen()  // A genuinely NEW object created after the stored fact exists.
      defer { try? afterCommit.close() }
      guard let fresh = try afterCommit.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      #expect(fresh.observation == observed)
      let committedState = try Self.state(f)
      Self.expectSafe {
        _ = try afterCommit.commitObservedProtocolFact(
          expectedSnapshot: firstCommitted, observation: observed)
      }
      try Self.expectUnchanged(f, committedState)
      let newer = try Self.observation(f.binding, version: 3)
      _ = try afterCommit.commitObservedProtocolFact(expectedSnapshot: fresh, observation: newer)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding, observedVersion: 3)
      try afterCommit.close()
      retained = nil
    }
  }

  private static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      Thread { continuation.resume(returning: body()) }.start()
    }
  }
  private final class WorkerResult: Sendable {
    let value = Mutex<Result<ProtocolVerificationSnapshot, any Error>?>(nil)
  }
  private static func compete(
    _ operation: @escaping @Sendable () throws -> ProtocolVerificationSnapshot
  ) async -> (Bool, Int, [Result<ProtocolVerificationSnapshot, any Error>]) {
    // The controller itself is dedicated: a late cooperative resume cannot hold native workers
    // at the gate. Completion means each synchronous operation ended, not kernel Thread exit.
    await onThread {
      let entered = Mutex(0), called = Mutex(0), release = DispatchSemaphore(value: 0)
      let first = WorkerResult(), second = WorkerResult()
      let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
      let work: @Sendable (WorkerResult, DispatchSemaphore) -> Void = { result, done in
        defer { done.signal() }
        entered.withLock { $0 += 1 }
        guard release.wait(timeout: .now() + .seconds(8)) == .success else {
          result.value.withLock { $0 = .failure(FixtureFailure.barrierTimeout) }
          return
        }
        called.withLock { $0 += 1 }
        let outcome = Result { try operation() }
        result.value.withLock { $0 = outcome }
      }
      let firstWorker = Thread { work(first, firstDone) }
      let secondWorker = Thread { work(second, secondDone) }
      firstWorker.start(); secondWorker.start()
      let deadline = ContinuousClock.now + .seconds(3)
      while entered.withLock({ $0 }) != 2, ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
      let ready = entered.withLock { $0 == 2 }
      release.signal(); release.signal()
      // Always release and join BOTH actual operations before returning results/assertions.
      withExtendedLifetime((firstWorker, secondWorker)) {
        firstDone.wait(); secondDone.wait()
      }
      let a = first.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape)
      let b = second.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape)
      return (ready, called.withLock { $0 }, [a, b])
    }
  }

  @Test func concurrentInitializationAndCompareAndWriteUseOneNativeRevision() async throws {
    try await Self.withFixture { f in
      let (ready, called, initialized) = await Self.compete {
        try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      }
      #expect(ready); #expect(called == 2)
      var preparations: [ProtocolVerificationSnapshot] = []
      for result in initialized { preparations.append(try result.get()) }
      #expect(preparations.count == 2)
      _ = try Self.expectRecord(f, revision: "0", binding: f.binding)
      guard let snapshot = preparations.first else { throw FixtureFailure.nativeShape }
      let observation = try Self.observation(f.binding)
      let (commitReady, commitCalled, outcomes) = await Self.compete {
        try f.database.commitObservedProtocolFact(expectedSnapshot: snapshot, observation: observation)
      }
      #expect(commitReady); #expect(commitCalled == 2)
      var successes = 0, failures = 0
      for result in outcomes {
        switch result {
        case .success: successes += 1
        case .failure:
          failures += 1
          Self.expectSafe { _ = try result.get() }
        }
      }
      #expect(successes == 1 && failures == 1)
      _ = try Self.expectRecord(f, revision: "1", binding: f.binding, observedVersion: 2)
    }
  }

  @Test func reservedAndNulSettingsKeysRefuseBeforeReadOrValueEncoding() async throws {
    try await Self.withFixture { f in
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let before = try Self.state(f)
      let privateBefore = try Self.recordText(f)
      #expect(throws: EncodingError.self) { _ = try JSONCoding.encoder.encode(JSONValue.number(.nan)) }
      for key in [Self.key, Self.key + "\0suffix", "other\0" + Self.key] {
        Self.expectSafe { _ = try f.database.settings(key: key) }
        Self.expectSafe { try f.database.setSetting(key: key, value: .number(.nan)) }
        try Self.expectUnchanged(f, before)
      }
      for key in [
        Self.key + "-suffix", "prefix-" + Self.key, "＿b4app_agent_protocol_activation_v1", "owner-é",
        "owner-e\u{301}",
      ] {
        try f.database.setSetting(key: key, value: .string(key))
        let value = try f.database.settings(key: key)?.stringValue
        let exact = value.map { Self.equalBytes($0, key) } ?? false
        #expect(exact)
      }
      let privateAfter = try Self.recordText(f)
      let privateUnchanged = privateBefore.map { Data($0.utf8) } == privateAfter.map { Data($0.utf8) }
      #expect(privateUnchanged)
    }
  }

  @Test func closedStoredRecordsRejectUnknownKeysNullOptionalsAndConflictingObservations() async throws {
    try await Self.withFixture { f in
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let observation = try Self.observation(f.binding)
      let current = try f.database.commitObservedProtocolFact(
        expectedSnapshot: prepared, observation: observation)
      let valid = try Self.expectRecord(f, revision: "1", binding: f.binding, observedVersion: 2)
      guard let bound = valid["binding"] as? [String: Any],
        let observed = valid["observation"] as? [String: Any],
        let observedBinding = observed["binding"] as? [String: Any]
      else { throw FixtureFailure.nativeShape }
      var variants: [[String: Any]] = []
      var wrong = valid
      for field in ["version", "storeIncarnation", "membershipIncarnation", "revision"] {
        wrong = valid; wrong.removeValue(forKey: field); variants.append(wrong)
      }
      for field in [
        "accountID", "canonicalHubBase", "hubUserID", "hubOrgID", "deviceID", "databaseName", "linkJoinedAt",
      ] {
        var incomplete = bound; incomplete.removeValue(forKey: field)
        wrong = valid; wrong["binding"] = incomplete; variants.append(wrong)
        var incompleteObservedBinding = observedBinding; incompleteObservedBinding.removeValue(forKey: field)
        var incompleteObservation = observed; incompleteObservation["binding"] = incompleteObservedBinding
        wrong = valid; wrong["observation"] = incompleteObservation; variants.append(wrong)
      }
      for field in ["binding", "reportedMinimum", "reportedVersion", "healthy"] {
        var incomplete = observed; incomplete.removeValue(forKey: field)
        wrong = valid; wrong["observation"] = incomplete; variants.append(wrong)
      }
      wrong = valid; wrong["unknown"] = true; variants.append(wrong)
      wrong = valid; wrong["version"] = 2; variants.append(wrong)
      wrong = valid; wrong["version"] = true; variants.append(wrong)
      wrong = valid; wrong["storeIncarnation"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      variants.append(wrong)
      wrong = valid; wrong["membershipIncarnation"] = "not-a-uuid"; variants.append(wrong)
      for field in ["binding", "observation"] {
        wrong = valid; wrong[field] = NSNull(); variants.append(wrong)
      }
      var nested = bound; nested["unknown"] = true
      wrong = valid; wrong["binding"] = nested; variants.append(wrong)
      nested = observed; nested["unknown"] = true
      wrong = valid; wrong["observation"] = nested; variants.append(wrong)
      var conflictingBinding = observedBinding; conflictingBinding["hubOrgID"] = "ACTIVATION_OTHER_ORG"
      nested = observed; nested["binding"] = conflictingBinding
      wrong = valid; wrong["observation"] = nested; variants.append(wrong)
      var extraObservationBinding = observedBinding; extraObservationBinding["unknown"] = true
      nested = observed; nested["binding"] = extraObservationBinding
      wrong = valid; wrong["observation"] = nested; variants.append(wrong)
      wrong = valid; wrong.removeValue(forKey: "binding"); variants.append(wrong)
      for (field, value) in [
        ("reportedMinimum", 1 as Any), ("reportedMinimum", 3 as Any),
        ("reportedVersion", 1 as Any), ("healthy", false as Any), ("healthy", 1 as Any),
      ] {
        nested = observed; nested[field] = value
        wrong = valid; wrong["observation"] = nested; variants.append(wrong)
      }
      for bad in ["", "00", "+1", "-0", "-1", "1.0", "1e0", " 1", "1 ", "١", "9223372036854775808"] {
        wrong = valid; wrong["revision"] = bad; variants.append(wrong)
      }
      for bad in [1 as Any, true as Any, NSNull() as Any] {
        wrong = valid; wrong["revision"] = bad; variants.append(wrong)
      }
      for variant in variants {
        try Self.putRecord(f, variant)  // Explicit owned native corruption, never a generic settings bypass.
        let before = try Self.state(f)
        Self.expectSafe { _ = try f.database.readProtocolFact(expectedBinding: f.binding) }
        Self.expectSafe { _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding) }
        Self.expectSafe {
          _ = try f.database.commitObservedProtocolFact(expectedSnapshot: current, observation: observation)
        }
        Self.expectSafe { try f.database.saveHubLink(f.link) }
        Self.expectSafe { try f.database.clearHubLink() }
        try Self.expectUnchanged(f, before)
      }
      try Self.putRecord(f, valid)
      #expect(try f.database.readProtocolFact(expectedBinding: f.binding)?.observation == observation)
    }
  }

  @Test func revisionTextPreservesBeyondDoublePrecisionAndOverflowRefusesEveryMutation() async throws {
    try await Self.withFixture { f in
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      var value = try Self.nativeRecord(f)
      value["revision"] = "9007199254740993"
      try Self.putRecord(f, value)
      guard let large = try f.database.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      let observation = try Self.observation(f.binding)
      _ = try f.database.commitObservedProtocolFact(expectedSnapshot: large, observation: observation)
      _ = try Self.expectRecord(f, revision: "9007199254740994", binding: f.binding, observedVersion: 2)
      value = try Self.nativeRecord(f); value["revision"] = "9223372036854775807"
      try Self.putRecord(f, value)
      guard let maximum = try f.database.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      let before = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(expectedSnapshot: maximum, observation: observation)
      }
      Self.expectSafe { try f.database.saveHubLink(f.link, membershipChange: .replace) }
      Self.expectSafe { try f.database.clearHubLink() }
      try Self.expectUnchanged(f, before)
      // Nonmutating matching prepare/token refresh must not fabricate another revision.
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      var refresh = f.link; refresh.tokenRef = "secret:rotated"; refresh.username = "new-label"
      let privateBefore = try Self.recordText(f)
      try f.database.saveHubLink(refresh)
      let preserved = try Self.recordText(f).map { Data($0.utf8) } == privateBefore.map { Data($0.utf8) }
      #expect(preserved)
    }
  }

  @Test func routineRefreshPreservesControlBytesButExplicitReplacementInvalidatesIt() async throws {
    try await Self.withFixture { f in
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let observation = try Self.observation(f.binding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: prepared, observation: observation)
      let nativeBefore = try Self.expectRecord(f, revision: "1", binding: f.binding, observedVersion: 2)
      let bytesBefore = try Self.recordText(f)
      var refresh = f.link
      refresh.url += "/"; refresh.tokenRef = "secret:changed-not-identity"
      refresh.deviceName = "new name"; refresh.orgSlug = "different-label";
      refresh.username = "different-label"
      refresh.lastPushAt = "new-time"; refresh.lastError = "new-status"; refresh.cursor = 999
      try f.database.saveHubLink(refresh)
      let same = try Self.recordText(f).map { Data($0.utf8) } == bytesBefore.map { Data($0.utf8) }
      #expect(same)
      #expect(try f.database.hubLink()?.cursor == 0)  // Existing conflict-update cursor preservation.
      try f.database.saveHubLink(refresh, membershipChange: .replace)
      let replaced = try Self.expectRecord(f, revision: "2", binding: nil)
      let sameStore =
        (nativeBefore["storeIncarnation"] as? String).flatMap { a in
          (replaced["storeIncarnation"] as? String).map { Self.equalBytes(a, $0) }
        } ?? false
      let newMember =
        (nativeBefore["membershipIncarnation"] as? String).flatMap { a in
          (replaced["membershipIncarnation"] as? String).map { !Self.equalBytes(a, $0) }
        } ?? false
      #expect(sameStore); #expect(newMember)
      #expect(try f.database.readProtocolFact(expectedBinding: f.binding) == nil)
      let before = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(expectedSnapshot: committed, observation: observation)
      }
      try Self.expectUnchanged(f, before)
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      _ = try Self.expectRecord(f, revision: "3", binding: f.binding)
    }
  }

  @Test func changedNativeTupleAndRepeatedClearRotateOnlyMembershipAndRejectOldSnapshots() async throws {
    try await Self.withFixture { f in
      var link = f.link
      for field in ["url", "deviceId", "joinedAt"] {
        let binding = try Self.binding(
          canonicalHubBase: link.url, deviceID: link.deviceId, databaseName: f.endpoint.database,
          linkJoinedAt: link.joinedAt)
        let oldSnapshot = try f.database.prepareProtocolVerification(expectedBinding: binding)
        let old = try Self.nativeRecord(f)
        guard let revision = old["revision"] as? String, let value = Int64(revision) else {
          throw FixtureFailure.nativeShape
        }
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw FixtureFailure.nativeShape }
        if field == "url" { link.url = "https://example.invalid/OtherDeployment" }
        if field == "deviceId" { link.deviceId = "ACTIVATION_CHANGED_DEVICE" }
        if field == "joinedAt" { link.joinedAt = "2026-11-12T01:00:00.000Z" }
        try f.database.saveHubLink(link)
        let now = try Self.expectRecord(f, revision: String(next), binding: nil)
        let storePreserved =
          (old["storeIncarnation"] as? String).flatMap { a in
            (now["storeIncarnation"] as? String).map { Self.equalBytes(a, $0) }
          } ?? false
        let memberChanged =
          (old["membershipIncarnation"] as? String).flatMap { a in
            (now["membershipIncarnation"] as? String).map { !Self.equalBytes(a, $0) }
          } ?? false
        #expect(storePreserved); #expect(memberChanged)
        let observation = try Self.observation(binding), before = try Self.state(f)
        Self.expectSafe {
          _ = try f.database.commitObservedProtocolFact(
            expectedSnapshot: oldSnapshot, observation: observation)
        }
        try Self.expectUnchanged(f, before)
      }
      for _ in 0..<2 {
        let old = try Self.nativeRecord(f)
        guard let revision = old["revision"] as? String, let value = Int64(revision) else {
          throw FixtureFailure.nativeShape
        }
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw FixtureFailure.nativeShape }
        try f.database.clearHubLink()  // The second call is already empty, and still invalidates.
        let now = try Self.expectRecord(f, revision: String(next), binding: nil)
        let changed =
          (old["membershipIncarnation"] as? String).flatMap { a in
            (now["membershipIncarnation"] as? String).map { !Self.equalBytes(a, $0) }
          } ?? false
        let storePreserved =
          (old["storeIncarnation"] as? String).flatMap { a in
            (now["storeIncarnation"] as? String).map { Self.equalBytes(a, $0) }
          } ?? false
        #expect(changed); #expect(storePreserved)
        #expect(try f.database.hubLink() == nil)
        #expect(try f.database.readProtocolFact(expectedBinding: f.binding) == nil)
      }
      let empty = try Self.state(f)
      Self.expectSafe { _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding) }
      try Self.expectUnchanged(f, empty)
    }
  }

  @Test func actualDeferredCommitFailureIsSafeAndRollsBackNativeRecordAndOtherRows() async throws {
    try await Self.withFixture { f in
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let observed = try Self.observation(f.binding)
      let current = try f.database.commitObservedProtocolFact(
        expectedSnapshot: prepared, observation: observed)
      let before = try Self.state(f)
      let changedObservation = try Self.observation(f.binding, version: 3)
      try f.raw.execute(
        "ALTER TABLE public.settings ADD CONSTRAINT activation_test_refusal CHECK (key<>'__b4app_agent_protocol_activation_v1' OR value#>>'{observation,reportedVersion}'<>'3')"
      )
      // Positive raw native control, always rolled back before any assertion. Never print DETAIL.
      try f.raw.execute("BEGIN")
      let nativeControl = Result {
        try f.raw.execute(
          "UPDATE public.settings SET value=jsonb_set(value,'{observation,reportedVersion}','3'::jsonb) WHERE key=$1",
          [Self.key])
      }
      let rolledBack = Result { try f.raw.execute("ROLLBACK") }
      _ = try rolledBack.get()
      let actualConstraint: Bool
      if case .failure(let error) = nativeControl {
        actualConstraint = (error as? PostgresError)?.sqlState == "23514"
      } else {
        actualConstraint = false
      }
      #expect(actualConstraint)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(
          expectedSnapshot: current, observation: changedObservation)
      }
      try Self.expectUnchanged(f, before)
      try f.raw.execute("ALTER TABLE public.settings DROP CONSTRAINT activation_test_refusal")
      try f.raw.execute(
        """
        CREATE SCHEMA activation_test;
        CREATE SEQUENCE activation_test.probe;
        CREATE FUNCTION activation_test.refuse_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF NEW.value->>'revision' IS DISTINCT FROM '2'
            OR NEW.value#>>'{observation,reportedMinimum}' IS DISTINCT FROM '2'
            OR NEW.value#>>'{observation,reportedVersion}' IS DISTINCT FROM '3'
            OR NEW.value#>>'{observation,healthy}' IS DISTINCT FROM 'true'
            OR NOT EXISTS (SELECT 1 FROM public.settings s WHERE s.key=NEW.key AND s.value=NEW.value)
            OR NOT EXISTS (SELECT 1 FROM public.\"schemaMigrations\" WHERE name='0014_agent_protocol')
          THEN RAISE EXCEPTION 'ACTIVATION_DEFERRED_STAGE_NOT_REACHED'; END IF;
          UPDATE public.settings SET value='"mutated-inside-commit"'::jsonb WHERE key='activation-unrelated';
          PERFORM nextval('activation_test.probe');
          RAISE EXCEPTION 'ACTIVATION_DEFERRED_PRIVATE_CANARY' USING ERRCODE='23514', DETAIL=NEW.value::text;
        END $$;
        CREATE CONSTRAINT TRIGGER activation_test_commit AFTER UPDATE ON public.settings
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
          WHEN (NEW.key='__b4app_agent_protocol_activation_v1') EXECUTE FUNCTION activation_test.refuse_commit();
        """)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(
          expectedSnapshot: current, observation: changedObservation)
      }
      // Nontransactional probe is deliberately outside the public business snapshot. It proves
      // the deferred function saw the candidate record at actual outer COMMIT before refusing.
      let probe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM activation_test.probe"
      ).rows.first
      #expect(probe?.text("n") == "1" && probe?.text("called") == "true")
      try Self.expectUnchanged(f, before)
      try f.raw.execute("DROP TRIGGER activation_test_commit ON public.settings")
      _ = try f.database.commitObservedProtocolFact(
        expectedSnapshot: current, observation: changedObservation)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding, observedVersion: 3)
    }
  }
}

extension ProtocolActivationStoreTests {
  private static let membershipGate: Int64 = 0x6234_5f61_6374_6c6b
  private static let changedDevice = "ACTIVATION_REPLACED_DEVICE_SENTINEL"

  private final class MembershipWriterResult: Sendable {
    let pid = Mutex<Int?>(nil)
    let value = Mutex<Result<Int, any Error>?>(nil)
  }
  private struct MembershipLockFacts: Sendable {
    let factPaused: Bool
    let writerStarted: Bool
    let writerBlocked: Bool
    let gateReleased: Bool
    let factJoined: Bool
    let writerJoined: Bool
    let controller: Result<Void, any Error>
    let fact: Result<ProtocolVerificationSnapshot, any Error>
    let writer: Result<Int, any Error>
  }
  private static func membershipConnection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func membershipLockController(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, observation: ProtocolVerificationObservation
  ) async -> MembershipLockFacts {
    await onThread {
      var control: PostgresConnection?
      var gateOwned = false, gateReleased = false
      var factPaused = false, writerBlocked = false
      var firstError: (any Error)?
      let fact = WorkerResult(), writer = MembershipWriterResult()
      let factDone = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0)
      var factWorker: Thread?, writerWorker: Thread?
      do {
        let c = try membershipConnection(f.endpoint)
        control = c
        guard let controllerPID = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"),
          controllerPID > 0
        else { throw FixtureFailure.nativeShape }
        try c.execute("SELECT pg_advisory_lock($1::bigint)", [String(membershipGate)])
        gateOwned = true
        let commitWorker = Thread {
          let result = Result {
            try f.database.commitObservedProtocolFact(expectedSnapshot: snapshot, observation: observation)
          }
          fact.value.withLock { $0 = result }
          factDone.signal()
        }
        factWorker = commitWorker
        commitWorker.start()
        var factPID: Int?
        let pausedDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < pausedDeadline {
          // The trigger requests only this controller's owned gate, after the fact's state read.
          let rows = try c.execute(
            """
            SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
            WHERE a.datname=$1 AND a.application_name='b4app' AND l.locktype='advisory'
              AND NOT l.granted AND $2::int=ANY(pg_blocking_pids(a.pid))
            """, [f.endpoint.database, String(controllerPID)]
          ).rows
          let completed = ContinuousClock.now
          if completed <= pausedDeadline, rows.count == 1, let pid = rows.first?.int("pid"), pid > 0 {
            factPID = pid; factPaused = true; break
          }
          guard completed < pausedDeadline else { break }
          Thread.sleep(forTimeInterval: 0.005)
        }
        let rawWriter = Thread {
          // Raw native UPDATE deliberately bypasses the cooperative/advisory storage API.
          // Its own connection ends before signalling actual operation completion.
          let result = Result<Int, any Error> {
            let raw = try membershipConnection(f.endpoint)
            guard let pid = try raw.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"), pid > 0
            else { throw FixtureFailure.nativeShape }
            writer.pid.withLock { $0 = pid }
            return try raw.execute(
              #"UPDATE public."hubLink" SET "deviceId"=$1 WHERE "id"=1"#, [changedDevice]
            ).affected
          }
          writer.value.withLock { $0 = result }
          writerDone.signal()
        }
        writerWorker = rawWriter
        rawWriter.start()
        if let factPID {
          let blockedDeadline = ContinuousClock.now + .seconds(3)
          while ContinuousClock.now < blockedDeadline {
            if let writerPID = writer.pid.withLock({ $0 }) {
              let rows = try c.execute(
                """
                SELECT 1 FROM pg_stat_activity a WHERE a.datname=$1 AND a.pid=$2::int
                  AND $3::int=ANY(pg_blocking_pids(a.pid))
                """, [f.endpoint.database, String(writerPID), String(factPID)]
              ).rows
              let completed = ContinuousClock.now
              if completed <= blockedDeadline, rows.count == 1 { writerBlocked = true; break }
              guard completed < blockedDeadline else { break }
            }
            // Completion before native blocking is the discriminating R1 failure, not success.
            if writer.value.withLock({ $0 != nil }) { break }
            Thread.sleep(forTimeInterval: 0.005)
          }
        }
      } catch { firstError = error }
      // Always release this controller's gate before joining either actual worker operation.
      // Closing this private session is the fallback release if explicit unlock itself fails.
      if gateOwned {
        do {
          guard let c = control,
            try c.execute("SELECT pg_advisory_unlock($1::bigint) AS released", [String(membershipGate)])
              .rows.first?.text("released") == "t"
          else { throw FixtureFailure.nativeShape }
          gateReleased = true
        } catch { if firstError == nil { firstError = error } }
      }
      control = nil
      var factJoined = false, writerJoined = false
      withExtendedLifetime((factWorker, writerWorker)) {
        if factWorker != nil { factDone.wait(); factJoined = true }
        if writerWorker != nil { writerDone.wait(); writerJoined = true }
      }
      let controlResult: Result<Void, any Error>
      if let firstError { controlResult = .failure(firstError) } else { controlResult = .success(()) }
      return MembershipLockFacts(
        factPaused: factPaused, writerStarted: writerWorker != nil, writerBlocked: writerBlocked,
        gateReleased: gateReleased, factJoined: factJoined, writerJoined: writerJoined,
        controller: controlResult,
        fact: fact.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape),
        writer: writer.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape))
    }
  }

  @Test func factCommitLocksActualMembershipUntilCommit() async throws {
    try await Self.withFixture { f in
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let observation = try Self.observation(f.binding)
      var cleaned = false
      let cleanupSQL = """
        DROP TRIGGER IF EXISTS activation_membership_pause ON public.settings;
        DROP FUNCTION IF EXISTS activation_membership_test.pause_fact();
        DROP SCHEMA IF EXISTS activation_membership_test CASCADE;
        """
      // No worker starts until installation completes. After it starts, controller cannot return
      // before its gate is released and every started native operation is actually joined.
      defer { if !cleaned { _ = try? f.raw.execute(cleanupSQL) } }
      try f.raw.execute(
        """
        CREATE SCHEMA activation_membership_test;
        CREATE FUNCTION activation_membership_test.pause_fact() RETURNS trigger
          LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF OLD.value->>'revision' IS DISTINCT FROM '0'
            OR NEW.value->>'revision' IS DISTINCT FROM '1'
            OR NEW.value#>>'{observation,reportedMinimum}' IS DISTINCT FROM '2'
          THEN RAISE EXCEPTION 'ACTIVATION_MEMBERSHIP_STAGE_NOT_REACHED'; END IF;
          PERFORM pg_advisory_xact_lock(\(Self.membershipGate)::bigint);
          RETURN NEW;
        END $$;
        CREATE TRIGGER activation_membership_pause BEFORE UPDATE ON public.settings
          FOR EACH ROW WHEN (NEW.key='__b4app_agent_protocol_activation_v1')
          EXECUTE FUNCTION activation_membership_test.pause_fact();
        """)
      let facts = await Self.membershipLockController(f, snapshot: prepared, observation: observation)
      // Remove the fault only AFTER both actual operations join, including every error path.
      let cleanup = Result { try f.raw.execute(cleanupSQL) }
      if case .success = cleanup { cleaned = true }
      print(
        "A4_MEMBERSHIP_ROW_LOCK factPaused=\(facts.factPaused) writerStarted=\(facts.writerStarted) "
          + "writerBlocked=\(facts.writerBlocked) gateReleased=\(facts.gateReleased) "
          + "factJoined=\(facts.factJoined) writerJoined=\(facts.writerJoined)"
      )
      #expect(facts.factPaused)
      #expect(facts.writerStarted && facts.writerBlocked)
      #expect(facts.gateReleased && facts.factJoined && facts.writerJoined)
      try facts.controller.get()
      let factSucceeded: Bool, writerSucceeded: Bool
      switch facts.fact {
      case .success: factSucceeded = true;
      case .failure: factSucceeded = false
      }
      switch facts.writer {
      case .success: writerSucceeded = true;
      case .failure: writerSucceeded = false
      }
      #expect(factSucceeded); #expect(writerSucceeded)
      let committed = try facts.fact.get()
      let affected = try facts.writer.get()
      #expect(affected == 1)
      #expect(committed.observation == observation)
      try cleanup.get()
      let currentDevice = try f.database.hubLink()?.deviceId
      let actualDeviceChanged = currentDevice.map { Self.equalBytes($0, Self.changedDevice) } ?? false
      #expect(actualDeviceChanged)
      let beforeRead = try Self.state(f)
      Self.expectSafe { _ = try f.database.readProtocolFact(expectedBinding: f.binding) }
      try Self.expectUnchanged(f, beforeRead)
    }
  }
}
