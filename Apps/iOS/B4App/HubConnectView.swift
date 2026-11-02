import SwiftUI
import UIKit
import WorkspaceSync
import WorkspaceUI

/// Joins this device to the hub with a one-time enrollment code from `b4hub enroll`. The code lives
/// in this view's state only until the enrollment request returns, then it is cleared; nothing logs it.
struct HubConnectView: View {
  let host: MirrorHost

  @State private var hubURL = HubConnectView.defaultURL
  @State private var code = ""
  @State private var deviceName = UIDevice.current.name
  @State private var error: String?
  @State private var connecting = false

  static let codeLength = 8

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
        LLASectionHead(
          "Connect to your hub",
          intro:
            "This device shows the threads your Mac syncs to the hub. Create an enrollment code on the hub, then enter it here. Sending turns from here comes later."
        )
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
        labeled("Device name") {
          LLAField("iPhone", text: $deviceName)
            .autocorrectionDisabled()
        }
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
        Button(connecting ? "Connecting…" : "Connect") {
          Task { await connect() }
        }
        .buttonStyle(.llaPrimary)
        .disabled(!canConnect)
      }
      .frame(maxWidth: 480, alignment: .leading)
      .padding(LLA.Metrics.margin)
      .frame(maxWidth: .infinity)
    }
    .background(LLA.Color.bg)
    .tint(LLA.Color.accent)
  }

  private var canConnect: Bool {
    !connecting && code.trimmingCharacters(in: .whitespaces).count == Self.codeLength
      && !hubURL.trimmingCharacters(in: .whitespaces).isEmpty
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
