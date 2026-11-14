import Foundation
import WorkspaceProtocol

/// Owner-protected, self-contained v4 archives; produced versions1–3 remain readable. Header,
/// source context and every row share one snapshot. Restore is one exclusive atomic write; source
/// ledger/hub context is retained in the file, never installed into the target account.
enum ArchiveWriteStage: Sendable, Equatable {
  case headerWritten, fileSynchronized
}

extension WorkspaceDatabase {
  public static let archiveFormat = WorkspaceArchive.format
  public static let archiveVersion = WorkspaceArchive.version
  public static let archiveTables = WorkspaceArchive.dataTables

  public struct ArchiveSummary: Sendable, Equatable {
    public var path: String
    public var rows: Int
  }
  public func tableCounts() throws -> [String: Int] {
    try read { c in
      var counts: [String: Int] = [:]
      for table in Self.archiveTables {
        counts[table] =
          try c.execute("SELECT count(*) AS n FROM \(Rows.quote(table))").rows.first?.int("n") ?? 0
      }
      return counts
    }
  }
  @discardableResult
  public func export(to path: String) throws -> ArchiveSummary { try export(to: path, observe: nil) }

  @discardableResult
  func export(
    to path: String, observe: (@Sendable (ArchiveWriteStage) throws -> Void)?
  ) throws -> ArchiveSummary {
    do {
      return try read { c in
        // Session lock precedes BEGIN: no migration/restore can pass, while normal shared writers
        // still commit after our snapshot/header. One existing pool lease throughout.
        try c.execute("SELECT pg_advisory_lock_shared($1::bigint)", [String(Self.remoteApplyLockKey)])
        defer {
          _ = try? c.execute(
            "SELECT pg_advisory_unlock_shared($1::bigint)", [String(Self.remoteApplyLockKey)])
        }
        try c.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        do {
          try ProtocolGrantProtection.establish(c)
          let present = Set(
            try c.execute("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'").rows
              .compactMap { $0.text("tablename") })
          let schema = try WorkspaceArchive.captureSchema(c, present: present)
          var rows = 0
          try ArchivePublication.write(
            to: path,
            observe: { stage in
              if case .fileSynchronized = stage { try observe?(.fileSynchronized) }
            }
          ) { handle in
            rows = try WorkspaceArchive.write(c, schema: schema, purpose: "onDemand", handle: handle) {
              try observe?(.headerWritten)
            }
          }
          try ProtocolGrantProtection.verify(c)
          try c.execute("COMMIT")
          return ArchiveSummary(path: path, rows: rows)
        } catch { _ = try? c.execute("ROLLBACK"); throw error }
      }
    } catch {
      // Includes parser/conversion/file/privacy/callback/COMMIT errors, never a raw SQL cause.
      throw WorkspaceError(.internalError, "The protected workspace archive could not be written.")
    }
  }

  /// View settings and the local protocol comparison record do not make a destination nonempty.
  /// Restore replaces the view rows and invalidates comparison facts in the same transaction.
  /// Every other business/private row still requires explicit replace.
  @discardableResult
  public func restore(from path: String, replace: Bool = false) throws -> ArchiveSummary {
    do {
      let input = try WorkspaceArchive.read(Data(contentsOf: URL(fileURLWithPath: path)))
      return try write(exclusive: true) { c in
        try ProtocolGrantProtection.establish(c)
        // This storage guard is authoritative for direct callers too, within the SAME exclusive TX.
        guard try c.execute("SELECT 1 FROM \"hubLink\" LIMIT 1").rows.isEmpty else {
          throw WorkspaceArchive.Rejection.joined
        }
        let present = Set(
          try c.execute("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'").rows
            .compactMap { $0.text("tablename") })
        let target = try WorkspaceArchive.captureSchema(c, present: present)
        guard target.migrations == WorkspaceArchive.migrations else {
          throw WorkspaceArchive.Rejection.future
        }
        let activation = try ProtocolActivationControl.captureRestore(c)
        var populated = false
        for table in Self.archiveTables where table != "viewSettings" {
          let condition =
            table == "settings"
            ? " WHERE \"key\" IS DISTINCT FROM $1"
            : (table == "changes" || table == "columnClocks")
              ? " WHERE \"table\" IS DISTINCT FROM 'viewSettings'" : ""
          let parameters: [String?] = table == "settings" ? [ProtocolActivationControl.key] : []
          if try !c.execute("SELECT 1 FROM \(Rows.quote(table))\(condition) LIMIT 1", parameters).rows.isEmpty
          {
            populated = true
          }
        }
        guard replace || !populated else { throw WorkspaceArchive.Rejection.notEmpty }

        // Prepare EVERY argument/JSON conversion/scalar/range/column check before any replay or
        // material bind. Fixed catalog names are the only parameters used above and here.
        var prepared: [String: [(sql: String, params: [String?])]] = [:]
        for table in Self.archiveTables {
          let known = try WorkspaceArchive.columns(table, at: WorkspaceArchive.migrations.count)
          let json = try jsonColumns(c, of: table)
          for record in input.records[table] ?? [] {
            guard Set(record.row.keys).isSubset(of: known) else { throw WorkspaceArchive.Rejection.invalid }
            if table.hasPrefix("protocol") {
              for key in ["connectionId", "threadId"] {
                guard let value = record.row[key] as? String, !value.isEmpty else {
                  throw WorkspaceArchive.Rejection.invalid
                }
              }
            }
            if table == "protocolGrantSecrets" {
              guard let reference = record.row["reference"] as? String, reference.hasPrefix("secret:"),
                reference.count > 7,
                let material = record.row["material"] as? String, !material.isEmpty
              else { throw WorkspaceArchive.Rejection.invalid }
            }
            let columns = record.row.keys.sorted()
            guard !columns.isEmpty else { throw WorkspaceArchive.Rejection.invalid }
            let values = try columns.map { column -> (column: String, param: String?) in
              if column == "seq", table == "changes" {
                guard let value = record.sequence else { throw WorkspaceArchive.Rejection.invalid }
                return (column, String(value))
              }
              let value = record.row[column]!
              if json.contains(column) {
                let text = try Self.jsonbParam(value, archiveVersion: input.version)
                // JSON text stays opaque (including precision beyond Foundation numbers). Actual
                // C-string NUL is refused; jsonb syntax/escaped-NUL validity remains atomic in PG.
                if let text { try WorkspaceArchive.representable(text) }
                return (column, text)
              }
              return (column, try WorkspaceArchive.parameter(value))
            }
            prepared[table, default: []].append(Rows.insert(table, values))
          }
        }
        let sequence = try c.execute(
          "SELECT min_value::text AS minimum,max_value::text AS maximum,increment_by::text AS step,cache_size::text AS cache,cycle FROM pg_sequences WHERE schemaname='public' AND sequencename='changes_seq_seq'"
        ).rows.first
        guard let minText = sequence?.text("minimum"), let minimum = Int64(minText),
          let maxText = sequence?.text("maximum"), let maximum = Int64(maxText),
          sequence?.text("step") == "1", sequence?.text("cache") == "1", sequence?.text("cycle") == "f",
          input.nextSequence >= minimum, input.nextSequence <= maximum
        else { throw WorkspaceArchive.Rejection.invalid }
        try ProtocolGrantProtection.verify(c)
        try c.execute("SET LOCAL b4app.replaying='on'")
        // Advance only valid recorded clocks; never rewrite unknown historical strings. On a later
        // failure memory may remain safely monotonic. Waiting local writes cannot stamp before us.
        for stamp in input.clocks { clock.observe(stamp) }
        if replace {
          for table in Self.archiveTables.reversed() {
            try ProtocolGrantProtection.verify(c)
            try c.execute("DELETE FROM \(Rows.quote(table))")
          }
        }
        if !replace {
          // Only these admitted view-setting rows are replaced; no unrelated row is cleared.
          try c.execute("DELETE FROM \"viewSettings\"")
          try c.execute("DELETE FROM \"changes\" WHERE \"table\" = 'viewSettings'")
          try c.execute("DELETE FROM \"columnClocks\" WHERE \"table\" = 'viewSettings'")
          // Retain the captured destination chronology while replaying every source row normally.
          try c.execute("DELETE FROM \"settings\" WHERE \"key\" = $1", [ProtocolActivationControl.key])
        }
        for table in Self.archiveTables {
          try ProtocolGrantProtection.verify(c)
          for statement in prepared[table] ?? [] { try c.execute(statement.sql, statement.params) }
        }
        try c.execute("UPDATE \"changes\" SET \"synced\"=false")
        // This is a checked integer literal, never authority or user SQL. RESTART is transactional;
        // every restored seq was explicit, so no default nextval can escape a failed transaction.
        try c.execute("ALTER SEQUENCE \"changes_seq_seq\" RESTART WITH \(input.nextSequence)")
        try ProtocolActivationControl.invalidateAfterRestore(c, capture: activation)
        try ProtocolGrantProtection.verify(c)
        return ArchiveSummary(path: path, rows: input.dataCount)
      }
    } catch let refusal as WorkspaceArchive.Rejection {
      switch refusal {
      case .future:
        throw WorkspaceError(
          .incompatibleVersion, "The workspace archive requires a newer archive or schema version.")
      case .joined:
        throw WorkspaceError(.protocolInvalid, "Leave the hub before restoring a workspace archive.")
      case .notEmpty:
        throw WorkspaceError(
          .protocolInvalid, "The store is not empty; pass --replace to overwrite it from the archive.")
      case .invalid:
        throw WorkspaceError(.protocolInvalid, "The workspace archive is not compatible with this store.")
      }
    } catch {
      // Outer boundary includes the actual write COMMIT and all PostgreSQL DETAIL/causes.
      throw WorkspaceError(.internalError, "The protected workspace archive could not be restored.")
    }
  }

  /// The clock migration 0004 gives a change written before clocks existed.
  static func wallClock(wall: Int, deviceId: String) -> String {
    let hex = String(wall, radix: 16)
    return String(repeating: "0", count: max(0, 12 - hex.count)) + hex + "-0000-" + deviceId
  }

  /// A result cell as a Foundation JSON object (typed by the column's OID). A `json` or `jsonb` cell
  /// stays its JSON text, so the archive carries the value exactly, whatever its type.
  static func jsonObject(_ cell: Row.Cell) throws -> Any {
    guard let text = cell.text else { return NSNull() }
    switch cell.typeOID {
    case 16: return text == "t"
    case 20, 21, 23, 26: return Int(text) ?? text
    case 700, 701, 1700: return Double(text) ?? text
    default: return text
    }
  }

  /// The JSON text to bind for a `jsonb` column from an archived value: NULL for an absent cell, the
  /// text itself from a version 2 archive, and for a version 1 archive (or a value that is not a
  /// string, such as an object someone wrote into the archive by hand) the value serialised as JSON.
  static func jsonbParam(_ value: Any, archiveVersion: Int) throws -> String? {
    if value is NSNull { return nil }
    if archiveVersion >= 2, let text = value as? String { return text }
    let data = try JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
  }

  /// The table's `json` and `jsonb` columns, from the catalog.
  func jsonColumns(_ c: PostgresConnection, of table: String) throws -> Set<String> {
    Set(
      try c.execute(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND data_type IN ('json', 'jsonb')",
        [table]
      ).rows.compactMap { $0.text("column_name") })
  }
}
