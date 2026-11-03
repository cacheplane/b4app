import SwiftUI
import UIKit
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync
import WorkspaceUI

/// Signs this phone in with a one-time enrollment code instead of a passkey or Apple (sign-in plan,
/// Task 14), and pairs it with a Mac (Task 15, D-066). Offered from "Other ways to sign in" for an operator's
/// hub with sign-up closed (the code typed, from `b4hub enroll`), and shown at once, signed in or not,
/// when a pairing link arrives: the Mac's `https://<site>/pair#c=<code>` from the system Camera, the
/// in-app scanner, or any link. A link fills the sheet and asks one question, "Pair this iPhone with
/// the hub at <host>?"; no code is redeemed without that tap. A signed-in phone first asks the hub,
/// without spending the code, whether it is its own account's (D-170): then it says "This iPhone is
/// already paired" and asks nothing. Then `MirrorHost.pair` signs a signed-out phone in, or (signed
/// in) tries the merge: it merges a phone-only account, says "already paired" for the code's own
/// account (when the check could not tell), and otherwise asks once more before switching, which
/// redeems the code before it ends the old session. A signed-in phone never sees the typed-code entry:
/// a typed code would replace its account without asking. The code lives in this view's state only
/// until the request returns, then it is cleared; nothing logs it.
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
  /// The question of the link that just paired, kept (without its code) while the sheet closes, so
  /// the face behind it never flashes (`EnrollSheetFace`).
  @State private var paired: String?
  @State private var scanning = false
  /// The switch question, after "Pair" on a phone signed in to another account: the org it leaves. The
  /// offer keeps the code until it is answered.
  @State private var switchFrom: String?
  /// The hub is checking whether the offer's code is this phone's own account's; the question waits.
  @State private var checking = false
  /// "This iPhone is already paired": the code is for the org the phone is in, found by the check or
  /// after "Pair".
  @State private var alreadyPaired = false
  /// Signed in when the sheet opened (and still): the typed entry never shows, and Cancel closes.
  @State private var openedSignedIn = false
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
          switch EnrollSheetFace.face(
            offering: offer != nil, paired: paired != nil, openedSignedIn: openedSignedIn,
            checking: checking, alreadyPaired: alreadyPaired)
          {
          case .confirmation: confirmation(offer?.prompt ?? paired ?? "")
          case .checking: checkingFace
          case .alreadyPaired: alreadyPairedFace
          case .signedInResult: signedInResult
          case .typedEntry: typedEntry
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
            .disabled(connecting || paired != nil)
            .accessibilityIdentifier("enroll.cancel")
        }
      }
    }
    .tint(LLA.Color.accent)
    .onAppear { openedSignedIn = host.isSignedIn }
    .alert(
      switchFrom.map { PairingCopy.switchQuestion(to: nil, from: $0) } ?? "",
      isPresented: Binding(get: { switchFrom != nil }, set: { if !$0 { switchFrom = nil } })
    ) {
      Button(PairingCopy.switchButton, role: .destructive) {
        switchFrom = nil
        if let offer { Task { await switchAndPair(offer) } }
      }
      .accessibilityIdentifier("pair.switch")
      Button("Cancel", role: .cancel) {
        switchFrom = nil
        cancelOffer()
      }
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

  // MARK: Signed in

  /// The check, which is quick; the question would only be taken back.
  @ViewBuilder private var checkingFace: some View {
    HStack(spacing: LLA.Space.m) {
      ProgressView()
      Text("Checking the pairing code…").llaSmallMuted()
    }
    .accessibilityIdentifier("pair.checking")
  }

  @ViewBuilder private var alreadyPairedFace: some View {
    LLASectionHead(PairingCopy.alreadyPaired, intro: PairingCopy.alreadyPairedDetail)
    Button("Done") { dismiss() }
      .buttonStyle(.llaSecondary)
      .accessibilityIdentifier("pair.alreadyPaired")
  }

  /// A signed-in phone whose pairing ended without a sign-in (a refused code, a link it will not take):
  /// the one line, and a way out. Never the typed entry.
  @ViewBuilder private var signedInResult: some View {
    errors
    Button("Done") { dismiss() }
      .buttonStyle(.llaSecondary)
      .accessibilityIdentifier("enroll.done")
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

  @ViewBuilder private func confirmation(_ prompt: String) -> some View {
    LLASectionHead(
      prompt,
      intro:
        "Pair only with a hub you run. This iPhone will show the threads your Mac syncs there and can send turns to it."
    )
    deviceNameField
    errors
    HStack(spacing: LLA.Space.m) {
      Button(connecting || paired != nil ? "Pairing…" : "Pair") {
        if let offer { Task { await pair(offer) } }
      }
      .buttonStyle(.llaPrimary)
      .disabled(connecting || offer == nil)
      .accessibilityIdentifier("connect.pair")
      Button("Cancel") { cancelOffer() }
        .buttonStyle(.llaSecondary)
        .disabled(connecting || offer == nil)
    }
  }

  /// Drop the offer and its code. A phone that was signed in has nothing to type here, so the sheet
  /// closes; a signed-out one goes back to the typed entry.
  private func cancelOffer() {
    offer = nil
    checking = false
    error = nil
    if openedSignedIn { dismiss() }
  }

  /// Takes a link or scan; nothing is sent until "Pair". While an offer is on screen another arrival is
  /// ignored, with a note, so the hub Brian is reading about cannot change under his thumb.
  private func accept(_ arrival: PairArrival) {
    guard !connecting else { return }
    // The same link twice (a universal link can reach the app by two routes) is one arrival.
    if case .offer(let link) = arrival, link == offer { return }
    guard offer == nil else {
      error = PairArrival.ignoredWhileOffering
      return
    }
    // A new link replaces an "already paired" answer for the last one.
    alreadyPaired = false
    switch arrival {
    case .offer(let link):
      offer = link
      error = nil
      if host.isSignedIn {
        checking = true
        Task { await check(link) }
      }
    case .invalid(let message):
      offer = nil
      error = message
    }
  }

  /// Asks the hub whether `link`'s code is this phone's own account's, spending nothing. Any answer but
  /// "yes" (a failure included) leaves the question to ask. Dropped if the offer changed meanwhile.
  private func check(_ link: PairLink) async {
    let answer = await host.offer(for: link)
    guard checking, offer == link else { return }
    checking = false
    if answer == .alreadyPaired {
      offer = nil
      alreadyPaired = true
    }
  }

  private func pair(_ link: PairLink) async {
    error = nil
    connecting = true
    defer { connecting = false }
    do {
      switch try await host.pair(link, deviceName: deviceName) {
      case .signedIn:
        paired = link.prompt
        offer = nil
        dismiss()
      case .alreadyPaired:
        offer = nil
        alreadyPaired = true
      case .askToSwitch(let from):
        // Nothing changed: the offer (and its code) waits for the answer.
        switchFrom = from
      }
    } catch {
      offer = nil
      // Signed in or out, the state is what it was; a 401 on the way may have signed it out.
      openedSignedIn = host.isSignedIn
      self.error = MirrorHost.describe(error)
    }
  }

  /// "Switch": redeem the code, then end the old session and sign in to the code's account. A refused
  /// code leaves the phone signed in as it was, with the one line.
  private func switchAndPair(_ link: PairLink) async {
    error = nil
    connecting = true
    defer {
      offer = nil
      connecting = false
    }
    do {
      try await host.switchAndPair(link, deviceName: deviceName)
      paired = link.prompt
      dismiss()
    } catch {
      openedSignedIn = host.isSignedIn
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

  /// The sheet's heading, and the sign-in sheet's row that opens it.
  static let title = ConnectMacCopy.enroll
}
