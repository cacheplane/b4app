import SwiftUI
import UIKit
import WorkspaceProtocol
import WorkspaceSync
import WorkspaceUI

/// Joins this device to the hub with a one-time enrollment code: typed (from `b4hub enroll`), scanned
/// from the QR code the Mac shows, or from a `b4app://pair` link. A scanned or opened link fills the
/// screen and asks one question, "Pair this iPhone with the hub at <host>?"; nothing enrolls without
/// that tap. The code lives in this view's state only until the enrollment request returns, then it is
/// cleared; nothing logs it.
struct HubConnectView: View {
  let host: MirrorHost
  /// A pairing link opened while this screen shows; taken into `offer` and cleared at once.
  @Binding var incoming: PairArrival?

  @State private var hubURL = HubConnectView.defaultURL
  @State private var code = ""
  @State private var deviceName = UIDevice.current.name
  @State private var error: String?
  @State private var connecting = false
  /// The link waiting for "Pair". Holds the code until the request returns or Brian cancels.
  @State private var offer: PairLink?
  @State private var scanning = false

  static let codeLength = PairLink.codeLength

  private static var defaultURL: String {
    #if DEBUG
      "http://localhost:8080"
    #else
      ""
    #endif
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LLA.Space.l) {
        LLAMarkView(height: 28)
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
    .tint(LLA.Color.accent)
    .onChange(of: incoming, initial: true) { _, arrival in
      guard let arrival else { return }
      incoming = nil
      accept(arrival)
    }
    .sheet(isPresented: $scanning) {
      QRScannerView { text in
        accept(PairArrival(scanned: text, decide: host.pairLink))
      }
    }
  }

  // MARK: Typed

  @ViewBuilder private var typedEntry: some View {
    LLASectionHead(
      "Connect to your hub",
      intro:
        "This device shows the threads your Mac syncs to the hub. Scan the code your Mac shows in Settings, Remote access, or enter a hub URL and an enrollment code."
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
      Button("Cancel") {
        self.offer = nil
        error = nil
      }
      .buttonStyle(.llaSecondary)
      .disabled(connecting)
    }
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
    defer {
      offer = nil
      connecting = false
    }
    do {
      try await host.connect(url: link.hub.absoluteString, code: link.code, deviceName: deviceName)
    } catch {
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
    } catch {
      self.error = MirrorHost.describe(error)
    }
  }
}
