import Foundation
import WorkspaceProtocol

/// Codable records to rows and back. Column names equal property names (quoted, so case survives),
/// JSON columns are `jsonb`, booleans and numbers travel as text and come back typed by the
/// column's OID, so the protocol structs decode through their ordinary `Codable` conformance.
enum Rows {
  static func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// `[(column, parameter)]` for every stored property of `value`, in a stable order.
  static func encode<T: Encodable>(_ value: T) throws -> [(column: String, param: String?)] {
    let data = try JSONCoding.encoder.encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw WorkspaceError(.internalError, "\(T.self) did not encode as an object")
    }
    return try object.keys.sorted().map { key in (key, try param(object[key]!)) }
  }

  static func param(_ any: Any) throws -> String? {
    switch any {
    case is NSNull: return nil
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
      let double = number.doubleValue
      if double == double.rounded(), abs(double) < 9.0e15 { return String(number.int64Value) }
      return String(double)
    case let string as String: return string
    default:
      let data = try JSONSerialization.data(
        withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes])
      return String(decoding: data, as: UTF8.self)
    }
  }

  static func decode<T: Decodable>(_ type: T.Type, from row: Row) throws -> T {
    var json = "{"
    var first = true
    for (name, cell) in row.cells {
      if !first { json += "," }
      first = false
      json += try jsonString(name) + ":" + jsonLiteral(cell)
    }
    json += "}"
    do {
      return try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    } catch {
      throw WorkspaceError(.internalError, "Row did not decode as \(T.self): \(error)")
    }
  }

  private static func jsonLiteral(_ cell: Row.Cell) throws -> String {
    guard let text = cell.text else { return "null" }
    switch cell.typeOID {
    case 16: return text == "t" ? "true" : "false"
    case 20, 21, 23, 26, 700, 701, 1700: return text
    case 114, 3802: return text
    default: return try jsonString(text)
    }
  }

  private static func jsonString(_ text: String) throws -> String {
    let data = try JSONCoding.encoder.encode(text)
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: Statement builders

  static func insert(
    _ table: String, _ columns: [(column: String, param: String?)], onConflict: String? = nil
  )
    -> (sql: String, params: [String?])
  {
    let names = columns.map { quote($0.column) }.joined(separator: ", ")
    let placeholders = (1...columns.count).map { "$\($0)" }.joined(separator: ", ")
    var sql = "INSERT INTO \(quote(table)) (\(names)) VALUES (\(placeholders))"
    if let onConflict { sql += " " + onConflict }
    return (sql, columns.map(\.param))
  }

  /// `UPDATE table SET ... WHERE key = $n` over every column of the table but the key; a column the
  /// record did not encode (a nil optional) becomes NULL, as it must.
  static func update(
    _ table: String, _ columns: [(column: String, param: String?)], key: String, allColumns: [String]
  ) -> (sql: String, params: [String?]) {
    let provided = Dictionary(uniqueKeysWithValues: columns.map { ($0.column, $0.param) })
    let setters = allColumns.filter { $0 != key }
    let assignments = setters.enumerated().map { "\(quote($1)) = $\($0 + 1)" }.joined(separator: ", ")
    let sql = "UPDATE \(quote(table)) SET \(assignments) WHERE \(quote(key)) = $\(setters.count + 1)"
    return (sql, setters.map { provided[$0] ?? nil } + [provided[key] ?? nil])
  }

  /// Insert, or on a key conflict update every other column (NULL for the ones the record omitted).
  static func upsert(
    _ table: String, _ columns: [(column: String, param: String?)], key: String, allColumns: [String]
  ) -> (sql: String, params: [String?]) {
    let provided = Set(columns.map(\.column))
    let setters = allColumns.filter { $0 != key }.map {
      provided.contains($0) ? "\(quote($0)) = EXCLUDED.\(quote($0))" : "\(quote($0)) = NULL"
    }
    return insert(
      table, columns,
      onConflict: "ON CONFLICT (\(quote(key))) DO UPDATE SET " + setters.joined(separator: ", "))
  }
}
