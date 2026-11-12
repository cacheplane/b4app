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
      let contextless = try #require(f.database.readProtocolFact(expectedBinding: f.binding))
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
