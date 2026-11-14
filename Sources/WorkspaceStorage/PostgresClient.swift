import Foundation
import Synchronization
import WorkspaceProtocol

/// A result row: column name to text value (nil for SQL NULL) plus the column's type OID, enough
/// to rebuild JSON for the Codable records.
struct Row: Sendable {
  struct Cell: Sendable {
    var text: String?
    var typeOID: UInt32
  }
  var cells: [String: Cell]

  func text(_ column: String) -> String? { cells[column]?.text }
  func int(_ column: String) -> Int? { cells[column]?.text.flatMap(Int.init) }
}

/// One libpq connection. Not thread-safe; the pool hands it to one caller at a time.
final class PostgresConnection: @unchecked Sendable {
  private let lib: LibPQ
  private let conn: LibPQ.Conn

  init(lib: LibPQ, connectionString: String) throws {
    self.lib = lib
    guard let conn = lib.connectdb(connectionString) else {
      throw WorkspaceError(.endpointUnavailable, "libpq could not allocate a connection")
    }
    guard lib.status(conn) == LibPQ.connectionOK else {
      let message = lib.errorMessage(conn).map { String(cString: $0) } ?? "unknown error"
      lib.finish(conn)
      throw WorkspaceError(
        .endpointUnavailable,
        "PostgreSQL connection failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    self.conn = conn
  }

  deinit { lib.finish(conn) }

  var isHealthy: Bool { lib.status(conn) == LibPQ.connectionOK }

  /// Run a statement with text parameters; returns the rows (empty for commands) and the affected count.
  @discardableResult
  func execute(_ sql: String, _ params: [String?] = []) throws -> (rows: [Row], affected: Int) {
    let result: LibPQ.Result?
    if params.isEmpty {
      result = lib.exec(conn, sql)
    } else {
      // Keep every C string alive for the duration of the call.
      let storage: [UnsafeMutablePointer<CChar>?] = params.map { $0.flatMap { strdup($0) } }
      defer { storage.forEach { free($0.map { UnsafeMutableRawPointer($0) }) } }
      let pointers: [UnsafePointer<CChar>?] = storage.map { $0.map { UnsafePointer($0) } }
      result = pointers.withUnsafeBufferPointer { buffer in
        lib.execParams(conn, sql, Int32(params.count), nil, buffer.baseAddress, nil, nil, 0)
      }
    }
    defer { lib.clear(result) }
    let status = lib.resultStatus(result)
    guard status == LibPQ.commandOK || status == LibPQ.tuplesOK else {
      let message = lib.resultErrorMessage(result).map { String(cString: $0) } ?? "unknown error"
      let state = lib.resultErrorField(result, LibPQ.sqlStateField).map { String(cString: $0) } ?? ""
      throw PostgresError(
        sqlState: state, message: message.trimmingCharacters(in: .whitespacesAndNewlines), sql: sql)
    }
    var rows: [Row] = []
    if status == LibPQ.tuplesOK {
      let count = lib.ntuples(result)
      let fields = lib.nfields(result)
      let names = (0..<fields).map { lib.fname(result, $0).map { String(cString: $0) } ?? "" }
      let types = (0..<fields).map { lib.ftype(result, $0) }
      rows.reserveCapacity(Int(count))
      for r in 0..<count {
        var cells: [String: Row.Cell] = [:]
        for f in 0..<fields {
          let isNull = lib.getisnull(result, r, f) != 0
          let text = isNull ? nil : lib.getvalue(result, r, f).map { String(cString: $0) }
          cells[names[Int(f)]] = Row.Cell(text: text, typeOID: types[Int(f)])
        }
        rows.append(Row(cells: cells))
      }
    }
    let affected = lib.cmdTuples(result).flatMap { Int(String(cString: $0)) } ?? 0
    return (rows, affected)
  }
}

/// A PostgreSQL error with its SQLSTATE, surfaced as a `WorkspaceError` by the store.
struct PostgresError: Error, CustomStringConvertible {
  var sqlState: String
  var message: String
  var sql: String
  var description: String { "[\(sqlState)] \(message)" }
  /// 23505 unique_violation, 23503 foreign_key_violation, 23514 check_violation.
  var isConstraintViolation: Bool { sqlState.hasPrefix("23") }
}

/// A fixed-size pool of connections to one database. `withConnection` blocks until one is free,
/// which keeps the store's API synchronous.
final class ConnectionPool: @unchecked Sendable {
  private let lib: LibPQ
  private let connectionString: String
  private let idle = Mutex<[PostgresConnection]>([])
  private let slots: DispatchSemaphore
  private let closed = Mutex(false)
  private let leases = DispatchGroup()

  init(lib: LibPQ, connectionString: String, size: Int) throws {
    self.lib = lib
    self.connectionString = connectionString
    self.slots = DispatchSemaphore(value: size)
    // Fail fast when the cluster is unreachable.
    let probe = try PostgresConnection(lib: lib, connectionString: connectionString)
    idle.withLock { $0.append(probe) }
  }

  func withConnection<T>(
    beforeWaiting: () -> Void = {}, _ body: (PostgresConnection) throws -> T
  ) throws -> T {
    if closed.withLock({ $0 }) { throw WorkspaceError(.endpointUnavailable, "The store is closed.") }
    // An internal observation seam for deterministic checkout/close boundary tests.
    beforeWaiting()
    slots.wait()
    defer { slots.signal() }
    // Close may have run while this caller waited for a slot. Admission and idle access share the
    // closed -> idle lock order with close and with returning a borrowed connection.
    var connection = try closed.withLock { isClosed in
      guard !isClosed else { throw WorkspaceError(.endpointUnavailable, "The store is closed.") }
      // Register admission while close is excluded. A pre-slot waiter has no lease to drain.
      leases.enter()
      return idle.withLock { $0.popLast() }
    }
    // Install before lazy creation or the body can throw. Every admitted path leaves exactly once.
    defer { leases.leave() }
    if connection == nil || connection?.isHealthy == false {
      connection = try PostgresConnection(lib: lib, connectionString: connectionString)
    }
    let live = connection!
    defer {
      if live.isHealthy {
        closed.withLock { isClosed in
          if !isClosed { idle.withLock { $0.append(live) } }
        }
      }
    }
    return try body(live)
  }

  func close() {
    closed.withLock {
      $0 = true
      idle.withLock { $0.removeAll() }
    }
  }

  /// Close admission, then wait only for admitted leases. Ordinary close remains nonwaiting.
  /// False leaves the pool closed and never authorizes migration capture or DDL.
  func closeForMigration(timeout: Duration) -> Bool {
    // Truncate sub-nanosecond fractions, saturate overflow, and start the deadline before close so
    // time spent closing does not extend the caller's budget. Nonpositive durations check now.
    let parts = max(timeout, .zero).components
    let (whole, wholeOverflow) = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (nanos, fractionOverflow) = whole.addingReportingOverflow(parts.attoseconds / 1_000_000_000)
    let interval = wholeOverflow || fractionOverflow ? Int.max : Int(max(0, nanos))
    let deadline = DispatchTime.now() + .nanoseconds(interval)
    close()
    return leases.wait(timeout: deadline) == .success
  }
}
extension ConnectionPool {
  func withOwnedProofConnection(
    onSlotWait: (DispatchTime, DispatchTime) -> Void = { _, _ in },
    _ body: (PostgresConnection) -> ProtocolOwnedProofWriteReceipt
  ) throws -> ProtocolOwnedProofWriteReceipt {
    if closed.withLock({ $0 }) {
      throw WorkspaceError(.endpointUnavailable, "The store is closed.")
    }
    let start = DispatchTime.now()
    let deadline = start + .seconds(5)
    onSlotWait(start, deadline)
    guard slots.wait(timeout: deadline) == .success else {
      throw WorkspaceError(
        .endpointUnavailable, "Timed out waiting for a proof-write connection.")
    }
    defer { slots.signal() }
    try admitOwnedProofCheckout()
    defer { leases.leave() }
    return try freshOwnedProofReceipt(body)
  }

  private func admitOwnedProofCheckout() throws {
    var displaced: PostgresConnection? = try closed.withLock { isClosed in
      guard !isClosed else {
        throw WorkspaceError(.endpointUnavailable, "The store is closed.")
      }
      leases.enter()
      return idle.withLock { $0.popLast() }
    }
    // Both pool mutex cells have been left before relinquishing this path's old reference.
    withExtendedLifetime(displaced) {}
    displaced = nil
  }

  private func freshOwnedProofReceipt(
    _ body: (PostgresConnection) -> ProtocolOwnedProofWriteReceipt
  ) throws -> ProtocolOwnedProofWriteReceipt {
    let connection = try PostgresConnection(lib: lib, connectionString: connectionString)
    return body(connection)
  }
}
