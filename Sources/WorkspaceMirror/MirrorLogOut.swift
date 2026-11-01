import Foundation
import WorkspaceSync

extension MirrorStore {
  /// Everything an account left on the phone: the link, every mirrored row and clock, the outbox of
  /// unsent edits, and the devices list. The schema and the device sequence counter stay.
  public func forgetAccount() throws {
    try locked {
      try transaction {
        try run(#"UPDATE "syncState" SET "link" = NULL, "cursor" = 0 WHERE "id" = 1"#)
        try deleteRows()
        try exec(#"DELETE FROM "outbox""#)
        try exec(#"DELETE FROM "devices""#)
      }
      clock.deviceId = "local"
    }
  }
}

/// The phone's Log out: revoke this device at the hub (best effort), forget its token, and empty the
/// mirror. Unsent edits are discarded rather than uploaded under whatever link comes next.
public enum MirrorLogOut {
  /// Returns whether the hub confirmed the revoke. The token is forgotten and the mirror emptied
  /// either way, so an unreachable hub cannot keep the phone signed in.
  @discardableResult
  public static func run(
    store: MirrorStore, api: (any HubAPI)?, forgetToken: @Sendable () async -> Void
  ) async -> Bool {
    var revoked = false
    if let api {
      do {
        try await api.revokeSelf()
        revoked = true
      } catch {
        revoked = false
      }
    }
    await forgetToken()
    try? store.forgetAccount()
    return revoked
  }
}
