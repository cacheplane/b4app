import AuthenticationServices
import SwiftUI

#if os(iOS)
  import SafariServices
  import UIKit
#endif

// The iPhone's signed-out screen and its signed-in, no-Mac twin (mockup A2, approved 2026-11-02): no
// wordmark (it stays on the Mac), "Connect your Mac" and one line, the primary "Scan the code" low in
// thumb reach, and one quiet "Other ways to sign in", whose sheet holds Continue with Apple (prod and
// beta), Sign in with a passkey, Use an enrollment code, then Get the Mac app and Help. Without a
// camera there is no Scan, and the sheet's options sit on the screen instead. The Mac's sign-in screen
// is `SignInContent` and is not this.

/// What the iPhone's landing shows, each element with the accessibility identifier the view gives
/// it. The views draw exactly this, so the copy and the controls can be checked without a window.
struct PhoneLandingContent: Equatable {
  var title: ScreenElement
  var intro: ScreenElement
  /// "This iPhone was signed out of <org name>." after the hub refused this phone.
  var reason: ScreenElement?
  var scan: ScreenElement?
  /// The quiet link to the sheet; signed out with a camera only.
  var otherWays: ScreenElement?
  /// The sheet's options, on the screen itself: signed out without a camera.
  var options: PhoneSignInOptionsContent?
  /// Get the Mac app and Help, quietly: signed in with no Mac.
  var links: [ScreenElement] = []
  var badge: ScreenElement?

  /// Signed out. `copyLabel` is Get the Mac app's, which reads "Copied" for two seconds after a copy.
  init(signIn model: WorkspaceModel, hasCamera: Bool, copyLabel: String = ConnectMacCopy.getMacApp) {
    title = ScreenElement(id: "signIn.title", text: ConnectMacCopy.title)
    intro = ScreenElement(id: "signIn.intro", text: ConnectMacCopy.message)
    if case .signedOut(let line?) = model.accountState {
      reason = ScreenElement(id: "signIn.reason", text: line)
    }
    if hasCamera {
      scan = ScreenElement(id: "signIn.scan", text: ConnectMacCopy.scan)
      otherWays = ScreenElement(id: "signIn.otherWays", text: ConnectMacCopy.otherWays)
    } else {
      options = PhoneSignInOptionsContent(model: model, copyLabel: copyLabel)
    }
    badge = model.signInConfiguration.badge.map { ScreenElement(id: "signIn.badge", text: $0) }
  }

  /// Signed in to an account with no Mac: the same heading and line, Scan where there is a camera, and
  /// the two quiet links in Other ways' place.
  init(connectMac state: ConnectMac) {
    title = ScreenElement(id: "connectMac.title", text: ConnectMacCopy.title)
    intro = ScreenElement(id: "connectMac.intro", text: ConnectMacCopy.message)
    if state.showsScan {
      scan = ScreenElement(id: "connectMac.scan", text: ConnectMacCopy.scan)
    }
    links = [
      ScreenElement(id: "connectMac.copyLink", text: state.copyLabel),
      ScreenElement(id: "connectMac.help", text: ConnectMacCopy.help),
    ]
  }

  /// Every element shown, top to bottom.
  var elements: [ScreenElement] {
    [title, intro, reason, scan].compactMap { $0 } + (options?.elements ?? [])
      + [otherWays].compactMap { $0 } + links + [badge].compactMap { $0 }
  }
}

/// "Other ways to sign in": Apple (where the flavour has it) and the passkey, or the "Create a new
/// account?" question in their place; the enrollment code; the one failure line; then Get the Mac app
/// and Help.
struct PhoneSignInOptionsContent: Equatable {
  var apple: ScreenElement?
  var passkey: ScreenElement?
  var confirmation: ScreenElement?
  var createAccount: ScreenElement?
  var cancelCreate: ScreenElement?
  var enroll = ScreenElement(id: "signIn.enroll", text: ConnectMacCopy.enroll)
  var failure: ScreenElement?
  var getMacApp: ScreenElement
  var help = ScreenElement(id: "signIn.help", text: ConnectMacCopy.help)
  var buttonsEnabled: Bool

  init(model: WorkspaceModel, copyLabel: String = ConnectMacCopy.getMacApp) {
    let progress = model.signInProgress
    if let question = progress.confirmation {
      confirmation = ScreenElement(id: "signIn.confirmation", text: question)
      createAccount = ScreenElement(id: "signIn.createAccount", text: SignInCopy.createAccount)
      cancelCreate = ScreenElement(id: "signIn.cancelCreate", text: SignInCopy.cancel)
    } else {
      if model.signInConfiguration.appleSignIn {
        apple = ScreenElement(
          id: "signIn.apple", text: progress.inFlight == .apple ? SignInCopy.signingIn : SignInCopy.apple)
      }
      passkey = ScreenElement(
        id: "signIn.passkey",
        text: progress.inFlight == .passkey ? SignInCopy.signingIn : ConnectMacCopy.passkey)
    }
    failure = progress.failure.map { ScreenElement(id: "signIn.failure", text: $0) }
    getMacApp = ScreenElement(id: "signIn.getMacApp", text: copyLabel)
    buttonsEnabled = progress.inFlight == nil && model.link == .ready
  }

  /// Every element shown, top to bottom.
  var elements: [ScreenElement] {
    [confirmation, createAccount, cancelCreate, apple, passkey, enroll, failure, getMacApp, help].compactMap {
      $0
    }
  }
}

/// What the iPhone's sign-in screen takes from the app, whose scanner and enrollment sheet they are.
public struct PhoneSignInHooks {
  /// A camera exists, so Scan the code shows.
  public var hasCamera: Bool
  /// Opens the scanner; what it reads takes the way every pairing link takes.
  public var scan: @MainActor () -> Void
  /// Opens the enrollment sheet ("Use an enrollment code"), after Other ways has closed.
  public var enroll: @MainActor () -> Void
  /// Other ways to sign in has closed, so a pairing link held back for it can be shown.
  public var sheetClosed: @MainActor () -> Void

  public init(
    hasCamera: Bool, scan: @escaping @MainActor () -> Void, enroll: @escaping @MainActor () -> Void,
    sheetClosed: @escaping @MainActor () -> Void
  ) {
    self.hasCamera = hasCamera
    self.scan = scan
    self.enroll = enroll
    self.sheetClosed = sheetClosed
  }
}

extension EnvironmentValues {
  /// The iPhone app's scanner and enrollment sheet for its sign-in screen. Nil (the Mac, and previews)
  /// means no camera and no enrollment sheet.
  @Entry public var phoneSignIn: PhoneSignInHooks? = nil
}

#if os(iOS)
  /// The iPhone's signed-out screen, in place of the Mac's (`SignInView`).
  struct PhoneSignInScreen: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.phoneSignIn) private var hooks
    /// Get the Mac app's copy and "Copied", and Help's Safari sheet.
    @State private var links: ConnectMac
    /// "Use an enrollment code" in the sheet: the app's sheet opens once this one has gone.
    @State private var enrollWhenClosed = false
    @State private var sheetHeight: CGFloat = 320

    init(model: WorkspaceModel) {
      self.model = model
      _links = State(
        initialValue: ConnectMac(
          siteDomain: model.signInConfiguration.siteDomain, hasCamera: false,
          copy: { UIPasteboard.general.string = $0 }))
    }

    var body: some View {
      let content = PhoneLandingContent(
        signIn: model, hasCamera: hooks?.hasCamera ?? false, copyLabel: links.copyLabel)
      PhoneLandingLayout(content: content) {
        if let scan = content.scan {
          Button {
            hooks?.scan()
          } label: {
            PhoneLabel(scan.text, systemImage: "viewfinder")
          }
          .buttonStyle(PhonePillStyle())
          .accessibilityIdentifier(scan.id)
        }
        if let otherWays = content.otherWays {
          Button(otherWays.text) { model.showSignInOptions = true }
            .buttonStyle(PhoneQuietLinkStyle(font: LLAFont.body))
            .padding(.top, LLA.Space.s)
            .accessibilityIdentifier(otherWays.id)
        }
        if content.options != nil {
          PhoneSignInOptions(model: model, links: links) { hooks?.enroll() }
        }
      }
      .background(LLA.Color.bg)
      .tint(LLA.Color.accent)
      .sheet(isPresented: $model.showSignInOptions, onDismiss: sheetClosed) {
        PhoneSignInOptions(model: model, links: links) {
          enrollWhenClosed = true
          model.showSignInOptions = false
        }
        .padding(.horizontal, 22)
        .padding(.top, LLA.Space.xl)
        .padding(.bottom, LLA.Space.l)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          sheetHeight = $0
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(LLA.Color.surface)
        .interactiveDismissDisabled(model.signInProgress.inFlight != nil)
      }
      // Signed in from the sheet: the screen goes, and the sheet with it.
      .onDisappear { model.showSignInOptions = false }
    }

    private func sheetClosed() {
      if enrollWhenClosed {
        enrollWhenClosed = false
        hooks?.enroll()
      }
      hooks?.sheetClosed()
    }
  }

  /// "Connect your Mac" on a signed-in phone whose account has no Mac: the landing's layout, with Get
  /// the Mac app and Help as quiet links in Other ways' place. The app owns the state (its pasteboard)
  /// and the scanner.
  public struct ConnectMacScreen: View {
    @Bindable var state: ConnectMac
    let onScan: () -> Void

    public init(state: ConnectMac, onScan: @escaping () -> Void) {
      self.state = state
      self.onScan = onScan
    }

    public var body: some View {
      let content = PhoneLandingContent(connectMac: state)
      PhoneLandingLayout(content: content) {
        if let scan = content.scan {
          Button(action: onScan) {
            PhoneLabel(scan.text, systemImage: "viewfinder")
          }
          .buttonStyle(PhonePillStyle())
          .accessibilityIdentifier(scan.id)
        }
        PhoneQuietLinks(
          getMacApp: content.links[0], help: content.links[1],
          copy: { Task { await state.copyDownloadLink() } }, openHelp: { state.openHelp() }
        )
        .padding(.top, content.scan == nil ? 0 : LLA.Space.s)
      }
      .sheet(item: $state.help) { help in
        SafariSheet(url: help.url).ignoresSafeArea()
      }
    }
  }

  /// Heading and line centred in the space above, the actions low in thumb reach, the flavour's badge
  /// at the bottom. It scrolls only when the text is too large to fit.
  struct PhoneLandingLayout<Actions: View>: View {
    let content: PhoneLandingContent
    @ViewBuilder let actions: Actions

    var body: some View {
      GeometryReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            Spacer(minLength: LLA.Space.xxl)
            heading
            Spacer(minLength: LLA.Space.xxl)
            VStack(spacing: 0) { actions }
            if let badge = content.badge {
              Text(badge.text)
                .font(LLAFont.caption)
                .foregroundStyle(LLA.Color.ghost)
                .padding(.top, LLA.Space.l)
                .accessibilityIdentifier(badge.id)
            }
          }
          .padding(.horizontal, LLA.Space.xl)
          .padding(.bottom, LLA.Space.l)
          .frame(maxWidth: 440)
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }

    private var heading: some View {
      VStack(spacing: LLA.Space.s) {
        Text(content.title.text)
          .llaDisplay()
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(content.title.id)
        Text(content.intro.text)
          .llaMuted()
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(content.intro.id)
        if let reason = content.reason {
          Text(reason.text)
            .llaSmall()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, LLA.Space.s)
            .accessibilityIdentifier(reason.id)
        }
      }
      .multilineTextAlignment(.center)
    }
  }

  /// The sheet's rows (or, without a camera, the screen's): Apple and the passkey, or the "Create a
  /// new account?" question; the enrollment code; the failure line; the two quiet links.
  struct PhoneSignInOptions: View {
    @Bindable var model: WorkspaceModel
    @Bindable var links: ConnectMac
    let onEnroll: () -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
      let content = PhoneSignInOptionsContent(model: model, copyLabel: links.copyLabel)
      VStack(spacing: 10) {
        if let question = content.confirmation {
          Text(question.text)
            .llaSmall()
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, LLA.Space.xs)
            .accessibilityIdentifier(question.id)
          if let create = content.createAccount {
            Button(create.text) { Task { await model.confirmCreateAccount() } }
              .buttonStyle(PhoneRowStyle(kind: .primary))
              .accessibilityIdentifier(create.id)
          }
          if let cancel = content.cancelCreate {
            Button(cancel.text) { model.cancelCreateAccount() }
              .buttonStyle(PhoneRowStyle(kind: .plain))
              .accessibilityIdentifier(cancel.id)
          }
        }
        Group {
          if let apple = content.apple {
            Button {
              Task {
                await model.signInWithApple(using: SystemAppleCeremony(session: webAuthenticationSession))
              }
            } label: {
              // Apple's logo from the system (SF Symbols), never a drawn copy.
              PhoneLabel(apple.text, systemImage: "apple.logo")
            }
            .buttonStyle(PhoneRowStyle(kind: .plain))
            .accessibilityLabel(apple.text)
            .accessibilityIdentifier(apple.id)
          }
          if let passkey = content.passkey {
            Button(passkey.text) { Task { await model.signInWithPasskey(using: SystemPasskeyCeremony()) } }
              .buttonStyle(PhoneRowStyle(kind: .plain))
              .accessibilityIdentifier(passkey.id)
          }
          Button(content.enroll.text, action: onEnroll)
            .buttonStyle(PhoneRowStyle(kind: .plain))
            .accessibilityIdentifier(content.enroll.id)
        }
        .disabled(!content.buttonsEnabled)
        if let failure = content.failure {
          Text(failure.text)
            .font(LLAFont.small)
            .foregroundStyle(LLA.Color.danger)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(failure.id)
        }
        PhoneQuietLinks(
          getMacApp: content.getMacApp, help: content.help,
          copy: { Task { await links.copyDownloadLink() } }, openHelp: { links.openHelp() }
        )
        .padding(.top, LLA.Space.xs)
      }
      .sheet(item: $links.help) { help in
        SafariSheet(url: help.url).ignoresSafeArea()
      }
    }
  }

  /// Get the Mac app and Help, side by side in quiet grey, stacked when the text is too large.
  private struct PhoneQuietLinks: View {
    let getMacApp: ScreenElement
    let help: ScreenElement
    let copy: () -> Void
    let openHelp: () -> Void

    var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 22) { buttons }
        VStack(spacing: 0) { buttons }
      }
    }

    @ViewBuilder private var buttons: some View {
      Button(getMacApp.text, action: copy)
        .buttonStyle(PhoneQuietLinkStyle(font: LLAFont.small))
        .accessibilityIdentifier(getMacApp.id)
      Button(help.text, action: openHelp)
        .buttonStyle(PhoneQuietLinkStyle(font: LLAFont.small))
        .accessibilityIdentifier(help.id)
    }
  }

  /// A title with its glyph, sized to the title.
  private struct PhoneLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
      self.title = title
      self.systemImage = systemImage
    }

    var body: some View {
      HStack(spacing: LLA.Space.s) {
        Image(systemName: systemImage)
          .imageScale(.medium)
          .accessibilityHidden(true)
        Text(title)
      }
    }
  }

  /// The landing's one primary action: an ink pill, full width, 50 points high.
  private struct PhonePillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(LLAFont.button)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 50)
        .foregroundStyle(LLA.Color.bg)
        .background(Capsule().fill(LLA.Color.ink))
        .contentShape(Capsule())
        .opacity(configuration.isPressed ? 0.8 : 1)
    }
  }

  /// The sheet's rows: the background colour with a hairline (or ink, for Create account), rounded,
  /// full width, 46 points high.
  private struct PhoneRowStyle: ButtonStyle {
    enum Kind { case plain, primary }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
      Row(kind: kind, configuration: configuration)
    }

    private struct Row: View {
      let kind: Kind
      let configuration: Configuration
      @Environment(\.isEnabled) private var isEnabled

      var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
          .font(LLAFont.button)
          .lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: 46)
          .foregroundStyle(kind == .primary ? LLA.Color.bg : LLA.Color.ink)
          .background {
            shape.fill(kind == .primary ? LLA.Color.ink : LLA.Color.bg)
            if kind == .plain { shape.strokeBorder(LLA.Color.rule) }
          }
          .contentShape(shape)
          .opacity(configuration.isPressed ? 0.8 : 1)
          .opacity(isEnabled ? 1 : 0.6)
      }
    }
  }

  /// A quiet grey text link, with a full-height target.
  private struct PhoneQuietLinkStyle: ButtonStyle {
    var font: Font

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(font)
        .foregroundStyle(LLA.Color.muted)
        .frame(minHeight: LLA.Metrics.row)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
  }

  /// A web page in Safari's own sheet: the reader's cookies and sign-ins, and nothing the app can read.
  struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
      SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
  }
#endif
