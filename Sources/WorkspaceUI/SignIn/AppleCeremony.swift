import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI
import WorkspaceProtocol

/// Sign in with Apple's sheets, behind a protocol so tests can stand in for them (sign-in plan,
/// Task 14). Nil means the person closed the sheet; the model then shows nothing.
///
/// - `nativeSignIn(nonce:)` is the iPhone's: Apple's own sheet (`ASAuthorizationAppleIDProvider`),
///   asking for the full name and the email, with the SHA-256 hex of the hub's `nonce` as the request's
///   nonce (`Hub/API.md`'s nonce rule). It answers the identity token, the authorization code, and the
///   formatted name (Apple gives it the first time only).
/// - `webSignIn(url:callbackScheme:)` is the Mac's: the hub's start page in an
///   `ASWebAuthenticationSession`, answering the URL it was called back with. A Developer ID app cannot
///   use the native flow, and this way the device token never enters the app.
public protocol AppleCeremony {
  func nativeSignIn(nonce: String) async throws -> AppleCredential?
  func webSignIn(url: URL, callbackScheme: String) async throws -> URL?
}

/// `<scheme>://auth?handoff=…` or `?error=…`: the hub's redirect at the end of Apple's web flow. A
/// ceremony takes its own from its session; one the app is handed any other way (opened from a page,
/// another app, or a session that already ended) belongs to no ceremony and is dropped unread.
public enum AuthCallback {
  public static func isAuthCallback(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "b4app" || scheme.hasPrefix("b4app-") else {
      return false
    }
    return url.host?.lowercased() == "auth"
  }
}

// MARK: - The system's sheets

/// `AppleCeremony` through the system: `ASAuthorizationController` with the Apple ID provider for the
/// native sheet, and SwiftUI's `WebAuthenticationSession` (an `ASWebAuthenticationSession` presented
/// from the view's window) for the web flow. Made by the view from its environment.
@MainActor
public struct SystemAppleCeremony: AppleCeremony {
  private let session: WebAuthenticationSession?

  public init(session: WebAuthenticationSession?) { self.session = session }

  /// How the no-window error names Apple's sheet.
  nonisolated static let sheetName = "Sign in with Apple"

  /// What Apple's request is handed for the hub's ceremony nonce: its lowercase hex SHA-256, which the
  /// identity token must carry.
  public nonisolated static func requestNonce(_ nonce: String) -> String {
    SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func nativeSignIn(nonce: String) async throws -> AppleCredential? {
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.requestedScopes = [.fullName, .email]
    request.nonce = Self.requestNonce(nonce)
    let authorization: ASAuthorization
    do {
      authorization = try await AuthorizationRun().perform(request, options: [], sheet: Self.sheetName)
    } catch let error as ASAuthorizationError where error.code == .canceled {
      return nil
    }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
      let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) })
    else { throw WorkspaceError(.credentialRejected, "Apple's sheet answered something else.") }
    return AppleCredential(
      identityToken: token, authorizationCode: code, fullName: Self.formatted(credential.fullName))
  }

  public func webSignIn(url: URL, callbackScheme: String) async throws -> URL? {
    guard let session else {
      throw WorkspaceError(.internalError, "There is no browser session to show Apple's page in.")
    }
    do {
      // An ephemeral session: Apple's page keeps no cookie in the shared browser.
      return try await session.authenticate(
        using: url, callback: .customScheme(callbackScheme), preferredBrowserSession: .ephemeral,
        additionalHeaderFields: [:])
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      return nil
    }
  }

  /// "Brian Love" from Apple's name parts, or nil when Apple gave none (every sign-in after the first).
  nonisolated static func formatted(_ name: PersonNameComponents?) -> String? {
    guard let name else { return nil }
    let text = PersonNameComponentsFormatter().string(from: name).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
