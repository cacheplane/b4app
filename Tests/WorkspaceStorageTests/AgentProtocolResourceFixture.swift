import Darwin
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Task-local test helpers shared by the two test targets through identical thin delegates.
/// EphemeralPostgres owns the opt-in resource registration and acknowledgment.
enum AgentProtocolResourceFixture {
  static var temporaryDirectory: String {
    let env = ProcessInfo.processInfo.environment
    if env["B4APP_A3_NONCE"] != nil, let root = env["B4APP_A3_PRIVATE_ROOT"] {
      return (root as NSString).appendingPathComponent("tmp") + "/"
    }
    // Ordinary CI may spell TMPDIR through /var; create fixtures under its physical base.
    // Adversarial paths supplied by individual tests are deliberately not normalized here.
    return URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/"
  }

  // The shared ephemeral test utility owns the same opt-in guard/registration/ACK for all callers.
  static func endpoint() throws -> PostgresEndpoint { try EphemeralPostgres.endpoint() }

  static func database() throws -> WorkspaceDatabase {
    let endpoint = try endpoint()
    return try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
  }
}
