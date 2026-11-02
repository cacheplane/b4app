import Foundation
import WorkspaceProtocol

/// Plan readings and B4 token counts (migration 0006). Local to this Mac: neither table is in the
/// change log.
extension WorkspaceDatabase {
  /// Replace the connection's latest plan reading.
  public func saveUsage(connectionId: String, reading: UsageReading) throws {
    let json = String(decoding: try JSONEncoder().encode(reading), as: UTF8.self)
    try write {
      _ = try $0.execute(
        """
        INSERT INTO "usageReadings" ("connectionId", "reading", "observedAt") VALUES ($1, $2, $3)
        ON CONFLICT ("connectionId") DO UPDATE SET "reading" = EXCLUDED."reading",
          "observedAt" = EXCLUDED."observedAt"
        """,
        [connectionId, json, reading.observedAt])
    }
  }

  /// Every stored plan reading, by connection id.
  public func usageReadings() throws -> [String: UsageReading] {
    try read {
      var readings: [String: UsageReading] = [:]
      for row in try $0.execute("SELECT \"connectionId\", \"reading\" FROM \"usageReadings\"").rows {
        guard let id = row.text("connectionId"), let json = row.text("reading") else { continue }
        readings[id] = try JSONDecoder().decode(UsageReading.self, from: Data(json.utf8))
      }
      return readings
    }
  }

  /// Count a finished turn's tokens once; a second call for the same turn changes nothing.
  public func recordTokens(turnId: String, connectionId: String, total: Int, at: String) throws {
    try write {
      _ = try $0.execute(
        """
        INSERT INTO "tokenUsage" ("turnId", "connectionId", "recordedAt", "totalTokens")
        VALUES ($1, $2, $3, $4::bigint) ON CONFLICT ("turnId") DO NOTHING
        """,
        [turnId, connectionId, at, String(total)])
    }
  }

  /// Whether any of the connection's turns has reported tokens; until one has, there is no figure.
  public func hasTokenUsage(connectionId: String) throws -> Bool {
    try read {
      !(try $0.execute(
        "SELECT 1 FROM \"tokenUsage\" WHERE \"connectionId\" = $1 LIMIT 1", [connectionId]
      ).rows.isEmpty)
    }
  }

  /// Tokens the connection's turns used at or after `since` (an ISO-8601 UTC timestamp).
  public func tokenTotals(connectionId: String, since: String) throws -> Int {
    try read {
      let row = try $0.execute(
        """
        SELECT COALESCE(SUM("totalTokens"), 0)::text AS "total" FROM "tokenUsage"
        WHERE "connectionId" = $1 AND "recordedAt" >= $2
        """,
        [connectionId, since]
      ).rows.first
      return row?.text("total").flatMap(Int.init) ?? 0
    }
  }
}
