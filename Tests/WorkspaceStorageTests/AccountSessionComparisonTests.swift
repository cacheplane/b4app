import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

struct AccountSessionComparisonTests {
  @Test func aCapturedAccountSessionRejectsReplacedOrNewlyLinkedCredentials() throws {
    let db = try AgentProtocolResourceFixture.database()
    defer { try? db.close() }
    let base = "https://example.invalid/hub"
    let check = AccountSessionComparisonCheck {}
    func capture(_ reference: String?) throws -> AccountSessionComparisonSnapshot {
      try db.captureAccountSessionComparison(
        accountID: "account", databaseName: db.endpoint.database, hubBase: base, deviceID: "device",
        tokenReference: reference, memoryCheck: check)
    }
    let absent = try capture(nil)
    try db.compareOriginalAccountSession(expectedSnapshot: absent, memoryCheck: check)
    var link = WorkspaceDatabase.HubLink(
      url: base, deviceId: "device", deviceName: "Mac", tokenRef: "secret:original",
      orgSlug: "display", username: "name", joinedAt: "then")
    try db.saveHubLink(link)
    #expect(throws: (any Error).self) {
      try db.compareOriginalAccountSession(expectedSnapshot: absent, memoryCheck: check)
    }
    let linked = try capture(link.tokenRef)
    try db.compareOriginalAccountSession(expectedSnapshot: linked, memoryCheck: check)
    link.tokenRef = "secret:replacement"
    try db.saveHubLink(link)
    #expect(throws: (any Error).self) {
      try db.compareOriginalAccountSession(expectedSnapshot: linked, memoryCheck: check)
    }
  }
}
