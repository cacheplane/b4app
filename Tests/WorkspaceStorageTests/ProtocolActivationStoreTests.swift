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
      // Keep the actual positive encoding control outside a nested throwing assertion macro.
      // Only a typed, Sendable Boolean reaches #expect in this async fixture closure.
      let rejectsNaN: Bool
      do {
        _ = try JSONCoding.encoder.encode(JSONValue.number(.nan))
        rejectsNaN = false
      } catch is EncodingError {
        rejectsNaN = true
      } catch {
        rejectsNaN = false
      }
      #expect(rejectsNaN)
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

// New captured-context companions only. The complete prior thirteen-method prefix is retained.
// These tests describe storage comparison/fencing, never authenticated account or runtime admission.
extension ProtocolActivationStoreTests {
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
  private static func incarnationBytesMatch(
    _ a: [String: Any], _ b: [String: Any], field: String
  ) -> Bool {
    (a[field] as? String).flatMap { first in
      (b[field] as? String).map { equalBytes(first, $0) }
    } ?? false
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
  private static func removeLogWitness(_ f: Fixture, seq: Int) throws {
    try f.raw.execute("DELETE FROM public.changes WHERE seq=$1::bigint", [String(seq)])
  }
  /// Fixture setup only: suppress change recording to isolate one LIVE-column witness at a time.
  /// Classifier assertions compare complete native snapshots; the classifier never resets history.
  private static func setLiveWitnessColumn(_ f: Fixture, column: String, value: String?) throws {
    guard protocolColumns.contains(column) else { throw FixtureFailure.nativeShape }
    try f.raw.execute("BEGIN")
    do {
      try f.raw.execute("SET LOCAL b4app.replaying='on'")
      try f.raw.execute(
        "UPDATE public.connections SET \(Rows.quote(column))=$1 WHERE id=$2", [value, witnessConnection])
      try f.raw.execute("COMMIT")
    } catch {
      _ = try? f.raw.execute("ROLLBACK")
      throw error
    }
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

  @Test func captureBeforeFirstAwaitCreatesClosedInactiveEpochWithoutInventingOrg() async throws {
    try await Self.withFixture { f in
      let before = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: nil)
      }
      try Self.expectUnchanged(f, before)
      for bad in ["", "ACTIVATION_BAD\0suffix"] {
        Self.expectSafe {
          _ = try f.database.captureProtocolVerification(
            accountID: bad, expectedMembership: Self.nativeMembership(f.link))
        }
        try Self.expectUnchanged(f, before)
      }
      let capture = try Self.capture(f)
      #expect(capture.observation == nil)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
      let captured = try Self.state(f)
      _ = try Self.capture(f)
      try Self.expectUnchanged(f, captured)
      for field in ["url", "deviceId", "joinedAt"] {
        var wrong = f.link
        if field == "url" { wrong.url = "https://example.invalid/Other" }
        if field == "deviceId" { wrong.deviceId = "ACTIVATION_WRONG_DEVICE" }
        if field == "joinedAt" { wrong.joinedAt = "different-stamp" }
        Self.expectSafe {
          _ = try f.database.captureProtocolVerification(
            accountID: f.binding.accountID, expectedMembership: Self.nativeMembership(wrong))
        }
        try Self.expectUnchanged(f, captured)
      }
    }
  }

  @Test func absentLinkCaptureMeansActualAbsenceAndBoundAccountMismatchCannotResetState() async throws {
    try await Self.withFixture { f in
      _ = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let bound = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.captureProtocolVerification(
          accountID: "ACTIVATION_OTHER_ACCOUNT", expectedMembership: Self.nativeMembership(f.link))
      }
      try Self.expectUnchanged(f, bound)
      try f.database.clearHubLink()
      let cleared = try Self.state(f)
      Self.expectSafe { _ = try Self.capture(f) }
      try Self.expectUnchanged(f, cleared)
      let unlinked = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      #expect(unlinked.observation == nil)
      _ = try Self.expectRecord(f, revision: "1", binding: nil)
      let noLink = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(expectedSnapshot: unlinked, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, noLink)
    }
  }

  @Test func capturedBindAndCommitPreserveContextAndExactRecordChronology() async throws {
    try await Self.withFixture { f in
      let first = try Self.capture(f)
      let inactive = try Self.expectRecord(f, revision: "0", binding: nil)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: first, expectedBinding: f.binding)
      let one = try Self.expectRecord(f, revision: "1", binding: f.binding)
      for field in ["storeIncarnation", "membershipIncarnation"] {
        let unchanged = Self.incarnationBytesMatch(inactive, one, field: field)
        #expect(unchanged)
      }
      let beforeStale = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(expectedSnapshot: first, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, beforeStale)
      let observed = try Self.observation(f.binding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: observed)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding, observedVersion: 2)
      // If either bind or positive commit drops captured context this actual fence must refuse.
      try f.database.fenceProtocolVerification(expectedSnapshot: committed)
      _ = try Self.expectRecord(f, revision: "3", binding: f.binding)
      let fenced = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(expectedSnapshot: committed, observation: observed)
      }
      try Self.expectUnchanged(f, fenced)
    }
  }

  @Test func oldDirectSnapshotsNeverAcquireContextThroughReadOrCommit() async throws {
    try await Self.withFixture { f in
      let prepared = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let observed = try Self.observation(f.binding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: prepared, observation: observed)
      guard let read = try f.database.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      for snapshot in [prepared, committed, read] {
        let before = try Self.state(f)
        Self.expectSafe {
          _ = try f.database.prepareProtocolVerification(
            expectedSnapshot: snapshot, expectedBinding: f.binding)
        }
        try Self.expectUnchanged(f, before)
        Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: snapshot) }
        try Self.expectUnchanged(f, before)
        Self.expectSafe {
          _ = try f.database.saveHubLink(
            f.link, membershipChange: .preserveIfUnchanged, expectedProtocolSnapshot: snapshot)
        }
        try Self.expectUnchanged(f, before)
      }
      let captured = try Self.capture(f)
      #expect(captured.observation == observed)
      try f.database.fenceProtocolVerification(expectedSnapshot: captured)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding)
    }
  }

  @Test func capturedContextRefusesDifferentObjectNativeTupleAndRecordChanges() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      let other = try f.reopen()
      defer { try? other.close() }
      var before = try Self.state(f)
      Self.expectSafe {
        _ = try other.prepareProtocolVerification(expectedSnapshot: snapshot, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, before)
      Self.expectSafe { try other.fenceProtocolVerification(expectedSnapshot: snapshot) }
      try Self.expectUnchanged(f, before)
      Self.expectSafe {
        _ = try other.saveHubLink(f.link, membershipChange: .replace, expectedProtocolSnapshot: snapshot)
      }
      try Self.expectUnchanged(f, before)
      try other.close()
      let wrongDatabase = try Self.binding(databaseName: "ACTIVATION_OTHER_DATABASE")
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(
          expectedSnapshot: snapshot, expectedBinding: wrongDatabase)
      }
      try Self.expectUnchanged(f, before)
      let valid = try Self.nativeRecord(f)
      for field in ["storeIncarnation", "membershipIncarnation", "revision"] {
        var changed = valid
        changed[field] = field == "revision" ? "1" : UUID().uuidString
        try Self.putRecord(f, changed)
        before = try Self.state(f)
        Self.expectSafe {
          _ = try f.database.prepareProtocolVerification(
            expectedSnapshot: snapshot, expectedBinding: f.binding)
        }
        try Self.expectUnchanged(f, before)
        if field != "revision" {
          Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: snapshot) }
          try Self.expectUnchanged(f, before)
        }
        Self.expectSafe {
          _ = try f.database.saveHubLink(
            f.link, membershipChange: .replace, expectedProtocolSnapshot: snapshot)
        }
        try Self.expectUnchanged(f, before)
        try Self.putRecord(f, valid)
      }
      try f.raw.execute(#"UPDATE public."hubLink" SET "deviceId"='é' WHERE id=1"#)
      before = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(expectedSnapshot: snapshot, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, before)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: snapshot) }
      try Self.expectUnchanged(f, before)
      Self.expectSafe {
        _ = try f.database.saveHubLink(f.link, membershipChange: .replace, expectedProtocolSnapshot: snapshot)
      }
      try Self.expectUnchanged(f, before)
    }
  }

  @Test func firstAwaitCaptureCannotAdoptRestoreOrSameLookingExplicitReplacement() async throws {
    try await Self.withFixture { f in
      let beforeAwait = try Self.capture(f)
      try f.database.saveHubLink(f.link, membershipChange: .replace)
      let replaced = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(
          expectedSnapshot: beforeAwait, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, replaced)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: beforeAwait) }
      try Self.expectUnchanged(f, replaced)
      Self.expectSafe {
        _ = try f.database.saveHubLink(
          f.link, membershipChange: .replace, expectedProtocolSnapshot: beforeAwait)
      }
      try Self.expectUnchanged(f, replaced)
      try f.database.clearHubLink()
      let unlinked = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      let path = f.root + "/before-await.jsonl"
      try f.database.export(to: path)
      try f.database.restore(from: path, replace: true)
      let restored = try Self.state(f)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: unlinked) }
      try Self.expectUnchanged(f, restored)
      Self.expectSafe {
        _ = try f.database.saveHubLink(f.link, membershipChange: .replace, expectedProtocolSnapshot: unlinked)
      }
      try Self.expectUnchanged(f, restored)
      // These are actual native interpositions between capture and redemption, not HTTP evidence.
    }
  }

  @Test func negativeFenceClearsLatestRevisionOnlyInsideItsCapturedMembershipEpoch() async throws {
    try await Self.withFixture { f in
      let bound = try Self.capturedBinding(f)
      let observed = try Self.observation(f.binding)
      let two = try f.database.commitObservedProtocolFact(expectedSnapshot: bound, observation: observed)
      let negativeCapture = try Self.capture(f)
      let three = try f.database.commitObservedProtocolFact(
        expectedSnapshot: two, observation: Self.observation(f.binding, version: 3))
      let before = try Self.nativeRecord(f)
      try f.database.fenceProtocolVerification(expectedSnapshot: negativeCapture)
      let now = try Self.expectRecord(f, revision: "4", binding: f.binding)
      for field in ["storeIncarnation", "membershipIncarnation"] {
        let same = Self.incarnationBytesMatch(before, now, field: field)
        #expect(same)
      }
      let fenced = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.commitObservedProtocolFact(expectedSnapshot: three, observation: observed)
      }
      try Self.expectUnchanged(f, fenced)
      Self.expectSafe {
        _ = try f.database.prepareProtocolVerification(
          expectedSnapshot: negativeCapture, expectedBinding: f.binding)
      }
      try Self.expectUnchanged(f, fenced)
      let fresh = try Self.capture(f)
      let rebound = try f.database.prepareProtocolVerification(
        expectedSnapshot: fresh, expectedBinding: f.binding)
      _ = try f.database.commitObservedProtocolFact(expectedSnapshot: rebound, observation: observed)
      _ = try Self.expectRecord(f, revision: "5", binding: f.binding, observedVersion: 2)
      let oldEpoch = try Self.capture(f)
      try f.database.saveHubLink(f.link, membershipChange: .replace)
      let replaced = try Self.state(f)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: oldEpoch) }
      try Self.expectUnchanged(f, replaced)
    }
  }

  @Test func capturedFenceDeferredCommitFailureRollsBackAndKeepsSafeError() async throws {
    try await Self.withFixture { f in
      let bound = try Self.capturedBinding(f)
      _ = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      let negative = try Self.capture(f)
      let before = try Self.state(f)
      try f.raw.execute(
        """
        CREATE SCHEMA activation_capture_fault;
        CREATE SEQUENCE activation_capture_fault.probe;
        CREATE FUNCTION activation_capture_fault.refuse_fence() RETURNS trigger
          LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF OLD.value->>'revision' IS DISTINCT FROM '2' OR NEW.value->>'revision' IS DISTINCT FROM '3'
            OR NOT (OLD.value ? 'observation') OR NEW.value ? 'observation'
            OR NEW.value->'binding' IS DISTINCT FROM OLD.value->'binding'
            OR NOT EXISTS(SELECT 1 FROM public.settings WHERE key=NEW.key AND value=NEW.value)
          THEN RAISE EXCEPTION 'ACTIVATION_FENCE_STAGE_NOT_REACHED'; END IF;
          UPDATE public.settings SET value='"changed-in-commit"'::jsonb WHERE key='activation-unrelated';
          PERFORM nextval('activation_capture_fault.probe');
          RAISE EXCEPTION 'ACTIVATION_FENCE_PRIVATE_CANARY' USING ERRCODE='23514', DETAIL=NEW.value::text;
        END $$;
        CREATE CONSTRAINT TRIGGER activation_fence_fault AFTER UPDATE ON public.settings
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.key='__b4app_agent_protocol_activation_v1')
          EXECUTE FUNCTION activation_capture_fault.refuse_fence();
        """)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: negative) }
      try Self.expectUnchanged(f, before)
      let probe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM activation_capture_fault.probe"
      ).rows.first
      #expect(probe?.text("n") == "1" && probe?.text("called") == "true")
      try Self.expectUnchanged(f, before)
      try f.raw.execute("DROP TRIGGER activation_fence_fault ON public.settings")
      try f.database.fenceProtocolVerification(expectedSnapshot: negative)
      _ = try Self.expectRecord(f, revision: "3", binding: f.binding)
    }
  }

  @Test func checkedPresentLinkPreservesCursorAndReturnsOnlyItsOwnTransitionContext() async throws {
    try await Self.withFixture { f in
      try f.database.setHubCursor(7)
      let capture = try Self.capture(f)
      var refresh = f.link; refresh.cursor = 999; refresh.tokenRef = "secret:refreshed";
      refresh.deviceName = "refreshed label"
      let original = try Self.recordText(f)
      try f.database.saveHubLink(refresh)  // Existing unconditional wrapper remains valid.
      let oldWrapperPreserved = try Self.recordText(f).map { Data($0.utf8) } == original.map { Data($0.utf8) }
      #expect(oldWrapperPreserved)
      let checked = try f.database.saveHubLink(
        refresh, membershipChange: .preserveIfUnchanged, expectedProtocolSnapshot: capture)
      #expect(try f.database.hubLink()?.cursor == 7)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: checked, expectedBinding: f.binding)
      _ = try Self.expectRecord(f, revision: "1", binding: f.binding)
      let observed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      var replacement = refresh; replacement.deviceId = "ACTIVATION_CHECKED_REPLACEMENT"
      let transitioned = try f.database.saveHubLink(
        replacement, membershipChange: .replace, expectedProtocolSnapshot: observed)
      _ = try Self.expectRecord(f, revision: "3", binding: nil)
      let replacementBinding = try Self.binding(
        deviceID: replacement.deviceId, databaseName: f.endpoint.database)
      let rebound = try f.database.prepareProtocolVerification(
        expectedSnapshot: transitioned, expectedBinding: replacementBinding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: rebound, observation: Self.observation(replacementBinding))
      try f.database.fenceProtocolVerification(expectedSnapshot: committed)
      _ = try Self.expectRecord(f, revision: "6", binding: replacementBinding)
      let state = try Self.state(f)
      Self.expectSafe {
        _ = try f.database.saveHubLink(f.link, membershipChange: .replace, expectedProtocolSnapshot: capture)
      }
      try Self.expectUnchanged(f, state)
    }
  }

  @Test func positiveWitnessClassifierUsesLiveColumnsWithoutReadingOpaqueUserJSON() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      try f.database.setSetting(
        key: "opaque-agentProtocol", value: ["peerProfile": "agentProtocol", "agentId": "user text"])
      _ = try f.database.insertDisplayItem(
        DisplayItem(
          id: "opaque-display", threadId: Self.witnessThread, role: .assistant, type: "agentProtocol",
          payload: ["kind": "agentProtocol", "agentId": "opaque", "nested": ["authMode": "bearer"]],
          sequence: 1, provenance: .cache))
      try f.raw.execute(
        """
        UPDATE public.connections SET capabilities='{"agentId":"opaque","kind":"agentProtocol"}',
          models='[{"peerProfile":"agentProtocol","protocolRetiredAt":"opaque"}]' WHERE id='capture-witness-c';
        INSERT INTO public."runtimeRequests"(id,"nativeRequestId","threadId","adapterGeneration",kind,state,payload,"createdAt","updatedAt")
          VALUES('opaque-request','opaque-native','capture-witness-t',0,'unknown','pending',
            '{"authMode":"bearer","kind":"agentProtocol"}','then','then');
        INSERT INTO public."viewSettings"(id,arrangement,"quietThreads") VALUES('view','future-value','agentProtocol');
        """)
      _ = try Self.capture(f)  // An inactive control row alone is not a modern graph witness.
      try Self.expectRequirement(f, .legacyOnly)
      for (column, value) in [
        ("peerProfile", "agentProtocol"), ("agentId", "agent"), ("authMode", "none"),
        ("authHeaderName", "X-Private"),
      ] {
        try Self.setLiveWitnessColumn(f, column: column, value: value)
        try Self.expectRequirement(f, .protocolTwo)
        try Self.setLiveWitnessColumn(f, column: column, value: nil)
        try Self.expectRequirement(f, .legacyOnly)
      }
      // Native CHECK requires the retirement pair together; retained-update cases below isolate
      // each literal column independently without weakening that schema constraint.
      try f.raw.execute("BEGIN")
      try f.raw.execute("SET LOCAL b4app.replaying='on'")
      try f.raw.execute(
        "UPDATE public.connections SET \"protocolRetiredAt\"='then',\"protocolRetiredReason\"='agent_protocol_cutover' WHERE id=$1",
        [Self.witnessConnection])
      try f.raw.execute("COMMIT")
      try Self.expectRequirement(f, .protocolTwo)
    }
  }

  @Test func everyPrivateProtocolTableIsAnIndependentRetainedPositiveWitness() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      let inserts = [
        "INSERT INTO public.\"protocolSubscriptions\"(\"threadId\",\"connectionId\",\"nativeThreadId\",generation,channels,namespaces,coverage,\"updatedAt\") VALUES('capture-witness-t','capture-witness-c','n','g','[]','[]','{}','then')",
        "INSERT INTO public.\"protocolRunSegments\"(\"connectionId\",\"threadId\",\"identityEpochKind\",\"identityEpochId\",namespace,\"nativeRunId\",\"localTurnId\",facts,\"updatedAt\") VALUES('capture-witness-c','capture-witness-t','local','retained-epoch','[]','run','capture-witness-turn','{}','then')",
        "INSERT INTO public.\"protocolOperations\"(\"operationId\",\"connectionId\",\"threadId\",kind,\"operationThreadId\",payload,\"grantReferences\",expectations,fingerprint,status,\"createdAt\",\"updatedAt\") VALUES('op','capture-witness-c','capture-witness-t','create','native','null','[]','{}','f','settled','then','then')",
        "INSERT INTO public.\"protocolGrantSecrets\"(reference,\"connectionId\",\"threadId\",material,\"createdAt\") VALUES('secret:private-witness','capture-witness-c','capture-witness-t','ACTIVATION_PRIVATE_SENTINEL','then')",
        "INSERT INTO public.\"protocolGrants\"(\"threadId\",\"pausedGeneration\",namespace,\"interruptId\",\"proposalHash\",\"connectionId\",disposition,\"updatedAt\") VALUES('capture-witness-t','g','[]','i','h','capture-witness-c','denied','then')",
        "INSERT INTO public.\"protocolPromptAnswers\"(\"threadId\",\"pausedGeneration\",namespace,\"interruptId\",\"proposalHash\",\"connectionId\",answer,status,\"updatedAt\") VALUES('capture-witness-t','g','[]','i','h','capture-witness-c','null','draft','then')",
        "INSERT INTO public.\"protocolHistoryAnchors\"(\"threadId\",generation,anchor,\"connectionId\",coverage,revision,\"updatedAt\") VALUES('capture-witness-t','g','a','capture-witness-c','{}','r','then')",
      ]
      try Self.expectRequirement(f, .legacyOnly)
      for (table, sql) in zip(Self.privateProtocolTables, inserts) {
        try f.raw.execute(sql)
        try Self.expectRequirement(f, .protocolTwo)
        try f.raw.execute("DELETE FROM public.\(Rows.quote(table))")
        try Self.expectRequirement(f, .legacyOnly)
      }
      // Parent remains a legacy Codex row; no live AP root/owner join can explain these positives.
    }
  }

  @Test func retainedRootImagesDistinguishMissingJsonNullAndOnlyLiteralProtocolValues() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      var negatives = [
        #"{"kind":"codex"}"#,
        #"{"kind":"codex","capabilities":{"kind":"agentProtocol","agentId":"opaque"}}"#,
        #"{"kind":"codex","agentId-suffix":"opaque","PeerProfile":"agentProtocol"}"#,
        #"{"kind":"AgentProtocol"}"#,
        #"["agentId","agentProtocol"]"#,
      ]
      for column in Self.protocolColumns {
        negatives.append("{\"kind\":\"codex\",\"\(column)\":null}")
      }
      for value in negatives {
        let seq = try Self.insertLogWitness(f, table: "connections", op: "insert", value: value)
        try Self.expectRequirement(f, .legacyOnly)
        try Self.removeLogWitness(f, seq: seq)
      }
      for value in [#"{"kind":"agentProtocol"}"#]
        + Self.protocolColumns.map({ "{\"kind\":\"codex\",\"\($0)\":\"witness\"}" })
      {
        let seq = try Self.insertLogWitness(f, table: "connections", op: "insert", value: value)
        try Self.expectRequirement(f, .protocolTwo)
        try f.raw.execute("UPDATE public.changes SET synced=true WHERE seq=$1::bigint", [String(seq)])
        try Self.expectRequirement(f, .protocolTwo)
        try Self.removeLogWitness(f, seq: seq)
      }
      try Self.expectRequirement(f, .legacyOnly)
    }
  }

  @Test func retainedExplicitProtocolColumnClearsAndPrivateTableNamesRemainPositive() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      for column in Self.protocolColumns {
        for value in [nil, "null", "\"witness\""] as [String?] {
          let seq = try Self.insertLogWitness(
            f, table: "connections", op: "update", column: column, value: value)
          try Self.expectRequirement(f, .protocolTwo)
          try Self.removeLogWitness(f, seq: seq)
        }
      }
      let modernKind = try Self.insertLogWitness(
        f, table: "connections", op: "update", column: "kind", value: "\"agentProtocol\"")
      try Self.expectRequirement(f, .protocolTwo)
      try Self.removeLogWitness(f, seq: modernKind)
      for table in Self.privateProtocolTables {
        let seq = try Self.insertLogWitness(f, table: table, op: "delete", synced: true)
        try Self.expectRequirement(f, .protocolTwo)
        try Self.removeLogWitness(f, seq: seq)
      }
      for (table, column, value) in [
        ("connections", "agentId-suffix", "\"x\""), ("connections", "kind", "\"b4\""),
        ("displayItems", "payload", "{\"agentId\":\"opaque\"}"),
        ("protocolOperationsSuffix", "kind", "\"agentProtocol\""),
      ] {
        let seq = try Self.insertLogWitness(f, table: table, op: "update", column: column, value: value)
        try Self.expectRequirement(f, .legacyOnly)
        try Self.removeLogWitness(f, seq: seq)
      }
      let tombstone = try Self.insertLogWitness(f, table: "connections", op: "delete")
      try Self.expectRequirement(f, .legacyOnly)
      try Self.removeLogWitness(f, seq: tombstone)
    }
  }

  @Test func actualInsertDeleteHistoryCannotBecomeLegacyWhenTheLiveProfileIsGone() async throws {
    try await Self.withFixture { f in
      _ = try f.database.insertConnection(
        Connection(
          id: "deleted-modern", kind: .agentProtocol, label: "Modern",
          target: "https://example.invalid/agent",
          nativeScope: "native-scope", peerProfile: .agentProtocol, agentId: "agent",
          authMode: ConnectionAuthMode.none))
      try f.raw.execute("DELETE FROM public.connections WHERE id='deleted-modern'")
      let liveGone =
        try f.raw.execute("SELECT count(*) AS n FROM public.connections WHERE id='deleted-modern'").rows
        .first?.int("n") == 0
      #expect(liveGone)
      try Self.expectRequirement(f, .protocolTwo)
      try f.raw.execute("UPDATE public.changes SET synced=true WHERE \"rowId\"='deleted-modern'")
      try Self.expectRequirement(f, .protocolTwo)
    }
  }

  @Test func actualRetirementSetThenClearStillHasModernQueuedHistory() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      try f.raw.execute(
        """
        UPDATE public.connections SET "protocolRetiredAt"='then',"protocolRetiredReason"='agent_protocol_cutover'
          WHERE id='capture-witness-c';
        UPDATE public.connections SET "protocolRetiredAt"=NULL,"protocolRetiredReason"=NULL
          WHERE id='capture-witness-c';
        """)
      let cleared =
        try f.raw.execute(
          "SELECT 1 FROM public.connections WHERE id=$1 AND \"protocolRetiredAt\" IS NULL AND \"protocolRetiredReason\" IS NULL",
          [Self.witnessConnection]
        ).rows.count == 1
      #expect(cleared)
      try Self.expectRequirement(f, .protocolTwo)
    }
  }

  @Test func literalConnectionClockColumnsCountWithoutNewLegacyAncestryRules() async throws {
    try await Self.withFixture { f in
      try Self.seedLegacyWitnesses(f)
      for column in Self.protocolColumns {
        try f.raw.execute(
          "INSERT INTO public.\"columnClocks\"(\"table\",\"rowId\",\"column\",hlc) VALUES('connections','missing-live-row',$1,'000000000000-0000-local')",
          [column])
        try Self.expectRequirement(f, .protocolTwo)
        try f.raw.execute("DELETE FROM public.\"columnClocks\" WHERE \"rowId\"='missing-live-row'")
      }
      for column in ["agentIdSuffix", "PeerProfile", "title"] {
        try f.raw.execute(
          "INSERT INTO public.\"columnClocks\"(\"table\",\"rowId\",\"column\",hlc) VALUES('connections','missing-live-row',$1,'000000000000-0000-local')",
          [column])
        try Self.expectRequirement(f, .legacyOnly)
        try f.raw.execute("DELETE FROM public.\"columnClocks\" WHERE \"rowId\"='missing-live-row'")
      }
      // A legacy child update whose parent no longer exists is NOT a new classifier rejection.
      let seq = try Self.insertLogWitness(
        f, table: "threads", op: "update", column: "title", value: "\"ordinary\"")
      try Self.expectRequirement(f, .legacyOnly)
      try Self.removeLogWitness(f, seq: seq)
    }
  }

  @Test func capturedBindIsACompareAndWriteAndCannotRebindAnExistingPrincipal() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      let (ready, called, outcomes) = await Self.compete {
        try f.database.prepareProtocolVerification(expectedSnapshot: snapshot, expectedBinding: f.binding)
      }
      #expect(ready); #expect(called == 2)
      var winner: ProtocolVerificationSnapshot?, failures = 0
      for result in outcomes {
        switch result {
        case .success(let value):
          let first = winner == nil
          #expect(first)
          winner = value
        case .failure:
          failures += 1
          Self.expectSafe { _ = try result.get() }
        }
      }
      #expect(failures == 1)
      guard let bound = winner else { throw FixtureFailure.nativeShape }
      _ = try Self.expectRecord(f, revision: "1", binding: f.binding)
      let current = try Self.capture(f)
      for field in ["accountID", "hubUserID", "hubOrgID"] {
        var values = Self.expectedBinding(f.binding); values[field] = "ACTIVATION_OTHER_PRINCIPAL"
        let wrong = try Self.makeBinding(values), before = try Self.state(f)
        Self.expectSafe {
          _ = try f.database.prepareProtocolVerification(expectedSnapshot: current, expectedBinding: wrong)
        }
        try Self.expectUnchanged(f, before)
      }
      let observed = try Self.observation(f.binding)
      let (commitReady, commitCalled, committed) = await Self.compete {
        try f.database.commitObservedProtocolFact(expectedSnapshot: bound, observation: observed)
      }
      #expect(commitReady); #expect(commitCalled == 2)
      var successes = 0, stale = 0
      for result in committed {
        switch result {
        case .success: successes += 1
        case .failure: stale += 1; Self.expectSafe { _ = try result.get() }
        }
      }
      #expect(successes == 1 && stale == 1)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding, observedVersion: 2)
    }
  }

  @Test func checkedAbsentLinkReturnsItsOwnNewContextInsteadOfRecapturingOtherState() async throws {
    try await Self.withFixture { f in
      try f.database.clearHubLink()
      let capture = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
      let linked = try f.database.saveHubLink(
        f.link, membershipChange: .replace, expectedProtocolSnapshot: capture)
      _ = try Self.expectRecord(f, revision: "1", binding: nil)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: linked, expectedBinding: f.binding)
      let observed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      try f.database.fenceProtocolVerification(expectedSnapshot: observed)
      _ = try Self.expectRecord(f, revision: "4", binding: f.binding)
    }
  }

  @Test func initialCaptureActualDeferredCommitFailureCannotLeaveAnUncommittedEpoch() async throws {
    try await Self.withFixture { f in
      let before = try Self.state(f)
      try f.raw.execute(
        """
        CREATE SCHEMA activation_capture_insert_fault;
        CREATE SEQUENCE activation_capture_insert_fault.probe;
        CREATE FUNCTION activation_capture_insert_fault.refuse_initial() RETURNS trigger
          LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF NEW.value->>'revision' IS DISTINCT FROM '0' OR NEW.value ? 'binding' OR NEW.value ? 'observation'
            OR (SELECT count(*) FROM jsonb_object_keys(NEW.value)) <> 4
          THEN RAISE EXCEPTION 'ACTIVATION_INITIAL_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('activation_capture_insert_fault.probe');
          RAISE EXCEPTION 'ACTIVATION_INITIAL_PRIVATE_CANARY' USING ERRCODE='23514',DETAIL=NEW.value::text;
        END $$;
        CREATE CONSTRAINT TRIGGER activation_initial_fault AFTER INSERT ON public.settings
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN(NEW.key='__b4app_agent_protocol_activation_v1')
          EXECUTE FUNCTION activation_capture_insert_fault.refuse_initial();
        """)
      Self.expectSafe { _ = try Self.capture(f) }
      try Self.expectUnchanged(f, before)
      let probe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM activation_capture_insert_fault.probe"
      ).rows.first
      #expect(probe?.text("n") == "1" && probe?.text("called") == "true")
      try Self.expectUnchanged(f, before)
      try f.raw.execute("DROP TRIGGER activation_initial_fault ON public.settings")
      _ = try Self.capture(f)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
    }
  }

  @Test func capturedFenceRejectsDecreasedOrExhaustedChronologyWithoutChangingMembership() async throws {
    try await Self.withFixture { f in
      let bound = try Self.capturedBinding(f)
      _ = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      let snapshot = try Self.capture(f)
      var current = try Self.nativeRecord(f)
      current["revision"] = "1"
      try Self.putRecord(f, current)
      var before = try Self.state(f)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: snapshot) }
      try Self.expectUnchanged(f, before)
      current["revision"] = "9223372036854775807"
      try Self.putRecord(f, current)
      let exhausted = try Self.capture(f)
      before = try Self.state(f)
      Self.expectSafe { try f.database.fenceProtocolVerification(expectedSnapshot: exhausted) }
      try Self.expectUnchanged(f, before)
      Self.expectSafe {
        _ = try f.database.saveHubLink(
          f.link, membershipChange: .replace, expectedProtocolSnapshot: exhausted)
      }
      try Self.expectUnchanged(f, before)
    }
  }

  private static let absentInsertGate: Int64 = 0x6234_5f61_6335_6e6c
  private static let absentCandidateDevice = "ACTIVATION_ABSENT_CANDIDATE"
  private static let absentCompetitorDevice = "ACTIVATION_ABSENT_COMPETITOR"
  private struct AbsentInsertFacts: Sendable {
    let paused: Bool
    let competitorBeforeRelease: Bool
    let released: Bool
    let candidateJoined: Bool
    let competitorJoined: Bool
    let expectedRows: [String: [Data]]?
    let expectedSequence: Data?
    let controller: Result<Void, any Error>
    let candidate: Result<ProtocolVerificationSnapshot, any Error>
    let competitor: Result<Int, any Error>
  }
  private static func absentInsertController(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, candidateLink: WorkspaceDatabase.HubLink
  ) async -> AbsentInsertFacts {
    await onThread {
      let candidate = WorkerResult(), competitor = MembershipWriterResult()
      let candidateDone = DispatchSemaphore(value: 0), competitorDone = DispatchSemaphore(value: 0)
      var candidateThread: Thread?, competitorThread: Thread?
      var control: PostgresConnection?
      var ownsGate = false, paused = false, competitorBeforeRelease = false, released = false
      var competitorOperationJoined = false
      var expectedRows: [String: [Data]]?, expectedSequence: Data?
      var failure: (any Error)?
      do {
        let c = try membershipConnection(f.endpoint)
        control = c
        guard let controllerPID = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"),
          controllerPID > 0
        else { throw FixtureFailure.nativeShape }
        try c.execute("SELECT pg_advisory_lock($1::bigint)", [String(absentInsertGate)])
        ownsGate = true
        let worker = Thread {
          let outcome = Result {
            try f.database.saveHubLink(
              candidateLink, membershipChange: .replace, expectedProtocolSnapshot: snapshot)
          }
          candidate.value.withLock { $0 = outcome }
          candidateDone.signal()
        }
        candidateThread = worker; worker.start()
        let pauseDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < pauseDeadline {
          let rows = try c.execute(
            """
            SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
            WHERE a.datname=$1 AND a.application_name='b4app' AND l.locktype='advisory'
              AND NOT l.granted AND $2::int=ANY(pg_blocking_pids(a.pid))
            """, [f.endpoint.database, String(controllerPID)]
          ).rows
          let completed = ContinuousClock.now
          if completed <= pauseDeadline, rows.count == 1 { paused = true; break }
          guard completed < pauseDeadline, !candidate.value.withLock({ $0 != nil }) else { break }
          Thread.sleep(forTimeInterval: 0.005)
        }
        guard paused else { throw FixtureFailure.barrierTimeout }
        let writer = Thread {
          let outcome = Result<Int, any Error> {
            let raw = try membershipConnection(f.endpoint)
            try raw.execute("BEGIN")
            do {
              let affected = try raw.execute(
                """
                INSERT INTO public."hubLink"(id,url,"deviceId","deviceName","tokenRef","orgSlug",username,cursor,"joinedAt")
                VALUES(1,$1,$2,'competitor label','secret:competitor','competitor-org','competitor-user',41,$3)
                """, [f.link.url, absentCompetitorDevice, f.link.joinedAt]
              ).affected
              try raw.execute("COMMIT")
              return affected
            } catch {
              _ = try? raw.execute("ROLLBACK")
              throw error
            }
          }
          competitor.value.withLock { $0 = outcome }
          competitorDone.signal()
        }
        competitorThread = writer; writer.start()
        let commitDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < commitDeadline {
          if competitor.value.withLock({ $0 != nil }) {
            competitorDone.wait()  // Actual original operation has completed; no DB wait remains.
            competitorOperationJoined = true
            competitorBeforeRelease = ContinuousClock.now <= commitDeadline
            break
          }
          Thread.sleep(forTimeInterval: 0.005)
        }
        if competitorBeforeRelease, let outcome = competitor.value.withLock({ $0 }),
          case .success(let count) = outcome, count == 1
        {
          // Raw connection is scoped to the finished competitor. Native reads see its full committed
          // row and OLD committed control, while candidate may hold uncommitted control changes.
          let expected = try state(f)
          expectedRows = expected.rows; expectedSequence = expected.sequence
        }
      } catch { failure = error }
      // Gate release/lexical close always precedes BOTH original work joins, even on failed stage.
      if ownsGate {
        do {
          guard let c = control,
            try c.execute("SELECT pg_advisory_unlock($1::bigint) AS released", [String(absentInsertGate)])
              .rows.first?.text("released") == "t"
          else { throw FixtureFailure.nativeShape }
          released = true
        } catch { if failure == nil { failure = error } }
      }
      control = nil
      var candidateJoined = false, competitorJoined = false
      withExtendedLifetime((candidateThread, competitorThread)) {
        if candidateThread != nil { candidateDone.wait(); candidateJoined = true }
        // A prior on-time join consumed this semaphore; otherwise release first, THEN join.
        if competitorThread != nil {
          if !competitorOperationJoined { competitorDone.wait() }
          competitorJoined = true
        }
      }
      let controller: Result<Void, any Error> = failure.map { .failure($0) } ?? .success(())
      return AbsentInsertFacts(
        paused: paused, competitorBeforeRelease: competitorBeforeRelease, released: released,
        candidateJoined: candidateJoined, competitorJoined: competitorJoined,
        expectedRows: expectedRows, expectedSequence: expectedSequence, controller: controller,
        candidate: candidate.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape),
        competitor: competitor.value.withLock { $0 } ?? .failure(FixtureFailure.nativeShape))
    }
  }

  @Test func checkedAbsentLinkNativeInsertRaceRefusesWithoutOverwritingCompetitor() async throws {
    try await Self.withFixture { f in
      try f.database.clearHubLink()
      let snapshot = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
      var link = f.link; link.deviceId = Self.absentCandidateDevice
      let cleanup =
        "DROP TRIGGER IF EXISTS activation_absent_pause ON public.\"hubLink\"; DROP SCHEMA IF EXISTS activation_absent_race CASCADE;"
      var cleaned = false
      defer { if !cleaned { _ = try? f.raw.execute(cleanup) } }
      try f.raw.execute(
        """
        CREATE SCHEMA activation_absent_race;
        CREATE SEQUENCE activation_absent_race.probe;
        CREATE FUNCTION activation_absent_race.pause_candidate() RETURNS trigger
          LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF EXISTS(SELECT 1 FROM public."hubLink" WHERE id=1)
          THEN RAISE EXCEPTION 'ACTIVATION_ABSENCE_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('activation_absent_race.probe');
          PERFORM pg_advisory_xact_lock(\(Self.absentInsertGate)::bigint);
          RETURN NEW;
        END $$;
        CREATE TRIGGER activation_absent_pause BEFORE INSERT ON public."hubLink"
          FOR EACH ROW WHEN(NEW."deviceId"='ACTIVATION_ABSENT_CANDIDATE')
          EXECUTE FUNCTION activation_absent_race.pause_candidate();
        """)
      let facts = await Self.absentInsertController(f, snapshot: snapshot, candidateLink: link)
      // No Issue/#expect/#require on raw workers; all stage checks follow actual joins here.
      #expect(facts.paused); #expect(facts.competitorBeforeRelease)
      #expect(facts.released && facts.candidateJoined && facts.competitorJoined)
      try facts.controller.get()
      let competitorAffected = try facts.competitor.get()
      #expect(competitorAffected == 1)
      guard let rows = facts.expectedRows, let sequence = facts.expectedSequence else {
        throw FixtureFailure.nativeShape
      }
      Self.expectSafe { _ = try facts.candidate.get() }
      try Self.expectUnchanged(f, NativeState(rows: rows, sequence: sequence))
      let probe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM activation_absent_race.probe"
      ).rows.first
      #expect(probe?.text("n") == "1" && probe?.text("called") == "true")
      let competitor = try f.database.hubLink()
      let competitorDevice =
        competitor.map { Self.equalBytes($0.deviceId, Self.absentCompetitorDevice) } ?? false
      #expect(competitorDevice)
      #expect(competitor?.cursor == 41)
      try f.raw.execute(cleanup); cleaned = true
    }
  }
  @Test func captureRefusesMalformedClosedDestinationBeforeIssuingContext() async throws {
    try await Self.withFixture { f in
      _ = try Self.capture(f)
      let valid = try Self.nativeRecord(f)
      var variants: [[String: Any]] = []
      var bad = valid; bad["unknown"] = true; variants.append(bad)
      bad = valid; bad["binding"] = NSNull(); variants.append(bad)
      bad = valid; bad["revision"] = 0; variants.append(bad)
      bad = valid; bad["storeIncarnation"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; variants.append(bad)
      for value in variants {
        try Self.putRecord(f, value)
        let before = try Self.state(f)
        Self.expectSafe { _ = try Self.capture(f) }
        try Self.expectUnchanged(f, before)
      }
    }
  }

}

// Read-only comparison surfaces only. Success returns Void, never authority, a lease or a new stamp.
extension ProtocolActivationStoreTests {
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
  /// Independent native fixture interposition, deliberately WITHOUT rotating the control row.
  private static func insertReadOnlyFixtureLink(_ f: Fixture) throws {
    try f.raw.execute(
      """
      INSERT INTO public."hubLink"(id,url,"deviceId","deviceName","tokenRef","orgSlug",username,cursor,"joinedAt")
      VALUES(1,$1,$2,$3,$4,$5,$6,0,$7)
      """,
      [
        f.link.url, f.link.deviceId, f.link.deviceName, f.link.tokenRef, f.link.orgSlug, f.link.username,
        f.link.joinedAt,
      ])
  }
  private static func seedReadOnlyModernProfile(_ f: Fixture) throws {
    _ = try f.database.insertConnection(
      Connection(
        id: "readonly-modern", kind: .agentProtocol, label: "Stored modern profile",
        target: "https://example.invalid/agent", nativeScope: "native-readonly",
        peerProfile: .agentProtocol, agentId: "agent", authMode: ConnectionAuthMode.none))
  }

  @Test func readOnlyValidationSeparatesLinkedLegacyAndAbsentProspectiveProof() async throws {
    try await Self.withFixture { f in
      let linked = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: linked, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: linked, sync: true)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
      try f.database.clearHubLink()
      let absent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: true, refuses: true)
      _ = try Self.expectRecord(f, revision: "1", binding: nil)
      try Self.insertReadOnlyFixtureLink(f)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: true, refuses: true)
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      try Self.expectReadOnlyValidation(f, snapshot: absent, sync: false)
      let ownTransition = try f.database.saveHubLink(
        f.link, membershipChange: .replace, expectedProtocolSnapshot: absent)
      try Self.expectReadOnlyValidation(f, snapshot: ownTransition, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: ownTransition, sync: true)
      _ = try Self.expectRecord(f, revision: "2", binding: nil)
    }
  }

  @Test func modernInactiveCanFetchVerificationButCannotValidateOrdinarySync() async throws {
    try await Self.withFixture { f in
      try Self.seedReadOnlyModernProfile(f)
      let inactive = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true, refuses: true)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: inactive, expectedBinding: f.binding)
      try Self.expectReadOnlyValidation(f, snapshot: bound, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: bound, sync: true, refuses: true)
      _ = try Self.expectRecord(f, revision: "1", binding: f.binding)
      let observed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding, version: 3))
      try Self.expectReadOnlyValidation(f, snapshot: observed, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: observed, sync: true)
      _ = try Self.expectRecord(f, revision: "2", binding: f.binding, observedVersion: 3)
    }
  }

  @Test func readOnlyValidatorsAllowInt64MaxAndSameTupleMetadataRefreshWithoutRewriting() async throws {
    try await Self.withFixture { f in
      try Self.seedReadOnlyModernProfile(f)
      let bound = try Self.capturedBinding(f)
      _ = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      var record = try Self.nativeRecord(f)
      record["revision"] = "9223372036854775807"
      try Self.putRecord(f, record)
      let maximum = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: maximum, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: maximum, sync: true)
      var refresh = f.link
      refresh.url += "/"; refresh.tokenRef = "secret:readonly-token-refresh"
      refresh.deviceName = "new label"; refresh.orgSlug = "not-principal-proof-new"
      refresh.username = "not-principal-proof-new"; refresh.lastError = "new status"; refresh.cursor = 999
      try f.database.saveHubLink(refresh)
      // Native comparison ignores token/label/status refresh. Actual owner/credential checks are
      // REQUIRED future work; these Void data checks cannot authenticate that changed token.
      try Self.expectReadOnlyValidation(f, snapshot: maximum, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: maximum, sync: true)
      _ = try Self.expectRecord(f, revision: "9223372036854775807", binding: f.binding, observedVersion: 2)
    }
  }

  @Test func readOnlyValidatorsRejectEveryStalePositiveAndNegativeRevisionWithoutAdoption() async throws {
    try await Self.withFixture { f in
      try Self.seedReadOnlyModernProfile(f)
      let zero = try Self.capture(f)
      let one = try f.database.prepareProtocolVerification(expectedSnapshot: zero, expectedBinding: f.binding)
      try Self.expectReadOnlyValidation(f, snapshot: zero, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: zero, sync: true, refuses: true)
      let two = try f.database.commitObservedProtocolFact(
        expectedSnapshot: one, observation: Self.observation(f.binding))
      try Self.expectReadOnlyValidation(f, snapshot: one, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: one, sync: true, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: true)
      // Each replacement is valid closed data at the SAME revision: decoding, native
      // membership and a revision-only comparison cannot detect these stale snapshots.
      let validTwo = try Self.nativeRecord(f)
      for field in ["storeIncarnation", "membershipIncarnation"] {
        let replacement = UUID().uuidString
        let original = try #require(validTwo[field] as? String)
        let differs = Data(replacement.utf8) != Data(original.utf8)
        try #require(differs)
        var changed = validTwo
        changed[field] = replacement
        try Self.putRecord(f, changed)
        try Self.expectReadOnlyValidation(f, snapshot: two, sync: false, refuses: true)
        try Self.expectReadOnlyValidation(f, snapshot: two, sync: true, refuses: true)
        try Self.putRecord(f, validTwo)
        try Self.expectReadOnlyValidation(f, snapshot: two, sync: false)
        try Self.expectReadOnlyValidation(f, snapshot: two, sync: true)
      }
      var changedObservation = validTwo
      var observation = try #require(validTwo["observation"] as? [String: Any])
      observation["reportedVersion"] = 3
      changedObservation["observation"] = observation
      try Self.putRecord(f, changedObservation)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: true, refuses: true)
      try Self.putRecord(f, validTwo)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: true)
      let three = try f.database.commitObservedProtocolFact(
        expectedSnapshot: two, observation: Self.observation(f.binding, version: 3))
      // Even another healthy observation makes the old full-record comparison stale.
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: two, sync: true, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: three, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: three, sync: true)
      try f.database.fenceProtocolVerification(expectedSnapshot: three)
      try Self.expectReadOnlyValidation(f, snapshot: three, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: three, sync: true, refuses: true)
      let withdrawn = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: withdrawn, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: withdrawn, sync: true, refuses: true)
      _ = try Self.expectRecord(f, revision: "4", binding: f.binding)
    }
  }

  @Test func readOnlyValidatorsDoNotAdoptSameLookingReplaceClearOrSuccessfulRestore() async throws {
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

  @Test func readOnlyValidatorsRefuseContextlessDirectSnapshotsEvenWithMatchingHealthyRecord() async throws {
    try await Self.withFixture { f in
      let direct = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let directCommitted = try f.database.commitObservedProtocolFact(
        expectedSnapshot: direct, observation: Self.observation(f.binding))
      guard let directRead = try f.database.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      for snapshot in [direct, directCommitted, directRead] {
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true)
      }
      let genuinelyCaptured = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: genuinelyCaptured, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: genuinelyCaptured, sync: true)
    }
  }

  @Test func readOnlyValidatorsRequireTheirActualLiveDatabaseObjectNotItsName() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      let other = try f.reopen()
      defer { try? other.close() }
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true, database: other)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true, database: other)
      let otherSnapshot = try other.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: Self.nativeMembership(f.link))
      try Self.expectReadOnlyValidation(f, snapshot: otherSnapshot, sync: false, database: other)
      try Self.expectReadOnlyValidation(f, snapshot: otherSnapshot, sync: true, database: other)
      try other.close()
      try Self.expectReadOnlyValidation(
        f, snapshot: otherSnapshot, sync: false, refuses: true, database: other)
      try Self.expectReadOnlyValidation(
        f, snapshot: otherSnapshot, sync: true, refuses: true, database: other)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
    }
  }

  @Test func readOnlyValidatorsRefuseMalformedControlAndNativeMismatchWithReadOnlyRecovery() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      let valid = try Self.nativeRecord(f)
      var variants: [[String: Any]] = []
      var invalid = valid; invalid["unknown"] = true; variants.append(invalid)
      invalid = valid; invalid["binding"] = NSNull(); variants.append(invalid)
      invalid = valid; invalid["revision"] = 0; variants.append(invalid)
      invalid = valid; invalid["membershipIncarnation"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      variants.append(invalid)
      for record in variants {
        try Self.putRecord(f, record)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true)
        try Self.putRecord(f, valid)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      }
      try f.raw.execute("DELETE FROM public.settings WHERE key=$1", [Self.key])
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true)
      try Self.putRecord(f, valid)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      for (column, value) in [
        ("url", "https://user@example.invalid/Deployment"), ("url", "https://example.invalid/Other"),
        ("deviceId", "ACTIVATION_NATIVE_MISMATCH"), ("joinedAt", "ACTIVATION_OTHER_STAMP"),
      ] {
        try f.raw.execute("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1", [value])
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true)
        let original =
          column == "url" ? f.link.url : (column == "deviceId" ? f.link.deviceId : f.link.joinedAt)
        try f.raw.execute("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1", [original])
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      }
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false, refuses: true)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true, refuses: true)
      try Self.insertReadOnlyFixtureLink(f)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: false)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
    }
  }
}

extension ProtocolActivationStoreTests {
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

  @Test func guardedMarkChangesOnlyAcceptedPrefixForLegacyAndHealthyModernStores() async throws {
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

  @Test func guardedMarkNoOpStillRefusesModernInactiveAndSameRevisionStaleFacts() async throws {
    try await Self.withFixture { f in
      _ = try Self.guardMarkPrefix(f)
      try f.raw.execute("DELETE FROM public.changes")
      var inactive = try Self.capture(f)
      try Self.expectGuardMark(f, through: Int.max, snapshot: inactive)
      try f.database.clearHubLink()
      let absent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      try Self.expectRequirement(f, .legacyOnly)
      let stillEmpty = try f.raw.execute("SELECT count(*) AS n FROM public.changes").rows.first?.int("n") == 0
      try #require(stillEmpty)
      try Self.expectGuardMark(f, through: Int.max, snapshot: absent, refuses: true)
      inactive = try f.database.saveHubLink(
        f.link, membershipChange: .replace, expectedProtocolSnapshot: absent)
      try Self.seedReadOnlyModernProfile(f)
      try f.raw.execute("DELETE FROM public.changes")
      try Self.expectRequirement(f, .protocolTwo)
      try Self.expectGuardMark(f, through: Int.max, snapshot: inactive, refuses: true)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: inactive, expectedBinding: f.binding)
      try Self.expectGuardMark(f, through: Int.max, snapshot: bound, refuses: true)
      let healthy = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      let valid = try Self.nativeRecord(f)
      var stale = valid
      var observed = try #require(valid["observation"] as? [String: Any])
      observed["reportedVersion"] = 3  // Valid healthy closed record, SAME revision and member.
      stale["observation"] = observed
      try Self.putRecord(f, stale)
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy, refuses: true)
      try Self.putRecord(f, valid)
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy)
      try f.database.fenceProtocolVerification(expectedSnapshot: healthy)
      try Self.expectGuardMark(f, through: Int.max, snapshot: healthy, refuses: true)
    }
  }

  private struct GuardMarkWriterFacts: Sendable {
    let ready: Bool, exclusiveBlocked: Bool, released: Bool, writerJoined: Bool, markJoined: Bool
    let expectedRows: [String: [Data]]?, expectedSequence: Data?
    let controller: Result<Void, any Error>, writer: Result<Void, any Error>, mark: Result<Void, any Error>
  }
  private static func guardMarkWriterRace(
    _ f: Fixture, through: Int, snapshot: ProtocolVerificationSnapshot
  ) async -> GuardMarkWriterFacts {
    let controllerThread = Mutex<Thread?>(nil)
    let facts: GuardMarkWriterFacts = await withCheckedContinuation { continuation in
      controllerThread.withLock { retained in
        retained = Thread {
          let writerThread = Mutex<Thread?>(nil), markThread = Mutex<Thread?>(nil)
          let writerResult = Mutex<Result<Void, any Error>?>(nil),
            markResult = Mutex<Result<Void, any Error>?>(nil)
          let writerPID = Mutex<Int?>(nil)
          let expectedRows = Mutex<[String: [Data]]?>(nil), expectedSequence = Mutex<Data?>(nil)
          let release = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0),
            markDone = DispatchSemaphore(value: 0)
          var ready = false, exclusiveBlocked = false, markStarted = false
          var failure: (any Error)?
          writerThread.withLock { thread in
            thread = Thread {
              let outcome = Result<Void, any Error> {
                // REAL normal framework writer, shared remoteApply key, marker consumes NO business sequence.
                try f.database.write { c in
                  guard let pid = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"),
                    pid > 0
                  else { throw FixtureFailure.nativeShape }
                  writerPID.withLock { $0 = pid }
                  try c.execute(
                    "INSERT INTO public.\"columnClocks\"(\"table\",\"rowId\",\"column\",hlc) VALUES('connections','guard-mark-writer','authMode','000000000000-0000-local')"
                  )
                  let own = Fixture(
                    database: f.database, raw: c, endpoint: f.endpoint, root: f.root, link: f.link,
                    binding: f.binding)
                  // Own transaction sees its committed-intent marker BEFORE candidate can act.
                  let expected = try Self.state(own)
                  expectedRows.withLock { $0 = expected.rows }
                  expectedSequence.withLock { $0 = expected.sequence }
                  guard release.wait(timeout: .now() + .seconds(8)) == .success else {
                    throw FixtureFailure.barrierTimeout
                  }
                }
              }
              writerResult.withLock { $0 = outcome }; writerDone.signal()
            }
            thread?.start()
          }
          do {
            let c = try Self.membershipConnection(f.endpoint)
            let readyDeadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < readyDeadline {
              if expectedRows.withLock({ $0 != nil }) { ready = ContinuousClock.now <= readyDeadline; break }
              if writerResult.withLock({ $0 != nil }) { break }
              Thread.sleep(forTimeInterval: 0.005)
            }
            guard ready, let pid = writerPID.withLock({ $0 }) else { throw FixtureFailure.barrierTimeout }
            markThread.withLock { thread in
              thread = Thread {
                let outcome = Result<Void, any Error> {
                  try f.database.markSynced(through: through, expectedProtocolSnapshot: snapshot)
                }
                markResult.withLock { $0 = outcome }; markDone.signal()
              }
              thread?.start()
            }
            markStarted = true
            let waitDeadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < waitDeadline {
              let rows = try c.execute(
                """
                SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
                WHERE a.datname=$1 AND a.application_name='b4app' AND l.locktype='advisory'
                  AND l.mode='ExclusiveLock' AND NOT l.granted AND l.classid=0::oid
                  AND l.objid=$3::oid AND l.objsubid=1 AND $2::int=ANY(pg_blocking_pids(a.pid))
                """, [f.endpoint.database, String(pid), String(0x6234_6170)]
              ).rows
              let completed = ContinuousClock.now
              if completed <= waitDeadline, rows.count == 1 { exclusiveBlocked = true; break }
              guard completed < waitDeadline, !markResult.withLock({ $0 != nil }) else { break }
              Thread.sleep(forTimeInterval: 0.005)
            }
          } catch { failure = error }
          // Observer/controller handles close lexically before releases/joins. Always release writer,
          // then join BOTH actual operations even if stage observation failed; no Thread exit claim.
          release.signal()
          writerDone.wait()
          if markStarted { markDone.wait() }
          writerThread.withLock { $0 = nil }; markThread.withLock { $0 = nil }
          continuation.resume(
            returning: GuardMarkWriterFacts(
              ready: ready, exclusiveBlocked: exclusiveBlocked, released: true, writerJoined: true,
              markJoined: markStarted,
              expectedRows: expectedRows.withLock { $0 }, expectedSequence: expectedSequence.withLock { $0 },
              controller: failure.map { .failure($0) } ?? .success(()),
              writer: writerResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape),
              mark: markResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape)))
        }
        retained?.start()
      }
    }
    controllerThread.withLock { $0 = nil }
    return facts
  }
  private static func expectGuardMarkWriterRace(
    _ f: Fixture, through: Int, snapshot: ProtocolVerificationSnapshot
  ) async throws {
    try expectRequirement(f, .legacyOnly)
    try expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
    let facts = await guardMarkWriterRace(f, through: through, snapshot: snapshot)
    #expect(facts.ready && facts.exclusiveBlocked && facts.released && facts.writerJoined && facts.markJoined)
    try facts.controller.get(); try facts.writer.get()
    expectSafe { try facts.mark.get() }
    guard let rows = facts.expectedRows, let sequence = facts.expectedSequence else {
      throw FixtureFailure.nativeShape
    }
    let onlyCommittedWriter = try state(f) == NativeState(rows: rows, sequence: sequence)
    #expect(onlyCommittedWriter)
    try expectRequirement(f, .protocolTwo)
  }
  @Test func guardedMarkWaitsForParticipatingSharedWriterThenRefusesItsModernMarker() async throws {
    try await Self.withFixture { f in
      let prefix = try Self.guardMarkPrefix(f)
      try await Self.expectGuardMarkWriterRace(f, through: prefix.through, snapshot: Self.capture(f))
    }
  }

  private static func withGuardMarkRepeatableRead(
    _ f: Fixture, _ body: @Sendable (Fixture) async throws -> Void
  ) async throws {
    let overrides = try f.raw.execute(
      "SELECT 1 FROM pg_db_role_setting s,unnest(s.setconfig) AS k(value) WHERE s.setdatabase=(SELECT oid FROM pg_database WHERE datname=$1) AND s.setrole=0 AND k.value LIKE 'default_transaction_isolation=%'",
      [f.endpoint.database]
    ).rows
    guard overrides.isEmpty else { throw FixtureFailure.nativeShape }
    try f.database.close()
    try f.raw.execute(
      "ALTER DATABASE \(Rows.quote(f.endpoint.database)) SET default_transaction_isolation='repeatable read'")
    var current: WorkspaceDatabase?, failure: (any Error)?
    do {
      let fresh = try f.reopen(); current = fresh
      let owned = Fixture(
        database: fresh, raw: f.raw, endpoint: f.endpoint, root: f.root, link: f.link, binding: f.binding)
      try await body(owned)
    } catch { failure = Self.unexpectedError(error) }
    do { try current?.close() } catch {
      if failure == nil {
        failure = Self.unexpectedError(error)
      } else {
        Issue.record("The owned isolation fixture close also failed; private details suppressed.")
      }
    }
    do {
      try f.raw.execute(
        "ALTER DATABASE \(Rows.quote(f.endpoint.database)) RESET default_transaction_isolation")
    } catch {
      if failure == nil {
        failure = Self.unexpectedError(error)
      } else {
        Issue.record("The owned isolation fixture reset also failed; private details suppressed.")
      }
    }
    if let failure { throw failure }
  }
  @Test func guardedMarkSelectsReadCommittedWhileOldMarkRetainsInheritedRepeatableRead() async throws {
    try await Self.withFixture { original in
      let prefix = try Self.guardMarkPrefix(original)
      try original.raw.execute(
        """
        CREATE SCHEMA guard_mark_isolation;
        CREATE TABLE guard_mark_isolation.observed(value text NOT NULL);
        CREATE FUNCTION guard_mark_isolation.record_isolation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO guard_mark_isolation.observed VALUES(current_setting('transaction_isolation'));
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_mark_isolation AFTER UPDATE ON public.changes FOR EACH ROW
          WHEN(NOT OLD.synced AND NEW.synced) EXECUTE FUNCTION guard_mark_isolation.record_isolation();
        """)
      try await Self.withGuardMarkRepeatableRead(original) { f in
        let inactive = try Self.capture(f)  // Snapshot belongs to this actual FRESH object.
        let oldCount = try #require(
          f.raw.execute(
            "SELECT count(*) AS n FROM public.changes WHERE seq <= $1::bigint AND NOT synced",
            [String(prefix.through)]
          ).rows.first?.int("n"))
        try #require(oldCount > 0)
        let expectedOld = try Self.expectedGuardMark(f, through: prefix.through)
        let oldOutcome = Result { try f.database.markSynced(through: prefix.through) }
        let oldExact = try Self.state(f) == expectedOld
        #expect(oldExact); try oldOutcome.get()
        let oldIsolation = try f.raw.execute(
          "SELECT count(*) AS n,bool_and(value='repeatable read')::text AS correct FROM guard_mark_isolation.observed"
        ).rows.first
        #expect(oldIsolation?.int("n") == oldCount && oldIsolation?.text("correct") == "true")
        try f.raw.execute("DELETE FROM guard_mark_isolation.observed")
        let guardedCount = try #require(
          f.raw.execute(
            "SELECT count(*) AS n FROM public.changes WHERE seq <= $1::bigint AND NOT synced",
            [String(prefix.later)]
          ).rows.first?.int("n"))
        try #require(guardedCount > 0)
        try Self.expectGuardMark(f, through: prefix.later, snapshot: inactive)
        let guardedIsolation = try f.raw.execute(
          "SELECT count(*) AS n,bool_and(value='read committed')::text AS correct FROM guard_mark_isolation.observed"
        ).rows.first
        #expect(guardedIsolation?.int("n") == guardedCount && guardedIsolation?.text("correct") == "true")
      }
    }
  }
  @Test func guardedMarkSeesPrecedingWriterUnderInheritedRepeatableReadWithoutRowConflict() async throws {
    try await Self.withFixture { original in
      let prefix = try Self.guardMarkPrefix(original)
      try await Self.withGuardMarkRepeatableRead(original) { f in
        try await Self.expectGuardMarkWriterRace(f, through: prefix.through, snapshot: Self.capture(f))
      }
    }
  }

  @Test func guardedMarkPostcheckRollsBackBodyMarkerAndSameTriggerHealthyControlSucceeds() async throws {
    try await Self.withFixture { f in
      let prefix = try Self.guardMarkPrefix(f)
      let inactive = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_mark_post;
        CREATE SEQUENCE guard_mark_post.probe;
        CREATE FUNCTION guard_mark_post.add_marker() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO public."columnClocks"("table","rowId","column",hlc)
            VALUES('connections','guard-mark-post','authMode','000000000000-0000-local');
          PERFORM nextval('guard_mark_post.probe');
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_mark_post AFTER UPDATE ON public.changes FOR EACH ROW
          WHEN(NOT OLD.synced AND NEW.synced AND NEW.seq=\(prefix.through)) EXECUTE FUNCTION guard_mark_post.add_marker();
        """)
      try Self.expectGuardMark(f, through: prefix.through, snapshot: inactive, refuses: true)
      let failedProbe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM guard_mark_post.probe"
      ).rows.first
      #expect(failedProbe?.text("n") == "1" && failedProbe?.text("called") == "true")
      try Self.expectRequirement(f, .legacyOnly)
      let healthy = try Self.healthyGuardMarkSnapshot(f)
      let expectedPrefix = try Self.expectedGuardMark(f, through: prefix.through)
      var rows = expectedPrefix.rows
      let clock = try #require(
        f.raw.execute(
          "SELECT jsonb_build_object('table','connections','rowId','guard-mark-post','column','authMode','hlc','000000000000-0000-local')::text AS value"
        ).rows.first?.text("value"))
      rows["columnClocks", default: []].append(Data(clock.utf8))
      rows["columnClocks"]?.sort { $0.lexicographicallyPrecedes($1) }
      let outcome = Result {
        try f.database.markSynced(through: prefix.through, expectedProtocolSnapshot: healthy)
      }
      let exact = try Self.state(f) == NativeState(rows: rows, sequence: expectedPrefix.sequence)
      #expect(exact); try outcome.get()
      let positiveProbe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM guard_mark_post.probe"
      ).rows.first
      #expect(positiveProbe?.text("n") == "2" && positiveProbe?.text("called") == "true")
      try Self.expectRequirement(f, .protocolTwo)
    }
  }

  @Test func guardedMarkActualDeferredCommitFailureIsSafeRollsBackAndRecovers() async throws {
    try await Self.withFixture { f in
      let prefix = try Self.guardMarkPrefix(f)
      let inactive = try Self.capture(f)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_mark_commit;
        CREATE SEQUENCE guard_mark_commit.probe;
        CREATE TABLE guard_mark_commit.expected AS SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1';
        CREATE FUNCTION guard_mark_commit.refuse_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF NOT NEW.synced OR NOT EXISTS(SELECT 1 FROM public.changes WHERE seq=NEW.seq AND synced)
            OR (SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1')
              IS DISTINCT FROM (SELECT value FROM guard_mark_commit.expected)
          THEN RAISE EXCEPTION 'ACTIVATION_GUARDED_MARK_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('guard_mark_commit.probe');
          RAISE EXCEPTION 'ACTIVATION_GUARDED_MARK_PRIVATE_CANARY' USING ERRCODE='23514',DETAIL='ACTIVATION_GUARDED_MARK_SECRET';
        END $$;
        CREATE CONSTRAINT TRIGGER guard_mark_commit AFTER UPDATE ON public.changes DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW WHEN(NOT OLD.synced AND NEW.synced AND NEW.seq=\(prefix.through)) EXECUTE FUNCTION guard_mark_commit.refuse_commit();
        """)
      let beforeNative = try Self.state(f)
      var knownNativeConstraint = false, nativeUpdateReturned = false, nativeCommitAttempted = false
      do {
        try f.raw.execute("BEGIN")
        try f.raw.execute(
          "UPDATE public.changes SET synced=true WHERE seq <= $1::bigint AND NOT synced",
          [String(prefix.through)])
        nativeUpdateReturned = true
        nativeCommitAttempted = true
        try f.raw.execute("COMMIT")
      } catch {
        knownNativeConstraint = (error as? PostgresError)?.sqlState == "23514"
        _ = try? f.raw.execute("ROLLBACK")
      }
      try Self.expectUnchanged(f, beforeNative)
      try #require(knownNativeConstraint && nativeUpdateReturned && nativeCommitAttempted)
      let nativeProbe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM guard_mark_commit.probe"
      ).rows.first
      #expect(nativeProbe?.text("n") == "1" && nativeProbe?.text("called") == "true")
      try Self.expectGuardMark(f, through: prefix.through, snapshot: inactive, refuses: true)
      let guardedProbe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM guard_mark_commit.probe"
      ).rows.first
      #expect(guardedProbe?.text("n") == "2" && guardedProbe?.text("called") == "true")
      // The SAME deferred fault was enabled throughout the targeted call; remove only for recovery.
      try f.raw.execute("DROP TRIGGER guard_mark_commit ON public.changes")
      try Self.expectGuardMark(f, through: prefix.through, snapshot: inactive)
      let recoveredProbe = try f.raw.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM guard_mark_commit.probe"
      ).rows.first
      #expect(recoveredProbe?.text("n") == "2" && recoveredProbe?.text("called") == "true")
    }
  }
}

// Source-first guarded-apply contract. These tests require the mandatory-snapshot overload;
// source review alone is neither a semantic RED nor compilation/native-execution evidence.
extension ProtocolActivationStoreTests {
  private static let applyStamp = "000000000100-0000-guard-phone"
  private static let applyOldStamp = "000000000010-0000-guard-phone"
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

  @Test func guardedApplyPreservesLegacyAndHealthyModernMergeEmptyAndSkippedSemantics() async throws {
    for modern in [false, true] {
      try await Self.withFixture { f in
        try Self.seedGuardApply(f)
        if modern { try Self.seedReadOnlyModernProfile(f) }
        let snapshot = try (modern ? Self.healthyGuardMarkSnapshot(f) : Self.capture(f))
        try Self.expectRequirement(f, modern ? .protocolTwo : .legacyOnly)
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
        let batch: [RemoteChange] = [
          Self.guardApplyChange("threads", "guard-thread", "title", .string(Self.applyTitle)),
          Self.guardApplyChange("environments", "guard-environment", "name", "After environment"),
          Self.guardApplyChange("drafts", "guard-thread", "text", "After draft"),
          // Another Mac may write view settings, while its thread edits remain skipped.
          Self.guardApplyChange("viewSettings", "view", "quietThreads", "tiny", device: "guard-other-mac"),
          Self.guardApplyChange("threads", "guard-thread", "title", "Own echo", device: f.link.deviceId),
          Self.guardApplyChange("threads", "guard-thread", "title", "Invalid clock", at: "invalid"),
          Self.guardApplyChange("threads", "guard-thread", "context", "/hub/filtered/context"),
          Self.guardApplyChange("threads", "guard-missing", "title", "Missing row"),
          Self.guardApplyChange("threads", "guard-thread", "title", "Older title", at: Self.applyOldStamp),
          // Ordinary boolean input syntax error (22P02) must skip only this change.
          Self.guardApplyChange("threads", "guard-thread", "archived", "not-a-boolean"),
          Self.guardApplyChange("threads", "guard-thread", "title", "Other Mac", device: "guard-other-mac"),
        ]
        let before = try Self.state(f)
        let expected = try Self.expectedGuardApply(
          f, before: before, cursor: 301,
          edits: [
            ("threads", "id", "guard-thread", ["title": Self.applyTitle]),
            ("environments", "id", "guard-environment", ["name": "After environment"]),
            ("drafts", "threadId", "guard-thread", ["text": "After draft"]),
            ("viewSettings", "id", "view", ["quietThreads": "tiny"]),
          ],
          clocks: [
            ("threads", "guard-thread", "title", Self.applyStamp),
            ("environments", "guard-environment", "name", Self.applyStamp),
            ("drafts", "guard-thread", "text", Self.applyStamp),
            ("viewSettings", "view", "quietThreads", Self.applyStamp),
          ])
        try Self.expectGuardApply(
          f, changes: batch, cursor: 301, snapshot: snapshot, expected: expected,
          result: RemoteApplied(
            touchedThreadIds: ["guard-thread"], touchedEnvironmentIds: ["guard-environment"],
            touchedDraftThreadIds: ["guard-thread"], touchedViewSettings: true, applied: 4, skipped: 7))
        let repeatedBefore = try Self.state(f)
        try Self.expectGuardApply(
          f, changes: batch, cursor: 302, snapshot: snapshot,
          expected: Self.expectedGuardApply(f, before: repeatedBefore, cursor: 302),
          result: RemoteApplied(skipped: 11))
        let emptyBefore = try Self.state(f)
        try Self.expectGuardApply(
          f, changes: [], cursor: 303, snapshot: snapshot,
          expected: Self.expectedGuardApply(f, before: emptyBefore, cursor: 303), result: RemoteApplied())
      }
    }
  }

  @Test func guardedApplyRefusesStaleOrAbsentSnapshotsBeforeReceivedClockObservation() async throws {
    try await Self.withFixture { original in
      // This fresh actual object has a controlled wall, through the EXISTING initializer only.
      let controlled = try WorkspaceDatabase(
        endpoint: original.endpoint, binDir: original.endpoint.binDir!,
        createIfMissing: false, backupDirectory: original.root + "/backups", wall: { 42 })
      defer { try? controlled.close() }
      let f = Fixture(
        database: controlled, raw: original.raw, endpoint: original.endpoint,
        root: original.root, link: original.link, binding: original.binding)
      try Self.seedGuardApply(f)
      try Self.seedReadOnlyModernProfile(f)
      func refuseBoth(_ candidate: ProtocolVerificationSnapshot, on database: WorkspaceDatabase? = nil) throws
      {
        for mutating in [false, true] {
          let capturedWall = epochMillis()
          let received = HLC(millis: capturedWall + 120_000, counter: 19, deviceId: "guard-phone")
          let changes =
            mutating
            ? [
              Self.guardApplyChange(
                "threads", "guard-thread", "title", "Refused future title", at: received.rawValue)
            ] : []
          let wallBefore = epochMillis()
          try #require(received.millis > wallBefore && received.millis - wallBefore < HLC.maxAheadMillis)
          try #require(received.clamped(toWall: wallBefore) == received)
          let clockDatabase = database ?? controlled
          let clockBefore = clockDatabase.clock.next()
          try Self.expectGuardApplyRefusal(
            f, changes: changes, cursor: 399, snapshot: candidate, database: database)
          let clockAfter = clockDatabase.clock.next()
          let wallAfter = epochMillis()
          try #require(wallAfter < received.millis)
          // A received observation would jump to received.millis. write.next() may advance the
          // enclosing transaction's counter, which is deliberately NOT claimed to roll back.
          #expect(clockAfter.millis < received.millis && clockAfter > clockBefore)
        }
      }
      let inactive = try Self.capture(f)
      try refuseBoth(inactive)  // Modern graph, inactive/unbound control.
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: inactive, expectedBinding: f.binding)
      try refuseBoth(bound)  // Bound without an observation.
      let healthy = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      let known = try Self.nativeRecord(f)
      try refuseBoth(inactive); try refuseBoth(bound)  // Old full records stay stale.
      let contextless = try #require(try f.database.readProtocolFact(expectedBinding: f.binding))
      try refuseBoth(contextless)
      let other = try f.reopen()
      defer { try? other.close() }
      try refuseBoth(healthy, on: other)  // Same database name, DIFFERENT actual object.
      for field in ["storeIncarnation", "membershipIncarnation"] {
        var replacement = known
        replacement[field] =
          field == "storeIncarnation"
          ? "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" : "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        try #require(replacement[field] as? String != known[field] as? String)
        try Self.putRecord(f, replacement)
        try refuseBoth(healthy)
        try Self.putRecord(f, known)  // Restore exact known record; NEVER adopt a replacement capture.
      }
      var substituted = known
      var observed = try #require(known["observation"] as? [String: Any])
      observed["reportedVersion"] = 3; substituted["observation"] = observed
      try Self.putRecord(f, substituted)
      try refuseBoth(healthy)
      try Self.putRecord(f, known)
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"deviceId\"='ACTIVATION_NATIVE_REPLACEMENT' WHERE id=1")
      try refuseBoth(healthy)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"deviceId\"=$1 WHERE id=1", [f.link.deviceId])
      let later = try f.database.commitObservedProtocolFact(
        expectedSnapshot: healthy, observation: Self.observation(f.binding, version: 3))
      try refuseBoth(healthy)
      try Self.putRecord(f, known)
      // Recreate the later fact with its original expected healthy snapshot; keep the returned
      // candidate only to perform a real fence transition, never to rescue an old apply call.
      let laterAgain = try f.database.commitObservedProtocolFact(
        expectedSnapshot: healthy, observation: Self.observation(f.binding, version: 3))
      try f.database.fenceProtocolVerification(expectedSnapshot: laterAgain)
      try refuseBoth(healthy); try refuseBoth(later)
      try Self.putRecord(f, known)
      // Removing the native link defeats even a matching observed record.
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      try refuseBoth(healthy)
      try Self.insertReadOnlyFixtureLink(f)
      // Restoration leaves the SAME candidate healthy; a refusal must not rewrite/adopt it.
      try Self.expectReadOnlyValidation(f, snapshot: healthy, sync: true)
    }
    for legacyRows in [false, true] {
      try await Self.withFixture { f in
        if legacyRows { try Self.seedGuardApply(f) }
        let linked = try Self.capture(f)
        try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
        let absent = try f.database.captureProtocolVerification(
          accountID: f.binding.accountID, expectedMembership: nil)
        let batch = [Self.guardApplyChange("threads", "guard-thread", "title", "Absent link")]
        for candidate in [linked, absent] {
          for changes in [[], batch] {
            try Self.expectGuardApplyRefusal(f, changes: changes, cursor: 399, snapshot: candidate)
          }
        }
      }
    }
  }

  @Test func guardedApplyPostguardRollsBackWholeBatchAndCursorWhileSameEnabledCanarySucceedsHealthy()
    async throws
  {
    try await Self.withFixture { f in
      try Self.seedGuardApply(f)
      let inactive = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_apply_post;
        CREATE SEQUENCE guard_apply_post.title_probe;
        CREATE SEQUENCE guard_apply_post.cursor_probe;
        CREATE FUNCTION guard_apply_post.add_marker() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO public."columnClocks"("table","rowId","column",hlc)
            VALUES('connections','guard-apply-post','authMode','000000000000-0000-local');
          PERFORM nextval('guard_apply_post.title_probe');
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_apply_post AFTER UPDATE OF title ON public.threads FOR EACH ROW
          WHEN(NEW.id='guard-thread' AND NEW.title='ACTIVATION_GUARDED_APPLY_TITLE')
          EXECUTE FUNCTION guard_apply_post.add_marker();
        CREATE FUNCTION guard_apply_post.cursor_reached() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN PERFORM nextval('guard_apply_post.cursor_probe'); RETURN NEW; END $$;
        CREATE TRIGGER guard_apply_cursor AFTER UPDATE OF cursor ON public."hubLink" FOR EACH ROW
          WHEN(NEW.id=1 AND NEW.cursor=411) EXECUTE FUNCTION guard_apply_post.cursor_reached();
        """)
      let batch = [
        Self.guardApplyChange("threads", "guard-thread", "pinned", true),
        Self.guardApplyChange("threads", "guard-thread", "archived", "not-a-boolean"),
        Self.guardApplyChange("threads", "guard-thread", "title", .string(Self.applyTitle)),
        Self.guardApplyChange("environments", "guard-environment", "name", "After environment"),
      ]
      let clockBeforeRefusal = f.database.clock.next()
      try Self.expectGuardApplyRefusal(f, changes: batch, cursor: 411, snapshot: inactive)
      let clockAfterRefusal = f.database.clock.next()
      #expect(clockAfterRefusal > clockBeforeRefusal)
      try Self.expectGuardApplyProbe(f, "guard_apply_post.title_probe", 1)
      try Self.expectGuardApplyProbe(f, "guard_apply_post.cursor_probe", 1)
      try Self.expectRequirement(f, .legacyOnly)
      let healthy = try Self.healthyGuardMarkSnapshot(f)
      let before = try Self.state(f)
      let expected = try Self.expectedGuardApply(
        f, before: before, cursor: 411,
        edits: [
          ("threads", "id", "guard-thread", ["pinned": true, "title": Self.applyTitle]),
          ("environments", "id", "guard-environment", ["name": "After environment"]),
        ],
        clocks: [
          ("threads", "guard-thread", "pinned", Self.applyStamp),
          ("threads", "guard-thread", "title", Self.applyStamp),
          ("environments", "guard-environment", "name", Self.applyStamp),
        ],
        extraClocks: [
          [
            "table": "connections", "rowId": "guard-apply-post", "column": "authMode",
            "hlc": "000000000000-0000-local",
          ]
        ])
      // Both immediate triggers and the exact same batch/cursor remain enabled for this control.
      try Self.expectGuardApply(
        f, changes: batch, cursor: 411, snapshot: healthy, expected: expected,
        result: RemoteApplied(
          touchedThreadIds: ["guard-thread"], touchedEnvironmentIds: ["guard-environment"], applied: 3,
          skipped: 1))
      try Self.expectGuardApplyProbe(f, "guard_apply_post.title_probe", 2)
      try Self.expectGuardApplyProbe(f, "guard_apply_post.cursor_probe", 2)
      try Self.expectRequirement(f, .protocolTwo)
      // These native rollback assertions intentionally say nothing about rollback of memory HLC.
    }
  }

  @Test func guardedApplySelectsReadCommittedWhileOrdinaryApplyRetainsInheritedRepeatableRead() async throws {
    try await Self.withFixture { original in
      try Self.seedGuardApply(original)
      try original.raw.execute(
        """
        CREATE SCHEMA guard_apply_isolation;
        CREATE TABLE guard_apply_isolation.observed(cursor bigint NOT NULL,value text NOT NULL);
        CREATE FUNCTION guard_apply_isolation.record_isolation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO guard_apply_isolation.observed VALUES(NEW.cursor,current_setting('transaction_isolation'));
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_apply_isolation AFTER UPDATE OF cursor ON public."hubLink" FOR EACH ROW
          WHEN(NEW.id=1 AND NEW.cursor IN (501,502)) EXECUTE FUNCTION guard_apply_isolation.record_isolation();
        """)
      try await Self.withGuardMarkRepeatableRead(original) { f in
        // Belongs to the actual fresh object/pool opened AFTER DB default RR.
        let snapshot = try Self.capture(f)
        let beforeOrdinary = try Self.state(f)
        let expectedOrdinary = try Self.expectedGuardApply(f, before: beforeOrdinary, cursor: 501)
        let outcome = Result {
          try f.database.applyRemote([], ownDeviceId: f.link.deviceId, macDeviceIds: [], cursor: 501)
        }
        let exactOrdinary = try Self.state(f) == expectedOrdinary
        #expect(exactOrdinary)
        #expect(try outcome.get() == RemoteApplied())
        let first = try f.raw.execute(
          "SELECT cursor::text AS cursor,value FROM guard_apply_isolation.observed ORDER BY cursor"
        ).rows
        #expect(
          first.count == 1 && first.first?.text("cursor") == "501"
            && first.first?.text("value") == "repeatable read")
        let beforeGuarded = try Self.state(f)
        try Self.expectGuardApply(
          f, changes: [], cursor: 502, snapshot: snapshot,
          expected: Self.expectedGuardApply(f, before: beforeGuarded, cursor: 502), result: RemoteApplied())
        let both = try f.raw.execute(
          "SELECT cursor::text AS cursor,value FROM guard_apply_isolation.observed ORDER BY cursor"
        ).rows
        #expect(both.count == 2)
        #expect(both.first?.text("cursor") == "501" && both.first?.text("value") == "repeatable read")
        #expect(both.last?.text("cursor") == "502" && both.last?.text("value") == "read committed")
      }
    }
  }

  @Test func guardedApplyActualDeferredCommitFailureRollsBackBatchCursorAndDurableClocksThenRecovers()
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
}

// Final three guarded effects: dormant data compatibility only. These appended cases target
// future overloads; source review is neither semantic RED nor compilation/native-run evidence.
// Full local claim values include Mac-private columns. This is NOT outbound SyncFilter, owner,
// account, credential, HTTP, actor, publication, schema-admission or runtime qualification.
extension ProtocolActivationStoreTests {
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
  private static func expectFinalEffectRefusal(
    _ f: Fixture, allocations: Int = 0, probes: [(name: String, count: Int)] = [],
    body: () throws -> Void
  ) throws {
    let before = try state(f)
    let probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    expectSafe(body)
    let after = try state(f)  // Observe EVERY public row and all three native sequence fields NOW.
    if allocations == 0 {
      let exact = after == before
      #expect(exact)
    } else {
      let exactRows = after.rows == before.rows
      #expect(exactRows)
      try expectFinalEffectAllocation(
        f, name: "public.changes_seq_seq", before: before.sequence, after: after.sequence,
        count: allocations)
    }
    for (index, probe) in probes.enumerated() {
      try expectFinalEffectAllocation(
        f, name: probe.name, before: probeBefore[index], after: finalEffectProbe(f, probe.name),
        count: probe.count)
    }
    // No restoration, recapture, counter reset, later call or in-memory HLC assertion precedes
    // these observations. A known sequence allocation is never called native rollback.
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

  @Test func guardedClaimPreservesLegacyAndHealthyEarlyReturnsAndReannouncesEveryNativeOwnedRow()
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

  @Test func guardedClaimEarlyZeroRunsPostguardAndStrictOriginalRecordComparisonBeforeCommit()
    async throws
  {
    try await Self.withFixture { f in
      try Self.seedFinalEffectOwnedRows(f)
      try Self.seedFinalEffectLinkSentinels(f)
      let inactive = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_claim_zero;
        CREATE SEQUENCE guard_claim_zero.marker_probe;
        CREATE SEQUENCE guard_claim_zero.substitution_probe;
        CREATE FUNCTION guard_claim_zero.add_marker() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO public."columnClocks"("table","rowId","column",hlc)
            VALUES('connections','guard-claim-zero','authMode','000000000000-0000-local')
            ON CONFLICT DO NOTHING;
          PERFORM nextval('guard_claim_zero.marker_probe');
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_claim_zero AFTER UPDATE OF "ownedAs" ON public."hubLink" FOR EACH ROW
          WHEN(NEW.id=1 AND NEW."ownedAs"='ACTIVATION_DEVICE_SENTINEL') EXECUTE FUNCTION guard_claim_zero.add_marker();
        """)
      let noPriorSynced =
        try f.raw.execute("SELECT count(*) AS n FROM public.changes WHERE synced")
        .rows.first?.int("n") == 0
      try #require(noPriorSynced)
      try Self.expectFinalEffectRefusal(f, probes: [("guard_claim_zero.marker_probe", 1)]) {
        _ = try f.database.claimOwnedRows(expectedProtocolSnapshot: inactive)
      }
      // The successful immediate trigger and its native sequence prove the UPDATE and early
      // return were reached. Its R6 marker and every business row were rolled back by postguard.
      let healthy = try Self.healthyGuardMarkSnapshot(f)
      try Self.expectFinalEffectClaim(
        f, snapshot: healthy, count: 0, updatesOwnedAs: true, markers: ["guard-claim-zero"],
        probes: [("guard_claim_zero.marker_probe", 1)])
      let markerTwice = try Self.finalEffectSequence(
        Self.finalEffectProbe(f, "guard_claim_zero.marker_probe"))
      let bothReached = markerTwice.last == 2 && markerTwice.called
      #expect(bothReached)
      // Separate valid SAME-revision whole-record substitution. A revision-only or merely
      // still-eligible postcheck would incorrectly commit this healthy claim.
      let known = try Self.nativeRecord(f)
      let substitute = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
      let distinct = known["membershipIncarnation"] as? String != substitute
      try #require(distinct)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"ownedAs\"='ACTIVATION_PREVIOUS_OWNER' WHERE id=1")
      try f.raw.execute(
        """
        CREATE FUNCTION guard_claim_zero.substitute_record() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          UPDATE public.settings SET value=jsonb_set(value,'{membershipIncarnation}',
            to_jsonb('CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC'::text),false)
            WHERE key='__b4app_agent_protocol_activation_v1';
          PERFORM nextval('guard_claim_zero.substitution_probe');
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_claim_substitution AFTER UPDATE OF "ownedAs" ON public."hubLink" FOR EACH ROW
          WHEN(NEW.id=1 AND NEW."ownedAs"='ACTIVATION_DEVICE_SENTINEL') EXECUTE FUNCTION guard_claim_zero.substitute_record();
        """)
      try Self.expectFinalEffectRefusal(
        f, probes: [("guard_claim_zero.marker_probe", 1), ("guard_claim_zero.substitution_probe", 1)]
      ) {
        _ = try f.database.claimOwnedRows(expectedProtocolSnapshot: healthy)
      }
      // Remove ONLY the substitution fault. No recapture/adoption or control-row restoration.
      try f.raw.execute("DROP TRIGGER guard_claim_substitution ON public.\"hubLink\"")
      try Self.expectReadOnlyValidation(f, snapshot: healthy, sync: true)
      try Self.expectFinalEffectClaim(
        f, snapshot: healthy, count: 0, updatesOwnedAs: true,
        probes: [("guard_claim_zero.marker_probe", 1), ("guard_claim_zero.substitution_probe", 0)])
      try Self.expectFinalEffectClaim(
        f, snapshot: healthy, count: 0, updatesOwnedAs: false,
        probes: [("guard_claim_zero.marker_probe", 0), ("guard_claim_zero.substitution_probe", 0)])
      // Already-owned has no natural UPDATE canary; no fake body/callback is invented.
      // Its routing through the common postguard is additionally a source-review obligation.
    }
  }

  @Test func guardedStatusesChangeOnlyExactFieldsAndPullNilActuallyAvoidsNonmatchingRowUpdates()
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

  @Test func guardedStatusesRefuseEmbeddedNulBeforeAnyNativeParameterOrPartialStatusUpdate()
    async throws
  {
    for modern in [false, true] {
      try await Self.withFixture { f in
        try Self.seedFinalEffectOwnedRows(f)
        try Self.seedFinalEffectLinkSentinels(f)
        if modern { try Self.seedReadOnlyModernProfile(f) }
        let snapshot = try (modern ? Self.healthyGuardMarkSnapshot(f) : Self.capture(f))
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
        try Self.installFinalEffectRowProbe(f)
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try f.database.recordHubPushResult(
            error: "ACTIVATION_PREFIX\0SUFFIX", pushedAt: "2026-11-12T02:03:04.005Z",
            expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try f.database.recordHubPushResult(
            error: "ACTIVATION_DISTINCT_VALID_ERROR", pushedAt: "ACTIVATION_TIME\0SUFFIX",
            expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try f.database.recordHubPullResult(
            error: "ACTIVATION_PULL\0SUFFIX", expectedProtocolSnapshot: snapshot)
        }
        // Valid counterparts demonstrate narrow NUL refusal and a live, unreset row probe.
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPushResult(error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": "", "lastPushAt": ""], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPushResult(error: "", pushedAt: "", expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": "Pull: "], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPullResult(error: "", expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPullResult(error: nil, expectedProtocolSnapshot: snapshot)
        }
        // No raw NUL input is sent to PostgreSQL: text parameters currently truncate at NUL.
        // Each refusal above has its OWN complete native/probe before/after image, before any
        // following call. Neither sanitizing a suffix nor relying on a PG data error is valid.
      }
    }
  }

  @Test func guardedClaimAndBothStatusesRefuseAbsentContextlessStaleAndForeignObjectEvenAtNoOp()
    async throws
  {
    try await Self.withFixture { f in
      try Self.seedFinalEffectOwnedRows(f)
      try Self.seedFinalEffectLinkSentinels(f)
      try Self.installFinalEffectRowProbe(f)
      func refuseAll(
        _ snapshot: ProtocolVerificationSnapshot, on database: WorkspaceDatabase? = nil
      ) throws {
        let target = database ?? f.database
        for alreadyOwned in [false, true] {
          // Explicit setup occurs AFTER the preceding per-call observations. No counters are
          // reset. The actual native device is used even in a tuple-replacement refusal.
          try f.raw.execute(
            """
            UPDATE public."hubLink" SET "ownedAs"=CASE WHEN $1::boolean THEN "deviceId"
              ELSE 'ACTIVATION_PREVIOUS_OWNER' END,"lastError"='ACTIVATION_NON_PULL_ERROR' WHERE id=1
            """, [alreadyOwned ? "true" : "false"])
          let noPriorSynced =
            try f.raw.execute("SELECT count(*) AS n FROM public.changes WHERE synced")
            .rows.first?.int("n") == 0
          try #require(noPriorSynced)
          try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
            _ = try target.claimOwnedRows(expectedProtocolSnapshot: snapshot)
          }
        }
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try target.recordHubPushResult(
            error: "ACTIVATION_REFUSED_PUSH", pushedAt: "2026-11-12T03:04:05.006Z",
            expectedProtocolSnapshot: snapshot)
        }
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try target.recordHubPullResult(error: "ACTIVATION_REFUSED_PULL", expectedProtocolSnapshot: snapshot)
        }
        // A nil pull with a non-Pull error would have NO visible or row-trigger effect, but
        // it still has to refuse the stale original comparison rather than silently succeed.
        try Self.expectFinalEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try target.recordHubPullResult(error: nil, expectedProtocolSnapshot: snapshot)
        }
      }
      let linkedLegacy = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      let capturedAbsent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      try refuseAll(linkedLegacy); try refuseAll(capturedAbsent)
      try Self.insertReadOnlyFixtureLink(f)
      try Self.seedFinalEffectLinkSentinels(f)
      // Restore only the known native tuple; do not adopt an absent/replacement snapshot.
      try Self.expectReadOnlyValidation(f, snapshot: linkedLegacy, sync: true)
      try Self.seedReadOnlyModernProfile(f)
      try Self.expectRequirement(f, .protocolTwo)
      let inactive = try Self.capture(f)
      try refuseAll(inactive)
      let bound = try f.database.prepareProtocolVerification(
        expectedSnapshot: inactive, expectedBinding: f.binding)
      try refuseAll(bound)
      let healthy = try f.database.commitObservedProtocolFact(
        expectedSnapshot: bound, observation: Self.observation(f.binding))
      let known = try Self.nativeRecord(f)
      try refuseAll(linkedLegacy); try refuseAll(inactive); try refuseAll(bound)
      let directValue = try f.database.readProtocolFact(expectedBinding: f.binding)
      guard let direct = directValue else { throw FixtureFailure.nativeShape }
      try refuseAll(direct)
      let other = try f.reopen()
      defer { try? other.close() }
      try refuseAll(healthy, on: other)
      for (field, substitute) in [
        ("storeIncarnation", "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"),
        ("membershipIncarnation", "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"),
      ] {
        let distinct = known[field] as? String != substitute
        try #require(distinct)
        var replacement = known; replacement[field] = substitute
        try Self.putRecord(f, replacement)
        try refuseAll(healthy)
        try Self.putRecord(f, known)
      }
      var substituted = known
      guard var observation = known["observation"] as? [String: Any] else {
        throw FixtureFailure.nativeShape
      }
      observation["reportedVersion"] = 3; substituted["observation"] = observation
      try Self.putRecord(f, substituted)
      try refuseAll(healthy)
      try Self.putRecord(f, known)
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"deviceId\"='ACTIVATION_NATIVE_OTHER_DEVICE' WHERE id=1")
      try refuseAll(healthy)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"deviceId\"=$1 WHERE id=1", [f.link.deviceId])
      let later = try f.database.commitObservedProtocolFact(
        expectedSnapshot: healthy, observation: Self.observation(f.binding, version: 3))
      try refuseAll(healthy)
      try f.database.fenceProtocolVerification(expectedSnapshot: later)
      try refuseAll(healthy); try refuseAll(later)
      try Self.putRecord(f, known)
      // The SAME original candidate recovers only after exact known fixture restoration.
      try Self.expectReadOnlyValidation(f, snapshot: healthy, sync: true)
      // These tests cannot prove postguard execution for a body that has no SQL write; strict
      // preguard refusal plus the common helper's source routing are the honest boundary.
    }
  }

  @Test func guardedStatusSuccessfulRowCanariesAreRolledBackByPostguardAndSucceedWithSameHealthyTrigger()
    async throws
  {
    // Push, pull write, and pull clear EACH have their own fresh, prevalidated legacy fixture.
    for effect in 0..<3 {
      try await Self.withFixture { f in
        try Self.seedFinalEffectOwnedRows(f)
        try Self.seedFinalEffectLinkSentinels(f)
        if effect == 2 {
          try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"='Pull: before clear' WHERE id=1")
        }
        let inactive = try Self.capture(f)
        try Self.expectRequirement(f, .legacyOnly)
        try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true)
        try f.raw.execute(
          """
          CREATE SCHEMA guard_status_post;
          CREATE SEQUENCE guard_status_post.probe;
          CREATE FUNCTION guard_status_post.add_marker() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
          BEGIN
            INSERT INTO public."columnClocks"("table","rowId","column",hlc)
              VALUES('connections','guard-status-post','authMode','000000000000-0000-local');
            PERFORM nextval('guard_status_post.probe');
            RETURN NEW;
          END $$;
          CREATE TRIGGER guard_status_post AFTER UPDATE OF "lastError","lastPushAt" ON public."hubLink" FOR EACH ROW
            WHEN(NEW.id=1) EXECUTE FUNCTION guard_status_post.add_marker();
          """)
        func perform(_ snapshot: ProtocolVerificationSnapshot) throws {
          if effect == 0 {
            try f.database.recordHubPushResult(
              error: "ACTIVATION_POST_PUSH", pushedAt: "2026-11-12T04:05:06.007Z",
              expectedProtocolSnapshot: snapshot)
          } else {
            try f.database.recordHubPullResult(
              error: effect == 1 ? "ACTIVATION_POST_PULL" : nil, expectedProtocolSnapshot: snapshot)
          }
        }
        try Self.expectFinalEffectRefusal(f, probes: [("guard_status_post.probe", 1)]) {
          try perform(inactive)
        }
        let healthy = try Self.healthyGuardMarkSnapshot(f)
        let edits: [String: Any]
        if effect == 0 {
          edits = ["lastError": "ACTIVATION_POST_PUSH", "lastPushAt": "2026-11-12T04:05:06.007Z"]
        } else if effect == 1 {
          edits = ["lastError": "Pull: ACTIVATION_POST_PULL"]
        } else {
          edits = ["lastError": NSNull()]
        }
        try Self.expectFinalEffectPositive(
          f, link: edits, markers: ["guard-status-post"], probes: [("guard_status_post.probe", 1)]
        ) {
          try perform(healthy)
        }
        let probe = try Self.finalEffectSequence(Self.finalEffectProbe(f, "guard_status_post.probe"))
        let bothReached = probe.last == 2 && probe.called
        #expect(bothReached)
        try Self.expectRequirement(f, .protocolTwo)
        // No data-error skipping is permitted around these single status effects. The successful
        // immediate trigger returns NEW; the incompatible post-state, not a trigger throw, refuses.
        // Nil/non-Pull issues no UPDATE, so it has no natural status-row postcheck canary.
      }
    }
  }

  @Test func guardedClaimRealAppendRollsBackAtPostguardAndActualDeferredCommitWithHonestSequenceAdvances()
    async throws
  {
    try await Self.withFixture { f in
      try Self.seedFinalEffectOwnedRows(f)
      try Self.seedFinalEffectLinkSentinels(f)
      _ = try Self.insertLogWitness(
        f, table: "threads", op: "update", column: "title",
        value: #""ACTIVATION_PRIOR_SYNCED_LOG""#, synced: true)
      let inactive = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: inactive, sync: true)
      let ownedCount = try Self.finalEffectOwnedRows(Self.state(f)).count
      let fourExplicitOwnedRows = ownedCount == 4
      try #require(fourExplicitOwnedRows)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_claim_append;
        CREATE SEQUENCE guard_claim_append.probe;
        CREATE FUNCTION guard_claim_append.add_marker() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO public."columnClocks"("table","rowId","column",hlc)
            VALUES('connections','guard-claim-append','authMode','000000000000-0000-local');
          PERFORM nextval('guard_claim_append.probe');
          RETURN NEW;
        END $$;
        CREATE TRIGGER guard_claim_append AFTER UPDATE OF "ownedAs" ON public."hubLink" FOR EACH ROW
          WHEN(NEW.id=1 AND NEW."ownedAs"='ACTIVATION_DEVICE_SENTINEL') EXECUTE FUNCTION guard_claim_append.add_marker();
        """)
      try Self.expectFinalEffectRefusal(
        f, allocations: ownedCount, probes: [("guard_claim_append.probe", 1)]
      ) {
        _ = try f.database.claimOwnedRows(expectedProtocolSnapshot: inactive)
      }
      // Actual N changes.seq allocations survive; all N appended rows, ownedAs, control,
      // existing log bits and the successful R6 marker disappear in the native rollback.
      let healthy = try Self.healthyGuardMarkSnapshot(f)
      try Self.expectFinalEffectClaim(
        f, snapshot: healthy, count: ownedCount, updatesOwnedAs: true,
        markers: ["guard-claim-append"], probes: [("guard_claim_append.probe", 1)])
      let probe = try Self.finalEffectSequence(Self.finalEffectProbe(f, "guard_claim_append.probe"))
      let sameEnabledProbeTwice = probe.last == 2 && probe.called
      #expect(sameEnabledProbeTwice)
    }
    try await Self.withFixture { f in
      try Self.seedFinalEffectOwnedRows(f)
      try Self.seedFinalEffectLinkSentinels(f)
      _ = try Self.insertLogWitness(
        f, table: "threads", op: "update", column: "title",
        value: #""ACTIVATION_PRIOR_SYNCED_LOG""#, synced: true)
      let snapshot = try Self.capture(f)
      try Self.expectRequirement(f, .legacyOnly)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      let ownedCount = try Self.finalEffectOwnedRows(Self.state(f)).count
      let fourExplicitOwnedRows = ownedCount == 4
      try #require(fourExplicitOwnedRows)
      try f.raw.execute(
        """
        CREATE SCHEMA guard_claim_commit;
        CREATE SEQUENCE guard_claim_commit.probe;
        CREATE TABLE guard_claim_commit.expected_control AS
          SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1';
        CREATE TABLE guard_claim_commit.expected_link AS SELECT "deviceId" FROM public."hubLink" WHERE id=1;
        CREATE TABLE guard_claim_commit.expected_log AS SELECT seq,to_jsonb(c) AS value FROM public.changes c;
        CREATE TABLE guard_claim_commit.expected_rows AS
          SELECT 'connections'::text AS "table",t.id AS "rowId",to_jsonb(t) AS value FROM public.connections t
          UNION ALL SELECT 'environments',t.id,to_jsonb(t) FROM public.environments t
          UNION ALL SELECT 'threads',t.id,to_jsonb(t) FROM public.threads t;
        CREATE FUNCTION guard_claim_commit.refuse_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        DECLARE device text;
        BEGIN
          SELECT "deviceId" INTO device FROM guard_claim_commit.expected_link;
          IF NEW."ownedAs" IS DISTINCT FROM device
            OR (SELECT "ownedAs" FROM public."hubLink" WHERE id=1) IS DISTINCT FROM device
            OR (SELECT value FROM public.settings WHERE key='__b4app_agent_protocol_activation_v1')
              IS DISTINCT FROM (SELECT value FROM guard_claim_commit.expected_control)
            OR (SELECT count(*) FROM public.changes) <>
              (SELECT count(*) FROM guard_claim_commit.expected_log)+(SELECT count(*) FROM guard_claim_commit.expected_rows)
            OR EXISTS(SELECT 1 FROM guard_claim_commit.expected_log e LEFT JOIN public.changes c ON c.seq=e.seq
              WHERE c.seq IS NULL OR to_jsonb(c) IS DISTINCT FROM e.value)
            OR EXISTS(SELECT 1 FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM guard_claim_commit.expected_log e WHERE e.seq=c.seq)
              AND (c."deviceId" IS DISTINCT FROM device OR c.op IS DISTINCT FROM 'insert' OR c."column" IS NOT NULL
                OR c.synced IS DISTINCT FROM false OR c.hlc IS DISTINCT FROM '000000000000-0000-'||device))
            OR (SELECT count(DISTINCT c.wall) FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM guard_claim_commit.expected_log e WHERE e.seq=c.seq)) <> 1
            OR EXISTS(
              (SELECT c."table",c."rowId",c.value FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM guard_claim_commit.expected_log e WHERE e.seq=c.seq))
              EXCEPT (SELECT "table","rowId",value FROM guard_claim_commit.expected_rows))
            OR EXISTS(
              (SELECT "table","rowId",value FROM guard_claim_commit.expected_rows)
              EXCEPT (SELECT c."table",c."rowId",c.value FROM public.changes c WHERE NOT EXISTS(
                SELECT 1 FROM guard_claim_commit.expected_log e WHERE e.seq=c.seq)))
          THEN RAISE EXCEPTION 'ACTIVATION_GUARDED_CLAIM_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('guard_claim_commit.probe');
          RAISE EXCEPTION 'ACTIVATION_GUARDED_CLAIM_PRIVATE_CANARY'
            USING ERRCODE='23514',DETAIL='ACTIVATION_GUARDED_CLAIM_SECRET';
        END $$;
        CREATE CONSTRAINT TRIGGER guard_claim_commit AFTER UPDATE OF "ownedAs" ON public."hubLink"
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
          WHEN(NEW.id=1 AND NEW."ownedAs"='ACTIVATION_DEVICE_SENTINEL') EXECUTE FUNCTION guard_claim_commit.refuse_commit();
        """)
      // Independently validate the actual fault stage FIRST, without the old or guarded claim.
      // A raw manual append from BEFORE-owned values and an ownedAs UPDATE must return, and
      // only the real COMMIT attempt may raise the private, known 23514.
      let nativeBefore = try Self.state(f)
      let nativeProbeBefore = try Self.finalEffectProbe(f, "guard_claim_commit.probe")
      var bodyReturned = false, commitAttempted = false, knownConstraint = false
      do {
        try f.raw.execute("BEGIN")
        try f.raw.execute(
          """
          INSERT INTO public.changes("deviceId",wall,"table","rowId",op,"column",value,synced,hlc)
            SELECT l."deviceId",1234567890000,e."table",e."rowId",'insert',NULL,e.value,false,
              '000000000000-0000-'||l."deviceId"
            FROM guard_claim_commit.expected_rows e CROSS JOIN guard_claim_commit.expected_link l;
          UPDATE public."hubLink" SET "ownedAs"=(SELECT "deviceId" FROM guard_claim_commit.expected_link) WHERE id=1;
          """)
        bodyReturned = true
        commitAttempted = true
        try f.raw.execute("COMMIT")
      } catch {
        knownConstraint = (error as? PostgresError)?.sqlState == "23514"
        _ = try? f.raw.execute("ROLLBACK")
      }
      let nativeAfter = try Self.state(f)
      let exactNativeRows = nativeAfter.rows == nativeBefore.rows
      #expect(exactNativeRows)
      try Self.expectFinalEffectAllocation(
        f, name: "public.changes_seq_seq", before: nativeBefore.sequence, after: nativeAfter.sequence,
        count: ownedCount)
      try Self.expectFinalEffectAllocation(
        f, name: "guard_claim_commit.probe", before: nativeProbeBefore,
        after: Self.finalEffectProbe(f, "guard_claim_commit.probe"), count: 1)
      let realKnownCommitFailure = bodyReturned && commitAttempted && knownConstraint
      try #require(realKnownCommitFailure)
      // SAME still-enabled constraint and complete intended append-set validation. A safe
      // refusal must cover COMMIT, return no Int and roll rows back, while nextval advances N.
      try Self.expectFinalEffectRefusal(
        f, allocations: ownedCount, probes: [("guard_claim_commit.probe", 1)]
      ) {
        _ = try f.database.claimOwnedRows(expectedProtocolSnapshot: snapshot)
      }
      let commitProbe = try Self.finalEffectSequence(Self.finalEffectProbe(f, "guard_claim_commit.probe"))
      let bothCommitAttemptsReached = commitProbe.last == 2 && commitProbe.called
      #expect(bothCommitAttemptsReached)
      // Remove ONLY the failing constraint trigger, with no control/row/sequence restoration.
      try f.raw.execute("DROP TRIGGER guard_claim_commit ON public.\"hubLink\"")
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      try Self.expectFinalEffectClaim(
        f, snapshot: snapshot, count: ownedCount, updatesOwnedAs: true,
        probes: [("guard_claim_commit.probe", 0)])
      try Self.expectFinalEffectClaim(
        f, snapshot: snapshot, count: 0, updatesOwnedAs: false,
        probes: [("guard_claim_commit.probe", 0)])
      // This establishes only a known deferred 23514 rollback. Successful deferred postcheck
      // mutators and unknown COMMIT outcomes are excluded. The helper orders participating
      // writers only; raw bypass writers and nontransactional memory HLC remain outside proof.
    }
  }
}

// Original linked credential DATA comparisons only. These tests grant no runtime admission,
// credential presence/authentication claim, or reference-aware effect/transaction guarantee.
extension ProtocolActivationStoreTests {
  private enum ReferenceComparison: Sendable { case strict, sync }
  private static func referenceFixtureValue<T>(_ value: T?) throws -> T {
    guard let value else { throw FixtureFailure.nativeShape }
    return value
  }
  private static func compareReference(
    _ database: WorkspaceDatabase, snapshot: ProtocolVerificationSnapshot, reference: String,
    method: ReferenceComparison
  ) throws {
    switch method {
    case .strict:
      try database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: reference)
    case .sync:
      try database.compareOriginalLinkedSyncCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: reference)
    }
  }
  private static func expectReferenceComparison(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, reference: String,
    method: ReferenceComparison, refuses: Bool = false, database: WorkspaceDatabase? = nil
  ) throws {
    let before = try state(f)
    let operation = {
      try compareReference(
        database ?? f.database, snapshot: snapshot, reference: reference, method: method)
    }
    if refuses {
      expectSafe(operation)
      try expectUnchanged(f, before)
    } else {
      let outcome = Result { try operation() }
      // Independently read native rows AND sequence even when an expected positive throws.
      try expectUnchanged(f, before)
      try outcome.get()
    }
  }
  private static func expectBothReferences(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, reference: String,
    refuses: Bool = false, database: WorkspaceDatabase? = nil
  ) throws {
    for method in [ReferenceComparison.strict, .sync] {
      try expectReferenceComparison(
        f, snapshot: snapshot, reference: reference, method: method, refuses: refuses, database: database)
    }
  }
  private static func setNativeReference(_ f: Fixture, _ reference: String?) throws {
    try f.raw.execute("UPDATE public.\"hubLink\" SET \"tokenRef\"=$1 WHERE id=1", [reference])
  }
  private static func healthyReferenceSnapshot(_ f: Fixture) throws -> ProtocolVerificationSnapshot {
    try f.database.commitObservedProtocolFact(
      expectedSnapshot: capturedBinding(f), observation: observation(f.binding))
  }

  @Test func linkedReferenceRequiresCapturedPresentMembership() async throws {
    try await Self.withFixture { f in
      let initiallyMissing = try Self.recordText(f) == nil
      try #require(initiallyMissing)
      let linked = try Self.capture(f)
      _ = try Self.expectRecord(f, revision: "0", binding: nil)
      try Self.expectBothReferences(f, snapshot: linked, reference: f.link.tokenRef)
      try f.raw.execute("DELETE FROM public.settings WHERE key=$1", [Self.key])
      try Self.expectBothReferences(f, snapshot: linked, reference: f.link.tokenRef, refuses: true)
      let stillMissing = try Self.recordText(f) == nil
      #expect(stillMissing)
    }
    try await Self.withFixture { f in
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      let absent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      let original = try Self.recordText(f).map { Data($0.utf8) }
      try Self.expectBothReferences(f, snapshot: absent, reference: f.link.tokenRef, refuses: true)
      try Self.insertReadOnlyFixtureLink(f)
      let controlUnrotated = try Self.recordText(f).map { Data($0.utf8) } == original
      try #require(controlUnrotated)
      try Self.expectBothReferences(f, snapshot: absent, reference: f.link.tokenRef, refuses: true)
      let direct = try f.database.prepareProtocolVerification(expectedBinding: f.binding)
      let committed = try f.database.commitObservedProtocolFact(
        expectedSnapshot: direct, observation: Self.observation(f.binding))
      guard let read = try f.database.readProtocolFact(expectedBinding: f.binding) else {
        throw FixtureFailure.nativeShape
      }
      for snapshot in [direct, committed, read] {
        try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef, refuses: true)
      }
      try Self.expectBothReferences(f, snapshot: Self.capture(f), reference: f.link.tokenRef)
    }
  }

  @Test func tokenRefreshPreservesFactsButOnlyCurrentAnchorCompares() async throws {
    try await Self.withFixture { f in
      let original = try Self.healthyReferenceSnapshot(f)
      try Self.seedReadOnlyModernProfile(f)
      let originalText = try Self.recordText(f).map { Data($0.utf8) }
      let originalRecord = try Self.nativeRecord(f)
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      var refreshed = f.link
      refreshed.tokenRef = "secret:ACTIVATION_REFERENCE_B"
      try f.database.saveHubLink(refreshed)
      let exactRecord = try Self.recordText(f).map { Data($0.utf8) } == originalText
      let preserved = try Self.nativeRecord(f)
      let exactRevision =
        (preserved["revision"] as? String).map {
          Self.equalBytes($0, originalRecord["revision"] as? String ?? "")
        } ?? false
      let exactIncarnations = ["storeIncarnation", "membershipIncarnation"].allSatisfy {
        Self.incarnationBytesMatch(originalRecord, preserved, field: $0)
      }
      try #require(exactRecord && exactRevision && exactIncarnations)
      for sync in [false, true] { try Self.expectReadOnlyValidation(f, snapshot: original, sync: sync) }
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
      // A separately obtained current DATA snapshot is not a new runtime owner or lease.
      let current = try Self.capture(f)
      try Self.expectBothReferences(f, snapshot: current, reference: refreshed.tokenRef)
      try Self.setNativeReference(f, f.link.tokenRef)
      let restoredTupleAndControl = try Self.state(f)
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      try Self.expectUnchanged(f, restoredTupleAndControl)
      // Explicit ABA limit: restoring the same reference bytes and unchanged facts may compare.
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"deviceName\"='changed label',username='changed label',\"lastError\"='status',cursor=41 WHERE id=1"
      )
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      var metadata = f.link
      metadata.deviceName = "ordinary metadata refresh"; metadata.cursor = 999
      try f.database.saveHubLink(metadata)
      let keptNativeCursor =
        try f.raw.execute(
          "SELECT cursor::text AS cursor FROM public.\"hubLink\" WHERE id=1"
        ).rows.first?.text("cursor") == "41"
      #expect(keptNativeCursor)
      let metadataKeptFacts = try Self.recordText(f).map { Data($0.utf8) } == originalText
      #expect(metadataKeptFacts)
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
    }
  }

  @Test func referenceSyntaxAndOpaqueUtf8AreExact() async throws {
    // Audit the ACTUAL SecretRef parser: Swift String.count is the boundary, not byte/scalar count.
    let accepted = [
      "secret:x", "secret:not-a-uuid", "secret:suffix ", "secret:雪", "secret:é", "secret:e\u{301}",
    ]
    let rejected = ["", "secret:", "Secret:x", "other:x", " secret:x", "secret:\u{301}"]
    for reference in accepted {
      let parserAccepts = SecretRef(rawValue: reference) != nil
      let wrapperAccepts = ProtocolCredentialReference(reference) != nil
      #expect(parserAccepts && wrapperAccepts)
    }
    for reference in rejected {
      let parserRejects = SecretRef(rawValue: reference) == nil
      let wrapperRejects = ProtocolCredentialReference(reference) == nil
      #expect(parserRejects && wrapperRejects)
    }
    let combiningBoundary = "secret:\u{301}"
    let combiningHasSevenCharacters = combiningBoundary.count == 7 && combiningBoundary.utf8.count > 7
    #expect(combiningHasSevenCharacters)
    // SecretRef itself accepts NUL; the new comparison wrapper independently refuses it.
    for reference in ["secret:ACTIVATION_NUL\0inside", "secret:ACTIVATION_TRAILING\0"] {
      let oldParserAccepts = SecretRef(rawValue: reference) != nil
      let newWrapperRejects = ProtocolCredentialReference(reference) == nil
      #expect(oldParserAccepts && newWrapperRejects)
    }
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      for reference in accepted {
        try Self.setNativeReference(f, reference)
        try Self.expectBothReferences(f, snapshot: snapshot, reference: reference)
      }
      for reference in rejected {
        try Self.setNativeReference(f, reference)
        // Valid expected input exercises the native current-reference path before refusal.
        try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef, refuses: true)
        try Self.expectBothReferences(f, snapshot: snapshot, reference: reference, refuses: true)
        for sync in [false, true] { try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: sync) }
      }
      let composed = "secret:é", decomposed = "secret:e\u{301}"
      let unequalUTF8 = !composed.utf8.elementsEqual(decomposed.utf8)
      try #require(unequalUTF8)
      for (current, other) in [(composed, decomposed), (decomposed, composed)] {
        try Self.setNativeReference(f, current)
        try Self.expectBothReferences(f, snapshot: snapshot, reference: current)
        try Self.expectBothReferences(f, snapshot: snapshot, reference: other, refuses: true)
      }
      try Self.setNativeReference(f, f.link.tokenRef)
      for invalid in rejected + ["secret:ACTIVATION_NUL\0inside", "secret:ACTIVATION_TRAILING\0"] {
        try Self.expectBothReferences(f, snapshot: snapshot, reference: invalid, refuses: true)
      }
      // PostgreSQL text cannot represent NUL. Nil/invalid current references are decoded without
      // poisoning the old validators. The temporary nullable fixture is fully restored below.
      let schemaSQL = """
        SELECT jsonb_build_object('type',a.atttypid,'typmod',a.atttypmod,'notnull',a.attnotnull,
          'collation',a.attcollation,'identity',a.attidentity,'generated',a.attgenerated,
          'default',pg_get_expr(d.adbin,d.adrelid),
          'constraints',(SELECT jsonb_agg(jsonb_build_object(
            'name',c.conname,'type',c.contype,'definition',pg_get_constraintdef(c.oid,true),
            'deferrable',c.condeferrable,'deferred',c.condeferred,'validated',c.convalidated)
            ORDER BY c.conname,c.contype) FROM pg_constraint c WHERE c.conrelid=a.attrelid))::text AS value,
          a.attnotnull::text AS required
        FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid='public."hubLink"'::regclass AND a.attname='tokenRef'
        """
      let schema = try Self.referenceFixtureValue(f.raw.execute(schemaSQL).rows.first)
      let schemaBefore = try Self.referenceFixtureValue(schema.text("value"))
      let wasRequired = schema.text("required") == "true"
      var recovered = false
      defer {
        if !recovered {
          try? Self.setNativeReference(f, f.link.tokenRef)
          if wasRequired {
            try? f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" SET NOT NULL")
          }
        }
      }
      if wasRequired {
        try f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" DROP NOT NULL")
      }
      try Self.setNativeReference(f, nil)
      let nativeNull =
        try f.raw.execute(
          "SELECT (\"tokenRef\" IS NULL)::text AS missing FROM public.\"hubLink\" WHERE id=1"
        ).rows.first?.text("missing") == "true"
      try #require(nativeNull)
      try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef, refuses: true)
      for sync in [false, true] { try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: sync) }
      try Self.setNativeReference(f, f.link.tokenRef)
      if wasRequired {
        try f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" SET NOT NULL")
      }
      let schemaAfter = try Self.referenceFixtureValue(f.raw.execute(schemaSQL).rows.first?.text("value"))
      let exactSchemaRecovered = Self.equalBytes(schemaBefore, schemaAfter)
      try #require(exactSchemaRecovered)
      recovered = true
      try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef)
    }
  }

  @Test func strictOriginalDatabaseRecordAndTupleRemainRequired() async throws {
    try await Self.withFixture { f in
      let original = try Self.healthyReferenceSnapshot(f)
      let valid = try Self.nativeRecord(f)
      let other = try f.reopen()
      defer { try? other.close() }
      try Self.expectBothReferences(
        f, snapshot: original, reference: f.link.tokenRef, refuses: true, database: other)
      let otherCapture = try other.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: Self.nativeMembership(f.link))
      try Self.expectBothReferences(f, snapshot: otherCapture, reference: f.link.tokenRef, database: other)
      // Independently valid closed records at the SAME revision isolate each full-record field.
      var changes: [[String: Any]] = []
      var changed = valid; changed["revision"] = "3"; changes.append(changed)
      for field in ["storeIncarnation", "membershipIncarnation"] {
        changed = valid; changed[field] = UUID().uuidString; changes.append(changed)
      }
      changed = valid
      var observed = try Self.referenceFixtureValue(valid["observation"] as? [String: Any])
      observed["reportedVersion"] = 3; changed["observation"] = observed; changes.append(changed)
      changed = valid
      var principal = try Self.referenceFixtureValue(valid["binding"] as? [String: Any])
      principal["hubUserID"] = "ACTIVATION_OTHER_VALID_USER"
      principal["hubOrgID"] = "ACTIVATION_OTHER_VALID_ORG"
      observed = try Self.referenceFixtureValue(valid["observation"] as? [String: Any])
      observed["binding"] = principal
      changed["binding"] = principal; changed["observation"] = observed; changes.append(changed)
      for record in changes {
        try Self.putRecord(f, record)
        let independentCurrent = try Self.capture(f)
        try Self.expectBothReferences(f, snapshot: independentCurrent, reference: f.link.tokenRef)
        try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
        try Self.putRecord(f, valid)
        try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      }
      for (column, replacement, restored) in [
        ("url", "https://example.invalid/Other", f.link.url),
        ("deviceId", "ACTIVATION_OTHER_DEVICE", f.link.deviceId),
        ("joinedAt", "ACTIVATION_OTHER_JOIN", f.link.joinedAt),
      ] {
        try f.raw.execute("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1", [replacement])
        try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
        try f.raw.execute("UPDATE public.\"hubLink\" SET \(Rows.quote(column))=$1 WHERE id=1", [restored])
        try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      }
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
      try Self.insertReadOnlyFixtureLink(f)
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      var malformed = valid; malformed["unknown"] = "ACTIVATION_DECODER_PRIVATE"
      for record in [malformed, ["version": "ACTIVATION_MALFORMED"]] {
        try Self.putRecord(f, record)
        try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
      }
      try f.raw.execute("DELETE FROM public.settings WHERE key=$1", [Self.key])
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
      try Self.putRecord(f, valid)
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef)
      // Closing the actual original object leaves the separate native fixture connection usable.
      try f.database.close()
      try Self.expectBothReferences(f, snapshot: original, reference: f.link.tokenRef, refuses: true)
    }
  }

  @Test func syncPurposeUsesWholeStoreEligibilityWhileStrictDoesNot() async throws {
    try await Self.withFixture { f in
      let inactive = try Self.capture(f)
      let originalText = try Self.recordText(f).map { Data($0.utf8) }
      try Self.expectBothReferences(f, snapshot: inactive, reference: f.link.tokenRef)
      let retained = try Self.insertLogWitness(
        f, table: "protocolHistoryAnchors", op: "delete", synced: true)
      let sameControl = try Self.recordText(f).map { Data($0.utf8) } == originalText
      try #require(sameControl)
      try Self.expectReferenceComparison(f, snapshot: inactive, reference: f.link.tokenRef, method: .strict)
      try Self.expectReferenceComparison(
        f, snapshot: inactive, reference: f.link.tokenRef, method: .sync, refuses: true)
      try Self.removeLogWitness(f, seq: retained)
      try Self.expectBothReferences(f, snapshot: inactive, reference: f.link.tokenRef)
      // A separate retained HISTORY marker, with no live profile or new classifier rules.
      let history = try Self.insertLogWitness(
        f, table: "connections", op: "update", column: "authMode", value: #""none""#, synced: true)
      try Self.expectReferenceComparison(f, snapshot: inactive, reference: f.link.tokenRef, method: .strict)
      try Self.expectReferenceComparison(
        f, snapshot: inactive, reference: f.link.tokenRef, method: .sync, refuses: true)
      try Self.removeLogWitness(f, seq: history)
      try Self.seedReadOnlyModernProfile(f)
      try Self.expectReferenceComparison(
        f, snapshot: inactive, reference: f.link.tokenRef, method: .sync, refuses: true)
      let healthy = try Self.healthyReferenceSnapshot(f)
      try Self.expectBothReferences(f, snapshot: healthy, reference: f.link.tokenRef)
      let freshHealthy = try Self.capture(f)
      try Self.expectBothReferences(f, snapshot: freshHealthy, reference: f.link.tokenRef)
      let later = try f.database.commitObservedProtocolFact(
        expectedSnapshot: healthy, observation: Self.observation(f.binding, version: 3))
      try Self.expectBothReferences(f, snapshot: healthy, reference: f.link.tokenRef, refuses: true)
      try Self.expectBothReferences(f, snapshot: later, reference: f.link.tokenRef)
      try f.database.fenceProtocolVerification(expectedSnapshot: later)
      try Self.expectBothReferences(f, snapshot: later, reference: f.link.tokenRef, refuses: true)
      let withdrawn = try Self.capture(f)
      try Self.expectReferenceComparison(f, snapshot: withdrawn, reference: f.link.tokenRef, method: .strict)
      try Self.expectReferenceComparison(
        f, snapshot: withdrawn, reference: f.link.tokenRef, method: .sync, refuses: true)
    }
  }

  @Test func referenceComparisonNeverRequiresSecretPresence() async throws {
    try await Self.withFixture { f in
      let synthetic = "secret:ACTIVATION_UNSTORED_\(UUID().uuidString)"
      let parserValid = SecretRef(rawValue: synthetic) != nil
      try #require(parserValid)
      // Only native metadata is written. No secret store fixture, value, lookup or mutation exists.
      try Self.setNativeReference(f, synthetic)
      let legacy = try Self.capture(f)
      try Self.expectBothReferences(f, snapshot: legacy, reference: synthetic)
      try Self.seedReadOnlyModernProfile(f)
      let modern = try Self.healthyReferenceSnapshot(f)
      try Self.expectBothReferences(f, snapshot: modern, reference: synthetic)
      // Reference equality cannot establish authentication/presence or detect secret-value changes.
    }
  }

  @Test func newReferenceValuesAndErrorsStayRedacted() async throws {
    let sentinelA = "secret:ACTIVATION_REFERENCE_PRIVATE_A"
    let sentinelB = "secret:ACTIVATION_REFERENCE_PRIVATE_B"
    let first = try Self.referenceFixtureValue(ProtocolCredentialReference(sentinelA))
    let second = try Self.referenceFixtureValue(ProtocolCredentialReference(sentinelB))
    let different = first != second
    let mirrorEmpty = Mirror(reflecting: first).children.isEmpty
    let fixedDescription = String(describing: first) == "ProtocolCredentialReference(redacted)"
    let fixedDebug = String(reflecting: first) == "ProtocolCredentialReference(redacted)"
    let notEncodable = !(first as Any is any Encodable)
    #expect(different && mirrorEmpty && fixedDescription && fixedDebug && notEncodable)
    let nested: [String: Any] = ["references": [first, second], "optional": Optional(first) as Any]
    var dumped = ""; dump(nested, to: &dumped)
    let rendered = String(describing: nested) + String(reflecting: nested) + dumped
    let recursivelyRedacted = !rendered.contains(sentinelA) && !rendered.contains(sentinelB)
    #expect(recursivelyRedacted)
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      try Self.setNativeReference(f, sentinelA)
      try Self.expectBothReferences(f, snapshot: snapshot, reference: sentinelB, refuses: true)
      try Self.expectBothReferences(f, snapshot: snapshot, reference: sentinelA + "\0", refuses: true)
      var corrupt = try Self.nativeRecord(f); corrupt["unknown"] = sentinelA
      try Self.putRecord(f, corrupt)
      try Self.expectBothReferences(f, snapshot: snapshot, reference: sentinelA, refuses: true)
    }
    // Private State's explicit redaction is checked by source review; it stays private.
    // Existing SecretRef and HubToken renderings are intentionally outside this new wrapper proof.
  }

  private struct ReferenceViewFacts: Sendable {
    let observedOuterA: Bool, actualWaiter: Bool, committedB: Bool, released: Bool, readerJoined: Bool
    let expectedRows: [String: [Data]]?, expectedSequence: Data?
    let controller: Result<Void, any Error>, reader: Result<Void, any Error>
  }
  private static func referenceViewRace(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, method: ReferenceComparison,
    changedControl: String, changedReference: String
  ) async -> ReferenceViewFacts {
    // The function receives the OUTER row's tokenRef. It never re-queries the backing relation.
    // Statement snapshot A therefore supplies BOTH the argument and all control/classifier reads.
    let gate: Int64 = 0x6234_7266
    return await onThread {
      let result = Mutex<Result<Void, any Error>?>(nil)
      let completed = DispatchSemaphore(value: 0)
      var readerThread: Thread?
      var controller: PostgresConnection?
      var gateOwned = false
      var started = false, outerA = false, waiter = false, committed = false, released = false
      var expected: NativeState?
      var failure: (any Error)?
      do {
        // The sole stored controller owner below survives this setup scope for explicit cleanup.
        let writerPID = try referenceFixtureValue(
          f.raw.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"))
        let c = try membershipConnection(f.endpoint)
        controller = c
        try c.execute("SELECT pg_advisory_lock($1::bigint)", [String(gate)])
        gateOwned = true
        readerThread = Thread {
          let outcome = Result<Void, any Error> {
            try compareReference(f.database, snapshot: snapshot, reference: f.link.tokenRef, method: method)
          }
          result.withLock { $0 = outcome }; completed.signal()
        }
        readerThread?.start(); started = true
        let expectedApplication =
          "ref-view:" + f.link.tokenRef.utf8.map { String(format: "%02x", $0) }.joined()
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
          let rows = try c.execute(
            """
            SELECT a.pid,a.application_name,pg_backend_pid() AS controller_pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
            WHERE a.datname=$1 AND a.application_name=$2 AND l.locktype='advisory'
              AND NOT l.granted AND l.classid=0::oid AND l.objid=$3::oid AND l.objsubid=1
              AND pg_backend_pid()=ANY(pg_blocking_pids(a.pid))
            """, [f.endpoint.database, expectedApplication, String(gate)]
          ).rows
          if rows.count == 1, let row = rows.first, let pid = row.int("pid"), pid > 0,
            let controllerPID = row.int("controller_pid"), controllerPID > 0
          {
            outerA = row.text("application_name").map { equalBytes($0, expectedApplication) } ?? false
            waiter = writerPID > 0 && pid != writerPID && pid != controllerPID && writerPID != controllerPID
            break
          }
          if result.withLock({ $0 != nil }) { break }
        }
        guard outerA, waiter else { throw FixtureFailure.barrierTimeout }
        // Native writer uses a SECOND connection, not the production advisory-lock convention.
        // AccessShare from the paused SELECT is compatible with these RowExclusive DML locks.
        try f.raw.execute("BEGIN")
        do {
          try f.raw.execute("SET LOCAL lock_timeout='3s'")
          try f.raw.execute(
            "UPDATE public.\"referenceViewBacking\" SET \"tokenRef\"=$1 WHERE id=1", [changedReference])
          try f.raw.execute("UPDATE public.settings SET value=$2::jsonb WHERE key=$1", [key, changedControl])
          try f.raw.execute(
            """
            INSERT INTO public."columnClocks"("table","rowId","column",hlc)
              VALUES('connections','reference-view-retained','authMode','000000000000-0000-local')
            """)
          try f.raw.execute("COMMIT"); committed = true
        } catch {
          _ = try? f.raw.execute("ROLLBACK"); throw error
        }
        // Independently captured committed B, while the A reader is still an observed waiter.
        expected = try state(f)
        let stillWaiting =
          try c.execute(
            """
            SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
            WHERE a.datname=$1 AND a.application_name=$2 AND l.locktype='advisory'
              AND NOT l.granted AND l.classid=0::oid AND l.objid=$3::oid AND l.objsubid=1
              AND pg_backend_pid()=ANY(pg_blocking_pids(a.pid))
            """, [f.endpoint.database, expectedApplication, String(gate)]
          ).rows.count == 1
        guard stillWaiting else { throw FixtureFailure.barrierTimeout }
      } catch { failure = error }
      // Explicit unlock is attempted on ALL paths. Its failure remains a controller failure;
      // clearing the SOLE retained session owner is the fallback release, before waiting.
      if gateOwned {
        do {
          guard let c = controller,
            try c.execute("SELECT pg_advisory_unlock($1::bigint)::text AS released", [String(gate)])
              .rows.first?.text("released") == "true"
          else { throw FixtureFailure.nativeShape }
          released = true
        } catch { if failure == nil { failure = error } }
      }
      controller = nil  // PostgresConnection.deinit calls lib.finish; no reader retains this session.
      // This waits for actual synchronous native-operation completion, not OS Thread exit or a
      // universal four-second bound. No fixture restoration can run before this completion signal.
      if started { completed.wait() }
      readerThread = nil
      return ReferenceViewFacts(
        observedOuterA: outerA, actualWaiter: waiter, committedB: committed,
        released: released, readerJoined: started,
        expectedRows: expected?.rows, expectedSequence: expected?.sequence,
        controller: failure.map { .failure($0) } ?? .success(()),
        reader: result.withLock { $0 } ?? .failure(FixtureFailure.nativeShape))
    }
  }

  @Test func oneNativeStatementViewCannotAssembleMixedReferenceState() async throws {
    for method in [ReferenceComparison.strict, .sync] {
      try await Self.withFixture { f in
        let snapshot = try Self.capture(f)
        let original = try Self.nativeRecord(f)
        var changed = original; changed["revision"] = "1"
        let changedControl = String(
          decoding: try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]), as: UTF8.self
        )
        let changedReference = "secret:ACTIVATION_REFERENCE_VIEW_B"
        let originalText = try Self.recordText(f).map { Data($0.utf8) }
        try f.raw.execute(
          """
          CREATE SCHEMA reference_view;
          CREATE FUNCTION reference_view.pause_outer_ref(p_ref text) RETURNS text
            LANGUAGE plpgsql VOLATILE SET search_path=pg_catalog AS $$
          BEGIN
            PERFORM set_config('application_name','ref-view:'||encode(convert_to(p_ref,'UTF8'),'hex'),false);
            PERFORM pg_advisory_xact_lock(1647604326::bigint);
            RETURN p_ref;
          END $$;
          ALTER TABLE public."hubLink" RENAME TO "referenceViewBacking";
          CREATE VIEW public."hubLink" WITH (security_barrier=true) AS
            SELECT b.id,b.url,b."deviceId",b."joinedAt",
              reference_view.pause_outer_ref(b."tokenRef") AS "tokenRef"
            FROM public."referenceViewBacking" b;
          """)
        var restored = false
        defer {
          if !restored {
            // referenceViewRace ALWAYS joins the reader before returning, even on failure.
            try? f.raw.execute(
              "DROP VIEW IF EXISTS public.\"hubLink\"; ALTER TABLE public.\"referenceViewBacking\" RENAME TO \"hubLink\"; DROP SCHEMA IF EXISTS reference_view CASCADE;"
            )
          }
        }
        let nativeOuterA = try f.raw.execute(
          "SELECT \"tokenRef\" FROM public.\"referenceViewBacking\" WHERE id=1"
        ).rows.first?.text("tokenRef")
        let actualA = nativeOuterA.map { Self.equalBytes($0, f.link.tokenRef) } ?? false
        let sameOriginalText = try Self.recordText(f).map { Data($0.utf8) } == originalText
        try #require(actualA && sameOriginalText)
        // Independent full rows/sequence BEFORE the actual reader starts. The writer's B snapshot
        // below is the expected AFTER image, since this case deliberately includes concurrent DML.
        _ = try Self.state(f)
        let facts = await Self.referenceViewRace(
          f, snapshot: snapshot, method: method, changedControl: changedControl,
          changedReference: changedReference)
        let joinedObservedStages =
          facts.observedOuterA && facts.actualWaiter && facts.committedB && facts.released
          && facts.readerJoined
        #expect(joinedObservedStages)
        // Inspect B BEFORE fixture restoration, even when the reader unexpectedly throws.
        if let rows = facts.expectedRows, let sequence = facts.expectedSequence {
          try Self.expectUnchanged(f, NativeState(rows: rows, sequence: sequence))
        } else {
          Issue.record("The independent committed native B snapshot was not captured.")
        }
        try facts.controller.get()
        try facts.reader.get()  // Established statement A must compare successfully in BOTH purposes.
        // Fresh statement sees atomic B and refuses original A, without writing any public row.
        try Self.expectReferenceComparison(
          f, snapshot: snapshot, reference: f.link.tokenRef, method: method, refuses: true)
        try f.raw.execute(
          "DROP VIEW public.\"hubLink\"; ALTER TABLE public.\"referenceViewBacking\" RENAME TO \"hubLink\"; DROP SCHEMA reference_view CASCADE;"
        )
        restored = true
      }
    }
    // Native planner/view/barrier engineering is intentionally unqualified until managed execution.
  }

  @Test func nativeSqlFailureIsFixedAndComparisonDoesNotWrite() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      try f.raw.execute("ALTER TABLE public.settings RENAME TO reference_missing_settings")
      var restored = false
      defer {
        if !restored {
          try? f.raw.execute("ALTER TABLE public.reference_missing_settings RENAME TO settings")
        }
      }
      // A valid expected reference reaches a REAL SELECT failure, not an early syntax rejection.
      try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef, refuses: true)
      try f.raw.execute("ALTER TABLE public.reference_missing_settings RENAME TO settings")
      restored = true
      try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef)
      try f.raw.execute(
        """
        CREATE SCHEMA reference_no_dml;
        CREATE SEQUENCE reference_no_dml.probe;
        CREATE FUNCTION reference_no_dml.refuse_dml() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          PERFORM nextval('reference_no_dml.probe');
          RAISE EXCEPTION 'ACTIVATION_REFERENCE_SQL_PRIVATE' USING ERRCODE='23514',DETAIL='ACTIVATION_REFERENCE_SQL_SECRET';
        END $$;
        CREATE TRIGGER reference_no_dml BEFORE INSERT OR UPDATE OR DELETE ON public.settings
          FOR EACH STATEMENT EXECUTE FUNCTION reference_no_dml.refuse_dml();
        CREATE TRIGGER reference_no_dml BEFORE INSERT OR UPDATE OR DELETE ON public."hubLink"
          FOR EACH STATEMENT EXECUTE FUNCTION reference_no_dml.refuse_dml();
        """)
      defer {
        try? f.raw.execute(
          "DROP TRIGGER IF EXISTS reference_no_dml ON public.settings; DROP TRIGGER IF EXISTS reference_no_dml ON public.\"hubLink\"; DROP SCHEMA IF EXISTS reference_no_dml CASCADE;"
        )
      }
      // Independently prove BOTH enabled denial triggers; nextval survives statement rollback.
      for statement in [
        "UPDATE public.settings SET value=value WHERE key='__b4app_agent_protocol_activation_v1'",
        "UPDATE public.\"hubLink\" SET \"tokenRef\"=\"tokenRef\" WHERE id=1",
      ] {
        let nativeBefore = try Self.state(f)
        var known = false
        do { try f.raw.execute(statement) } catch { known = (error as? PostgresError)?.sqlState == "23514" }
        try #require(known)
        try Self.expectUnchanged(f, nativeBefore)
      }
      let probeBefore = try Self.finalEffectProbe(f, "reference_no_dml.probe")
      let independentlyReachedBoth = try Self.finalEffectSequence(probeBefore).last == 2
      try #require(independentlyReachedBoth)
      try Self.expectBothReferences(f, snapshot: snapshot, reference: f.link.tokenRef)
      let probeAfter = try Self.finalEffectProbe(f, "reference_no_dml.probe")
      let attemptedNoGuardedDML = probeBefore == probeAfter
      #expect(attemptedNoGuardedDML)
      // This canary covers attempted DML on settings/hubLink, including rolled-back attempts.
      // It is not a universal no-write proof; absence of other production writes needs source review.
    }
  }
}

// Required-original-reference guarded effects. Test-first declarations only: managed execution
// must qualify this addition together with the unchanged prefix on the eventual combined tree.
// No runtime owner, secret availability, ABA prevention, wire admission, or unknown-COMMIT claim.
extension ProtocolActivationStoreTests {
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
  private enum RefEffectResult: Equatable, Sendable {
    case void, apply(RemoteApplied), claim(Int)
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
  /// The five real overloads are selected here with the mandatory original String. No production
  /// callback, current-reference recapture, or snapshot-only forwarding supplies the test body.
  private static func performRefEffect(
    _ f: Fixture, input: RefEffectInput, snapshot: ProtocolVerificationSnapshot,
    reference: String, database: WorkspaceDatabase? = nil
  ) throws -> RefEffectResult {
    let target = database ?? f.database
    switch input.route {
    case .mark:
      try target.markSynced(
        through: input.through, expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      return .void
    case .apply:
      return .apply(
        try target.applyRemote(
          input.batch(ownDeviceId: f.link.deviceId), ownDeviceId: f.link.deviceId,
          macDeviceIds: ["guard-other-mac"], cursor: 811,
          expectedProtocolSnapshot: snapshot, expectedTokenRef: reference))
    case .claimAppend, .claimZero:
      return .claim(
        try target.claimOwnedRows(
          expectedProtocolSnapshot: snapshot, expectedTokenRef: reference))
    case .push:
      try target.recordHubPushResult(
        error: "ACTIVATION_REFERENCE_PUSH", pushedAt: "2026-11-12T07:08:09.010Z",
        expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      return .void
    case .pull, .pullClear:
      try target.recordHubPullResult(
        error: input.route == .pull ? "ACTIVATION_REFERENCE_PULL" : nil,
        expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      return .void
    }
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
  private static func expectRefEffectPositive(
    _ f: Fixture, input: RefEffectInput, snapshot: ProtocolVerificationSnapshot,
    reference: String = effectReferenceA, probes: [(name: String, count: Int)] = []
  ) throws {
    if input.route == .claimAppend {
      try expectRefEffectClaim(
        f, snapshot: snapshot, reference: reference, count: input.ownedCount,
        updatesOwnedAs: true, probes: probes)
      return
    }
    let before = try state(f), expected = try expectedRefEffect(f, input: input, before: before)
    let probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    let result = Result { try performRefEffect(f, input: input, snapshot: snapshot, reference: reference) }
    let after = try state(f)
    let exact = after == expected
    #expect(exact)
    for (index, probe) in probes.enumerated() {
      try expectFinalEffectAllocation(
        f, name: probe.name, before: probeBefore[index], after: finalEffectProbe(f, probe.name),
        count: probe.count)
    }
    let actual = try result.get()
    let exactResult =
      actual == (input.route == .apply ? .apply(input.applied) : input.claim ? .claim(0) : .void)
    #expect(exactResult)
  }
  private static func expectRefEffectNoOpRefusal(
    _ f: Fixture, route: RefEffect, snapshot: ProtocolVerificationSnapshot, reference: String
  ) throws {
    try expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
      switch route {
      case .mark:
        try f.database.markSynced(
          through: -1, expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      case .apply:
        let actual = try f.database.applyRemote(
          [], ownDeviceId: f.link.deviceId, macDeviceIds: [], cursor: 701,
          expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
        _ = actual
      case .claimAppend, .claimZero:
        _ = try f.database.claimOwnedRows(expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      case .push:
        try f.database.recordHubPushResult(
          error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      case .pull, .pullClear:
        try f.database.recordHubPullResult(
          error: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
      }
    }
  }

  @Test func requiredReferenceAllFiveCommitExactBodiesAcrossLegacyAndHealthyModern() async throws {
    for route in RefEffect.allCases {
      try await Self.withFixture { f in
        let (input, snapshot) = try Self.prepareRefEffect(
          f, route: route, modern: route == .apply || route == .push)
        try Self.expectRefEffectPositive(f, input: input, snapshot: snapshot)
      }
    }
    try await Self.withFixture { f in
      try Self.seedReadOnlyModernProfile(f)
      let inactive = try Self.capture(f)
      try Self.installFinalEffectRowProbe(f)
      try Self.expectRefEffectNoOpRefusal(
        f, route: .mark, snapshot: inactive, reference: f.link.tokenRef)
    }
  }

  @Test func requiredReferenceOrdinaryRefreshPreservesFactsAndAllFiveRefuseOriginalEvenAtNoOp() async throws {
    try await Self.withFixture { f in
      let (_, snapshot) = try Self.prepareRefEffect(f, route: .claimZero, modern: true)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"ownedAs\"=\"deviceId\" WHERE id=1")
      let beforeRefresh = try Self.state(f)
      var refreshed = try Self.referenceFixtureValue(f.database.hubLink())
      refreshed.tokenRef = Self.effectReferenceB
      try f.database.saveHubLink(refreshed)
      let expectedRows = try Self.finalEffectExpectedRows(
        f, before: beforeRefresh,
        link: ["tokenRef": Self.effectReferenceB])
      // Ordinary same-membership refresh changes ONLY the explicitly supplied reference.
      let refreshedState = try Self.state(f)
      let exactRefresh = refreshedState == NativeState(rows: expectedRows, sequence: beforeRefresh.sequence)
      try #require(exactRefresh)
      let controlExact = refreshedState.rows["settings"] == beforeRefresh.rows["settings"]
      try #require(controlExact)
      try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      try f.database.markSynced(through: -1, expectedProtocolSnapshot: snapshot)
      try Self.installFinalEffectRowProbe(f)
      for route in [RefEffect.mark, .apply, .claimZero, .push, .pull] {
        try Self.expectRefEffectNoOpRefusal(
          f, route: route, snapshot: snapshot, reference: Self.effectReferenceA)
      }
      // B is explicit independent test input. No production operation re-captures it.
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": "ACTIVATION_REFERENCE_B_POSITIVE"], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPushResult(
          error: "ACTIVATION_REFERENCE_B_POSITIVE", pushedAt: nil,
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceB)
      }
    }
  }

  @Test func requiredReferencePreRefusalDoesNotObserveReceivedHlcOrAllocateClaimLog() async throws {
    try await Self.withFixture { original in
      let controlled = try WorkspaceDatabase(
        endpoint: original.endpoint, binDir: original.endpoint.binDir!, createIfMissing: false,
        backupDirectory: original.root + "/backups", wall: { 42 })
      defer { try? controlled.close() }
      let f = Fixture(
        database: controlled, raw: original.raw, endpoint: original.endpoint, root: original.root,
        link: original.link, binding: original.binding)
      let (_, snapshot) = try Self.prepareRefEffect(f, route: .claimAppend)
      var refreshed = f.link; refreshed.tokenRef = Self.effectReferenceB
      try controlled.saveHubLink(refreshed)
      let received = HLC(millis: epochMillis() + 120_000, counter: 19, deviceId: "guard-phone")
      let lower = controlled.clock.next()
      try Self.expectRefEffectRefusal(f) {
        _ = try controlled.applyRemote(
          [Self.guardApplyChange("threads", "guard-thread", "title", "refused", at: received.rawValue)],
          ownDeviceId: f.link.deviceId, macDeviceIds: [], cursor: 899,
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      let upper = controlled.clock.next()
      let notObserved = epochMillis() < received.millis && upper.millis < received.millis && upper > lower
      #expect(notObserved)
      try Self.expectRefEffectRefusal(f) {
        _ = try controlled.claimOwnedRows(
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
    }
  }

  @Test func requiredReferenceParserPreflightCorpusAndAllFiveSelectRequiredHelper() async throws {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      try Self.installFinalEffectRowProbe(f)
      for valid in ["secret:not-a-uuid", "secret:suffix ", "secret:雪"] {
        try Self.setNativeReference(f, valid)
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPushResult(
            error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: valid)
        }
      }
      let combining = "secret:\u{301}"
      let exactBoundary = combining.count == 7 && combining.utf8.count > 7
      try #require(exactBoundary)
      for invalid in [
        "", "secret:", "Secret:x", " secret:x", combining,
        "secret:ACTIVATION_NUL\0inside", "secret:ACTIVATION_TRAILING\0",
      ] {
        try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
          try f.database.recordHubPushResult(
            error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: invalid)
        }
      }
      for route in [RefEffect.mark, .apply, .claimZero, .pull] {
        try Self.expectRefEffectNoOpRefusal(f, route: route, snapshot: snapshot, reference: "secret:")
      }
      // Malformed expected/NUL never goes to a native parameter. No-change alone is NOT a
      // no-SELECT oracle: helper preflight before write/SQL remains an explicit source obligation.
    }
  }

  @Test func requiredReferenceValidExpectedRefusesMalformedCurrentAndUnicodeBytesDifferBothWays() async throws
  {
    try await Self.withFixture { f in
      let snapshot = try Self.capture(f)
      try Self.installFinalEffectRowProbe(f)
      for malformed in ["Secret:x", "secret:"] {
        try Self.setNativeReference(f, malformed)
        try Self.expectRefEffectNoOpRefusal(
          f, route: .push, snapshot: snapshot, reference: Self.effectReferenceA)
      }
      for (current, other) in [("secret:é", "secret:e\u{301}"), ("secret:e\u{301}", "secret:é")] {
        try Self.setNativeReference(f, current)
        try Self.expectRefEffectNoOpRefusal(f, route: .push, snapshot: snapshot, reference: other)
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPushResult(
            error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: current)
        }
      }
      let schemaSQL = """
        SELECT jsonb_build_object('type',a.atttypid,'typmod',a.atttypmod,'notnull',a.attnotnull,
          'collation',a.attcollation,'identity',a.attidentity,'generated',a.attgenerated,
          'default',pg_get_expr(d.adbin,d.adrelid),
          'constraints',(SELECT jsonb_agg(jsonb_build_object(
            'name',c.conname,'type',c.contype,'definition',pg_get_constraintdef(c.oid,true),
            'deferrable',c.condeferrable,'deferred',c.condeferred,'validated',c.convalidated)
            ORDER BY c.conname,c.contype) FROM pg_constraint c WHERE c.conrelid=a.attrelid))::text AS value,
          a.attnotnull::text AS required
        FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid='public."hubLink"'::regclass AND a.attname='tokenRef'
        """
      let schema = try Self.referenceFixtureValue(f.raw.execute(schemaSQL).rows.first)
      let catalog = try Self.referenceFixtureValue(schema.text("value"))
      let required = schema.text("required") == "true"
      var restored = false
      defer {
        if !restored {
          try? Self.setNativeReference(f, Self.effectReferenceA)
          if required {
            try? f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" SET NOT NULL")
          }
        }
      }
      if required {
        try f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" DROP NOT NULL")
      }
      try Self.setNativeReference(f, nil)
      let actualNull =
        try f.raw.execute(
          "SELECT (\"tokenRef\" IS NULL)::text AS missing FROM public.\"hubLink\" WHERE id=1"
        ).rows.first?.text("missing") == "true"
      try #require(actualNull)
      try Self.expectRefEffectNoOpRefusal(
        f, route: .push, snapshot: snapshot, reference: Self.effectReferenceA)
      try Self.setNativeReference(f, Self.effectReferenceA)
      if required {
        try f.raw.execute("ALTER TABLE public.\"hubLink\" ALTER COLUMN \"tokenRef\" SET NOT NULL")
      }
      let recovered = try Self.referenceFixtureValue(f.raw.execute(schemaSQL).rows.first?.text("value"))
      let exactCatalog = Self.equalBytes(catalog, recovered)
      try #require(exactCatalog); restored = true
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPushResult(
          error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot,
          expectedTokenRef: Self.effectReferenceA)
      }
    }
  }

  @Test func requiredReferenceRetainsActualObjectCapturedContextFullRecordTupleAndClosedRules() async throws {
    try await Self.withFixture { f in
      let (_, snapshot) = try Self.prepareRefEffect(f, route: .push, modern: true)
      let input = RefEffectInput(route: .push, through: 0, ownedCount: 0)
      func refuse(_ candidate: ProtocolVerificationSnapshot, on target: WorkspaceDatabase? = nil) throws {
        try Self.expectRefEffectRefusal(f) {
          _ = try Self.performRefEffect(
            f, input: input, snapshot: candidate, reference: Self.effectReferenceA, database: target)
        }
      }
      let direct = try Self.referenceFixtureValue(f.database.readProtocolFact(expectedBinding: f.binding))
      try refuse(direct)
      let other = try f.reopen()
      defer { try? other.close() }
      try refuse(snapshot, on: other)
      let known = try Self.nativeRecord(f)
      var stale = known
      var observed = try Self.referenceFixtureValue(known["observation"] as? [String: Any])
      observed["reportedVersion"] = 3; stale["observation"] = observed
      try Self.putRecord(f, stale)
      let current = try Self.capture(f)
      try Self.expectReadOnlyValidation(f, snapshot: current, sync: true)
      try refuse(snapshot)  // The negative still compares the ORIGINAL full record.
      try Self.putRecord(f, known)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"deviceId\"='ACTIVATION_CHANGED_TUPLE' WHERE id=1")
      try refuse(snapshot)
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"deviceId\"=$1 WHERE id=1", [f.link.deviceId])
      // The ORIGINAL snapshot and A compare immediately after exact tuple restoration, before close.
      // No replacement capture can turn the following refusal into a different stale test.
      try Self.expectReferenceComparison(
        f, snapshot: snapshot, reference: Self.effectReferenceA, method: .sync)
      try f.database.close()
      try refuse(snapshot)
    }
    // A bound modern record cannot legitimately capture a deleted native membership. Follow
    // the qualified absent-record fixture pattern independently of the closed-object sequence.
    try await Self.withFixture { f in
      let noInitialRecord = try Self.recordText(f) == nil
      try #require(noInitialRecord)
      try Self.setNativeReference(f, Self.effectReferenceA)
      try Self.installFinalEffectRowProbe(f)
      try f.raw.execute("DELETE FROM public.\"hubLink\" WHERE id=1")
      let absent = try f.database.captureProtocolVerification(
        accountID: f.binding.accountID, expectedMembership: nil)
      let originalControl = Data(try Self.referenceFixtureValue(Self.recordText(f)).utf8)
      let input = RefEffectInput(route: .push, through: 0, ownedCount: 0)
      try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
        _ = try Self.performRefEffect(
          f, input: input, snapshot: absent, reference: Self.effectReferenceA)
      }
      try Self.insertReadOnlyFixtureLink(f)
      try Self.setNativeReference(f, Self.effectReferenceA)
      let restoredReference = try f.raw.execute(
        "SELECT \"tokenRef\" FROM public.\"hubLink\" WHERE id=1"
      ).rows.first?.text("tokenRef")
      let referenceExact = restoredReference.map { Self.equalBytes($0, Self.effectReferenceA) } ?? false
      try #require(referenceExact)
      let controlUnrotated = try Self.recordText(f).map { Data($0.utf8) } == originalControl
      try #require(controlUnrotated)
      try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
        _ = try Self.performRefEffect(
          f, input: input, snapshot: absent, reference: Self.effectReferenceA)
      }
    }
  }

  @Test func requiredReferenceHealthyMaximumRevisionCommitsWithoutChronologyMutation() async throws {
    try await Self.withFixture { f in
      _ = try Self.prepareRefEffect(f, route: .push, modern: true)
      var record = try Self.nativeRecord(f); record["revision"] = String(Int64.max)
      try Self.putRecord(f, record)
      let snapshot = try Self.capture(f)
      let input = RefEffectInput(route: .push, through: 0, ownedCount: 0)
      try Self.expectRefEffectPositive(f, input: input, snapshot: snapshot)
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
  private static func installRefEffectPostTrigger(_ f: Fixture, input: RefEffectInput) throws {
    try installRefEffectStageImage(f, input: input)
    let when =
      input.route == .mark
      ? "NOT OLD.synced AND NEW.synced AND NEW.seq=\(input.through)" : "NEW.id=1"
    try f.raw.execute(
      """
      CREATE FUNCTION ref_effect_stage.replace_reference() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE replacement text;
      BEGIN
        SELECT reference INTO STRICT replacement FROM ref_effect_stage.mode;
        UPDATE public."hubLink" SET "tokenRef"=replacement WHERE id=1;
        -- Read ACTUAL stored row after nested UPDATE. NEW can still contain A in an AFTER trigger.
        -- Complete-image equality below also proves control/tuple/classifier inputs stayed exact.
        PERFORM ref_effect_stage.assert_complete(replacement);
        PERFORM nextval('ref_effect_stage.probe');
        RETURN NEW;
      END $$;
      CREATE TRIGGER ref_effect_reference AFTER UPDATE OF \(input.route.triggerColumns)
        ON public.\(Rows.quote(input.route.triggerTable)) FOR EACH ROW WHEN(\(when))
        EXECUTE FUNCTION ref_effect_stage.replace_reference();
      """)
  }

  @Test func requiredReferenceSevenNaturalPostBodiesRollbackAndSameEnabledAtoAControlsCommit() async throws {
    for route in RefEffect.allCases {
      try await Self.withFixture { f in
        let (input, snapshot) = try Self.prepareRefEffect(f, route: route)
        try Self.installRefEffectPostTrigger(f, input: input)
        try Self.expectRefEffectRefusal(
          f, allocations: route == .claimAppend ? input.ownedCount : 0,
          probes: [("ref_effect_stage.probe", 1)]
        ) {
          _ = try Self.performRefEffect(f, input: input, snapshot: snapshot, reference: Self.effectReferenceA)
        }
        // Public rollback and all native sequence/probe observations have already happened.
        // SAME installed enabled trigger, SAME original snapshot/ref/input. Only private requested
        // replacement mode changes B -> A; no recapture, public repair, or sequence reset.
        try f.raw.execute("UPDATE ref_effect_stage.mode SET reference=$1", [Self.effectReferenceA])
        try Self.expectRefEffectPositive(
          f, input: input, snapshot: snapshot, probes: [("ref_effect_stage.probe", 1)])
        let total = try Self.finalEffectSequence(Self.finalEffectProbe(f, "ref_effect_stage.probe"))
        let bothSuccessfulStages = total.last == 2 && total.called
        #expect(bothSuccessfulStages)
        // For apply, complete image at the later cursor UPDATE includes BOTH successful rows,
        // their durable clocks, the unchanged invalid-boolean row, filtered echo, and exact cursor.
        // True no-write returns have no natural trigger and remain common-POST source obligations.
      }
    }
  }

  private static func installRefEffectCommitFault(_ f: Fixture, input: RefEffectInput) throws {
    try installRefEffectStageImage(f, input: input)
    let when =
      input.route == .mark
      ? "NOT OLD.synced AND NEW.synced AND NEW.seq=\(input.through)" : "NEW.id=1"
    try f.raw.execute(
      """
      CREATE FUNCTION ref_effect_stage.refuse_commit() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        PERFORM ref_effect_stage.assert_complete('secret:ACTIVATION_REFERENCE_EFFECT_A');
        PERFORM nextval('ref_effect_stage.probe');
        RAISE EXCEPTION 'ACTIVATION_REFERENCE_COMMIT_PRIVATE_CANARY'
          USING ERRCODE='23514',DETAIL='ACTIVATION_REFERENCE_COMMIT_PRIVATE_DETAIL';
      END $$;
      CREATE CONSTRAINT TRIGGER ref_effect_commit AFTER UPDATE OF \(input.route.triggerColumns)
        ON public.\(Rows.quote(input.route.triggerTable)) DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW WHEN(\(when)) EXECUTE FUNCTION ref_effect_stage.refuse_commit();
      """)
  }
  /// Independent explicit SQL, rather than an old or new effect API, establishes fault timing.
  /// The body returns normally; only the caller's actual COMMIT may raise the known 23514.
  private static func rawRefEffectBody(_ f: Fixture, input: RefEffectInput) throws {
    switch input.route {
    case .mark:
      try f.raw.execute(
        "UPDATE public.changes SET synced=true WHERE seq <= $1::bigint AND NOT synced",
        [String(input.through)])
    case .apply:
      // Check the same pure input discriminator, then independently model its filtered echo
      // by omitting that fourth write. No effect API supplies this raw-body expectation.
      _ = try input.batch(ownDeviceId: f.link.deviceId)
      try f.raw.execute("SET LOCAL b4app.replaying='on'")
      try f.raw.execute("UPDATE public.threads SET title=$1 WHERE id='guard-thread'", [applyTitle])
      try f.raw.execute("SAVEPOINT ordinary_skip")
      var dataError = false
      do {
        try f.raw.execute(
          "UPDATE public.threads SET archived=$1::boolean WHERE id='guard-thread'", ["not-a-boolean"])
      } catch {
        dataError = (error as? PostgresError)?.sqlState == "22P02"
        try f.raw.execute("ROLLBACK TO SAVEPOINT ordinary_skip")
      }
      try f.raw.execute("RELEASE SAVEPOINT ordinary_skip")
      guard dataError else { throw FixtureFailure.nativeShape }
      try f.raw.execute(
        "UPDATE public.environments SET name='After environment' WHERE id='guard-environment'")
      try f.raw.execute(
        """
        UPDATE public."columnClocks" SET hlc=$1 WHERE
          ("table"='threads' AND "rowId"='guard-thread' AND "column"='title') OR
          ("table"='environments' AND "rowId"='guard-environment' AND "column"='name')
        """, [applyStamp])
      try f.raw.execute("UPDATE public.\"hubLink\" SET cursor=811 WHERE id=1")
    case .claimAppend:
      try f.raw.execute(
        """
        INSERT INTO public.changes("deviceId",wall,"table","rowId",op,"column",value,synced,hlc)
          SELECT 'ACTIVATION_DEVICE_SENTINEL',floor(extract(epoch FROM statement_timestamp())*1000)::bigint,
            name,id,'insert',NULL,value,false,'000000000000-0000-ACTIVATION_DEVICE_SENTINEL'
          FROM ref_effect_stage.owned;
        UPDATE public."hubLink" SET "ownedAs"='ACTIVATION_DEVICE_SENTINEL' WHERE id=1;
        """)
    case .claimZero:
      try f.raw.execute("UPDATE public.\"hubLink\" SET \"ownedAs\"='ACTIVATION_DEVICE_SENTINEL' WHERE id=1")
    case .push:
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"lastError\"='ACTIVATION_REFERENCE_PUSH',\"lastPushAt\"='2026-11-12T07:08:09.010Z' WHERE id=1"
      )
    case .pull:
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"lastError\"='Pull: ACTIVATION_REFERENCE_PULL' WHERE id=1")
    case .pullClear:
      try f.raw.execute(
        "UPDATE public.\"hubLink\" SET \"lastError\"=NULL WHERE id=1 AND left(\"lastError\",6) COLLATE \"C\"='Pull: '"
      )
    }
  }

  @Test func requiredReferenceAllFiveCoverKnownActualDeferredCommit23514AndSameInputRecovery() async throws {
    for route in [RefEffect.mark, .apply, .claimAppend, .push, .pull] {
      try await Self.withFixture { f in
        let (input, snapshot) = try Self.prepareRefEffect(f, route: route)
        try Self.installRefEffectCommitFault(f, input: input)
        let before = try Self.state(f), probeBefore = try Self.finalEffectProbe(f, "ref_effect_stage.probe")
        var bodyReturned = false, commitAttempted = false, knownFault = false
        do {
          try f.raw.execute("BEGIN")
          try Self.rawRefEffectBody(f, input: input)
          bodyReturned = true; commitAttempted = true
          try f.raw.execute("COMMIT")
        } catch {
          if let pg = error as? PostgresError {
            knownFault =
              pg.sqlState == "23514"
              && pg.message.contains("ACTIVATION_REFERENCE_COMMIT_PRIVATE_CANARY")
              && pg.message.contains("ACTIVATION_REFERENCE_COMMIT_PRIVATE_DETAIL")
          }
          _ = try? f.raw.execute("ROLLBACK")
        }
        let after = try Self.state(f)
        let samePublicRows = after.rows == before.rows
        #expect(samePublicRows)
        try Self.expectFinalEffectAllocation(
          f, name: "public.changes_seq_seq", before: before.sequence, after: after.sequence,
          count: route == .claimAppend ? input.ownedCount : 0)
        try Self.expectFinalEffectAllocation(
          f, name: "ref_effect_stage.probe", before: probeBefore,
          after: Self.finalEffectProbe(f, "ref_effect_stage.probe"), count: 1)
        let actualCommitStage = bodyReturned && commitAttempted && knownFault
        try #require(actualCommitStage)
        // SAME still-enabled deferred fault validates original A/full control/tuple/complete body.
        // Reference PRE and POST succeed; the outer actual COMMIT alone refuses, with no result.
        try Self.expectRefEffectRefusal(
          f, allocations: route == .claimAppend ? input.ownedCount : 0,
          probes: [("ref_effect_stage.probe", 1)]
        ) {
          _ = try Self.performRefEffect(f, input: input, snapshot: snapshot, reference: Self.effectReferenceA)
        }
        try f.raw.execute("DROP TRIGGER ref_effect_commit ON public.\(Rows.quote(route.triggerTable))")
        try Self.expectRefEffectPositive(
          f, input: input, snapshot: snapshot, probes: [("ref_effect_stage.probe", 0)])
        // Only a known independently reached 23514 supports the observed rollback. Successful
        // deferred mutations after POST and unknown COMMIT outcomes are outside this contract.
      }
    }
  }

  @Test func requiredReferenceStatusesPreserveNilEmptyExactPrefixesAndSameEnabledUpdateProbe() async throws {
    try await Self.withFixture { f in
      let (_, snapshot) = try Self.prepareRefEffect(f, route: .push)
      try Self.installFinalEffectRowProbe(f)
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPushResult(
          error: nil, pushedAt: nil, expectedProtocolSnapshot: snapshot,
          expectedTokenRef: Self.effectReferenceA)
      }
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": "", "lastPushAt": ""], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPushResult(
          error: "", pushedAt: "", expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA
        )
      }
      for nonmatch in [nil, "", "pull: x", "Pull:x", "XPull: x", "Pull:"] as [String?] {
        try f.raw.execute("UPDATE public.\"hubLink\" SET \"lastError\"=$1 WHERE id=1", [nonmatch])
        try Self.expectFinalEffectPositive(f, link: [:], probes: [("guard_effect_probe.updates", 0)]) {
          try f.database.recordHubPullResult(
            error: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
        }
      }
      for error in ["", "Pull: nested", "repeat", "repeat"] {
        try Self.expectFinalEffectPositive(
          f, link: ["lastError": "Pull: " + error], probes: [("guard_effect_probe.updates", 1)]
        ) {
          try f.database.recordHubPullResult(
            error: error, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
        }
      }
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPullResult(
          error: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
        try f.database.recordHubPushResult(
          error: "ACTIVATION_STATUS\0TAIL", pushedAt: "valid",
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
        try f.database.recordHubPushResult(
          error: "valid", pushedAt: "ACTIVATION_TIME\0TAIL",
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      try Self.expectRefEffectRefusal(f, probes: [("guard_effect_probe.updates", 0)]) {
        try f.database.recordHubPullResult(
          error: "ACTIVATION_PULL\0TAIL", expectedProtocolSnapshot: snapshot,
          expectedTokenRef: Self.effectReferenceA)
      }
      // Valid original A/snapshot plus the same enabled probe. NUL never crosses native parameters.
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": "", "lastPushAt": ""], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPushResult(
          error: "", pushedAt: "", expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA
        )
      }
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": "Pull: "], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPullResult(
          error: "", expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      try Self.expectFinalEffectPositive(
        f, link: ["lastError": NSNull()], probes: [("guard_effect_probe.updates", 1)]
      ) {
        try f.database.recordHubPullResult(
          error: nil, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
    }
  }

  @Test func requiredReferenceNoWriteOwnedClaimExhaustedMarkEmptyAndSkippedApplyStillUseGuard() async throws {
    try await Self.withFixture { f in
      let (input, snapshot) = try Self.prepareRefEffect(f, route: .claimAppend)
      try Self.installFinalEffectRowProbe(f)
      try Self.expectRefEffectPositive(
        f, input: input, snapshot: snapshot, probes: [("guard_effect_probe.updates", 1)])
      try Self.expectFinalEffectPositive(f, link: [:], probes: [("guard_effect_probe.updates", 0)]) {
        let value = try f.database.claimOwnedRows(
          expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
        let exactZero = value == 0
        #expect(exactZero)
      }
      let expected = try Self.expectedGuardMark(f, through: Int.max)
      try f.database.markSynced(
        through: Int.max, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      let exact = try Self.state(f) == expected
      #expect(exact)
      try Self.expectFinalEffectPositive(f, link: [:], probes: [("guard_effect_probe.updates", 0)]) {
        try f.database.markSynced(
          through: Int.max, expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
      }
      for changes in [[], [Self.guardApplyChange("threads", "guard-thread", "archived", "not-a-boolean")]] {
        try Self.expectFinalEffectPositive(
          f, link: ["cursor": 823], probes: [("guard_effect_probe.updates", 1)]
        ) {
          let result = try f.database.applyRemote(
            changes, ownDeviceId: f.link.deviceId, macDeviceIds: [], cursor: 823,
            expectedProtocolSnapshot: snapshot, expectedTokenRef: Self.effectReferenceA)
          let exactResult = result == RemoteApplied(skipped: changes.count)
          #expect(exactResult)
        }
      }
      var refreshed = try Self.referenceFixtureValue(f.database.hubLink());
      refreshed.tokenRef = Self.effectReferenceB
      try f.database.saveHubLink(refreshed)
      try Self.expectRefEffectNoOpRefusal(
        f, route: .mark, snapshot: snapshot, reference: Self.effectReferenceA)
      // Native PRE refusal is proved for true no-write paths. Common POST routing for those
      // paths is a source-review requirement; no product callback/fake UPDATE canary is invented.
    }
  }

  private static func expectRefEffectClaim(
    _ f: Fixture, snapshot: ProtocolVerificationSnapshot, reference: String, count: Int, updatesOwnedAs: Bool,
    markers: [String] = [], probes: [(name: String, count: Int)] = []
  ) throws {
    let before = try state(f)
    let owned = try finalEffectOwnedRows(before)
    let probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    var expectedRows = try finalEffectExpectedRows(
      f, before: before, link: updatesOwnedAs ? ["ownedAs": f.link.deviceId] : [:], markers: markers)
    let lowerWall = Int64(Date().timeIntervalSince1970 * 1000)
    let outcome = Result {
      try f.database.claimOwnedRows(expectedProtocolSnapshot: snapshot, expectedTokenRef: reference)
    }
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

  private struct RefEffectWriterFacts: Sendable {
    let ready: Bool, exclusiveBlocked: Bool, released: Bool, writerJoined: Bool, markJoined: Bool
    let expectedRows: [String: [Data]]?, expectedSequence: Data?
    let controller: Result<Void, any Error>, writer: Result<Void, any Error>, mark: Result<Void, any Error>
  }
  private static func refEffectPrecedingWriterRace(
    _ f: Fixture, through: Int, snapshot: ProtocolVerificationSnapshot
  ) async -> RefEffectWriterFacts {
    let controllerThread = Mutex<Thread?>(nil)
    let facts: RefEffectWriterFacts = await withCheckedContinuation { continuation in
      controllerThread.withLock { retained in
        retained = Thread {
          let writerThread = Mutex<Thread?>(nil), markThread = Mutex<Thread?>(nil)
          let writerResult = Mutex<Result<Void, any Error>?>(nil),
            markResult = Mutex<Result<Void, any Error>?>(nil)
          let writerPID = Mutex<Int?>(nil)
          let expectedRows = Mutex<[String: [Data]]?>(nil), expectedSequence = Mutex<Data?>(nil)
          let release = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0),
            markDone = DispatchSemaphore(value: 0)
          var ready = false, exclusiveBlocked = false, markStarted = false
          var failure: (any Error)?
          writerThread.withLock { thread in
            thread = Thread {
              let outcome = Result<Void, any Error> {
                // REAL participating shared writer changes ONLY reference A -> B before exclusive acquisition.
                try f.database.write { c in
                  guard let pid = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"),
                    pid > 0
                  else { throw FixtureFailure.nativeShape }
                  writerPID.withLock { $0 = pid }
                  try c.execute(
                    "UPDATE public.\"hubLink\" SET \"tokenRef\"=$1 WHERE id=1", [effectReferenceB]
                  )
                  let own = Fixture(
                    database: f.database, raw: c, endpoint: f.endpoint, root: f.root, link: f.link,
                    binding: f.binding)
                  // Own transaction sees its exact reference-only committed intent BEFORE candidate can act.
                  let expected = try Self.state(own)
                  expectedRows.withLock { $0 = expected.rows }
                  expectedSequence.withLock { $0 = expected.sequence }
                  guard release.wait(timeout: .now() + .seconds(8)) == .success else {
                    throw FixtureFailure.barrierTimeout
                  }
                }
              }
              writerResult.withLock { $0 = outcome }; writerDone.signal()
            }
            thread?.start()
          }
          do {
            let c = try Self.membershipConnection(f.endpoint)
            let readyDeadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < readyDeadline {
              if expectedRows.withLock({ $0 != nil }) { ready = ContinuousClock.now <= readyDeadline; break }
              if writerResult.withLock({ $0 != nil }) { break }
              Thread.sleep(forTimeInterval: 0.005)
            }
            guard ready, let pid = writerPID.withLock({ $0 }) else { throw FixtureFailure.barrierTimeout }
            markThread.withLock { thread in
              thread = Thread {
                let outcome = Result<Void, any Error> {
                  try f.database.markSynced(
                    through: through, expectedProtocolSnapshot: snapshot, expectedTokenRef: effectReferenceA)
                }
                markResult.withLock { $0 = outcome }; markDone.signal()
              }
              thread?.start()
            }
            markStarted = true
            let waitDeadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < waitDeadline {
              let rows = try c.execute(
                """
                SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
                WHERE a.datname=$1 AND a.application_name='b4app' AND l.locktype='advisory'
                  AND l.mode='ExclusiveLock' AND NOT l.granted AND l.classid=0::oid
                  AND l.objid=$3::oid AND l.objsubid=1 AND $2::int=ANY(pg_blocking_pids(a.pid))
                """, [f.endpoint.database, String(pid), String(0x6234_6170)]
              ).rows
              let completed = ContinuousClock.now
              if completed <= waitDeadline, rows.count == 1 { exclusiveBlocked = true; break }
              guard completed < waitDeadline, !markResult.withLock({ $0 != nil }) else { break }
              Thread.sleep(forTimeInterval: 0.005)
            }
          } catch { failure = error }
          // Observer/controller handles close lexically before releases/joins. Always release writer,
          // then join BOTH actual operations even if stage observation failed; no Thread exit claim.
          release.signal()
          writerDone.wait()
          if markStarted { markDone.wait() }
          writerThread.withLock { $0 = nil }; markThread.withLock { $0 = nil }
          continuation.resume(
            returning: RefEffectWriterFacts(
              ready: ready, exclusiveBlocked: exclusiveBlocked, released: true, writerJoined: true,
              markJoined: markStarted,
              expectedRows: expectedRows.withLock { $0 }, expectedSequence: expectedSequence.withLock { $0 },
              controller: failure.map { .failure($0) } ?? .success(()),
              writer: writerResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape),
              mark: markResult.withLock { $0 } ?? .failure(FixtureFailure.nativeShape)))
        }
        retained?.start()
      }
    }
    controllerThread.withLock { $0 = nil }
    return facts
  }

  @Test func requiredReferenceFreshHelperOverridesRepeatableReadAndSeesPrecedingReferenceWriter() async throws
  {
    try await Self.withFixture { original in
      let (input, _) = try Self.prepareRefEffect(original, route: .mark)
      try original.raw.execute(
        """
        CREATE SCHEMA ref_effect_isolation;
        CREATE TABLE ref_effect_isolation.observed(value text NOT NULL);
        CREATE FUNCTION ref_effect_isolation.observe() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          INSERT INTO ref_effect_isolation.observed VALUES(current_setting('transaction_isolation'));
          RETURN NEW;
        END $$;
        CREATE TRIGGER ref_effect_isolation AFTER UPDATE OF synced ON public.changes FOR EACH ROW
          WHEN(NOT OLD.synced AND NEW.synced) EXECUTE FUNCTION ref_effect_isolation.observe();
        """)
      try await Self.withGuardMarkRepeatableRead(original) { f in
        let snapshot = try Self.capture(f)  // The actual FRESH object, not the closed original.
        // Independently prove the inherited pool/session default before the requiredref helper.
        let inherited = try f.database.read {
          try $0.execute("SHOW default_transaction_isolation").rows.first?.text(
            "default_transaction_isolation")
        }
        let inheritedRR = inherited == "repeatable read"
        try #require(inheritedRR)
        try Self.expectRefEffectPositive(f, input: input, snapshot: snapshot)
        let observed = try f.raw.execute(
          "SELECT count(*) AS n,bool_and(value='read committed')::text AS correct FROM ref_effect_isolation.observed"
        ).rows.first
        let actualRC = observed?.int("n") == 1 && observed?.text("correct") == "true"
        try #require(actualRC)
        let before = try Self.state(f)
        let expected = NativeState(
          rows: try Self.finalEffectExpectedRows(
            f, before: before, link: ["tokenRef": Self.effectReferenceB]),
          sequence: before.sequence)
        let facts = await Self.refEffectPrecedingWriterRace(f, through: Int.max, snapshot: snapshot)
        let stages =
          facts.ready && facts.exclusiveBlocked && facts.released && facts.writerJoined && facts.markJoined
        #expect(stages)
        // Immediate complete native state after joined refusal. The only committed change is B;
        // the later unsynced witness stays unsynced. Original snapshot-only rules still compare.
        let after = try Self.state(f)
        let exact = after == expected
        #expect(exact)
        let writerImageExact =
          facts.expectedRows == expected.rows && facts.expectedSequence == expected.sequence
        #expect(writerImageExact)
        try facts.controller.get(); try facts.writer.get()
        Self.expectRefEffectSafe { try facts.mark.get() }
        try Self.expectReadOnlyValidation(f, snapshot: snapshot, sync: true)
      }
    }
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

  @Test func requiredReferenceLocksRetainCompetingReferenceWriterUntilActualCommitOrRollback() async throws {
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
  private static func expectRefEffectRefusal(
    _ f: Fixture, allocations: Int = 0, probes: [(name: String, count: Int)] = [], body: () throws -> Void
  ) throws {
    let before = try state(f), probeBefore = try probes.map { try finalEffectProbe(f, $0.name) }
    expectRefEffectSafe(body)
    let after = try state(f)
    if allocations == 0 {
      let exact = after == before
      #expect(exact)
    } else {
      let exactRows = after.rows == before.rows
      #expect(exactRows)
      try expectFinalEffectAllocation(
        f, name: "public.changes_seq_seq", before: before.sequence, after: after.sequence, count: allocations)
    }
    for (index, probe) in probes.enumerated() {
      try expectFinalEffectAllocation(
        f, name: probe.name, before: probeBefore[index], after: finalEffectProbe(f, probe.name),
        count: probe.count)
    }
  }

  @Test func requiredReferenceValidExpectedActualSqlFaultIsFixedRedactedAndRollsBack() async throws {
    try await Self.withFixture { f in
      let (input, snapshot) = try Self.prepareRefEffect(f, route: .push)
      try f.raw.execute(
        """
        CREATE SCHEMA ref_effect_sql;
        CREATE SEQUENCE ref_effect_sql.probe;
        CREATE FUNCTION ref_effect_sql.reject_status() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF NEW."lastError" IS DISTINCT FROM 'ACTIVATION_REFERENCE_PUSH'
            OR (SELECT "tokenRef" FROM public."hubLink" WHERE id=1) IS DISTINCT FROM 'secret:ACTIVATION_REFERENCE_EFFECT_A'
          THEN RAISE EXCEPTION 'ACTIVATION_REFERENCE_SQL_STAGE_NOT_REACHED'; END IF;
          PERFORM nextval('ref_effect_sql.probe');
          RAISE EXCEPTION 'ACTIVATION_REFERENCE_SQL_PRIVATE_CANARY'
            USING ERRCODE='22000',DETAIL='ACTIVATION_REFERENCE_SQL_PRIVATE_DETAIL';
        END $$;
        CREATE TRIGGER ref_effect_sql BEFORE UPDATE OF "lastError","lastPushAt" ON public."hubLink"
          FOR EACH ROW WHEN(NEW.id=1) EXECUTE FUNCTION ref_effect_sql.reject_status();
        """)
      let before = try Self.state(f), probeBefore = try Self.finalEffectProbe(f, "ref_effect_sql.probe")
      var nativeFault = false
      do {
        try f.raw.execute("BEGIN")
        try Self.rawRefEffectBody(f, input: input)
      } catch {
        if let pg = error as? PostgresError {
          nativeFault =
            pg.sqlState == "22000" && pg.message.contains("ACTIVATION_REFERENCE_SQL_PRIVATE_CANARY")
            && pg.message.contains("ACTIVATION_REFERENCE_SQL_PRIVATE_DETAIL")
        }
      }
      _ = try? f.raw.execute("ROLLBACK")
      try Self.expectUnchanged(f, before)
      try Self.expectFinalEffectAllocation(
        f, name: "ref_effect_sql.probe", before: probeBefore,
        after: Self.finalEffectProbe(f, "ref_effect_sql.probe"), count: 1)
      try #require(nativeFault)
      try Self.expectRefEffectRefusal(f, probes: [("ref_effect_sql.probe", 1)]) {
        _ = try Self.performRefEffect(f, input: input, snapshot: snapshot, reference: Self.effectReferenceA)
      }
      try f.raw.execute("DROP TRIGGER ref_effect_sql ON public.\"hubLink\"")
      try Self.expectRefEffectPositive(
        f, input: input, snapshot: snapshot, probes: [("ref_effect_sql.probe", 0)])
    }
  }
}
