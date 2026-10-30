import Foundation
import GRDB
import WorkspaceProtocol

// Protocol structs double as GRDB records inside this module only. Column names equal property names.

/// Loss-free JSON columns. Without this GRDB would hand `JSONValue`'s single-value decoder the raw
/// column text and payloads would come back as strings.
extension JSONValue: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue {
    guard let data = try? JSONCoding.encoder.encode(self) else { return "null".databaseValue }
    return String(decoding: data, as: UTF8.self).databaseValue
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> JSONValue? {
    guard let text = String.fromDatabaseValue(dbValue) else { return nil }
    return try? JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
  }
}

extension Connection: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "connections"
}

extension LocalServer: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "localServers"
}

extension ConversationThread: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "threads"
}

extension Turn: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "turns"
}

extension DisplayItem: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "displayItems"
}

extension RuntimeRequest: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "runtimeRequests"
}

extension Draft: FetchableRecord, PersistableRecord {
  public static let databaseTableName = "drafts"
}
