import Foundation
import Synchronization
import WorkspaceProtocol

/// Comparison classification only; neither case grants session or network authority.
package enum AccountSessionPresence: Sendable {
  case nativeAbsent, nativeLinked
}

/// Required synchronous memory-only check. Bodies must not perform SQL, scheduling, actor hops,
/// or other effects. Constructibility does not establish the provenance of a supplied body.
package final class AccountSessionComparisonCheck: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let check: @Sendable () throws -> Void

  package init(_ check: @escaping @Sendable () throws -> Void) { self.check = check }
  func requireCurrent() throws { try check() }

  package var description: String { "AccountSessionComparisonCheck(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

fileprivate struct AccountSessionCapturedContext: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let accountID: String
  let databaseName: String
  let canonicalHubBase: String
  let deviceID: String
  let tokenReference: ProtocolCredentialReference?

  fileprivate init(
    accountID: String, databaseName: String, canonicalHubBase: String, deviceID: String,
    tokenReference: ProtocolCredentialReference?
  ) {
    self.accountID = accountID
    self.databaseName = databaseName
    self.canonicalHubBase = canonicalHubBase
    self.deviceID = deviceID
    self.tokenReference = tokenReference
  }

  var description: String { "AccountSessionCapturedContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Sealed original facts and actual database object, without lifecycle owners or a native lease.
package struct AccountSessionComparisonSnapshot: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let database: WorkspaceDatabase
  fileprivate let context: AccountSessionCapturedContext
  fileprivate let facts: AccountSessionNativeFacts

  fileprivate init(
    database: WorkspaceDatabase, context: AccountSessionCapturedContext, facts: AccountSessionNativeFacts
  ) {
    self.database = database
    self.context = context
    self.facts = facts
  }

  package var presence: AccountSessionPresence {
    switch facts.link {
    case .absent: .nativeAbsent
    case .linked: .nativeLinked
    }
  }
  package var description: String { "AccountSessionComparisonSnapshot(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Unsealed storage transport. These values cannot mint a comparison snapshot outside this file.
struct AccountSessionNativeFacts: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let databaseName: String
  let link: AccountSessionNativeLink
  init(databaseName: String, link: AccountSessionNativeLink) {
    self.databaseName = databaseName
    self.link = link
  }
  var description: String { "AccountSessionNativeFacts(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum AccountSessionNativeLink: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case absent
  case linked(membership: ProtocolNativeMembership, reference: ProtocolCredentialReference)
  var description: String { "AccountSessionNativeLink(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct AccountSessionRawField: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let label: String?
  let oid: UInt32
  let isNull: Int32
  let length: Int32
  let bytes: [UInt8]?
  init(label: String?, oid: UInt32, isNull: Int32, length: Int32, bytes: [UInt8]?) {
    self.label = label
    self.oid = oid
    self.isNull = isNull
    self.length = length
    self.bytes = bytes
  }
  var description: String { "AccountSessionRawField(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct AccountSessionRawResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let rowCount: Int32
  let fieldCount: Int32
  let fields: [AccountSessionRawField]
  init(rowCount: Int32, fieldCount: Int32, fields: [AccountSessionRawField]) {
    self.rowCount = rowCount
    self.fieldCount = fieldCount
    self.fields = fields
  }
  var description: String { "AccountSessionRawResult(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum AccountSessionComparisonFailure {
  static var value: WorkspaceError {
    WorkspaceError(.internalError, "The account session comparison could not be completed.")
  }
}

enum AccountSessionFactsDecoder {
  private static let labels = [
    "database_name", "schema_ok", "native_link_id", "native_url", "native_device", "native_joined",
    "native_reference",
  ]
  private static let oids: [UInt32] = [25, 16, 23, 25, 25, 25, 25]

  static func decode(_ raw: AccountSessionRawResult) throws -> AccountSessionNativeFacts {
    guard raw.rowCount == 1, raw.fieldCount == 7, raw.fields.count == 7 else {
      throw AccountSessionComparisonFailure.value
    }
    // Exact positional ASCII labels imply uniqueness; never collapse fields into a dictionary.
    for index in labels.indices {
      guard let label = raw.fields[index].label,
        label.utf8.elementsEqual(labels[index].utf8), raw.fields[index].oid == oids[index]
      else { throw AccountSessionComparisonFailure.value }
    }
    var values: [String?] = []
    for field in raw.fields {
      guard (field.isNull == 0 || field.isNull == 1), field.length >= 0 else {
        throw AccountSessionComparisonFailure.value
      }
      if field.isNull == 1 {
        guard field.length == 0, field.bytes == nil else { throw AccountSessionComparisonFailure.value }
        values.append(nil)
      } else {
        guard let bytes = field.bytes, bytes.count == Int(field.length), !bytes.contains(0),
          let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty
        else { throw AccountSessionComparisonFailure.value }
        values.append(value)
      }
    }
    guard let databaseName = values[0], let schema = values[1], schema.utf8.elementsEqual([116]) else {
      throw AccountSessionComparisonFailure.value
    }
    if values[2] == nil {
      guard values[3...6].allSatisfy({ $0 == nil }) else { throw AccountSessionComparisonFailure.value }
      return AccountSessionNativeFacts(databaseName: databaseName, link: .absent)
    }
    guard let id = values[2], id.utf8.elementsEqual([49]), let base = values[3],
      let device = values[4], let joined = values[5], let rawReference = values[6],
      let reference = ProtocolCredentialReference(rawReference)
    else { throw AccountSessionComparisonFailure.value }
    let membership = try ProtocolNativeMembership(
      canonicalHubBase: base, deviceID: device, linkJoinedAt: joined)
    return AccountSessionNativeFacts(
      databaseName: databaseName, link: .linked(membership: membership, reference: reference))
  }

  /// Copies exact owned bytes while the caller's PGresult remains alive. The caller clears it.
  static func decodeNative(_ result: LibPQ.Result, lib: LibPQ) throws -> AccountSessionNativeFacts {
    guard lib.resultStatus(result) == LibPQ.tuplesOK, lib.ntuples(result) == 1,
      lib.nfields(result) == 7
    else { throw AccountSessionComparisonFailure.value }
    var fields: [AccountSessionRawField] = []
    for index in labels.indices {
      let column = Int32(index)
      guard let pointer = lib.fname(result, column), let label = String(validatingCString: pointer),
        label.utf8.elementsEqual(labels[index].utf8), lib.ftype(result, column) == oids[index]
      else { throw AccountSessionComparisonFailure.value }
      let isNull = lib.getisnull(result, 0, column)
      let length = lib.getlength(result, 0, column)
      guard (isNull == 0 || isNull == 1), length >= 0 else { throw AccountSessionComparisonFailure.value }
      let bytes: [UInt8]?
      if isNull == 1 {
        guard length == 0 else { throw AccountSessionComparisonFailure.value }
        bytes = nil
      } else {
        guard let value = lib.getvalue(result, 0, column) else { throw AccountSessionComparisonFailure.value }
        bytes = Array(UnsafeRawBufferPointer(start: value, count: Int(length)))
      }
      fields.append(
        AccountSessionRawField(label: label, oid: oids[index], isNull: isNull, length: length, bytes: bytes))
    }
    return try decode(AccountSessionRawResult(rowCount: 1, fieldCount: 7, fields: fields))
  }
}

extension WorkspaceDatabase {
  package func captureAccountSessionComparison(
    accountID: String, databaseName: String, hubBase: String, deviceID: String,
    tokenReference: String?, memoryCheck: AccountSessionComparisonCheck
  ) throws -> AccountSessionComparisonSnapshot {
    do {
      for value in [accountID, databaseName, deviceID] {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw AccountSessionComparisonFailure.value }
      }
      let base = try ProtocolNativeMembership.canonicalComparisonBase(hubBase)
      let reference: ProtocolCredentialReference?
      if let tokenReference {
        guard let parsed = ProtocolCredentialReference(tokenReference) else {
          throw AccountSessionComparisonFailure.value
        }
        reference = parsed
      } else {
        reference = nil
      }
      guard databaseName.utf8.elementsEqual(endpoint.database.utf8) else {
        throw AccountSessionComparisonFailure.value
      }
      let context = AccountSessionCapturedContext(
        accountID: accountID, databaseName: databaseName, canonicalHubBase: base, deviceID: deviceID,
        tokenReference: reference)
      try memoryCheck.requireCurrent()  // G0
      let facts = try readAccountSessionNativeFacts(memoryCheck: memoryCheck)
      try memoryCheck.requireCurrent()  // G9: all pool cleanup has returned.
      guard facts.databaseName.utf8.elementsEqual(endpoint.database.utf8),
        facts.databaseName.utf8.elementsEqual(context.databaseName.utf8)
      else { throw AccountSessionComparisonFailure.value }
      if case .linked(let membership, let nativeReference) = facts.link {
        guard membership.canonicalHubBase.utf8.elementsEqual(context.canonicalHubBase.utf8),
          membership.deviceID.utf8.elementsEqual(context.deviceID.utf8),
          let reference = context.tokenReference, reference == nativeReference
        else { throw AccountSessionComparisonFailure.value }
      }
      return AccountSessionComparisonSnapshot(database: self, context: context, facts: facts)
    } catch { throw AccountSessionComparisonFailure.value }
  }

  package func compareOriginalAccountSession(
    expectedSnapshot: AccountSessionComparisonSnapshot, memoryCheck: AccountSessionComparisonCheck
  ) throws {
    do {
      guard expectedSnapshot.database === self,
        expectedSnapshot.context.databaseName.utf8.elementsEqual(endpoint.database.utf8)
      else { throw AccountSessionComparisonFailure.value }
      try memoryCheck.requireCurrent()  // G0
      let facts = try readAccountSessionNativeFacts(memoryCheck: memoryCheck)
      try memoryCheck.requireCurrent()  // G9
      guard facts.databaseName.utf8.elementsEqual(endpoint.database.utf8),
        facts.databaseName.utf8.elementsEqual(expectedSnapshot.context.databaseName.utf8),
        facts.databaseName.utf8.elementsEqual(expectedSnapshot.facts.databaseName.utf8)
      else { throw AccountSessionComparisonFailure.value }
      switch (expectedSnapshot.facts.link, facts.link) {
      case (.absent, .absent): break
      case (.linked(let original, let reference), .linked(let current, let currentReference)):
        guard original == current, reference == currentReference else {
          throw AccountSessionComparisonFailure.value
        }
      default: throw AccountSessionComparisonFailure.value
      }
    } catch { throw AccountSessionComparisonFailure.value }
  }
}

// Targeted catalog compatibility deliberately does not inspect CHECK-only drift. Extra columns
// and non-key INCLUDE attributes are allowed; missing/schema/decoder errors never mean absence.
let accountSessionComparisonFactsSQL = """
  SELECT pg_catalog.current_database()::pg_catalog.text AS database_name,
         (
           EXISTS (
             SELECT 1
             FROM pg_catalog.pg_class AS c
             JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
             WHERE c.oid = 'public."hubLink"'::pg_catalog.regclass
               AND n.nspname = 'public'
               AND c.relname = 'hubLink'
               AND c.relkind = 'r'
               AND NOT c.relrowsecurity
               AND NOT c.relforcerowsecurity
               AND (
                 SELECT pg_catalog.count(*)
                 FROM (
                   VALUES ('id'::pg_catalog.text, 23::pg_catalog.oid),
                          ('url'::pg_catalog.text, 25::pg_catalog.oid),
                          ('deviceId'::pg_catalog.text, 25::pg_catalog.oid),
                          ('joinedAt'::pg_catalog.text, 25::pg_catalog.oid),
                          ('tokenRef'::pg_catalog.text, 25::pg_catalog.oid)
                 ) AS wanted(name, type_oid)
                 JOIN pg_catalog.pg_attribute AS a
                   ON a.attrelid = c.oid AND a.attname = wanted.name
                 WHERE a.attnum > 0
                   AND NOT a.attisdropped
                   AND a.atttypid = wanted.type_oid
                   AND a.attnotnull
               ) = 5
               AND EXISTS (
                 SELECT 1
                 FROM pg_catalog.pg_constraint AS p
                 JOIN pg_catalog.pg_index AS i
                   ON i.indexrelid = p.conindid AND i.indrelid = c.oid
                 JOIN pg_catalog.pg_attribute AS a
                   ON a.attrelid = c.oid AND a.attname = 'id'
                 WHERE p.conrelid = c.oid
                   AND p.contype = 'p'
                   AND p.convalidated
                   AND pg_catalog.array_length(p.conkey, 1) = 1
                   AND p.conkey[1] = a.attnum
                   AND a.attnum > 0
                   AND NOT a.attisdropped
                   AND a.atttypid = 23::pg_catalog.oid
                   AND a.attnotnull
                   AND i.indisprimary
                   AND i.indisunique
                   AND i.indisvalid
                   AND i.indisready
                   AND i.indislive
                   AND i.indnkeyatts = 1
                   AND i.indkey[0] = a.attnum
                   AND i.indexprs IS NULL
                   AND i.indpred IS NULL
               )
           )
         )::pg_catalog.bool AS schema_ok,
         l.id AS native_link_id,
         l.url AS native_url,
         l."deviceId" AS native_device,
         l."joinedAt" AS native_joined,
         l."tokenRef" AS native_reference
  FROM (SELECT 1) AS singleton
  LEFT JOIN public."hubLink" AS l ON true
  """

// Closed scalar observation seam, nil by default. It cannot own a lifecycle or native resource.
enum AccountSessionComparisonCommand: Int, Sendable {
  case begin, lockBudget, statementBudget, facts, rollback
}

enum AccountSessionComparisonPhase: Int, Sendable {
  case beforeSlotWait, afterAdmissionBeforeG1, afterOldReferenceReleaseBeforeG2
  case afterConnectBeforeG3, afterBeginBeforeG4, afterLockBudgetBeforeG5
  case afterStatementBudgetBeforeG6, afterFactsBeforeG7, afterRollbackBeforeG8
  case beforeFreshFinish, afterFreshFinishBeforeLeaseLeave, afterLeaseLeave, afterSlotSignal
}

struct AccountSessionComparisonTestHold: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let phase: AccountSessionComparisonPhase
  let expiry: DispatchTime
  init(phase: AccountSessionComparisonPhase, expiry: DispatchTime) {
    self.phase = phase
    self.expiry = expiry
  }
  var description: String { "AccountSessionComparisonTestHold(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct AccountSessionComparisonTestSample: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let sequence: UInt
  let phaseCounts: [UInt]
  let phaseSequence: [UInt]
  let acceptedGuards: UInt
  let refusedGuards: UInt
  let commandStarts: [UInt]
  let commandAcknowledgements: [UInt]
  let selectReturns: UInt
  let resultClears: [UInt]
  let factsDecoded: UInt
  let rollbackAttempts: UInt
  let rollbackAcknowledgements: UInt
  let waitStart: UInt64?
  let waitDeadline: UInt64?
  let leaseEntered: Bool
  let leaseLeft: Bool
  let slotSignalled: Bool
  let freshFinishReturned: Bool
  let holdEntered: Bool
  let holdReleased: Bool
  let holdExpired: Bool
  init(
    sequence: UInt,
    phaseCounts: [UInt],
    phaseSequence: [UInt],
    acceptedGuards: UInt,
    refusedGuards: UInt,
    commandStarts: [UInt],
    commandAcknowledgements: [UInt],
    selectReturns: UInt,
    resultClears: [UInt],
    factsDecoded: UInt,
    rollbackAttempts: UInt,
    rollbackAcknowledgements: UInt,
    waitStart: UInt64?,
    waitDeadline: UInt64?,
    leaseEntered: Bool,
    leaseLeft: Bool,
    slotSignalled: Bool,
    freshFinishReturned: Bool,
    holdEntered: Bool,
    holdReleased: Bool,
    holdExpired: Bool
  ) {
    self.sequence = sequence
    self.phaseCounts = phaseCounts
    self.phaseSequence = phaseSequence
    self.acceptedGuards = acceptedGuards
    self.refusedGuards = refusedGuards
    self.commandStarts = commandStarts
    self.commandAcknowledgements = commandAcknowledgements
    self.selectReturns = selectReturns
    self.resultClears = resultClears
    self.factsDecoded = factsDecoded
    self.rollbackAttempts = rollbackAttempts
    self.rollbackAcknowledgements = rollbackAcknowledgements
    self.waitStart = waitStart
    self.waitDeadline = waitDeadline
    self.leaseEntered = leaseEntered
    self.leaseLeft = leaseLeft
    self.slotSignalled = slotSignalled
    self.freshFinishReturned = freshFinishReturned
    self.holdEntered = holdEntered
    self.holdReleased = holdReleased
    self.holdExpired = holdExpired
  }
  var description: String { "AccountSessionComparisonTestSample(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

final class AccountSessionComparisonTestProbe: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private struct State: Sendable {
    var sequence: UInt = 0
    var phaseCounts: [UInt] = Array(repeating: 0, count: 13)
    var phaseSequence: [UInt] = Array(repeating: 0, count: 13)
    var acceptedGuards: UInt = 0
    var refusedGuards: UInt = 0
    var commandStarts: [UInt] = Array(repeating: 0, count: 5)
    var commandAcknowledgements: [UInt] = Array(repeating: 0, count: 5)
    var selectReturns: UInt = 0
    var resultClears: [UInt] = Array(repeating: 0, count: 5)
    var factsDecoded: UInt = 0
    var rollbackAttempts: UInt = 0
    var rollbackAcknowledgements: UInt = 0
    var waitStart: UInt64? = nil
    var waitDeadline: UInt64? = nil
    var leaseEntered: Bool = false
    var leaseLeft: Bool = false
    var slotSignalled: Bool = false
    var freshFinishReturned: Bool = false
    var holdEntered: Bool = false
    var holdReleased: Bool = false
    var holdExpired: Bool = false
    var sample: AccountSessionComparisonTestSample {
      AccountSessionComparisonTestSample(
        sequence: sequence,
        phaseCounts: phaseCounts,
        phaseSequence: phaseSequence,
        acceptedGuards: acceptedGuards,
        refusedGuards: refusedGuards,
        commandStarts: commandStarts,
        commandAcknowledgements: commandAcknowledgements,
        selectReturns: selectReturns,
        resultClears: resultClears,
        factsDecoded: factsDecoded,
        rollbackAttempts: rollbackAttempts,
        rollbackAcknowledgements: rollbackAcknowledgements,
        waitStart: waitStart,
        waitDeadline: waitDeadline,
        leaseEntered: leaseEntered,
        leaseLeft: leaseLeft,
        slotSignalled: slotSignalled,
        freshFinishReturned: freshFinishReturned,
        holdEntered: holdEntered,
        holdReleased: holdReleased,
        holdExpired: holdExpired)
    }
  }

  private let cell = Mutex(State())
  private let hold: AccountSessionComparisonTestHold?
  private let release = DispatchSemaphore(value: 0)

  init(hold: AccountSessionComparisonTestHold? = nil) { self.hold = hold }
  func snapshot() -> AccountSessionComparisonTestSample { cell.withLock { $0.sample } }
  var hasExpired: Bool { cell.withLock { $0.holdExpired } }

  func releaseHold() {
    let first = cell.withLock {
      guard !$0.holdReleased else { return false }
      $0.holdReleased = true
      return true
    }
    if first { release.signal() }
  }

  /// A selected wait uses its original absolute expiry once, entirely outside every cell.
  func recordPhase(_ phase: AccountSessionComparisonPhase) throws {
    let claim = cell.withLock { state in
      state.sequence += 1
      state.phaseCounts[phase.rawValue] += 1
      state.phaseSequence[phase.rawValue] = state.sequence
      guard let hold, hold.phase == phase, !state.holdEntered else { return false }
      state.holdEntered = true
      return true
    }
    if claim, let hold {
      if release.wait(timeout: hold.expiry) == .timedOut {
        cell.withLock { $0.holdExpired = true }
      }
    }
    if hasExpired { throw AccountSessionComparisonFailure.value }
  }

  func recordGuard(_ ordinal: Int, accepted: Bool) {
    cell.withLock {
      let bit = UInt(1) << (ordinal - 1)
      if accepted { $0.acceptedGuards |= bit } else { $0.refusedGuards |= bit }
    }
  }
  func recordWait(start: DispatchTime, deadline: DispatchTime) {
    cell.withLock {
      $0.waitStart = start.uptimeNanoseconds
      $0.waitDeadline = deadline.uptimeNanoseconds
    }
  }
  func recordCommandStart(_ command: AccountSessionComparisonCommand) {
    cell.withLock {
      $0.commandStarts[command.rawValue] += 1
      if command == .rollback { $0.rollbackAttempts += 1 }
    }
  }
  func recordCommandAcknowledgement(_ command: AccountSessionComparisonCommand) {
    cell.withLock {
      $0.commandAcknowledgements[command.rawValue] += 1
      if command == .rollback { $0.rollbackAcknowledgements += 1 }
    }
  }
  func recordResultClear(_ command: AccountSessionComparisonCommand) {
    cell.withLock { $0.resultClears[command.rawValue] += 1 }
  }
  func recordSelectReturn() { cell.withLock { $0.selectReturns += 1 } }
  func recordFactsDecoded() { cell.withLock { $0.factsDecoded += 1 } }
  func recordLeaseEntered() { cell.withLock { $0.leaseEntered = true } }
  func recordLeaseLeft() { cell.withLock { $0.leaseLeft = true } }
  func recordSlotSignalled() { cell.withLock { $0.slotSignalled = true } }
  func recordFreshFinishReturned() { cell.withLock { $0.freshFinishReturned = true } }

  var description: String { "AccountSessionComparisonTestProbe(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Only the fixed path calls this helper, with literal G1–G8 ordinals. G0/G9 remain outside the pool.
func requireAccountSessionComparisonGuard(
  _ ordinal: Int, memoryCheck: AccountSessionComparisonCheck, probe: AccountSessionComparisonTestProbe?
) throws {
  do {
    try memoryCheck.requireCurrent()
    probe?.recordGuard(ordinal, accepted: true)
  } catch {
    probe?.recordGuard(ordinal, accepted: false)
    throw AccountSessionComparisonFailure.value
  }
}
