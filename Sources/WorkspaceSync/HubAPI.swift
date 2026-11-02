import Foundation

/// The hub's HTTP API, one method per route in `Hub/API.md`. Failures are `HubError`s (or
/// `CancellationError` when the calling task is cancelled).
///
/// The sign-in calls (`authConfig` through `handoff`, and `enroll`) carry no bearer token: the
/// credential is the passkey, the Apple token, or the enrollment code. The account calls need the
/// device's token. A conformer that does not serve accounts, such as a test double that only forwards
/// the sync calls, inherits defaults that fail with `unsupported` rather than answering anything.
public protocol HubAPI: Sendable {
  /// `POST /v1/enroll` with no merge: the device has no account of its own to bring along.
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse
  /// `POST /v1/enroll`. A phone signed in to an account of its own sends that account's token, and the
  /// hub merges the account into the code's as the code is redeemed. A `nil` token is `enroll(_:)`.
  func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse
  func me() async throws -> MeResponse
  func push(_ changes: [SyncChange]) async throws -> PushResponse
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse
  /// `GET /v1/snapshot`: the user's state, for a reader whose cursor the hub has pruned past.
  func snapshot() async throws -> SnapshotResponse
  /// `GET /v1/devices`: this user's devices, oldest enrolled first, revoked ones included.
  func devices() async throws -> [DeviceInfo]
  func revokeSelf() async throws

  // MARK: Signing in (no bearer)

  /// `GET /v1/auth/config`.
  func authConfig() async throws -> AuthConfig
  /// `POST /v1/auth/passkey/begin`.
  func passkeyBegin() async throws -> PasskeyBeginResponse
  /// `POST /v1/auth/passkey/finish`: signs in with an assertion, or up with an attestation.
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession
  /// `POST /v1/auth/apple/begin`.
  func appleBegin() async throws -> AppleBeginResponse
  /// `POST /v1/auth/apple/native`.
  func appleNative(_ request: AppleNativeRequest) async throws -> AuthSession
  /// `POST /v1/auth/handoff`: ends the Mac's web flow.
  func handoff(_ request: HandoffRequest) async throws -> AuthSession

  // MARK: The signed-in account (bearer)

  /// `PUT /v1/me/profile`: onboarding's full name; answers as `me()`.
  func setProfile(_ request: ProfileRequest) async throws -> MeResponse
  /// The account's sign-in methods, oldest first (`GET /v1/me`'s `identities`).
  func identities() async throws -> [Identity]
  /// `POST /v1/me/passkeys/begin`.
  func addPasskeyBegin() async throws -> AddPasskeyBeginResponse
  /// `POST /v1/me/passkeys/finish`: answers the new identity.
  func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity
  /// `DELETE /v1/me/identities/{id}`. The account's last one is `last_identity`.
  func removeIdentity(_ id: String) async throws
  /// `DELETE /v1/sessions/self`: logs out. The device stays enrolled and unrevoked.
  func endSession() async throws
  /// `DELETE /v1/me`: deletes the account and everything in its personal org.
  func deleteAccount() async throws
}

extension HubAPI {
  public func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse {
    guard token == nil else { throw HubError.unsupported("Enrolling with a merge") }
    return try await enroll(request)
  }

  public func authConfig() async throws -> AuthConfig { throw HubError.unsupported("authConfig") }
  public func passkeyBegin() async throws -> PasskeyBeginResponse {
    throw HubError.unsupported("passkeyBegin")
  }
  public func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    throw HubError.unsupported("passkeyFinish")
  }
  public func appleBegin() async throws -> AppleBeginResponse { throw HubError.unsupported("appleBegin") }
  public func appleNative(_ request: AppleNativeRequest) async throws -> AuthSession {
    throw HubError.unsupported("appleNative")
  }
  public func handoff(_ request: HandoffRequest) async throws -> AuthSession {
    throw HubError.unsupported("handoff")
  }
  public func setProfile(_ request: ProfileRequest) async throws -> MeResponse {
    throw HubError.unsupported("setProfile")
  }
  public func identities() async throws -> [Identity] { throw HubError.unsupported("identities") }
  public func addPasskeyBegin() async throws -> AddPasskeyBeginResponse {
    throw HubError.unsupported("addPasskeyBegin")
  }
  public func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity {
    throw HubError.unsupported("addPasskeyFinish")
  }
  public func removeIdentity(_ id: String) async throws { throw HubError.unsupported("removeIdentity") }
  public func endSession() async throws { throw HubError.unsupported("endSession") }
  public func deleteAccount() async throws { throw HubError.unsupported("deleteAccount") }
}

extension HubError {
  /// What a `HubAPI` that does not serve a call answers: no request was made, so `status` is 0.
  static func unsupported(_ call: String) -> HubError {
    HubError(
      kind: "execution_error", code: "unsupported", message: "\(call) is not supported by this hub client.",
      status: 0)
  }
}
