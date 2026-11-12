import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// Opaque UTF-8, never decoded through JSONValue/Double. PostgreSQL validates JSON and normalizes
/// jsonb spelling inside the protected transaction; this does not preserve original wire lexemes.
/// There is no public raw getter or Codable conformance that could put private facts on RPC/sync.
public struct ProtocolProjectionJSON: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  fileprivate let source: String
  public init(utf8: Data) throws {
    guard let text = String(data: utf8, encoding: .utf8), !text.utf8.contains(0) else {
      throw ProjectionStore.failure()
    }
    source = text
  }
  public var description: String { "ProtocolProjectionJSON(private)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// A captured physical store and exact profile/thread binding, not an activation or account lease.
/// SessionService must retain/recheck its account lease and A4 admission before using this API.
public struct ProtocolProjectionOwner: Sendable, CustomReflectable {
  public let connectionId: String
  public let threadId: String
  public let nativeThreadId: String
  fileprivate let database: WorkspaceDatabase
  fileprivate let binding: [String?]
  fileprivate let peerProfile: String
  public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum ProtocolProjectionEpoch: Sendable, Equatable {
  case b4(String)
  case local(String)
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind && lhs.id.utf8.elementsEqual(rhs.id.utf8)
  }
  fileprivate var kind: String { if case .b4 = self { "b4" } else { "local" } }
  fileprivate var id: String {
    switch self {
    case .b4(let id), .local(let id): id
    }
  }
}

public struct ProtocolProjectionCoverage: Sendable {
  public let channels: [String]
  public let namespaces: [[String]]
  fileprivate let descriptor: ProtocolProjectionJSON
  public init(channels: [String], namespaces: [[String]], descriptor: ProtocolProjectionJSON) {
    self.channels = channels; self.namespaces = namespaces; self.descriptor = descriptor
  }
}

/// Returned only by this store after checking the bound subscription. The local revision is a
/// canonical ISO timestamp CAS, independent of upstream seq and local viewer/sync sequences.
public struct ProtocolProjectionPrecondition: Sendable {
  public let epoch: ProtocolProjectionEpoch
  public let appliedEventId: String?
  public let appliedSequence: UInt64?
  public let revision: String
  fileprivate let owner: ProtocolProjectionOwner
  fileprivate let coverage: ProtocolProjectionCoverage
}

public enum ProtocolProjectionPosition: Sendable {
  case b4(eventId: String, sequence: UInt64)
  /// Complete replacement images only. No invented generic upstream event ID or replay promise.
  case genericImage
}

/// One canonical standard message image. Its established role and raw message ID do not change
/// with content kind or Run continuation. Tool facts remain private; tool presentation is deferred.
public struct ProtocolProjectionPresentation: Sendable {
  public enum Content: Sendable { case text(String), unknown }
  public let nativeItemId: String
  public let role: DisplayItemRole
  public let content: Content
  public init(nativeItemId: String, role: DisplayItemRole, content: Content) {
    self.nativeItemId = nativeItemId; self.role = role; self.content = content
  }
}

/// Whole private partial-state images, never additive deltas. Root/predecessor associations can be
/// filled once, but a conflict refuses. No incoming event can acknowledge a local operation: existing
/// localTurnId/submissionId are preserved; A6 receipt reconciliation is a separate future boundary.
public struct ProtocolProjectionSegment: Sendable {
  public let namespace: [String]
  public let nativeRunId: String
  public let rootRunId: String?
  public let predecessorRunId: String?
  fileprivate let facts: ProtocolProjectionJSON
  public let presentation: [ProtocolProjectionPresentation]
  public init(
    namespace: [String], nativeRunId: String, rootRunId: String? = nil,
    predecessorRunId: String? = nil, facts: ProtocolProjectionJSON,
    presentation: [ProtocolProjectionPresentation] = []
  ) {
    self.namespace = namespace; self.nativeRunId = nativeRunId; self.rootRunId = rootRunId
    self.predecessorRunId = predecessorRunId; self.facts = facts; self.presentation = presentation
  }
}

public struct ProtocolProjectionBatch: Sendable {
  fileprivate let precondition: ProtocolProjectionPrecondition
  fileprivate let position: ProtocolProjectionPosition
  fileprivate let segments: [ProtocolProjectionSegment]
  public init(
    precondition: ProtocolProjectionPrecondition, position: ProtocolProjectionPosition,
    segments: [ProtocolProjectionSegment]
  ) {
    self.precondition = precondition; self.position = position; self.segments = segments
  }
}

public struct ProtocolProjectionCommit: Sendable {
  public let changedItemIds: [String]
  public let appliedSequence: UInt64?
  public let revision: String
}

// Inert in production. No raw connection, private value or transaction control crosses this seam.
enum ProtocolProjectionStage: String, Sendable { case segments, presentation, cursor }

extension WorkspaceDatabase {
  public func protocolProjectionOwner(
    connectionId: String, threadId: String
  ) throws -> ProtocolProjectionOwner {
    try ProjectionStore.transaction(self) { c in
      try ProjectionStore.text(connectionId); try ProjectionStore.text(threadId)
      return try ProjectionStore.owner(self, c, connectionId: connectionId, threadId: threadId)
    }
  }

  /// Initialize an absent subscription only. Reconfiguration/coverage widening requires A7 and is
  /// deliberately unavailable here; an existing exact subscription is returned without rewriting it.
  public func prepareProtocolProjection(
    owner: ProtocolProjectionOwner, epoch: ProtocolProjectionEpoch,
    coverage: ProtocolProjectionCoverage
  ) throws -> ProtocolProjectionPrecondition {
    try ProjectionStore.transaction(self) { c in
      try ProjectionStore.checkOwner(self, c, owner)
      let encoded = try ProjectionStore.coverage(c, owner: owner, epoch: epoch, coverage: coverage)
      if try ProjectionStore.subscription(c, threadId: owner.threadId) == nil {
        let stamp = try ProjectionStore.nextStamp(c, after: nil)
        try c.execute(
          """
          INSERT INTO public."protocolSubscriptions"
            ("threadId","connectionId","nativeThreadId",generation,"localObservationEpoch",channels,namespaces,coverage,"updatedAt")
          VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8::jsonb,$9)
          """,
          [
            owner.threadId, owner.connectionId, owner.nativeThreadId,
            epoch.kind == "b4" ? epoch.id : nil, epoch.kind == "local" ? epoch.id : nil,
            encoded.channels, encoded.namespaces, encoded.binding, stamp,
          ])
      }
      return try ProjectionStore.state(c, owner: owner, epoch: epoch, coverage: coverage, encoded: encoded)
    }
  }

  /// Re-read after restart or an uncertain COMMIT result. No lost-reply rollback assertion, reset,
  /// raw facts read or replay dispatch is performed by this storage foundation.
  public func protocolProjectionState(
    owner: ProtocolProjectionOwner, epoch: ProtocolProjectionEpoch,
    coverage: ProtocolProjectionCoverage
  ) throws -> ProtocolProjectionPrecondition {
    try ProjectionStore.transaction(self) { c in
      try ProjectionStore.checkOwner(self, c, owner)
      let encoded = try ProjectionStore.coverage(c, owner: owner, epoch: epoch, coverage: coverage)
      return try ProjectionStore.state(c, owner: owner, epoch: epoch, coverage: coverage, encoded: encoded)
    }
  }

  public func applyProtocolProjection(_ batch: ProtocolProjectionBatch) throws -> ProtocolProjectionCommit {
    try applyProtocolProjection(batch, observe: nil)
  }

  func applyProtocolProjection(
    _ batch: ProtocolProjectionBatch,
    observe: ((ProtocolProjectionStage) throws -> Void)?
  ) throws -> ProtocolProjectionCommit {
    try ProjectionStore.transaction(self) { c in
      let expected = batch.precondition, owner = expected.owner
      try ProjectionStore.checkOwner(self, c, owner)
      let encoded = try ProjectionStore.coverage(
        c, owner: owner, epoch: expected.epoch, coverage: expected.coverage)
      let current = try ProjectionStore.state(
        c, owner: owner, epoch: expected.epoch, coverage: expected.coverage, encoded: encoded)
      guard current.revision == expected.revision,
        ProjectionStore.equal(current.appliedEventId, expected.appliedEventId),
        current.appliedSequence == expected.appliedSequence
      else { throw ProjectionStore.failure() }
      let next = try ProjectionStore.position(batch.position, after: current)
      // Validate all native JSON and identities before the first mutation. No opaque numeric parse.
      var keys = Set<Data>()
      var messages: [Data: ProtocolProjectionPresentation] = [:]
      for segment in batch.segments {
        try ProjectionStore.validate(c, segment, expected.coverage)
        guard keys.insert(ProjectionStore.identity(owner, expected.epoch, segment, item: nil)).inserted else {
          throw ProjectionStore.failure()
        }
        for item in segment.presentation {
          let identity = ProjectionStore.identity(owner, expected.epoch, segment, item: item.nativeItemId)
          if let prior = messages[identity] {
            guard ProjectionStore.sameImage(prior, item) else { throw ProjectionStore.failure() }
          } else {
            messages[identity] = item
          }
        }
      }
      let stamp = try ProjectionStore.nextStamp(c, after: current.revision)
      var linked: [(ProtocolProjectionSegment, String?)] = []
      for segment in batch.segments {
        linked.append((segment, try ProjectionStore.saveSegment(c, owner, expected.epoch, segment, stamp)))
      }
      try observe?(.segments)
      var changed: [String] = []
      var changedIdentities = Set<Data>()
      for (segment, localTurn) in linked {
        for item in segment.presentation {
          let id = try ProjectionStore.savePresentation(
            c, owner, expected.epoch, segment, item, localTurn, stamp)
          if changedIdentities.insert(Data(id.utf8)).inserted { changed.append(id) }
        }
      }
      try observe?(.presentation)
      // Owner/subscription locks and CAS precede all mutations; replay position advances last.
      let advanced = try c.execute(
        """
        UPDATE public."protocolSubscriptions" SET "appliedEventId"=$2,"appliedSeq"=$3::bigint,"updatedAt"=$4
        WHERE "threadId"=$1
        """, [owner.threadId, next.event, next.sequence.map { String($0) }, stamp])
      guard advanced.affected == 1 else { throw ProjectionStore.failure() }
      try observe?(.cursor)
      return ProtocolProjectionCommit(
        changedItemIds: changed, appliedSequence: next.sequence, revision: stamp)
    }
  }
}

private enum ProjectionStore {
  static let maximumSequence: UInt64 = 9_007_199_254_740_991
  static func failure() -> WorkspaceError {
    WorkspaceError(.protocolInvalid, "The protocol projection could not be committed.")
  }
  // Swift String equality normalizes canonically equivalent Unicode. Native opaque identities do
  // not: compare UTF-8 bytes (and use Data for duplicate sets) at every binding/namespace boundary.
  static func equal(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): lhs.utf8.elementsEqual(rhs.utf8)
    case (nil, nil): true
    default: false
    }
  }
  static func text(_ value: String, empty: Bool = false) throws {
    guard (empty || !value.isEmpty), !value.utf8.contains(0) else { throw failure() }
  }
  static func transaction<T>(_ db: WorkspaceDatabase, _ body: (PostgresConnection) throws -> T) throws -> T {
    do {
      // Existing shared remoteApply fence precedes owner/subscription row locks. Exactly one BEGIN
      // and actual COMMIT, including privacy verification and deferred SQL failures, is sanitized.
      return try db.write { c in
        try ProtocolGrantProtection.establish(c)
        let value = try body(c)
        try ProtocolGrantProtection.verify(c)
        return value
      }
    } catch { throw failure() }
  }
  static func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  static let profileFields = [
    "id", "kind", "enabled", "profileRevision", "target", "peerProfile", "agentId", "nativeScope", "authMode",
    "authHeaderName", "authReference",
  ]
  static let threadFields = [
    "id", "connectionId", "nativeThreadId", "nativeScope", "continuity", "userDeletedAt",
  ]

  static func owner(
    _ db: WorkspaceDatabase, _ c: PostgresConnection, connectionId: String, threadId: String
  ) throws -> ProtocolProjectionOwner {
    // Fixed order shared with future tailored A6 operations: connection, thread, subscription.
    guard
      let profile = try c.execute(
        "SELECT \(profileFields.map(Rows.quote).joined(separator: ",")) FROM public.connections WHERE id=$1 FOR UPDATE",
        [connectionId]
      ).rows.first,
      profile.text("kind") == "agentProtocol", profile.text("enabled") == "t",
      let peer = profile.text("peerProfile"), ["b4", "agentProtocol"].contains(peer),
      let revision = profile.text("profileRevision"), let number = Int(revision), number >= 0,
      let mode = profile.text("authMode"), ["none", "bearer", "header"].contains(mode),
      let target = profile.text("target"), !target.isEmpty,
      let agent = profile.text("agentId"), !agent.isEmpty,
      let scope = profile.text("nativeScope"), !scope.isEmpty
    else { throw failure() }
    if mode != "none" {
      guard let reference = profile.text("authReference"), reference.hasPrefix("secret:"), reference.count > 7
      else { throw failure() }
    }
    guard
      let thread = try c.execute(
        "SELECT \(threadFields.map(Rows.quote).joined(separator: ",")) FROM public.threads WHERE id=$1 FOR UPDATE",
        [threadId]
      ).rows.first,
      equal(thread.text("connectionId"), connectionId), equal(thread.text("nativeScope"), scope),
      thread.text("continuity") == "available", thread.text("userDeletedAt") == nil,
      let native = thread.text("nativeThreadId"), !native.isEmpty
    else { throw failure() }
    return ProtocolProjectionOwner(
      connectionId: connectionId, threadId: threadId, nativeThreadId: native,
      database: db, binding: profileFields.map { profile.text($0) } + threadFields.map { thread.text($0) },
      peerProfile: peer)
  }
  static func checkOwner(
    _ db: WorkspaceDatabase, _ c: PostgresConnection, _ captured: ProtocolProjectionOwner
  ) throws {
    guard captured.database === db else { throw failure() }
    let now = try owner(db, c, connectionId: captured.connectionId, threadId: captured.threadId)
    guard now.binding.count == captured.binding.count,
      zip(now.binding, captured.binding).allSatisfy({ equal($0.0, $0.1) })
    else { throw failure() }
  }

  struct EncodedCoverage { let channels: String; let namespaces: String; let binding: String }
  static func coverage(
    _ c: PostgresConnection, owner: ProtocolProjectionOwner, epoch: ProtocolProjectionEpoch,
    coverage: ProtocolProjectionCoverage
  ) throws -> EncodedCoverage {
    try text(epoch.id)
    switch epoch {
    case .b4(let generation):
      guard owner.peerProfile == "b4", UUID(uuidString: generation)?.uuidString.lowercased() == generation
      else { throw failure() }
    case .local: guard owner.peerProfile == "agentProtocol" else { throw failure() }
    }
    guard !coverage.channels.isEmpty, !coverage.namespaces.isEmpty,
      Set(coverage.channels.map { Data($0.utf8) }).count == coverage.channels.count,
      Set(coverage.namespaces.map(framed)).count == coverage.namespaces.count
    else { throw failure() }
    for channel in coverage.channels { try text(channel) }
    for namespace in coverage.namespaces { for component in namespace { try text(component, empty: true) } }
    try object(c, coverage.descriptor)
    // Storage owns this wrapper. A freshly captured changed profile cannot adopt the old cursor.
    // The caller's opaque descriptor stays private and never goes through a Foundation number.
    let binding =
      "{\"format\":\"protocol-projection-v1\",\"owner\":\(try json(owner.binding)),\"descriptor\":\(coverage.descriptor.source)}"
    return EncodedCoverage(
      channels: try json(coverage.channels), namespaces: try json(coverage.namespaces), binding: binding)
  }
  static func subscription(_ c: PostgresConnection, threadId: String) throws -> Row? {
    try c.execute(#"SELECT * FROM public."protocolSubscriptions" WHERE "threadId"=$1 FOR UPDATE"#, [threadId])
      .rows.first
  }
  static func state(
    _ c: PostgresConnection, owner: ProtocolProjectionOwner, epoch: ProtocolProjectionEpoch,
    coverage: ProtocolProjectionCoverage, encoded: EncodedCoverage
  ) throws -> ProtocolProjectionPrecondition {
    guard let row = try subscription(c, threadId: owner.threadId),
      equal(row.text("connectionId"), owner.connectionId),
      equal(row.text("nativeThreadId"), owner.nativeThreadId),
      equal(row.text("generation"), epoch.kind == "b4" ? epoch.id : nil),
      equal(row.text("localObservationEpoch"), epoch.kind == "local" ? epoch.id : nil),
      let stamp = row.text("updatedAt"), canonicalStamp(stamp)
    else { throw failure() }
    let validStamp = try c.execute(
      """
      WITH input AS (SELECT $1::text AS raw)
      SELECT to_char(raw::timestamptz AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')=raw AS valid FROM input
      """, [stamp]
    ).rows.first?.text("valid")
    guard validStamp == "t" else { throw failure() }
    let exact = try c.execute(
      """
      SELECT channels=$2::jsonb AND namespaces=$3::jsonb AND coverage=$4::jsonb AS exact
      FROM public."protocolSubscriptions" WHERE "threadId"=$1
      """, [owner.threadId, encoded.channels, encoded.namespaces, encoded.binding]
    ).rows.first?.text("exact")
    guard exact == "t" else { throw failure() }
    let event = row.text("appliedEventId"), raw = row.text("appliedSeq")
    let sequence = raw.flatMap(UInt64.init)
    if epoch.kind == "b4", let sequence {
      guard sequence > 0, sequence <= maximumSequence, event == "b4e1.\(epoch.id).\(sequence)" else {
        throw failure()
      }
    } else {
      guard event == nil, raw == nil else { throw failure() }
    }
    return ProtocolProjectionPrecondition(
      epoch: epoch, appliedEventId: event, appliedSequence: sequence,
      revision: stamp, owner: owner, coverage: coverage)
  }
  static func canonicalStamp(_ stamp: String) -> Bool {
    stamp.range(
      of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$"#, options: .regularExpression)
      != nil
  }
  static func nextStamp(_ c: PostgresConnection, after prior: String?) throws -> String {
    if let prior { guard canonicalStamp(prior) else { throw failure() } }
    // Native date validity/roundtrip is checked before advancing; no parse of any opaque fact.
    let row = try c.execute(
      """
      WITH input AS (SELECT $1::text AS raw)
      SELECT to_char(GREATEST(clock_timestamp(),COALESCE(raw::timestamptz,'-infinity'::timestamptz)+interval '1 microsecond')
        AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS stamp,
        (raw IS NULL OR to_char(raw::timestamptz AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')=raw) AS valid FROM input
      """, [prior]
    ).rows.first
    guard row?.text("valid") == "t", let stamp = row?.text("stamp"), canonicalStamp(stamp) else {
      throw failure()
    }
    if let prior { guard stamp > prior else { throw failure() } }
    return stamp
  }
  static func position(
    _ next: ProtocolProjectionPosition, after state: ProtocolProjectionPrecondition
  ) throws -> (event: String?, sequence: UInt64?) {
    switch (state.epoch, next) {
    case (.b4(let generation), .b4(let event, let sequence)):
      guard sequence > (state.appliedSequence ?? 0), sequence <= maximumSequence,
        event == "b4e1.\(generation).\(sequence)"
      else { throw failure() }
      return (event, sequence)
    case (.local, .genericImage): return (nil, nil)
    default: throw failure()
    }
  }
  static func object(_ c: PostgresConnection, _ value: ProtocolProjectionJSON) throws {
    guard
      try c.execute("SELECT jsonb_typeof($1::jsonb) AS kind", [value.source]).rows.first?.text("kind")
        == "object"
    else { throw failure() }
  }
  static func validate(
    _ c: PostgresConnection, _ segment: ProtocolProjectionSegment, _ coverage: ProtocolProjectionCoverage
  ) throws {
    try text(segment.nativeRunId)
    if let root = segment.rootRunId { try text(root) }
    if let previous = segment.predecessorRunId { try text(previous) }
    for component in segment.namespace { try text(component, empty: true) }
    guard
      coverage.namespaces.contains(where: { prefix in
        segment.namespace.count >= prefix.count
          && zip(segment.namespace, prefix).allSatisfy { equal($0.0, $0.1) }
      })
    else { throw failure() }
    try object(c, segment.facts)
    var itemIds = Set<Data>()
    for item in segment.presentation {
      try text(item.nativeItemId)
      guard itemIds.insert(Data(item.nativeItemId.utf8)).inserted, coverage.channels.contains("messages")
      else { throw failure() }
      if case .text(let body) = item.content {
        guard item.role == .user || item.role == .assistant else { throw failure() }
        try text(body, empty: true)
      }
    }
  }
  static func framed(_ components: [String]) -> Data {
    var result = Data()
    for component in components {
      result.append(contentsOf: String(component.utf8.count).utf8)
      result.append(0x3a)
      result.append(contentsOf: component.utf8)
    }
    return result
  }
  static func identity(
    _ owner: ProtocolProjectionOwner, _ epoch: ProtocolProjectionEpoch,
    _ segment: ProtocolProjectionSegment, item: String?
  ) -> Data {
    // Explicit decimal UTF-8 byte lengths, namespace component count and versioned kind. Identity
    // is independent of Foundation JSON escaping choices and never relies on a hash collision.
    let prefix = [
      item == nil ? "protocol-segment-v1" : "protocol-message-v1", owner.connectionId,
      owner.threadId, owner.nativeThreadId, epoch.kind, epoch.id, String(segment.namespace.count),
    ]
    // A message belongs to the Thread/epoch/namespace, not the referencing Run. Continuations may
    // carry the same canonical message ID; the segment Run is an association, not message identity.
    return framed(prefix + segment.namespace + [item ?? segment.nativeRunId])
  }
  static func saveSegment(
    _ c: PostgresConnection, _ owner: ProtocolProjectionOwner, _ epoch: ProtocolProjectionEpoch,
    _ segment: ProtocolProjectionSegment, _ stamp: String
  ) throws -> String? {
    let key: [String?] = [
      owner.connectionId, owner.threadId, epoch.kind, epoch.id, try json(segment.namespace),
      segment.nativeRunId,
    ]
    let old = try c.execute(
      """
      SELECT "rootRunId","predecessorRunId","localTurnId" FROM public."protocolRunSegments"
      WHERE "connectionId"=$1 AND "threadId"=$2 AND "identityEpochKind"=$3 AND "identityEpochId"=$4
        AND namespace=$5::jsonb AND "nativeRunId"=$6 FOR UPDATE
      """, key
    ).rows.first
    for (column, incoming) in [
      ("rootRunId", segment.rootRunId), ("predecessorRunId", segment.predecessorRunId),
    ] {
      if let stored = old?.text(column), let incoming, !equal(stored, incoming) { throw failure() }
    }
    try ProtocolGrantProtection.verify(c)
    let saved = try c.execute(
      """
      INSERT INTO public."protocolRunSegments" AS retained
        ("connectionId","threadId","identityEpochKind","identityEpochId",namespace,"nativeRunId","rootRunId","predecessorRunId",facts,"updatedAt")
      VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7,$8,$9::jsonb,$10)
      ON CONFLICT ("connectionId","threadId","identityEpochKind","identityEpochId",namespace,"nativeRunId") DO UPDATE SET
        "rootRunId"=COALESCE(retained."rootRunId",EXCLUDED."rootRunId"),
        "predecessorRunId"=COALESCE(retained."predecessorRunId",EXCLUDED."predecessorRunId"),
        facts=EXCLUDED.facts,"updatedAt"=EXCLUDED."updatedAt"
      """, key + [segment.rootRunId, segment.predecessorRunId, segment.facts.source, stamp])
    guard saved.affected == 1 else { throw failure() }
    return old?.text("localTurnId")
  }
  static func sameImage(_ lhs: ProtocolProjectionPresentation, _ rhs: ProtocolProjectionPresentation) -> Bool
  {
    guard lhs.role == rhs.role else { return false }
    switch (lhs.content, rhs.content) {
    case (.unknown, .unknown): return true
    case (.text(let lhs), .text(let rhs)): return equal(lhs, rhs)
    default: return false
    }
  }
  static func savePresentation(
    _ c: PostgresConnection, _ owner: ProtocolProjectionOwner, _ epoch: ProtocolProjectionEpoch,
    _ segment: ProtocolProjectionSegment, _ item: ProtocolProjectionPresentation, _ localTurn: String?,
    _ stamp: String
  ) throws -> String {
    // Keep exact raw namespace separately in the segment; this local composite ID is never an
    // upstream selector. Full length-framed identity is retained, not a hash used as equality proof.
    let id = "protocol.v1." + identity(owner, epoch, segment, item: item.nativeItemId).base64EncodedString()
    let old = try c.execute(
      #"SELECT "threadId","turnId","nativeItemId",role FROM public."displayItems" WHERE id=$1 FOR UPDATE"#,
      [id]
    ).rows.first
    if let old {
      guard equal(old.text("threadId"), owner.threadId), equal(old.text("nativeItemId"), id),
        old.text("role") == item.role.rawValue
      else { throw failure() }
      if let turn = old.text("turnId") {
        // An unresolved continuation does not remove or manufacture the established message link.
        // Two known unequal links refuse; never infer the continuation's own acceptance from this.
        if let localTurn { guard equal(turn, localTurn) else { throw failure() } }
        guard
          try c.execute(
            #"SELECT 1 FROM public.turns WHERE id=$1 AND "threadId"=$2"#,
            [turn, owner.threadId]
          ).rows.count == 1
        else { throw failure() }
      }
    }
    let content: [String: String]
    let type: String
    switch item.content {
    case .text(let text): content = ["text": text]; type = item.role == .user ? "userMessage" : "agentMessage"
    case .unknown: content = ["text": "Unsupported protocol content."]; type = "unknown"
    }
    let payload = try json(content)
    let saved: (rows: [Row], affected: Int)
    if old == nil {
      saved = try c.execute(
        """
        INSERT INTO public."displayItems" (id,"threadId","turnId","nativeItemId",role,type,payload,"sequence",provenance,"createdAt")
        SELECT $1,$2,$3,$1,$4,$5,$6::jsonb,COALESCE(MAX("sequence"),-1)+1,'live',$7
        FROM public."displayItems" WHERE "threadId"=$2
        """, [id, owner.threadId, localTurn, item.role.rawValue, type, payload, stamp])
    } else {
      saved = try c.execute(
        """
        UPDATE public."displayItems" SET "turnId"=COALESCE("turnId",$2),role=$3,type=$4,payload=$5::jsonb,provenance='live' WHERE id=$1
        """, [id, localTurn, item.role.rawValue, type, payload])
    }
    guard saved.affected == 1 else { throw failure() }
    return id
  }
}
