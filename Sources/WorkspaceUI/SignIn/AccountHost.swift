import Foundation
import WorkspaceProtocol

/// The account of a host that owns it (sign-in plan, Task 14): the iPhone signs in at its hub itself,
/// with no coordinator, through `MirrorAccount` in `WorkspaceMirror`, which the app declares conforms to
/// this. The model runs the same sign-in, onboarding, log-out, and Settings → Account flows over it as
/// over the coordinator's `account.*` commands (`accountSource == .host`); only where each call goes
/// differs. `WorkspaceUI` never imports `WorkspaceMirror`: this protocol is the whole seam.
///
/// The host reports a change it made on its own (the hub refusing the token, `/v1/me` arriving) with
/// `WorkspaceModel.applyHostAccount(_:)`. No method takes or answers a token.
@MainActor
public protocol AccountHost: AnyObject {
  /// Who is signed in now, known without asking the hub.
  var accountStatus: AccountStatus.Result { get }

  func passkeyBegin() async throws -> AccountPasskeyBegin.Result
  /// Finish with exactly one of an assertion (sign in) or an attestation (sign up).
  func signIn(passkey params: AccountPasskeyFinish.Params) async throws -> AccountStatus.Result
  /// Begin Apple's native flow; the sheet is handed the SHA-256 hex of the nonce.
  func appleBegin() async throws -> AppleNativeCeremony
  func signIn(apple credential: AppleCredential, ceremonyId: String) async throws -> AccountStatus.Result
  func completeProfile(fullName: String) async throws -> AccountStatus.Result
  /// Always ends signed out, whatever the hub answers.
  func logOut() async -> AccountStatus.Result

  func identities() async throws -> [AccountIdentity]
  /// Begin confirming it's you with a passkey (D-150): options for the account's own passkeys.
  func stepUpPasskeyBegin() async throws -> AccountStepUpBegin.Result
  /// Begin confirming it's you with the account's Apple ID, on the native sheet.
  func stepUpAppleBegin() async throws -> AppleNativeCeremony
  /// The changes below take the confirmation (`nil` only for an account with no sign-in method),
  /// finish it at the hub, and make the change with the grant it earns, in one call.
  func addPasskeyBegin(stepUp: AccountStepUp?) async throws -> AccountAddPasskeyBegin.Result
  func addPasskeyFinish(_ params: AccountAddPasskeyFinish.Params) async throws -> AccountIdentity
  /// Answers the methods left.
  func removeIdentity(id: String, stepUp: AccountStepUp?) async throws -> [AccountIdentity]
  func deleteAccount(stepUp: AccountStepUp?) async throws -> AccountStatus.Result
  /// Begin linking an Apple ID with the native sheet.
  func appleLinkBegin(stepUp: AccountStepUp?) async throws -> AppleNativeCeremony
  func linkApple(_ credential: AppleCredential, ceremonyId: String) async throws -> AccountIdentity
}
