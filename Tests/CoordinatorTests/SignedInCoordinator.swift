import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

// Since the per-account split (sign-in plan, Task 9) a coordinator with nobody signed in answers
// `signed_out` to every store command. The suites that predate it start signed in to a local test
// account whose database is the coordinator's own and which has joined no hub, restored the way a
// restart restores any account, and reach its services through the accessors below.

enum TestAccount {
  /// Register an active account for `paths`' store, unless one is active already (a restart).
  static func register(_ paths: PlatformPaths) throws {
    let endpoint = paths.postgres
    let registry = try AccountRegistry(
      endpoint: endpoint, binDir: endpoint.binDir!,
      databaseName: AccountManager.registryDatabaseName(for: endpoint))
    defer { registry.close() }
    guard try registry.active() == nil else { return }
    let row = AccountRow(
      id: AccountRegistry.newId(), hubURL: "http://localhost:8080",
      hubUserId: "o-test/u-\(UUID().uuidString.prefix(8).lowercased())", deviceId: "local",
      database: endpoint.database, displayName: "Test", orgName: "Test Org")
    try registry.insert(row)
    try registry.activate(id: row.id, tokenRef: SecretRef.make().rawValue)
  }
}

extension Coordinator {
  /// `start`, signed in to a test account (`TestAccount.register`).
  static func startSignedIn(options: CoordinatorOptions) async throws -> StartOutcome {
    try TestAccount.register(options.paths)
    return try await start(options: options)
  }
}

extension RunningCoordinator {
  /// The signed-in account's scope; a test that reaches for it while signed out has gone wrong.
  var scope: AccountScope {
    guard let scope = accounts.current else { preconditionFailure("nobody is signed in") }
    return scope
  }
  var database: WorkspaceDatabase { scope.database }
  var sessions: SessionService { scope.sessions }
  var servers: LocalServerService { scope.servers }
  var projects: ProjectService { scope.projects }
  var hub: HubSync { scope.hub }
}
