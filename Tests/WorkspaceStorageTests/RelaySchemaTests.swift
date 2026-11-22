import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite struct RelaySchemaTests {
  @Test func settingsRoundTripAndAreNeverInTheChangeLog() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try db.settings(key: "keepAwake") == nil)

    let values: [JSONValue] = [
      true, "text", .number(3), ["nested": ["a", .number(1)]], .null,
    ]
    for value in values {
      try db.setSetting(key: "keepAwake", value: value)
      #expect(try db.settings(key: "keepAwake") == value)
    }
    // A second key is independent, and a write replaces rather than adds.
    try db.setSetting(key: "other", value: "x")
    try db.setSetting(key: "keepAwake", value: false)
    #expect(try db.settings(key: "keepAwake") == false)
    #expect(try db.settings(key: "other") == "x")

    // No trigger: nothing about settings reaches the change log, and none is attached to the table.
    #expect(try db.changes(after: 0).allSatisfy { $0.table != "settings" })
    let triggers = try db.read { c in
      try c.execute(
        "SELECT tgname FROM pg_trigger WHERE tgrelid = '\"settings\"'::regclass AND NOT tgisinternal"
      ).rows.count
    }
    #expect(triggers == 0)
    #expect(!WorkspaceDatabase.syncedTables.contains { $0.table == "settings" })
  }

  @Test func connectionEnvironmentIsLoggedAndClearedWhenItsEnvironmentIsDeleted() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.insertEnvironment(WorkEnvironment(id: "p1"), folders: ["/tmp/a"])
    _ = try db.insertConnection(
      Connection(id: "c1", kind: .b4, label: "B4", target: "http://127.0.0.1:1", environmentId: "p1"))
    #expect(try db.connection(id: "c1")?.environmentId == "p1")
    let insert = try #require(try db.changes(after: 0).first { $0.table == "connections" })
    #expect(insert.value?["environmentId"] == .string("p1"))

    try db.setConnectionEnvironment(id: "c1", environmentId: nil)
    #expect(try db.connection(id: "c1")?.environmentId == nil)
    try db.setConnectionEnvironment(id: "c1", environmentId: "p1")
    let moves = try db.changes(after: 0).filter { $0.table == "connections" && $0.column == "environmentId" }
    // A cleared column is a SQL NULL in the log, which decodes as no value.
    #expect(moves.map(\.value) == [nil, .string("p1")])

    // The environment's deletion leaves the connection, unassigned.
    try db.deleteEnvironment(id: "p1")
    #expect(try db.connection(id: "c1")?.environmentId == nil)
    // An environment that does not exist is refused, not silently dropped.
    #expect(throws: WorkspaceError.self) {
      try db.setConnectionEnvironment(id: "c1", environmentId: "missing")
    }
  }

  @Test func aConnectionWithoutAEnvironmentIdStillDecodes() throws {
    let json = """
      {"id":"c1","kind":"codex","label":"Codex","enabled":true,"profileRevision":0,"target":"/x",
       "capabilities":{},"status":"ready","authStatus":"authenticated","createdAt":"now","updatedAt":"now"}
      """
    let connection = try JSONCoding.decoder.decode(Connection.self, from: Data(json.utf8))
    #expect(connection.environmentId == nil)
  }
}
