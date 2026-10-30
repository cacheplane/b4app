import Foundation
import GRDB
import WorkspaceProtocol

// Protocol structs double as GRDB records inside this module only. Column names equal property names.

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
