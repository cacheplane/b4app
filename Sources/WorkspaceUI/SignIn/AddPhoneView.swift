#if os(macOS)
  import SwiftUI
  import WorkspaceProtocol

  /// "Add your iPhone"'s words (the plan's global constraints, verbatim).
  enum AddPhoneCopy {
    static let title = "Add your iPhone"
    static let intro = "Scan this with your iPhone's camera to see your threads there."
    static let expiry = "Works for 5 minutes"
    static let newCode = "New code"
    static let done = "Done"
    static let appStore = "No iPhone app yet? It's on the App Store."
  }

  /// What "Add your iPhone" shows for the pairing flow's phase (see `SignInContent`).
  struct AddPhoneContent: Equatable {
    var title = AddPhoneCopy.title
    var intro = AddPhoneCopy.intro
    /// The QR code is on screen (a code is waiting to be scanned).
    var showsCode: Bool
    /// "Works for 5 minutes", beside New code, while a code shows.
    var expiry: String?
    /// "New code", except once paired.
    var newCode: String?
    /// The line in place of the code: getting one, expired, paired, or why none came.
    var status: String?
    var statusIsFailure = false
    var done = AddPhoneCopy.done
    var appStore = AddPhoneCopy.appStore

    @MainActor init(flow: PairingFlow) {
      switch flow.phase {
      case .waiting:
        showsCode = flow.link != nil
        expiry = AddPhoneCopy.expiry
        newCode = AddPhoneCopy.newCode
      case .paired:
        showsCode = false
        status = flow.message
      case .minting:
        showsCode = false
        status = flow.message
      case .expired, .notJoined:
        showsCode = false
        status = flow.message
        newCode = AddPhoneCopy.newCode
      case .failed:
        showsCode = false
        status = flow.message
        statusIsFailure = true
        newCode = AddPhoneCopy.newCode
      }
    }
  }

  /// "Add your iPhone" (`pairing.html`, left): shown once after a new account finishes onboarding (Done
  /// skips it), and from Settings → Remote access. M8c's `hub.pair` code as a QR code, minted again on
  /// New code and, a couple of times, when it expires; it closes itself with "Paired with <name>"
  /// (`hub.pairStatus`). The code lives in the flow only while this is open (D-058).
  struct AddPhoneView: View {
    let model: WorkspaceModel
    @State private var flow: PairingFlow
    @Environment(\.dismiss) private var dismiss

    /// How many expired codes are replaced without a tap: about 15 minutes on screen, well inside the
    /// hub's 10 codes an hour.
    static let renewals = 2

    init(model: WorkspaceModel) {
      self.model = model
      _flow = State(initialValue: Self.makeFlow(model: model))
    }

    /// The flow this view runs: M8c's, renewing an expired code `renewals` times.
    static func makeFlow(model: WorkspaceModel) -> PairingFlow {
      let flow = PairingFlow(model: model)
      flow.renewsExpiredCodes = renewals
      return flow
    }

    var body: some View {
      let content = AddPhoneContent(flow: flow)
      VStack(spacing: 0) {
        Text(content.title)
          .font(LLAFont.sans(22, weight: .semibold, relativeTo: .title))
          .tracking(-0.2)
          .foregroundStyle(LLA.Color.ink)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("addPhone.title")
        Text(content.intro)
          .llaMuted()
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, LLA.Space.s)
          .padding(.bottom, 18)
          .accessibilityIdentifier("addPhone.intro")
        code(content)
          .padding(.bottom, 10)
        footnote(content)
          .padding(.bottom, 18)
        Button(content.done) { close() }
          .buttonStyle(SignInPillStyle(kind: .passkey))
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("addPhone.done")
        Text(content.appStore)
          .font(LLAFont.caption)
          .foregroundStyle(LLA.Color.muted)
          .multilineTextAlignment(.center)
          .padding(.top, 14)
          .accessibilityIdentifier("addPhone.appStore")
      }
      .frame(width: 300)
      .padding(.horizontal, 130)
      .padding(.vertical, 48)
      .background(LLA.Color.bg)
      .tint(LLA.Color.accent)
      .task(id: flow.generation) {
        await flow.run()
        // A paired phone closes the sheet after a moment to read "Paired with …".
        if case .paired = flow.phase {
          try? await Task.sleep(for: .seconds(2))
          if !Task.isCancelled { close() }
        }
      }
      .onDisappear {
        flow.clear()
        model.showAddPhone = false
      }
    }

    private func close() {
      flow.clear()
      model.showAddPhone = false
      dismiss()
    }

    /// The QR code in its frame (150 pt with 12 pt of white around it, radius 16), or the line that
    /// stands in for it in the same space.
    @ViewBuilder private func code(_ content: AddPhoneContent) -> some View {
      let frame = RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous)
      ZStack {
        frame.fill(content.showsCode ? Color.white : LLA.Color.surface)
        if content.showsCode, let link = flow.link, let image = QRCode.image(for: link.absoluteString) {
          Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .padding(12)
            .accessibilityLabel("QR code for adding your iPhone")
            .accessibilityIdentifier("addPhone.code")
        } else if let status = content.status {
          Text(status)
            .font(LLAFont.small)
            .foregroundStyle(content.statusIsFailure ? LLA.Color.danger : LLA.Color.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(LLA.Space.m)
            .accessibilityIdentifier("addPhone.status")
        }
      }
      .frame(width: 150, height: 150)
      .overlay(frame.strokeBorder(LLA.Color.rule))
    }

    /// "Works for 5 minutes · New code".
    private func footnote(_ content: AddPhoneContent) -> some View {
      HStack(spacing: 4) {
        if let expiry = content.expiry {
          Text(expiry).accessibilityIdentifier("addPhone.expiry")
          Text("·").accessibilityHidden(true)
        }
        if let newCode = content.newCode {
          Button(newCode) { flow.restart() }
            .buttonStyle(.plain)
            .foregroundStyle(LLA.Color.accent)
            .disabled(flow.phase == .minting)
            .accessibilityIdentifier("addPhone.newCode")
        }
      }
      .font(LLAFont.sans(11, relativeTo: .caption2))
      .foregroundStyle(LLA.Color.muted)
      .frame(minHeight: 16)
    }
  }
#endif
