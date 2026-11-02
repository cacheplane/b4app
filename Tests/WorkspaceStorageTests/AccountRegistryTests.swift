import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite struct AccountRegistryTests {
  /// A registry in its own database on the shared test cluster, so tests never collide on `registry`.
  private func makeRegistry() throws -> AccountRegistry {
    let endpoint = try EphemeralPostgres.endpoint()
    let name = "registry_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return try AccountRegistry(endpoint: endpoint, binDir: endpoint.binDir!, databaseName: name)
  }

  private func row(
    _ id: String = AccountRegistry.newId(), hubURL: String = "https://hub.example.com",
    hubUserId: String = "user-1"
  ) -> AccountRow {
    AccountRow(
      id: id, hubURL: hubURL, hubUserId: hubUserId, deviceId: "device-\(id)",
      database: AccountRegistry.databaseName(id: id), displayName: "Brian", orgName: "Acme",
      tokenRef: nil, lastSignedInAt: nil, active: false)
  }

  @Test func insertFindActivate() throws {
    let registry = try makeRegistry()
    #expect(try registry.all().isEmpty)
    #expect(try registry.active() == nil)

    let account = row()
    try registry.insert(account)
    #expect(try registry.all() == [account])
    #expect(try registry.find(hubURL: account.hubURL, hubUserId: account.hubUserId) == account)
    #expect(try registry.find(hubURL: account.hubURL, hubUserId: "other") == nil)
    #expect(try registry.find(hubURL: "https://other.example.com", hubUserId: account.hubUserId) == nil)

    try registry.activate(id: account.id, tokenRef: "secret-ref")
    let active = try #require(try registry.active())
    #expect(active.id == account.id)
    #expect(active.active)
    #expect(active.tokenRef == "secret-ref")
    let signedInAt = try #require(active.lastSignedInAt)
    #expect(Timestamp.date(from: signedInAt) != nil)

    try registry.remove(id: account.id)
    #expect(try registry.all().isEmpty)
  }

  @Test func activateIsExclusive() throws {
    let registry = try makeRegistry()
    let first = row(hubUserId: "user-1")
    let second = row(hubUserId: "user-2")
    try registry.insert(first)
    try registry.insert(second)

    try registry.activate(id: first.id, tokenRef: "ref-1")
    try registry.activate(id: second.id, tokenRef: "ref-2")

    let rows = try registry.all()
    #expect(rows.filter(\.active).map(\.id) == [second.id])
    #expect(try registry.active()?.id == second.id)
    // The first account stays registered and keeps its token ref; only its active flag moved.
    let demoted = try #require(rows.first { $0.id == first.id })
    #expect(!demoted.active)
    #expect(demoted.tokenRef == "ref-1")

    #expect(throws: WorkspaceError.self) { try registry.activate(id: "missing", tokenRef: "x") }
    // A failed activation leaves the active account alone.
    #expect(try registry.active()?.id == second.id)
  }

  @Test func uniqueHubUser() throws {
    let registry = try makeRegistry()
    try registry.insert(row())
    #expect(throws: WorkspaceError.self) { try registry.insert(row()) }
    // The same user on another hub is a different account.
    try registry.insert(row(hubURL: "https://other.example.com"))
    #expect(try registry.all().count == 2)
  }

  @Test func databaseRefusesTwoActiveRows() throws {
    let registry = try makeRegistry()
    var first = row(hubUserId: "user-1")
    first.active = true
    var second = row(hubUserId: "user-2")
    second.active = true
    try registry.insert(first)
    #expect(throws: WorkspaceError.self) { try registry.insert(second) }
    #expect(try registry.all().count == 1)
  }

  @Test func signOutClearsToken() throws {
    let registry = try makeRegistry()
    let account = row()
    try registry.insert(account)
    try registry.activate(id: account.id, tokenRef: "secret-ref")
    let signedInAt = try #require(try registry.active()?.lastSignedInAt)

    try registry.signOut(id: account.id)

    #expect(try registry.active() == nil)
    let after = try #require(try registry.find(hubURL: account.hubURL, hubUserId: account.hubUserId))
    #expect(after.tokenRef == nil)
    #expect(!after.active)
    #expect(after.lastSignedInAt == signedInAt)
  }

  @Test func newIdIs16Hex() {
    let ids = (0..<50).map { _ in AccountRegistry.newId() }
    for id in ids {
      #expect(id.count == 16)
      #expect(id.allSatisfy { "0123456789abcdef".contains($0) })
    }
    #expect(Set(ids).count == ids.count)
    #expect(AccountRegistry.databaseName(id: "00ff00ff00ff00ff") == "workspace_00ff00ff00ff00ff")
  }

  @Test func registryMigratesOnItsOwnListAndIsIdempotent() throws {
    let endpoint = try EphemeralPostgres.endpoint()
    let name = "registry_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let first = try AccountRegistry(endpoint: endpoint, binDir: endpoint.binDir!, databaseName: name)
    try first.insert(row())
    // Reopening the same database finds it, applies nothing new, and keeps the rows.
    let second = try AccountRegistry(endpoint: endpoint, binDir: endpoint.binDir!, databaseName: name)
    #expect(try second.all().count == 1)
    #expect(try second.appliedMigrations() == ["0001_registry"])
    // The workspace migration list is untouched by the registry's files.
    #expect(try Migrator.files().allSatisfy { !$0.name.contains("registry") })
  }
}
