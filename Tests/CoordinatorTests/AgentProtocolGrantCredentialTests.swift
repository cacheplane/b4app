import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

struct AgentProtocolGrantCredentialTests {
  @Test func grantAndMetadataCommitTogetherWithoutExposingMaterial() throws {
    let database = try WorkspaceDatabase.temporary()
    defer { try? database.close() }
    let connection = try HistoricalCoordinatorFixture.seedDormantConnection(database)
    let thread = try database.insertThread(
      ConversationThread(
        id: "grant-thread", connectionId: connection.id, nativeThreadId: "native",
        nativeScope: try #require(connection.nativeScope), title: "Grant"))
    let owner = ProtocolGrantSecretStore.Owner(connectionId: connection.id, threadId: thread.id)
    let reference = SecretRef.make()
    let material = "private-grant-" + UUID().uuidString
    let before = try database.changes(after: 0)
    func writeGrant(rollback: Bool) throws {
      try ProtocolGrantSecretStore.transaction(database: database, owner: owner) { c, store in
        try store.put(material, reference: reference)
        try c.execute(
          """
          INSERT INTO "protocolGrants" ("threadId","pausedGeneration","namespace","interruptId",
            "proposalHash","connectionId","grantReference","disposition","updatedAt")
          VALUES ($1,'generation','[]','interrupt','proposal',$2,$3,'allow','now')
          """, [thread.id, connection.id, reference.rawValue])
        let privacy = try c.execute(
          """
          SELECT current_setting('log_parameter_max_length') AS normal,
            current_setting('log_parameter_max_length_on_error') AS errors
          """
        ).rows.first
        #expect(privacy?.text("normal") == "0" && privacy?.text("errors") == "0")
        if rollback { throw WorkspaceError(.internalError, material) }
      }
    }

    do {
      try writeGrant(rollback: true)
      Issue.record("The failed grant transaction committed.")
    } catch let error as WorkspaceError {
      #expect(error.message == "The private protocol credential transaction could not be completed.")
      #expect(error.details == nil)
    }
    // Reusing both primary keys succeeds only if neither write from the first attempt survived.
    try writeGrant(rollback: false)
    let matched = try ProtocolGrantSecretStore.transaction(database: database, owner: owner) { _, store in
      try store.read(reference) == material
    }
    #expect(matched)
    #expect(try database.changes(after: 0) == before)
  }
}
