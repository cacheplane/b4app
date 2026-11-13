import Foundation
import WorkspaceProtocol

/// The account's view settings (migrations 0013 and 0014): one synced row, id `ViewSettings.rowId`.
extension WorkspaceDatabase {
  /// The stored settings, read leniently: no row, a null, or a value this build does not know is the
  /// field's default. Writes nothing.
  public func viewSettings() throws -> ViewSettings {
    try read { try Self.viewSettings($0) }
  }

  /// Write the given fields and `updatedAt`, inserting the row when it is missing; a field not given
  /// keeps its stored value, known or not. With no field given nothing is written. Returns the result.
  ///
  /// Setting `quietThreads` without `density` on a stored row whose old value implied a density
  /// (`tiny`, with no density stored: `ViewSettings.impliedDensity`) also writes that density, so the
  /// rows keep their size when the old value is replaced.
  @discardableResult
  public func setViewSettings(
    arrangement: ViewSettings.Arrangement? = nil, quietThreads: ViewSettings.QuietThreads? = nil,
    showArchived: Bool? = nil, density: ViewSettings.Density? = nil
  ) throws -> ViewSettings {
    var fields: [(column: String, param: String?)] = []
    if let arrangement { fields.append(("arrangement", arrangement.rawValue)) }
    if let quietThreads { fields.append(("quietThreads", quietThreads.rawValue)) }
    if let showArchived { fields.append(("showArchived", showArchived ? "true" : "false")) }
    if let density { fields.append(("density", density.rawValue)) }
    guard !fields.isEmpty else { return try viewSettings() }
    fields.append(("updatedAt", Timestamp.now()))
    return try write { c in
      if quietThreads != nil, density == nil,
        let stored = try c.execute(
          "SELECT \"quietThreads\", \"density\" FROM \"viewSettings\" WHERE \"id\" = $1", [ViewSettings.rowId]
        ).rows.first,
        let implied = ViewSettings.impliedDensity(
          storedQuietThreads: stored.text("quietThreads"), storedDensity: stored.text("density"))
      {
        fields.append(("density", implied.rawValue))
      }
      // One statement, so two first writes cannot both insert. A conflict fires only the update trigger,
      // which logs the columns whose value changed.
      let names = fields.map { Rows.quote($0.column) }
      let sql = """
        INSERT INTO "viewSettings" ("id", \(names.joined(separator: ", ")))
        VALUES ($1, \(fields.indices.map { "$\($0 + 2)" }.joined(separator: ", ")))
        ON CONFLICT ("id") DO UPDATE SET \(names.map { "\($0) = EXCLUDED.\($0)" }.joined(separator: ", "))
        """
      try c.execute(sql, [ViewSettings.rowId as String?] + fields.map(\.param))
      return try Self.viewSettings(c)
    }
  }

  static func viewSettings(_ c: PostgresConnection) throws -> ViewSettings {
    guard
      let row = try c.execute(
        "SELECT * FROM \"viewSettings\" WHERE \"id\" = $1", [ViewSettings.rowId]
      ).rows.first
    else { return ViewSettings() }
    return ViewSettings(
      arrangement: row.text("arrangement"), quietThreads: row.text("quietThreads"),
      showArchived: row.text("showArchived").map { $0 == "t" }, density: row.text("density"))
  }
}
