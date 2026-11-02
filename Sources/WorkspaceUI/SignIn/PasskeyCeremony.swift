import AuthenticationServices
import Foundation
import SwiftUI
import WorkspaceProtocol

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// The platform's passkey sheet, behind a protocol so tests can stand in for it. The options and the
/// answers are the WebAuthn JSON the hub speaks (`{"publicKey": {...}}` in, a `PublicKeyCredential`
/// out), passed through as `JSONValue`.
public protocol PasskeyCeremony {
  /// Sign in with a passkey the device already has for the relying party. Nil when there is none the
  /// person wants to use (none on the device, or the sheet closed: the system does not tell them apart).
  func assert(_ options: JSONValue) async throws -> JSONValue?
  /// Make a new passkey. `SignInCanceled` when the person closed the sheet, `PasskeysNotSetUp` when
  /// the device cannot keep one.
  func register(_ options: JSONValue) async throws -> JSONValue
  /// Tell the password manager that a passkey is unknown to the relying party (a registration the hub
  /// refused, or a sign-in it refused, as after the account was deleted), so it is not offered again.
  func reportUnknownCredential(relyingParty: String, credentialID: Data) async
  /// Tell the password manager the new name of the passkey this ceremony made for `userHandle`, once
  /// the account has one (after onboarding), so the Passwords app shows "Brian Love" rather than the
  /// placeholder "Agent Workspace account".
  func renamePasskey(relyingParty: String, userHandle: Data, name: String) async
}

extension PasskeyCeremony {
  public func reportUnknownCredential(relyingParty: String, credentialID: Data) async {}
  public func renamePasskey(relyingParty: String, userHandle: Data, name: String) async {}
}

// MARK: - The system's passkey sheet

/// `PasskeyCeremony` through `ASAuthorizationController` and the platform passkey provider, preferring
/// immediately available credentials, so a device without a passkey for the site shows no sheet.
@MainActor
public final class SystemPasskeyCeremony: NSObject, PasskeyCeremony {
  override public init() {}

  /// Whether an assertion's error means "no passkey to use". With
  /// `preferImmediatelyAvailableCredentials`, Apple reports a device with no passkey for the site as
  /// `.canceled`, the same code as the person closing the sheet, and keeps the two indistinguishable on
  /// purpose, for privacy (Apple Developer Forums 713321 and 735867; Apple's passkeys sample treats
  /// `.canceled` either way). Every `.canceled` is read as no credential: the model then asks "Create
  /// a new account?", which has its own Cancel.
  nonisolated static func meansNoCredential(_ error: any Error) -> Bool {
    guard let error = error as? ASAuthorizationError else { return false }
    return error.code == .canceled || error.code == .notInteractive
  }

  public func assert(_ options: JSONValue) async throws -> JSONValue? {
    let request = try WebAuthnJSON.assertionRequest(from: options)
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: request.relyingParty)
    let assertion = provider.createCredentialAssertionRequest(challenge: request.challenge)
    if let preference = request.userVerification {
      assertion.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreference(
        rawValue: preference)
    }
    let run = AuthorizationRun()
    do {
      let authorization = try await run.perform(assertion, options: .preferImmediatelyAvailableCredentials)
      guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion
      else { throw WorkspaceError(.credentialRejected, "The passkey sheet answered something else.") }
      return WebAuthnJSON.assertion(
        credentialID: credential.credentialID, authenticatorData: credential.rawAuthenticatorData,
        clientDataJSON: credential.rawClientDataJSON, signature: credential.signature,
        userID: credential.userID)
    } catch  where Self.meansNoCredential(error) {
      return nil
    }
  }

  /// The system's registration request for the hub's options.
  nonisolated static func platformRequest(
    for request: WebAuthnJSON.RegistrationRequest
  ) -> ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest {
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: request.relyingParty)
    let registration = provider.createCredentialRegistrationRequest(
      challenge: request.challenge, name: request.name, userID: request.userID)
    if let preference = request.userVerification {
      registration.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreference(
        rawValue: preference)
    }
    registration.attestationPreference = .none
    // The account's passkeys: a device that already holds one for this account refuses to make
    // another (`.matchedExcludedCredential`) rather than overwriting it under the same user handle,
    // which would leave the hub holding a passkey that no longer exists anywhere.
    registration.excludedCredentials = request.excludedCredentials.map {
      ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
    }
    return registration
  }

  public func register(_ options: JSONValue) async throws -> JSONValue {
    let registration = Self.platformRequest(for: try WebAuthnJSON.registrationRequest(from: options))
    let run = AuthorizationRun()
    do {
      let authorization = try await run.perform(registration, options: [])
      guard
        let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
        let attestationObject = credential.rawAttestationObject
      else { throw WorkspaceError(.credentialRejected, "The passkey sheet answered something else.") }
      return WebAuthnJSON.attestation(
        credentialID: credential.credentialID, attestationObject: attestationObject,
        clientDataJSON: credential.rawClientDataJSON)
    } catch let error as ASAuthorizationError {
      throw Self.registrationError(error)
    }
  }

  /// A registration's system error as the model reads it.
  nonisolated static func registrationError(_ error: ASAuthorizationError) -> any Error {
    switch error.code {
    case .canceled: return SignInCanceled()
    case .deviceNotConfiguredForPasskeyCreation: return PasskeysNotSetUp()
    case .matchedExcludedCredential: return PasskeyAlreadyOnDevice()
    default: return error
    }
  }

  public func reportUnknownCredential(relyingParty: String, credentialID: Data) async {
    // Best effort: a password manager that cannot take the report keeps the passkey, and the hub
    // refuses it at the next sign-in as before.
    if #available(macOS 26.2, iOS 26.2, *) {
      try? await ASCredentialDataManager().reportUnknownPublicKeyCredential(
        relyingPartyIdentifier: relyingParty, credentialID: credentialID)
    } else {
      try? await ASCredentialUpdater().reportUnknownPublicKeyCredential(
        relyingPartyIdentifier: relyingParty, credentialID: credentialID)
    }
  }

  public func renamePasskey(relyingParty: String, userHandle: Data, name: String) async {
    // Best effort, like the report above: a password manager that does not take it keeps the
    // placeholder name, and the passkey works the same.
    if #available(macOS 26.2, iOS 26.2, *) {
      try? await ASCredentialDataManager().reportPublicKeyCredentialUpdate(
        relyingPartyIdentifier: relyingParty, userHandle: userHandle, newName: name)
    } else {
      try? await ASCredentialUpdater().reportPublicKeyCredentialUpdate(
        relyingPartyIdentifier: relyingParty, userHandle: userHandle, newName: name)
    }
  }
}

/// One `ASAuthorizationController` run as an async call (passkeys, and Apple's native sheet).
@MainActor
final class AuthorizationRun: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private var continuation: CheckedContinuation<ASAuthorization, any Error>?
  private var controller: ASAuthorizationController?
  private var window: ASPresentationAnchor?

  /// `sheet` names the sheet in the error when there is no window to show it in.
  func perform(
    _ request: ASAuthorizationRequest, options: ASAuthorizationController.RequestOptions,
    sheet: String = "the passkey sheet"
  ) async throws -> ASAuthorization {
    guard let window = Self.anchor() else {
      throw WorkspaceError(.internalError, "There is no window to show \(sheet) in.")
    }
    self.window = window
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    defer {
      self.controller = nil
      self.window = nil
    }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      controller.performRequests(options: options)
    }
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    continuation?.resume(returning: authorization)
    continuation = nil
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    // `perform` resolves the window before the request runs and refuses to start without one.
    if let window = window ?? Self.anchor() { return window }
    preconditionFailure("A sign-in sheet asked for a window while the app has none.")
  }

  /// The key window, else the first visible window that can be a main window; never a hidden one.
  static func anchor() -> ASPresentationAnchor? {
    #if canImport(AppKit)
      if let key = NSApplication.shared.keyWindow, key.isVisible { return key }
      return NSApplication.shared.windows.first { $0.isVisible && $0.canBecomeMain }
    #else
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(
        \.windows)
      if let key = windows.first(where: \.isKeyWindow), !key.isHidden { return key }
      return windows.first { !$0.isHidden }
    #endif
  }
}

// MARK: - WebAuthn JSON

/// Reads the hub's WebAuthn options and writes the platform's answers in the JSON shape the hub
/// (`webauthn-rs`) takes: every binary field base64url without padding.
public enum WebAuthnJSON {
  public struct AssertionRequest: Equatable {
    public var relyingParty: String
    public var challenge: Data
    public var userVerification: String?
  }

  public struct RegistrationRequest: Equatable {
    public var relyingParty: String
    public var challenge: Data
    public var name: String
    public var userID: Data
    public var userVerification: String?
    /// `excludeCredentials`' ids: the passkeys the account already has.
    public var excludedCredentials: [Data] = []
  }

  static func invalid(_ what: String) -> WorkspaceError {
    WorkspaceError(.protocolInvalid, "The passkey options lack \(what).")
  }

  public static func assertionRequest(from options: JSONValue) throws -> AssertionRequest {
    let key = options["publicKey"] ?? options
    guard let rpId = key["rpId"]?.stringValue, !rpId.isEmpty else { throw invalid("rpId") }
    guard let challenge = key["challenge"]?.stringValue.flatMap(data(base64URL:)) else {
      throw invalid("a challenge")
    }
    return AssertionRequest(
      relyingParty: rpId, challenge: challenge, userVerification: key["userVerification"]?.stringValue)
  }

  public static func registrationRequest(from options: JSONValue) throws -> RegistrationRequest {
    let key = options["publicKey"] ?? options
    guard let rpId = key["rp"]?["id"]?.stringValue, !rpId.isEmpty else { throw invalid("rp.id") }
    guard let challenge = key["challenge"]?.stringValue.flatMap(data(base64URL:)) else {
      throw invalid("a challenge")
    }
    guard let userID = key["user"]?["id"]?.stringValue.flatMap(data(base64URL:)) else {
      throw invalid("user.id")
    }
    guard let name = key["user"]?["name"]?.stringValue, !name.isEmpty else { throw invalid("user.name") }
    var excluded: [Data] = []
    if case .array(let descriptors)? = key["excludeCredentials"] {
      for descriptor in descriptors {
        guard let id = descriptor["id"]?.stringValue.flatMap(data(base64URL:)) else {
          throw invalid("an id for each excluded credential")
        }
        excluded.append(id)
      }
    }
    return RegistrationRequest(
      relyingParty: rpId, challenge: challenge, name: name, userID: userID,
      userVerification: key["authenticatorSelection"]?["userVerification"]?.stringValue,
      excludedCredentials: excluded)
  }

  public static func assertion(
    credentialID: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data, userID: Data
  ) -> JSONValue {
    let id = JSONValue.string(base64URL(credentialID))
    return [
      "id": id, "rawId": id, "type": "public-key", "extensions": [:],
      "response": [
        "authenticatorData": .string(base64URL(authenticatorData)),
        "clientDataJSON": .string(base64URL(clientDataJSON)),
        "signature": .string(base64URL(signature)),
        "userHandle": .string(base64URL(userID)),
      ],
    ]
  }

  public static func attestation(
    credentialID: Data, attestationObject: Data, clientDataJSON: Data
  ) -> JSONValue {
    let id = JSONValue.string(base64URL(credentialID))
    return [
      "id": id, "rawId": id, "type": "public-key", "extensions": [:],
      "response": [
        "attestationObject": .string(base64URL(attestationObject)),
        "clientDataJSON": .string(base64URL(clientDataJSON)),
      ],
    ]
  }

  public static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    )
    .replacingOccurrences(of: "=", with: "")
  }

  public static func data(base64URL text: String) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
  }
}
