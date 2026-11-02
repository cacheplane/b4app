import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// The iPhone's signed-out screen and its signed-in, no-Mac twin (mockup A2, approved 2026-11-02):
// "Connect your Mac", one line, Scan the code in thumb reach, and one quiet "Other ways to sign in",
// whose sheet holds Apple, the passkey, the enrollment code, and two quiet links. No wordmark: that
// stays on the Mac, whose screen (`SignInContent`, `SignInTests`) is unchanged. The views draw
// `PhoneLandingContent` and `PhoneSignInOptionsContent`, so the tests read the screens through them.

private let beta = SignInConfiguration(siteDomain: "test.b4.run", appleSignIn: true, badge: "Test hub")
private let prod = SignInConfiguration(siteDomain: "b4.run", appleSignIn: true, badge: nil)
private let local = SignInConfiguration(siteDomain: "local.b4.run", appleSignIn: false, badge: "Local hub")

/// A connected model whose account is signed out (with `reason`, when the hub refused this device).
@MainActor
private func signedOutModel(
  _ configuration: SignInConfiguration = beta, reason: SignOutReason? = nil
) async throws -> WorkspaceModel {
  let transport = ScriptedTransport()
  transport.script(
    .accountStatus,
    [.result(try JSONValue(encoding: AccountStatus.Result(state: .signedOut, reason: reason)))])
  let model = WorkspaceModel(transportProvider: { transport })
  model.signInConfiguration = configuration
  model.connect()
  try #require(await model.settledLink() == .ready)
  try #require(model.rootScreen == .signIn)
  return model
}

extension Array where Element == ScreenElement {
  fileprivate var ids: [String] { map(\.id) }
  fileprivate var texts: [String] { map(\.text) }
  fileprivate func text(of id: String) -> String? { first { $0.id == id }?.text }
}

@MainActor
@Suite struct PhoneLandingTests {
  // MARK: The landing

  @Test func landingShowsHeadingLineScanOtherWaysAndBadge() async throws {
    let model = try await signedOutModel(beta)
    let screen = PhoneLandingContent(signIn: model, hasCamera: true).elements
    #expect(
      screen.ids == ["signIn.title", "signIn.intro", "signIn.scan", "signIn.otherWays", "signIn.badge"])
    #expect(
      screen.texts == [
        "Connect your Mac", "Scan the code Agent Workspace shows on your Mac.", "Scan the code",
        "Other ways to sign in", "Test hub",
      ])
    // No wordmark, tagline, or "New here?" on the iPhone; the sign-in buttons are behind Other ways.
    #expect(!screen.ids.contains("signIn.wordmark"))
    #expect(!screen.texts.contains { $0.contains("b4.run") })
    #expect(!screen.texts.contains(SignInCopy.intro))
    #expect(!screen.texts.contains(SignInCopy.newHere))
    #expect(!screen.ids.contains("signIn.apple") && !screen.ids.contains("signIn.passkey"))
  }

  @Test func theBadgeIsTheFlavours() async throws {
    let model = try await signedOutModel(local)
    #expect(PhoneLandingContent(signIn: model, hasCamera: true).badge?.text == "Local hub")
    model.signInConfiguration = beta
    #expect(PhoneLandingContent(signIn: model, hasCamera: true).badge?.text == "Test hub")
    // The App Store build has none.
    model.signInConfiguration = prod
    let shipped = PhoneLandingContent(signIn: model, hasCamera: true)
    #expect(shipped.badge == nil)
    #expect(!shipped.elements.ids.contains("signIn.badge"))
  }

  @Test func aSignedOutReasonSitsUnderTheLine() async throws {
    let model = try await signedOutModel(beta, reason: .rejectedByHub("Brian's Org"))
    let screen = PhoneLandingContent(signIn: model, hasCamera: true).elements
    #expect(
      screen.ids == [
        "signIn.title", "signIn.intro", "signIn.reason", "signIn.scan", "signIn.otherWays", "signIn.badge",
      ])
    #expect(screen.text(of: "signIn.reason") == "This Mac was signed out of Brian's Org.")
  }

  // MARK: Other ways to sign in

  @Test func theSheetPerFlavour() async throws {
    let model = try await signedOutModel(prod)
    let shipped = PhoneSignInOptionsContent(model: model).elements
    #expect(
      shipped.ids == ["signIn.apple", "signIn.passkey", "signIn.enroll", "signIn.getMacApp", "signIn.help"])
    #expect(
      shipped.texts == [
        "Continue with Apple", "Sign in with a passkey", "Use an enrollment code", "Get the Mac app", "Help",
      ])

    model.signInConfiguration = beta
    #expect(PhoneSignInOptionsContent(model: model).elements == shipped)

    // The local flavour has no Apple.
    model.signInConfiguration = local
    let localSheet = PhoneSignInOptionsContent(model: model).elements
    #expect(localSheet.ids == ["signIn.passkey", "signIn.enroll", "signIn.getMacApp", "signIn.help"])
    #expect(PhoneSignInOptionsContent(model: model).buttonsEnabled)
  }

  @Test func theSheetFollowsTheSignIn() async throws {
    let model = try await signedOutModel(beta)
    // While the passkey call is out, its row says so and the rows are off.
    model.signInProgress = SignInProgress(inFlight: .passkey)
    let busy = PhoneSignInOptionsContent(model: model)
    #expect(busy.elements.text(of: "signIn.passkey") == "Signing in…")
    #expect(busy.elements.text(of: "signIn.apple") == "Continue with Apple")
    #expect(!busy.buttonsEnabled)

    // "No passkey… Create a new account?" stands in for Apple and the passkey.
    let question = SignInCopy.noPasskey(siteDomain: "test.b4.run")
    model.signInProgress = SignInProgress(confirmation: question)
    let asking = PhoneSignInOptionsContent(model: model).elements
    #expect(
      asking.ids == [
        "signIn.confirmation", "signIn.createAccount", "signIn.cancelCreate", "signIn.enroll",
        "signIn.getMacApp",
        "signIn.help",
      ])
    #expect(
      asking.text(of: "signIn.confirmation")
        == "No passkey for test.b4.run on this device. Create a new account?")
    #expect(asking.text(of: "signIn.createAccount") == "Create account")
    #expect(asking.text(of: "signIn.cancelCreate") == "Cancel")

    // A refusal's one line sits under the rows.
    model.signInProgress = SignInProgress(failure: "That sign-in wasn't accepted. Try again.")
    let failed = PhoneSignInOptionsContent(model: model).elements
    #expect(failed.text(of: "signIn.failure") == "That sign-in wasn't accepted. Try again.")
    #expect(failed.ids.firstIndex(of: "signIn.failure")! > failed.ids.firstIndex(of: "signIn.enroll")!)

    // Get the Mac app reads "Copied" after a copy, as Connect your Mac's link does.
    model.signInProgress = SignInProgress()
    #expect(PhoneSignInOptionsContent(model: model, copyLabel: "Copied").getMacApp.text == "Copied")
  }

  @Test func noCameraMeansNoScanAndTheOptionsInline() async throws {
    let model = try await signedOutModel(beta)
    let content = PhoneLandingContent(signIn: model, hasCamera: false)
    #expect(content.scan == nil)
    #expect(content.otherWays == nil)
    #expect(content.options == PhoneSignInOptionsContent(model: model))
    #expect(
      content.elements.ids == [
        "signIn.title", "signIn.intro", "signIn.apple", "signIn.passkey", "signIn.enroll", "signIn.getMacApp",
        "signIn.help", "signIn.badge",
      ])
    // With a camera, the options are behind the link instead.
    #expect(PhoneLandingContent(signIn: model, hasCamera: true).options == nil)
  }

  // MARK: Signed in, no Mac

  @Test func connectMacUsesTheSameLayoutWithoutOtherWays() async {
    let state = ConnectMac(siteDomain: "test.b4.run", hasCamera: true, copy: { _ in }, sleep: { _ in })
    let screen = PhoneLandingContent(connectMac: state).elements
    #expect(
      screen.ids == [
        "connectMac.title", "connectMac.intro", "connectMac.scan", "connectMac.copyLink", "connectMac.help",
      ])
    #expect(
      screen.texts == [
        "Connect your Mac", "Scan the code Agent Workspace shows on your Mac.", "Scan the code",
        "Get the Mac app", "Help",
      ])
    #expect(!screen.texts.contains("Other ways to sign in"))

    // Without a camera: no Scan.
    let noCamera = ConnectMac(siteDomain: "test.b4.run", hasCamera: false, copy: { _ in })
    #expect(
      PhoneLandingContent(connectMac: noCamera).elements.ids == [
        "connectMac.title", "connectMac.intro", "connectMac.copyLink", "connectMac.help",
      ])
  }
}
