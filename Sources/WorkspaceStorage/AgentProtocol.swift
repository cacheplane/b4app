import WorkspacePlatform
import WorkspaceProtocol

/// Owner-private authority, borrowed only by one synchronous storage transaction. Values never
/// enter public models, RPC, sync or diagnostics. The callback is trusted internal storage code:
/// it must not control the transaction, change privacy settings, or retain its raw connection.
final class ProtocolGrantSecretStore {
  struct Owner: Sendable, Equatable {
    let connectionId: String
    let threadId: String
  }

  private let owner: Owner
  private var connection: PostgresConnection?

  private init(connection: PostgresConnection, owner: Owner) {
    self.connection = connection
    self.owner = owner
  }

  static func transaction<T>(
    database: WorkspaceDatabase, owner: Owner,
    _ body: (PostgresConnection, ProtocolGrantSecretStore) throws -> T
  ) throws -> T {
    do {
      try requireScalar(owner.connectionId)
      try requireScalar(owner.threadId)
      // Exactly one existing write owns BEGIN, advisory ordering, rollback and COMMIT. The caller
      // writes grant metadata and its cursor through this same connection, never a nested write.
      return try database.write { connection in
        try ProtocolGrantProtection.establish(connection)
        let store = ProtocolGrantSecretStore(connection: connection, owner: owner)
        defer { store.connection = nil }
        let result = try body(connection, store)
        try ProtocolGrantProtection.verify(connection)
        return result
      }
    } catch {
      // Includes connection/privacy setup, callback and actual COMMIT failures after write's
      // rollback/mapping. Never preserve raw SQL DETAIL, material, an underlying error or a cause.
      throw failure()
    }
  }

  /// A reference is fresh; any collision refuses without overwriting an existing owner's value.
  func put(_ material: String, reference: SecretRef) throws {
    do {
      // This check MUST precede even privacy queries: an expired borrow cannot touch its old pool
      // connection after the transaction returns. Scalar refusal also precedes any bind/query.
      guard let connection else { throw Self.failure() }
      try Self.requireScalar(reference.rawValue)
      try Self.requireScalar(material)
      try ProtocolGrantProtection.verify(connection)
      try connection.execute(
        """
        INSERT INTO "protocolGrantSecrets" ("reference", "connectionId", "threadId", "material", "createdAt")
        VALUES ($1, $2, $3, $4, $5)
        """,
        [reference.rawValue, owner.connectionId, owner.threadId, material, Timestamp.now()])
    } catch {
      throw Self.failure()
    }
  }

  /// No global/reference-only lookup: the transaction's fixed connection/thread owner is required.
  func read(_ reference: SecretRef) throws -> String? {
    do {
      guard let connection else { throw Self.failure() }
      try Self.requireScalar(reference.rawValue)
      try ProtocolGrantProtection.verify(connection)
      return try connection.execute(
        """
        SELECT "material" FROM "protocolGrantSecrets"
        WHERE "reference" = $1 AND "connectionId" = $2 AND "threadId" = $3
        """,
        [reference.rawValue, owner.connectionId, owner.threadId]
      ).rows.first?.text("material")
    } catch {
      throw Self.failure()
    }
  }

  private static func requireScalar(_ value: String) throws {
    // libpq text parameters use C strings. Reject NUL rather than silently truncating into another
    // owner/reference/value. Preserve every other opaque UTF-8 byte; no trim or token/UUID parsing.
    guard !value.isEmpty, !value.utf8.contains(0) else { throw failure() }
  }

  private static func failure() -> WorkspaceError {
    WorkspaceError(.internalError, "The private protocol credential transaction could not be completed.")
  }
}

/// Internal connection protection only: no owner/material API, pool or transaction lifecycle. The
/// caller owns its existing transaction and sanitizes the entire outer boundary through COMMIT.
enum ProtocolGrantProtection {
  private enum Failure: Error { case unavailable }

  static func establish(_ connection: PostgresConnection) throws {
    try connection.execute("SET LOCAL log_error_verbosity = terse")
    try connection.execute("SET LOCAL log_parameter_max_length = 0")
    try connection.execute("SET LOCAL log_parameter_max_length_on_error = 0")
    try verify(connection)
  }

  static func verify(_ connection: PostgresConnection) throws {
    let row = try connection.execute(
      """
      SELECT current_setting('log_error_verbosity') AS verbosity,
        current_setting('log_parameter_max_length') AS parameters,
        current_setting('log_parameter_max_length_on_error') AS error_parameters,
        current_setting('debug_print_parse') AS debug_parse,
        current_setting('debug_print_rewritten') AS debug_rewritten,
        current_setting('debug_print_plan') AS debug_plan
      """
    ).rows.first
    guard row?.text("verbosity") == "terse", row?.text("parameters") == "0",
      row?.text("error_parameters") == "0", row?.text("debug_parse") == "off",
      row?.text("debug_rewritten") == "off", row?.text("debug_plan") == "off"
    else { throw Failure.unavailable }
  }
}
