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
  /// Sign in with a passkey the device already has for the relying party. Nil when it has none (no
  /// sheet was shown); `SignInCanceled` when the person closed the sheet.
  func assert(_ options: JSONValue) async throws -> JSONValue?
  /// Make a new passkey. `SignInCanceled` when the person closed the sheet.
  func register(_ options: JSONValue) async throws -> JSONValue
}

/// The Mac's Sign in with Apple web flow: open `url` in an `ASWebAuthenticationSession` waiting for
/// `callbackScheme`, and return the URL it was called back with. `SignInCanceled` when closed.
public protocol AppleWebSignIn {
  func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

// MARK: - The system's passkey sheet

/// `PasskeyCeremony` through `ASAuthorizationController` and the platform passkey provider, preferring
/// immediately available credentials, so a device without a passkey for the site shows no sheet.
@MainActor
public final class SystemPasskeyCeremony: NSObject, PasskeyCeremony {
  /// With `preferImmediatelyAvailableCredentials` the system reports "no passkey here" as a cancel
  /// that comes before any sheet. A cancel this soon after the request, or before the controller ever
  /// asked where to present, is read as no credential rather than as the person's cancel.
  static let noCredentialWindow: TimeInterval = 0.6

  override public init() {}

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
    } catch let error as ASAuthorizationError {
      switch error.code {
      case .notInteractive: return nil
      case .canceled:
        if !run.presented || run.elapsed < Self.noCredentialWindow { return nil }
        throw SignInCanceled()
      default: throw error
      }
    }
  }

  public func register(_ options: JSONValue) async throws -> JSONValue {
    let request = try WebAuthnJSON.registrationRequest(from: options)
    let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
      relyingPartyIdentifier: request.relyingParty)
    let registration = provider.createCredentialRegistrationRequest(
      challenge: request.challenge, name: request.name, userID: request.userID)
    if let preference = request.userVerification {
      registration.userVerificationPreference = ASAuthorizationPublicKeyCredentialUserVerificationPreference(
        rawValue: preference)
    }
    registration.attestationPreference = .none
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
    } catch let error as ASAuthorizationError where error.code == .canceled {
      throw SignInCanceled()
    }
  }
}

/// One `ASAuthorizationController` run as an async call, noting whether the system asked where to
/// present its sheet.
@MainActor
private final class AuthorizationRun: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private var continuation: CheckedContinuation<ASAuthorization, any Error>?
  private var controller: ASAuthorizationController?
  private var window: ASPresentationAnchor?
  private var started = Date()
  private(set) var presented = false
  var elapsed: TimeInterval { Date().timeIntervalSince(started) }

  func perform(
    _ request: ASAuthorizationRequest, options: ASAuthorizationController.RequestOptions
  ) async throws -> ASAuthorization {
    guard let window = Self.anchor() else {
      throw WorkspaceError(.internalError, "There is no window to show the passkey sheet in.")
    }
    self.window = window
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self
    controller.presentationContextProvider = self
    self.controller = controller
    started = Date()
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
    presented = true
    // `perform` resolves the window before the request runs and refuses to start without one.
    if let window = window ?? Self.anchor() { return window }
    preconditionFailure("The passkey sheet asked for a window while the app has none.")
  }

  /// The key window, else any window of the app.
  static func anchor() -> ASPresentationAnchor? {
    #if canImport(AppKit)
      return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
    #else
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(
        \.windows)
      return windows.first(where: \.isKeyWindow) ?? windows.first
    #endif
  }
}

// MARK: - The system's web authentication session

/// `AppleWebSignIn` through SwiftUI's `WebAuthenticationSession`, which runs an
/// `ASWebAuthenticationSession` presented from the view's window. Made by the view from its
/// environment (`@Environment(\.webAuthenticationSession)`).
public struct SystemAppleWebSignIn: AppleWebSignIn {
  private let session: WebAuthenticationSession

  public init(session: WebAuthenticationSession) { self.session = session }

  public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    do {
      // An ephemeral session: Apple's page keeps no cookie in the shared browser.
      return try await session.authenticate(
        using: url, callback: .customScheme(callbackScheme), preferredBrowserSession: .ephemeral,
        additionalHeaderFields: [:])
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      throw SignInCanceled()
    }
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
    return RegistrationRequest(
      relyingParty: rpId, challenge: challenge, name: name, userID: userID,
      userVerification: key["authenticatorSelection"]?["userVerification"]?.stringValue)
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
