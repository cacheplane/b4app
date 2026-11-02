import AuthenticationServices
import SwiftUI
import WorkspaceProtocol

/// One line or control of the sign-in or onboarding screen: its accessibility identifier and what it
/// says.
struct ScreenElement: Equatable {
  var id: String
  var text: String
}

/// What the sign-in screen shows for the model's state, each element with the accessibility
/// identifier the view gives it. `SignInView` draws exactly this, so the copy and the controls can
/// be checked without a window (SwiftUI builds no accessibility tree for an in-process reader).
struct SignInContent: Equatable {
  var wordmark = ScreenElement(id: "signIn.wordmark", text: "b4.run")
  var title = ScreenElement(id: "signIn.title", text: SignInCopy.title)
  var intro = ScreenElement(id: "signIn.intro", text: SignInCopy.intro)
  /// "This Mac was signed out of <org name>." after the hub refused this Mac.
  var reason: ScreenElement?
  /// The buttons, unless the "Create a new account?" question stands in their place.
  var apple: ScreenElement?
  var passkey: ScreenElement?
  var buttonsEnabled = true
  var confirmation: ScreenElement?
  var createAccount: ScreenElement?
  var cancelCreate: ScreenElement?
  var failure: ScreenElement?
  var newHere = ScreenElement(id: "signIn.newHere", text: SignInCopy.newHere)
  /// The Mac's "By continuing you agree to the terms and privacy policy."
  var terms: ScreenElement?
  var badge: ScreenElement?

  init(model: WorkspaceModel) {
    let progress = model.signInProgress
    let configuration = model.signInConfiguration
    if case .signedOut(let line?) = model.accountState {
      reason = ScreenElement(id: "signIn.reason", text: line)
    }
    if let question = progress.confirmation {
      confirmation = ScreenElement(id: "signIn.confirmation", text: question)
      createAccount = ScreenElement(id: "signIn.createAccount", text: SignInCopy.createAccount)
      cancelCreate = ScreenElement(id: "signIn.cancelCreate", text: SignInCopy.cancel)
    } else {
      if configuration.appleSignIn {
        apple = ScreenElement(
          id: "signIn.apple", text: progress.inFlight == .apple ? SignInCopy.signingIn : SignInCopy.apple)
      }
      passkey = ScreenElement(
        id: "signIn.passkey", text: progress.inFlight == .passkey ? SignInCopy.signingIn : SignInCopy.passkey)
    }
    buttonsEnabled = progress.inFlight == nil && model.link == .ready
    failure = progress.failure.map { ScreenElement(id: "signIn.failure", text: $0) }
    #if os(macOS)
      terms = ScreenElement(id: "signIn.terms", text: SignInCopy.terms)
    #endif
    badge = configuration.badge.map { ScreenElement(id: "signIn.badge", text: $0) }
  }

  /// Every element shown, top to bottom.
  var elements: [ScreenElement] {
    [
      wordmark, title, intro, reason, confirmation, apple, passkey, createAccount, cancelCreate, failure,
      newHere,
    ]
    .compactMap { $0 } + [terms, badge].compactMap { $0 }
  }
}

/// The sign-in screen (`docs/superpowers/specs/2026-11-01-sign-in/sign-in.html`): the whole window on
/// `bg`, a centred column with the b4.run wordmark, the title, one sentence, Continue with Apple
/// (hidden on the local flavour) and Continue with a passkey, the fine print, and the flavour's badge at
/// the bottom. The iPhone shows its own landing instead (`PhoneSignInScreen`: "Connect your Mac", led
/// by Scan the code). Nothing else in the app is reachable from here.
public struct SignInView: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  public init(model: WorkspaceModel) { self.model = model }

  private let columnWidth: CGFloat = 300
  private let wordmarkHeight: CGFloat = 30

  public var body: some View {
    #if os(iOS)
      PhoneSignInScreen(model: model)
    #else
      macScreen
    #endif
  }

  @ViewBuilder private var macScreen: some View {
    let content = SignInContent(model: model)
    VStack(spacing: 0) {
      Spacer(minLength: LLA.Space.xl)
      column(content)
        .frame(width: columnWidth)
      Spacer(minLength: LLA.Space.xl)
      if let badge = content.badge {
        Text(badge.text)
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.ghost)
          .padding(.bottom, 14)
          .accessibilityIdentifier(badge.id)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LLA.Color.bg)
    .modifier(WorkspaceWindowBackground())
    .tint(LLA.Color.accent)
  }

  private func column(_ content: SignInContent) -> some View {
    VStack(spacing: 0) {
      B4Wordmark(height: wordmarkHeight)
        .padding(.bottom, max(0, 26 - B4Wordmark.clearSpace(height: wordmarkHeight)))
        .accessibilityIdentifier(content.wordmark.id)
      Text(content.title.text)
        .llaTitle()
        .multilineTextAlignment(.center)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(content.title.id)
      Text(content.intro.text)
        .llaMuted()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, LLA.Space.s)
        .accessibilityIdentifier(content.intro.id)
      if let reason = content.reason {
        Text(reason.text)
          .llaSmall()
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, LLA.Space.m)
          .accessibilityIdentifier(reason.id)
      }
      Group {
        if let question = content.confirmation {
          confirmation(question, content: content)
        } else {
          buttons(content)
        }
      }
      .padding(.top, 26)
      if let failure = content.failure {
        Text(failure.text)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.danger)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, LLA.Space.m)
          .accessibilityIdentifier(failure.id)
      }
      finePrint(content)
        .padding(.top, 22)
    }
  }

  // MARK: The buttons

  private func buttons(_ content: SignInContent) -> some View {
    VStack(spacing: 10) {
      if let apple = content.apple {
        Button {
          // The Mac opens Apple's page in a browser session; the phone shows Apple's own sheet.
          Task { await model.signInWithApple(using: SystemAppleCeremony(session: webAuthenticationSession)) }
        } label: {
          pillLabel(apple.text, systemImage: "apple.logo")
        }
        .buttonStyle(SignInPillStyle(kind: .apple))
        .accessibilityLabel(apple.text)
        .accessibilityIdentifier(apple.id)
      }
      if let passkey = content.passkey {
        Button {
          Task { await model.signInWithPasskey(using: SystemPasskeyCeremony()) }
        } label: {
          pillLabel(passkey.text, systemImage: "person.badge.key")
        }
        .buttonStyle(SignInPillStyle(kind: .passkey))
        .accessibilityLabel(passkey.text)
        .accessibilityIdentifier(passkey.id)
      }
    }
    .disabled(!content.buttonsEnabled)
  }

  private func pillLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 7) {
      // Apple's logo from the system (SF Symbols), never a drawn copy; sized to the title.
      Image(systemName: systemImage)
        .font(LLAFont.button)
        .imageScale(.medium)
        .accessibilityHidden(true)
      Text(title)
    }
  }

  /// "No passkey for <site> on this device. Create a new account?", in place of the two buttons.
  @ViewBuilder
  private func confirmation(_ question: ScreenElement, content: SignInContent) -> some View {
    VStack(spacing: 10) {
      Text(question.text)
        .llaSmall()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, LLA.Space.xs)
        .accessibilityIdentifier(question.id)
      if let create = content.createAccount {
        Button {
          Task { await model.confirmCreateAccount() }
        } label: {
          Text(create.text)
        }
        .buttonStyle(SignInPillStyle(kind: .primary))
        .accessibilityLabel(create.text)
        .accessibilityIdentifier(create.id)
      }
      if let cancel = content.cancelCreate {
        Button {
          model.cancelCreateAccount()
        } label: {
          Text(cancel.text)
        }
        .buttonStyle(SignInPillStyle(kind: .passkey))
        .accessibilityLabel(cancel.text)
        .accessibilityIdentifier(cancel.id)
      }
    }
  }

  // MARK: The fine print

  private func finePrint(_ content: SignInContent) -> some View {
    VStack(spacing: 2) {
      Text(content.newHere.text)
        .accessibilityIdentifier(content.newHere.id)
      if let terms = content.terms {
        Text(Self.termsLine(model.signInConfiguration))
          .accessibilityLabel(terms.text)
          .accessibilityIdentifier(terms.id)
      }
    }
    .font(LLAFont.caption)
    .foregroundStyle(LLA.Color.muted)
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// "By continuing you agree to the terms and privacy policy.", the two in the accent colour as links
  /// to `https://<site>/app/terms` and `/app/privacy`.
  static func termsLine(_ configuration: SignInConfiguration) -> AttributedString {
    var line = AttributedString("By continuing you agree to the ")
    var terms = AttributedString("terms")
    terms.link = configuration.termsURL
    terms.foregroundColor = LLA.Color.accent
    var privacy = AttributedString("privacy policy")
    privacy.link = configuration.privacyURL
    privacy.foregroundColor = LLA.Color.accent
    line += terms
    line += AttributedString(" and ")
    line += privacy
    line += AttributedString(".")
    return line
  }
}

/// The sign-in pills, which carry a glyph (the LLA pills drop icons): Apple's ink fill with the white
/// logo (inverting in dark mode, as Apple's guidelines allow), the passkey's surface fill with a rule
/// border, and a plain ink pill. Full width, at least Apple's minimum height.
struct SignInPillStyle: ButtonStyle {
  enum Kind { case apple, passkey, primary }
  var kind: Kind

  func makeBody(configuration: Configuration) -> some View {
    Pill(kind: kind, configuration: configuration)
  }

  private struct Pill: View {
    let kind: Kind
    let configuration: Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    #if os(iOS)
      private let height: CGFloat = 44
    #else
      private let height: CGFloat = 34
    #endif

    var body: some View {
      configuration.label
        .font(LLAFont.button)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: height)
        .foregroundStyle(kind == .passkey ? LLA.Color.ink : LLA.Color.bg)
        .background {
          Capsule().fill(fill)
          if kind == .passkey { Capsule().strokeBorder(LLA.Color.rule) }
        }
        .contentShape(Capsule())
        .opacity(configuration.isPressed ? 0.8 : 1)
        .opacity(isEnabled ? 1 : 0.6)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
      switch kind {
      case .apple, .primary: return LLA.Color.ink
      case .passkey: return hovering ? LLA.Color.surfaceRaised : LLA.Color.surface
      }
    }
  }
}
