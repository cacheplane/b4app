import SwiftUI
import UIKit
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync
import WorkspaceUI

/// Signs this phone in with a one-time enrollment code instead of a passkey or Apple (sign-in plan,
/// Task 14), and pairs it with a Mac (Task 15, D-066). Offered from the sign-in screen for an operator's
/// hub with sign-up closed (the code typed, from `b4hub enroll`), and shown at once, signed in or not,
/// when a pairing link arrives: the Mac's `https://<site>/pair#c=<code>` from the system Camera, the
/// in-app scanner, or any link. A link fills the sheet and asks one question, "Pair this iPhone with
/// the hub at <host>?"; nothing is sent without that tap. Then `MirrorHost.pair` signs a signed-out
/// phone in or merges a phone-only account; a phone signed in to an account with a Mac (or one the hub
/// will not merge) is asked once more before it logs out and switches. The code lives in this view's
/// state only until the request returns, then it is cleared; nothing logs it.
struct EnrollView: View {
  let host: MirrorHost
  /// A pairing link opened while this screen shows; taken into `offer` and cleared at once.
  @Binding var incoming: PairArrival?

  @State private var hubURL = EnrollView.defaultURL
  @State private var code = ""
  @State private var deviceName = UIDevice.current.name
  @State private var error: String?
  @State private var connecting = false
  /// The link waiting for "Pair". Holds the code until the request returns or Brian cancels.
  @State private var offer: PairLink?
  @State private var scanning = false
  /// The switch question, after "Pair" on a phone signed in to another account: the org it leaves, and
  /// whether that account has a Mac. The offer keeps the code until it is answered.
  @State private var switchQuestion: SwitchQuestion?
  /// Signed in when the sheet opened: Cancel then closes it, since the typed entry is for signing in.
  @State private var openedSignedIn = false

  struct SwitchQuestion: Equatable {
    let from: String
    let alreadyPaired: Bool
  }
  @Environment(\.dismiss) private var dismiss

  static let codeLength = PairLink.codeLength

  private static var defaultURL: String {
    #if DEBUG
      "http://localhost:8080"
    #else
      ""
    #endif
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: LLA.Space.l) {
          if let offer {
            confirmation(offer)
          } else {
            typedEntry
          }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(LLA.Metrics.margin)
        .frame(maxWidth: .infinity)
      }
      .background(LLA.Color.bg)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(connecting)
            .accessibilityIdentifier("enroll.cancel")
        }
      }
    }
    .tint(LLA.Color.accent)
    .onAppear { openedSignedIn = host.accountStatus.map { $0.state != .signedOut } ?? false }
    .alert(
      switchQuestion.map { PairingCopy.title(alreadyPaired: $0.alreadyPaired) } ?? "",
      isPresented: Binding(get: { switchQuestion != nil }, set: { if !$0 { switchQuestion = nil } }),
      presenting: switchQuestion
    ) { question in
      Button(PairingCopy.switchButton, role: .destructive) {
        switchQuestion = nil
        if let offer { Task { await switchAndPair(offer) } }
      }
      .accessibilityIdentifier("pair.switch")
      Button("Cancel", role: .cancel) {
        switchQuestion = nil
        cancelOffer()
      }
    } message: { question in
      Text(PairingCopy.message(alreadyPaired: question.alreadyPaired, from: question.from))
    }
    .onChange(of: incoming, initial: true) { _, arrival in
      guard let arrival else { return }
      incoming = nil
      accept(arrival)
    }
    .sheet(isPresented: $scanning) {
      QRScannerView { text in
        accept(PairArrival(scanned: text, decide: host.pairLinkDecision))
      }
    }
  }

  // MARK: Typed

  @ViewBuilder private var typedEntry: some View {
    LLASectionHead(
      EnrollView.title,
      intro:
        "For a hub that gives out enrollment codes. Scan the code your Mac shows in Settings, Remote access, or enter the hub URL and the code."
    )
    if QRScannerView.isAvailable {
      Button("Scan QR code") { scanning = true }
        .buttonStyle(.llaSecondary)
        .disabled(connecting)
        .accessibilityIdentifier("connect.scan")
    }
    labeled("Hub URL") {
      LLAField("https://hub.example.com", text: $hubURL)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.URL)
    }
    labeled("Enrollment code") {
      LLAField("8 characters", text: $code)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .textContentType(.oneTimeCode)
        .onChange(of: code) { _, value in
          if value.count > Self.codeLength { code = String(value.prefix(Self.codeLength)) }
        }
    }
    deviceNameField
    errors
    Button(connecting ? "Connecting…" : "Connect") {
      Task { await connect() }
    }
    .buttonStyle(.llaPrimary)
    .disabled(!canConnect)
  }

  private var canConnect: Bool {
    !connecting && code.trimmingCharacters(in: .whitespaces).count == Self.codeLength
      && !hubURL.trimmingCharacters(in: .whitespaces).isEmpty
  }

  // MARK: From a link or a scan

  @ViewBuilder private func confirmation(_ offer: PairLink) -> some View {
    LLASectionHead(
      offer.prompt,
      intro:
        "Pair only with a hub you run. This iPhone will show the threads your Mac syncs there and can send turns to it."
    )
    deviceNameField
    errors
    HStack(spacing: LLA.Space.m) {
      Button(connecting ? "Pairing…" : "Pair") {
        Task { await pair(offer) }
      }
      .buttonStyle(.llaPrimary)
      .disabled(connecting)
      .accessibilityIdentifier("connect.pair")
      Button("Cancel") { cancelOffer() }
        .buttonStyle(.llaSecondary)
        .disabled(connecting)
    }
  }

  /// Drop the offer and its code. A phone that was signed in has nothing to type here, so the sheet
  /// closes; a signed-out one goes back to the typed entry.
  private func cancelOffer() {
    offer = nil
    error = nil
    if openedSignedIn { dismiss() }
  }

  /// Takes a link or scan; nothing is sent until "Pair". While an offer is on screen another arrival is
  /// ignored, with a note, so the hub Brian is reading about cannot change under his thumb.
  private func accept(_ arrival: PairArrival) {
    guard !connecting else { return }
    guard offer == nil else {
      error = PairArrival.ignoredWhileOffering
      return
    }
    switch arrival {
    case .offer(let link):
      offer = link
      error = nil
    case .invalid(let message):
      offer = nil
      error = message
    }
  }

  private func pair(_ link: PairLink) async {
    error = nil
    connecting = true
    defer { connecting = false }
    do {
      switch try await host.pair(link, deviceName: deviceName) {
      case .signedIn:
        offer = nil
        dismiss()
      case .askToSwitch(let from, let alreadyPaired):
        // Nothing was sent: the offer (and its code) waits for the answer.
        switchQuestion = SwitchQuestion(from: from, alreadyPaired: alreadyPaired)
      }
    } catch {
      offer = nil
      self.error = MirrorHost.describe(error)
    }
  }

  /// "Switch": log out, then enroll into the code's account. A refused code leaves the phone signed
  /// out, with the refusal on the typed entry.
  private func switchAndPair(_ link: PairLink) async {
    error = nil
    connecting = true
    defer {
      offer = nil
      connecting = false
    }
    do {
      try await host.switchAndPair(link, deviceName: deviceName)
      dismiss()
    } catch {
      openedSignedIn = false
      self.error = MirrorHost.describe(error)
    }
  }

  // MARK: Shared

  private var deviceNameField: some View {
    labeled("Device name") {
      LLAField("iPhone", text: $deviceName)
        .autocorrectionDisabled()
    }
  }

  @ViewBuilder private var errors: some View {
    if let error {
      Text(error)
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.danger)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("connect.error")
    }
    if let storeError = host.storeError {
      Text(storeError)
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.danger)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func labeled<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text(title).llaSmallMuted()
      field()
    }
  }

  private func connect() async {
    error = nil
    // Refuse a non-HTTPS, non-loopback URL before any request is made.
    do {
      _ = try HubURL.validate(hubURL)
    } catch {
      self.error = MirrorHost.describe(error)
      return
    }
    connecting = true
    defer {
      code = ""
      connecting = false
    }
    do {
      try await host.connect(url: hubURL, code: code, deviceName: deviceName)
      dismiss()
    } catch {
      self.error = MirrorHost.describe(error)
    }
  }

  /// The sheet's heading, and the sign-in screen's link to it.
  static let title = "Use an enrollment code"
}
