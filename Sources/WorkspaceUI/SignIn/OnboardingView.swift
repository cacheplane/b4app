import SwiftUI
import WorkspaceProtocol

/// What onboarding shows, each element with the accessibility identifier the view gives it (see
/// `SignInContent`).
struct OnboardingContent: Equatable {
  var title = ScreenElement(id: "onboarding.title", text: SignInCopy.welcome)
  var prompt = ScreenElement(id: "onboarding.prompt", text: SignInCopy.askName)
  var label = ScreenElement(id: "onboarding.label", text: SignInCopy.fullName)
  /// The field; its text is the name it starts with.
  var name: ScreenElement
  var continueButton = ScreenElement(id: "onboarding.continue", text: SignInCopy.continue)
  var logOut = ScreenElement(id: "onboarding.logOut", text: SignInCopy.notYou)

  init(model: WorkspaceModel) {
    if case .needsOnboarding(let prefill?) = model.accountState {
      name = ScreenElement(id: "onboarding.name", text: prefill)
    } else {
      name = ScreenElement(id: "onboarding.name", text: "")
    }
  }

  var elements: [ScreenElement] { [title, prompt, label, name, continueButton, logOut] }
}

/// The one screen a new account sees before the app (`onboarding.html`, the left panel): "Welcome",
/// "What should we call you?", the full name (Apple's when Apple gave one), Continue, and "Not you?
/// Log out". Continue is on for 1 to 200 characters once trimmed.
public struct OnboardingView: View {
  @Bindable var model: WorkspaceModel
  private let content: OnboardingContent
  @State private var name: String
  @State private var loggingOut = false
  @State private var logOutFailure: String?
  @FocusState private var nameFocused: Bool

  public init(model: WorkspaceModel) {
    self.model = model
    content = OnboardingContent(model: model)
    _name = State(initialValue: content.name.text)
  }

  #if os(iOS)
    private let columnWidth: CGFloat = 214
  #else
    private let columnWidth: CGFloat = 300
  #endif

  private var canContinue: Bool { FullName.isValid(name) && !model.onboardingBusy && !loggingOut }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(content.title.text)
        .llaTitle()
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(content.title.id)
      Text(content.prompt.text)
        .llaMuted()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, LLA.Space.s)
        .accessibilityIdentifier(content.prompt.id)
      Text(content.label.text)
        .font(LLAFont.caption)
        .foregroundStyle(LLA.Color.muted)
        .padding(.top, 22)
        .padding(.bottom, 5)
        .accessibilityHidden(true)
      LLAField(content.label.text, text: $name)
        .textContentType(.name)
        .focused($nameFocused)
        .onSubmit(submit)
        .accessibilityLabel(content.label.text)
        .accessibilityValue(name)
        .accessibilityIdentifier(content.name.id)
      Button(content.continueButton.text, action: submit)
        .buttonStyle(SignInPillStyle(kind: .primary))
        .disabled(!canContinue)
        .padding(.top, 14)
        .accessibilityLabel(content.continueButton.text)
        .accessibilityIdentifier(content.continueButton.id)
      if let failure = model.onboardingFailure ?? logOutFailure {
        Text(failure)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, LLA.Space.m)
          .accessibilityIdentifier("onboarding.failure")
      }
      Button(content.logOut.text) {
        Task { await logOut() }
      }
      .buttonStyle(OnboardingLinkStyle())
      .disabled(loggingOut)
      .frame(maxWidth: .infinity)
      .padding(.top, 14)
      .accessibilityLabel(content.logOut.text)
      .accessibilityIdentifier(content.logOut.id)
    }
    .frame(width: columnWidth)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LLA.Color.bg)
    .modifier(WorkspaceWindowBackground())
    .tint(LLA.Color.accent)
    .onAppear { nameFocused = true }
  }

  private func submit() {
    guard canContinue else { return }
    let name = self.name
    Task { await model.completeProfile(fullName: name) }
  }

  /// Nothing runs before onboarding, so this log-out cannot be refused for running work.
  private func logOut() async {
    loggingOut = true
    defer { loggingOut = false }
    if case .failed(let line) = await model.logOut(stopWork: false) {
      logOutFailure = line
    } else {
      logOutFailure = nil
    }
  }
}

/// "Not you? Log out": a quiet muted line, darker while hovered; not an accent link, which the LLA
/// rules keep for navigation.
private struct OnboardingLinkStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Label(configuration: configuration)
  }

  private struct Label: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(LLAFont.caption)
        .foregroundStyle(hovering ? LLA.Color.ink : LLA.Color.muted)
        .frame(minHeight: LLA.Metrics.row)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.7 : 1)
        .onHover { hovering = $0 }
    }
  }
}
