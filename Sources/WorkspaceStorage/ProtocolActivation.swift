import CoreFoundation
import Foundation
import WorkspaceProtocol

/// Comparison identity only. The caller must establish the authenticated account and physical
/// scope separately; a stored binding grants no authority to contact or activate an agent.
public struct ProtocolMembershipBinding: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let accountID: String
  public let canonicalHubBase: String
  public let hubUserID: String
  public let hubOrgID: String
  public let deviceID: String
  public let databaseName: String
  public let linkJoinedAt: String

  public init(
    accountID: String, canonicalHubBase: String, hubUserID: String, hubOrgID: String,
    deviceID: String, databaseName: String, linkJoinedAt: String
  ) throws {
    for value in [accountID, canonicalHubBase, hubUserID, hubOrgID, deviceID, databaseName, linkJoinedAt] {
      try ProtocolActivationControl.requireIdentity(value)
    }
    self.accountID = accountID
    self.canonicalHubBase = try ProtocolActivationControl.canonicalBase(canonicalHubBase)
    self.hubUserID = hubUserID
    self.hubOrgID = hubOrgID
    self.deviceID = deviceID
    self.databaseName = databaseName
    self.linkJoinedAt = linkJoinedAt
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    zip(lhs.values, rhs.values).allSatisfy { ProtocolActivationControl.bytesEqual($0.0, $0.1) }
  }
  fileprivate var values: [String] {
    [accountID, canonicalHubBase, hubUserID, hubOrgID, deviceID, databaseName, linkJoinedAt]
  }
  public var description: String { "ProtocolMembershipBinding(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Caller-supplied comparison data, never proof of an authenticated HTTP response or admission.
public struct ProtocolVerificationObservation: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let binding: ProtocolMembershipBinding
  public let reportedMinimum: Int
  public let reportedVersion: Int
  public let healthy: Bool

  public init(
    binding: ProtocolMembershipBinding, reportedMinimum: Int, reportedVersion: Int, healthy: Bool
  ) throws {
    guard reportedMinimum == 2, reportedVersion >= 2, healthy else { throw ProtocolActivationControl.failure }
    self.binding = binding
    self.reportedMinimum = reportedMinimum
    self.reportedVersion = reportedVersion
    self.healthy = healthy
  }
  public var description: String { "ProtocolVerificationObservation(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// A comparison snapshot strongly holds its actual database object, but holds no pool/account
/// lease. Closing that database still closes admission; another object cannot redeem it.
public struct ProtocolVerificationSnapshot: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let database: WorkspaceDatabase
  fileprivate let record: ProtocolActivationControl.Record
  public var observation: ProtocolVerificationObservation? { record.observation }
  fileprivate init(database: WorkspaceDatabase, record: ProtocolActivationControl.Record) {
    self.database = database
    self.record = record
  }
  public var description: String { "ProtocolVerificationSnapshot(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum ProtocolMembershipChange: Sendable, Equatable { case preserveIfUnchanged, replace }

extension WorkspaceDatabase {
  public func prepareProtocolVerification(
    expectedBinding: ProtocolMembershipBinding
  ) throws -> ProtocolVerificationSnapshot {
    do {
      return try write(exclusive: true) { c in
        let state = try ProtocolActivationControl.state(c, locking: true)
        try ProtocolActivationControl.requireMembership(
          state, binding: expectedBinding, endpoint: endpoint.database)
        var record =
          try state.control.map(ProtocolActivationControl.decode)
          ?? ProtocolActivationControl.Record.fresh(revision: 0)
        if let binding = record.binding {
          guard binding == expectedBinding else { throw ProtocolActivationControl.failure }
        } else {
          // Initial creation binds revision0. Binding an existing inactive record is a mutation.
          if state.control != nil { record.revision = try ProtocolActivationControl.next(record.revision) }
          record.binding = expectedBinding
          try ProtocolActivationControl.store(c, record, insertingOnly: state.control == nil)
        }
        return ProtocolVerificationSnapshot(database: self, record: record)
      }
    } catch { throw ProtocolActivationControl.failure }
  }

  public func readProtocolFact(
    expectedBinding: ProtocolMembershipBinding
  ) throws -> ProtocolVerificationSnapshot? {
    do {
      return try read { c in
        let state = try ProtocolActivationControl.state(c, locking: false)
        try ProtocolActivationControl.requireDatabase(
          state, binding: expectedBinding, endpoint: endpoint.database)
        guard let text = state.control else { return nil }
        let record = try ProtocolActivationControl.decode(text)
        guard let binding = record.binding else { return nil }
        guard binding == expectedBinding else { throw ProtocolActivationControl.failure }
        try ProtocolActivationControl.requireMembership(
          state, binding: expectedBinding, endpoint: endpoint.database)
        return ProtocolVerificationSnapshot(database: self, record: record)
      }
    } catch { throw ProtocolActivationControl.failure }
  }

  public func commitObservedProtocolFact(
    expectedSnapshot: ProtocolVerificationSnapshot, observation: ProtocolVerificationObservation
  ) throws -> ProtocolVerificationSnapshot {
    do {
      guard expectedSnapshot.database === self,
        expectedSnapshot.record.binding == observation.binding
      else { throw ProtocolActivationControl.failure }
      return try write(exclusive: true) { c in
        let state = try ProtocolActivationControl.state(c, locking: true)
        try ProtocolActivationControl.requireMembership(
          state, binding: observation.binding, endpoint: endpoint.database)
        guard let text = state.control else { throw ProtocolActivationControl.failure }
        var record = try ProtocolActivationControl.decode(text)
        guard record == expectedSnapshot.record else { throw ProtocolActivationControl.failure }
        record.revision = try ProtocolActivationControl.next(record.revision)
        record.observation = observation
        try ProtocolActivationControl.store(c, record)
        return ProtocolVerificationSnapshot(database: self, record: record)
      }
    } catch { throw ProtocolActivationControl.failure }
  }
}

/// Internal transaction-borrowing seams. No helper begins/commits a transaction, awaits work,
/// or exposes the private record. Public wrappers cover the actual outer COMMIT with safe errors.
enum ProtocolActivationControl {
  static let key = "__b4app_agent_protocol_activation_v1"
  static let failure = WorkspaceError(
    .internalError, "The protocol verification comparison could not be completed.")

  static func requireGenericSettingKey(_ key: String) throws {
    guard !key.utf8.contains(0), !bytesEqual(key, Self.key) else { throw failure }
  }

  struct RestoreCapture {
    fileprivate let preparedRevision: Int64
  }
  static func captureRestore(_ c: PostgresConnection) throws -> RestoreCapture {
    do {
      let text = try c.execute(
        "SELECT value::text AS control FROM public.settings WHERE key=$1 FOR UPDATE", [key]
      )
      .rows.first?.text("control")
      // Refuse a known exhausted destination BEFORE the caller replays any archive rows or
      // restarts a sequence. Imported chronology is never consulted.
      let revision = try text.map { try next(decode($0).revision) } ?? 0
      return RestoreCapture(preparedRevision: revision)
    } catch { throw failure }
  }
  static func invalidateAfterRestore(_ c: PostgresConnection, capture: RestoreCapture) throws {
    do {
      try store(c, Record.fresh(revision: capture.preparedRevision))
    } catch { throw failure }
  }

  /// The borrowing transaction must first SELECT the actual id1 hubLink row FOR UPDATE,
  /// including when clearing it, before entering this control-row lock. Preserve link→control
  /// order used by prepare/commit; this helper neither owns nor nests that transaction.
  static func mutateMembership(
    _ c: PostgresConnection, oldLink: WorkspaceDatabase.HubLink?, newLink: WorkspaceDatabase.HubLink?,
    change: ProtocolMembershipChange
  ) throws {
    do {
      guard
        let text = try c.execute(
          "SELECT value::text AS control FROM public.settings WHERE key=$1 FOR UPDATE", [key]
        ).rows.first?.text("control")
      else { return }
      var record = try decode(text)
      // Nil newLink denotes every clear, including an already-empty one. Labels/token/cursor
      // are deliberately excluded; a routine unchanged refresh never rewrites the JSONB row.
      if change == .preserveIfUnchanged, let oldLink, let newLink,
        try sameMembership(oldLink, newLink)
      {
        return
      }
      record.revision = try next(record.revision)
      record.membershipIncarnation = UUID().uuidString
      record.binding = nil
      record.observation = nil
      try store(c, record)
    } catch { throw failure }
  }

  fileprivate static func requireIdentity(_ value: String) throws {
    guard !value.isEmpty, !value.utf8.contains(0) else { throw failure }
  }
  fileprivate static func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

  fileprivate static func canonicalBase(_ value: String) throws -> String {
    do {
      try requireIdentity(value)  // Before Foundation parsing or any native text parameter.
      guard let components = URLComponents(string: value), components.user == nil,
        components.password == nil, components.query == nil, components.fragment == nil,
        let delimiter = value.range(of: "://")
      else { throw failure }
      let scheme = String(value[..<delimiter.lowerBound]).lowercased()
      let remainder = value[delimiter.upperBound...]
      let split = remainder.firstIndex(of: "/") ?? remainder.endIndex
      let authority = String(remainder[..<split]).lowercased()
      var required = scheme + "://" + authority + String(remainder[split...])
      while required.hasSuffix("/") { required.removeLast() }
      let canonical = try HubURL.canonical(value)
      // Validate through the existing helper, but never silently fold a deployment path, escape,
      // explicit port, or ambiguous spelling that Foundation could not preserve.
      guard bytesEqual(canonical, required) else { throw failure }
      return canonical
    } catch { throw failure }
  }

  private static func sameMembership(
    _ a: WorkspaceDatabase.HubLink, _ b: WorkspaceDatabase.HubLink
  ) throws -> Bool {
    try requireIdentity(a.deviceId); try requireIdentity(b.deviceId)
    try requireIdentity(a.joinedAt); try requireIdentity(b.joinedAt)
    return try bytesEqual(canonicalBase(a.url), canonicalBase(b.url))
      && bytesEqual(a.deviceId, b.deviceId) && bytesEqual(a.joinedAt, b.joinedAt)
  }

  fileprivate struct Record: Sendable, Equatable {
    var storeIncarnation: String
    var membershipIncarnation: String
    var revision: Int64
    var binding: ProtocolMembershipBinding?
    var observation: ProtocolVerificationObservation?
    static func fresh(revision: Int64) -> Self {
      Self(
        storeIncarnation: UUID().uuidString, membershipIncarnation: UUID().uuidString,
        revision: revision, binding: nil, observation: nil)
    }
    static func == (a: Self, b: Self) -> Bool {
      bytesEqual(a.storeIncarnation, b.storeIncarnation)
        && bytesEqual(a.membershipIncarnation, b.membershipIncarnation)
        && a.revision == b.revision && a.binding == b.binding && a.observation == b.observation
    }
  }
  fileprivate struct State {
    let database: String
    let control: String?
    let url: String?
    let device: String?
    let joined: String?
  }
  fileprivate static func state(_ c: PostgresConnection, locking: Bool) throws -> State {
    // Writes first lock the actual link tuple, so even a native writer outside the advisory
    // convention cannot replace it between comparison and fact write. Membership saves/clears
    // use this same link→control order. The read API remains exactly ONE native statement.
    if locking {
      try c.execute("SELECT id FROM public.\"hubLink\" WHERE id=1 FOR UPDATE")
    }
    // Scalar subqueries read record/link/database together, including the absent-row case.
    let lock = locking ? " FOR UPDATE" : ""
    let rows = try c.execute(
      """
      SELECT current_database() AS database,
        (SELECT value::text FROM public.settings WHERE key=$1\(lock)) AS control,
        l.url, l."deviceId" AS device, l."joinedAt" AS joined
      FROM (SELECT 1) singleton LEFT JOIN public."hubLink" l ON l.id=1
      """, [key]
    ).rows
    guard rows.count == 1, let row = rows.first, let database = row.text("database") else { throw failure }
    return State(
      database: database, control: row.text("control"), url: row.text("url"),
      device: row.text("device"), joined: row.text("joined"))
  }
  fileprivate static func requireDatabase(
    _ state: State, binding: ProtocolMembershipBinding, endpoint: String
  ) throws {
    guard bytesEqual(state.database, endpoint), bytesEqual(binding.databaseName, endpoint) else {
      throw failure
    }
  }
  fileprivate static func requireMembership(
    _ state: State, binding: ProtocolMembershipBinding, endpoint: String
  ) throws {
    try requireDatabase(state, binding: binding, endpoint: endpoint)
    guard let url = state.url, let device = state.device, let joined = state.joined else { throw failure }
    try requireIdentity(device); try requireIdentity(joined)
    guard try bytesEqual(canonicalBase(url), binding.canonicalHubBase),
      bytesEqual(device, binding.deviceID), bytesEqual(joined, binding.linkJoinedAt)
    else { throw failure }
  }
  fileprivate static func next(_ revision: Int64) throws -> Int64 {
    let (next, overflow) = revision.addingReportingOverflow(1)
    guard revision >= 0, !overflow else { throw failure }
    return next
  }

  private static let bindingKeys: Set<String> = [
    "accountID", "canonicalHubBase", "hubUserID", "hubOrgID", "deviceID", "databaseName", "linkJoinedAt",
  ]
  private static func dictionary(_ value: Any) throws -> [String: Any] {
    guard let result = value as? [String: Any] else { throw failure }
    return result
  }
  private static func exactInteger(_ value: Any?) throws -> Int64 {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      let integer = Int64(n.stringValue), bytesEqual(String(integer), n.stringValue)
    else { throw failure }
    return integer
  }
  private static func uuid(_ value: Any?) throws -> String {
    guard let text = value as? String, let uuid = UUID(uuidString: text), bytesEqual(text, uuid.uuidString)
    else { throw failure }
    return text
  }
  private static func decodeBinding(_ value: Any) throws -> ProtocolMembershipBinding {
    let object = try dictionary(value)
    guard Set(object.keys) == bindingKeys else { throw failure }
    var strings: [String: String] = [:]
    for key in bindingKeys {
      guard let text = object[key] as? String else { throw failure }
      strings[key] = text
    }
    guard let account = strings["accountID"], let base = strings["canonicalHubBase"],
      let user = strings["hubUserID"], let org = strings["hubOrgID"], let device = strings["deviceID"],
      let database = strings["databaseName"], let joined = strings["linkJoinedAt"]
    else { throw failure }
    let binding = try ProtocolMembershipBinding(
      accountID: account, canonicalHubBase: base, hubUserID: user,
      hubOrgID: org, deviceID: device, databaseName: database, linkJoinedAt: joined)
    guard bytesEqual(binding.canonicalHubBase, base) else { throw failure }
    return binding
  }
  fileprivate static func decode(_ text: String) throws -> Record {
    let object = try dictionary(JSONSerialization.jsonObject(with: Data(text.utf8)))
    let required: Set<String> = ["version", "storeIncarnation", "membershipIncarnation", "revision"]
    guard required.isSubset(of: Set(object.keys)),
      Set(object.keys).isSubset(of: required.union(["binding", "observation"])),
      try exactInteger(object["version"]) == 1, let revisionText = object["revision"] as? String,
      let revision = Int64(revisionText), revision >= 0, bytesEqual(String(revision), revisionText)
    else { throw failure }
    let binding = try object["binding"].map(decodeBinding)
    var observation: ProtocolVerificationObservation?
    if let value = object["observation"] {
      let facts = try dictionary(value)
      guard Set(facts.keys) == Set(["binding", "reportedMinimum", "reportedVersion", "healthy"]),
        let observedBinding = facts["binding"], let healthy = facts["healthy"] as? NSNumber,
        CFGetTypeID(healthy) == CFBooleanGetTypeID(), healthy.boolValue,
        let binding
      else { throw failure }
      let matched = try decodeBinding(observedBinding)
      guard matched == binding, try exactInteger(facts["reportedMinimum"]) == 2,
        let version = Int(exactly: try exactInteger(facts["reportedVersion"]))
      else { throw failure }
      observation = try ProtocolVerificationObservation(
        binding: matched, reportedMinimum: 2,
        reportedVersion: version, healthy: true)
    }
    return try Record(
      storeIncarnation: uuid(object["storeIncarnation"]),
      membershipIncarnation: uuid(object["membershipIncarnation"]), revision: revision,
      binding: binding, observation: observation)
  }
  private static func bindingObject(_ binding: ProtocolMembershipBinding) -> [String: Any] {
    Dictionary(
      uniqueKeysWithValues: zip(
        [
          "accountID", "canonicalHubBase", "hubUserID", "hubOrgID", "deviceID", "databaseName",
          "linkJoinedAt",
        ], binding.values
      ).map { ($0.0, $0.1 as Any) })
  }
  fileprivate static func store(
    _ c: PostgresConnection, _ record: Record, insertingOnly: Bool = false
  ) throws {
    var object: [String: Any] = [
      "version": 1, "storeIncarnation": record.storeIncarnation,
      "membershipIncarnation": record.membershipIncarnation, "revision": String(record.revision),
    ]
    if let binding = record.binding { object["binding"] = bindingObject(binding) }
    if let observation = record.observation {
      object["observation"] =
        [
          "binding": bindingObject(observation.binding),
          "reportedMinimum": observation.reportedMinimum, "reportedVersion": observation.reportedVersion,
          "healthy": observation.healthy,
        ] as [String: Any]
    }
    let text = String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    // Initial prepare must never overwrite a row inserted since its absent-state read. Existing
    // locked mutations and restore invalidation retain their ordinary replacement behavior.
    let conflict = insertingOnly ? "" : " ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value"
    let changed = try c.execute(
      "INSERT INTO public.settings(key,value) VALUES($1,$2::jsonb)" + conflict, [key, text]
    ).affected
    guard changed == 1 else { throw failure }
    // A positive native equality witness covers the WHOLE candidate, not just affected count.
    // Suppressed/rewritten fields cannot produce a snapshot of facts that were never stored.
    let stored = try c.execute(
      "SELECT (value=$2::jsonb)::text AS matches FROM public.settings WHERE key=$1", [key, text]
    ).rows
    guard stored.count == 1, stored.first?.text("matches") == "true" else { throw failure }
  }
}
