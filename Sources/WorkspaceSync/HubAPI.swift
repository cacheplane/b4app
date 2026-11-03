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
  /// `POST /v1/pairing-codes`: a single-use code that enrolls a phone, valid five minutes. A `macos`
  /// device only; the eleventh in an hour is `429 rate_limited` with `retryAfterMs`.
  func mintPairingCode() async throws -> PairingCodeResponse
  func revokeSelf() async throws

  // MARK: Signing in (no bearer)

  /// `GET /v1/auth/config`.
  func authConfig() async throws -> AuthConfig
  /// `POST /v1/auth/passkey/begin`.
  func passkeyBegin() async throws -> PasskeyBeginResponse
  /// `POST /v1/auth/passkey/finish`: signs in with an assertion, or up with an attestation.
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession
  /// `POST /v1/auth/apple/begin`. `appleBegin()` begins the native flow.
  func appleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse
  /// `POST /v1/auth/apple/native`.
  func appleNative(_ request: AppleNativeRequest) async throws -> AuthSession
  /// `POST /v1/auth/handoff`: ends the Mac's web flow.
  func handoff(_ request: HandoffRequest) async throws -> AuthSession

  // MARK: The signed-in account (bearer)

  /// `PUT /v1/me/profile`: onboarding's full name; answers as `me()`.
  func setProfile(_ request: ProfileRequest) async throws -> MeResponse
  /// The account's sign-in methods, oldest first (`GET /v1/me`'s `identities`).
  func identities() async throws -> [Identity]
  /// `POST /v1/me/passkeys/begin`, with the step-up grant (`nil` only for an account with no sign-in
  /// method, which needs none).
  func addPasskeyBegin(stepUp: String?) async throws -> AddPasskeyBeginResponse
  /// `POST /v1/me/passkeys/finish`: answers the new identity.
  func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity
  /// `DELETE /v1/me/identities/{id}`, with the step-up grant. The account's last one is
  /// `last_identity`.
  func removeIdentity(_ id: String, stepUp: String?) async throws
  /// `POST /v1/me/apple`: begin linking an Apple ID to the signed-in account. The body is
  /// `appleBegin`'s (empty natively, the verifier's hash and the scheme on the web); `apple_linked`
  /// when the account has one already. Carries the step-up grant.
  func appleLinkBegin(_ request: AppleBeginRequest, stepUp: String?) async throws -> AppleBeginResponse
  /// `POST /v1/me/apple/native`: finish a native link; answers the new identity.
  func appleLinkNative(_ request: AppleLinkNativeRequest) async throws -> Identity
  /// `POST /v1/me/apple/handoff`: finish a web link with the redirect's handoff and the verifier;
  /// answers the new identity.
  func appleLinkHandoff(_ request: AppleLinkHandoffRequest) async throws -> Identity
  /// `DELETE /v1/sessions/self`: logs out. The device stays enrolled and unrevoked.
  func endSession() async throws
  /// `DELETE /v1/me`: deletes the account and everything in its personal org. Carries the step-up
  /// grant.
  func deleteAccount(stepUp: String?) async throws

  // MARK: Step-up (bearer, D-150)

  /// `POST /v1/me/step-up/passkey/begin`: assertion options for the account's own passkeys.
  func stepUpPasskeyBegin() async throws -> StepUpBeginResponse
  /// `POST /v1/me/step-up/passkey/finish`: answers the grant.
  func stepUpPasskeyFinish(_ request: StepUpFinishRequest) async throws -> StepUpResponse
  /// `POST /v1/me/step-up/apple`: `appleBegin`'s body (empty natively, the verifier's hash and the
  /// scheme on the web); `not_found` for an account with no Apple ID.
  func stepUpAppleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse
  /// `POST /v1/me/step-up/apple/native`: answers the grant.
  func stepUpAppleNative(_ request: StepUpAppleNativeRequest) async throws -> StepUpResponse
  /// `POST /v1/me/step-up/apple/handoff`: the web flow's handoff and verifier; answers the grant.
  func stepUpAppleHandoff(_ request: AppleLinkHandoffRequest) async throws -> StepUpResponse
  /// `POST /v1/me/step-up/code`: spends an operator's enrollment code for this user and answers the
  /// grant; `invalid_code` for any other code (D-151).
  func stepUpCode(_ request: StepUpCodeRequest) async throws -> StepUpResponse
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
  public func appleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    throw HubError.unsupported("appleBegin")
  }
  /// Begins the native flow (no verifier or scheme).
  public func appleBegin() async throws -> AppleBeginResponse { try await appleBegin(AppleBeginRequest()) }
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
  public func addPasskeyBegin(stepUp: String?) async throws -> AddPasskeyBeginResponse {
    throw HubError.unsupported("addPasskeyBegin")
  }
  public func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity {
    throw HubError.unsupported("addPasskeyFinish")
  }
  public func removeIdentity(_ id: String, stepUp: String?) async throws {
    throw HubError.unsupported("removeIdentity")
  }
  public func appleLinkBegin(_ request: AppleBeginRequest, stepUp: String?) async throws -> AppleBeginResponse
  {
    throw HubError.unsupported("appleLinkBegin")
  }
  public func appleLinkNative(_ request: AppleLinkNativeRequest) async throws -> Identity {
    throw HubError.unsupported("appleLinkNative")
  }
  public func appleLinkHandoff(_ request: AppleLinkHandoffRequest) async throws -> Identity {
    throw HubError.unsupported("appleLinkHandoff")
  }
  public func endSession() async throws { throw HubError.unsupported("endSession") }
  public func deleteAccount(stepUp: String?) async throws { throw HubError.unsupported("deleteAccount") }
  public func stepUpPasskeyBegin() async throws -> StepUpBeginResponse {
    throw HubError.unsupported("stepUpPasskeyBegin")
  }
  public func stepUpPasskeyFinish(_ request: StepUpFinishRequest) async throws -> StepUpResponse {
    throw HubError.unsupported("stepUpPasskeyFinish")
  }
  public func stepUpAppleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    throw HubError.unsupported("stepUpAppleBegin")
  }
  public func stepUpAppleNative(_ request: StepUpAppleNativeRequest) async throws -> StepUpResponse {
    throw HubError.unsupported("stepUpAppleNative")
  }
  public func stepUpAppleHandoff(_ request: AppleLinkHandoffRequest) async throws -> StepUpResponse {
    throw HubError.unsupported("stepUpAppleHandoff")
  }
  public func stepUpCode(_ request: StepUpCodeRequest) async throws -> StepUpResponse {
    throw HubError.unsupported("stepUpCode")
  }
}

extension HubError {
  /// What a `HubAPI` that does not serve a call answers: no request was made, so `status` is 0.
  static func unsupported(_ call: String) -> HubError {
    HubError(
      kind: "execution_error", code: "unsupported", message: "\(call) is not supported by this hub client.",
      status: 0)
  }
}
