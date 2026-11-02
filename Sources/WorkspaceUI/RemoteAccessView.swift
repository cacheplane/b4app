#if os(macOS)
  import CoreImage
  import CoreImage.CIFilterBuiltins
  import Observation
  import SwiftUI
  import WorkspaceProtocol

  // MARK: - The QR code

  /// A QR code as a bitmap of whole pixels per module, so it stays sharp at any size on screen.
  enum QRCode {
    /// Pixels per module, and modules of white around the code (the quiet zone scanners need).
    static let moduleSize: CGFloat = 8
    static let quietModules: CGFloat = 4

    /// Black modules on white, error correction "M". nil only when the text cannot be encoded.
    static func image(for text: String) -> CGImage? {
      let filter = CIFilter.qrCodeGenerator()
      filter.message = Data(text.utf8)
      filter.correctionLevel = "M"
      guard let output = filter.outputImage else { return nil }
      // The generator draws one pixel per module. Sample it without smoothing, then scale by a whole
      // number, so every module stays a crisp square.
      let modules = output.samplingNearest().transformed(
        by: CGAffineTransform(scaleX: moduleSize, y: moduleSize))
      let margin = quietModules * moduleSize
      let canvas = modules.extent.insetBy(dx: -margin, dy: -margin)
      let page = CIImage(color: .white).cropped(to: canvas)
      let framed = modules.composited(over: page)
      return CIContext(options: [.useSoftwareRenderer: true])
        .createCGImage(framed, from: canvas)
    }
  }

  // MARK: - The sheet's state

  /// What the pairing sheet is doing. It owns the code, and so lives exactly as long as the sheet: the
  /// code is a credential shown on purpose (D-058), so it is held here and nowhere else, cleared when it
  /// is used, when it expires, and when the sheet goes.
  @MainActor @Observable
  final class PairingFlow {
    enum Phase: Equatable {
      case minting
      case waiting
      case paired(String)
      case expired
      case notJoined
      case failed(String)
    }

    /// A code lives five minutes, counted from when the Mac got it, on a clock that does not follow the
    /// Mac's wall clock. The coordinator's `expired` answer is the authority; this is the display.
    static let lifetime: Duration = .seconds(300)

    private(set) var phase = Phase.minting
    private(set) var code: String?
    private(set) var link: URL?
    private(set) var secondsLeft: Int?
    /// Bumped by "New code" so the view restarts `run()`.
    private(set) var generation = 0

    @ObservationIgnored private let model: WorkspaceModel
    /// How many times an expired code is replaced by a new one without a tap ("Add your iPhone" keeps a
    /// code on screen; the hub mints at most 10 an hour, so this stays small). Then it waits for New code.
    @ObservationIgnored var renewsExpiredCodes = 0
    /// Seams for tests: how long to wait between polls, and the monotonic clock.
    @ObservationIgnored var pollInterval: Duration = .seconds(1)
    @ObservationIgnored var sleep: @MainActor (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
    @ObservationIgnored var uptime: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }

    init(model: WorkspaceModel) {
      self.model = model
    }

    /// What the sheet says under its title.
    var message: String {
      switch phase {
      case .minting: return "Getting a code…"
      case .waiting: return "Scan this with the Agent Workspace app on your iPhone."
      case .paired(let name): return "Paired with \(name)"
      case .expired: return "This code has expired."
      case .notJoined: return "Join a hub first"
      case .failed(let text): return text
      }
    }

    func restart() { generation += 1 }

    /// Drop the code from memory.
    func clear() {
      code = nil
      link = nil
      secondsLeft = nil
    }

    /// Mint a code, then ask the coordinator about it about once a second until a phone pairs, the code
    /// expires, or the task is cancelled (the sheet closing). Nothing is polled after that. An expired
    /// code is replaced up to `renewsExpiredCodes` times.
    func run() async {
      var renewals = renewsExpiredCodes
      while true {
        await runOnce()
        guard phase == .expired, renewals > 0, !Task.isCancelled else { return }
        renewals -= 1
      }
    }

    private func runOnce() async {
      clear()
      phase = .minting
      let minted: HubPair.Result
      do {
        minted = try await model.pair()
      } catch {
        phase = Self.phase(for: error)
        return
      }
      guard !Task.isCancelled else { return }
      code = minted.code
      link = PairLink.make(url: minted.url, code: minted.code)
      let deadline = uptime().advanced(by: Self.lifetime)
      secondsLeft = Int(Self.lifetime.components.seconds)
      phase = .waiting

      while !Task.isCancelled {
        do { try await sleep(pollInterval) } catch { return }
        guard !Task.isCancelled else { return }
        let left = deadline - uptime()
        secondsLeft = max(0, Int(Self.seconds(left).rounded(.up)))
        if let status = await model.pairStatus() {
          guard !Task.isCancelled else { return }
          switch status.state {
          case .paired:
            clear()
            phase = .paired(status.deviceName ?? "your iPhone")
            return
          case .expired, .none:
            // `none` after a mint means the coordinator forgot the code (it restarted, or left the hub).
            clear()
            phase = .expired
            return
          case .waiting:
            break
          }
        }
        if left <= .zero {
          clear()
          phase = .expired
          return
        }
      }
    }

    private static func seconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func phase(for error: any Error) -> Phase {
      let failure = WorkspaceError.from(error)
      if failure.code == .protocolInvalid, failure.message == "Join a hub first" { return .notJoined }
      if failure.code == .rateLimited {
        let wait = failure.details?["retryAfterMs"]?.numberValue.map {
          max(1, Int(($0 / 60_000).rounded(.up)))
        }
        guard let wait else { return .failed("Too many codes for now. Try again later.") }
        return .failed("Too many codes for now. Try again in \(wait) \(wait == 1 ? "minute" : "minutes").")
      }
      return .failed(failure.message)
    }
  }

  // MARK: - The page

  /// Settings > Remote access: pair a phone, and keep the Mac awake while it is joined so the phone can
  /// reach it.
  struct RemoteAccessView: View {
    @Bindable var model: WorkspaceModel
    @State private var pairing = false
    @State private var confirmingRemove = false

    static let removeButton = "Remove this Mac from your account"
    static let removeTitle = "Remove this Mac from your account?"
    static let removeMessage =
      "This Mac stops syncing, your iPhone stops seeing its threads, and this Mac signs out. Threads, connections, and servers stay on this Mac. Signing in again adds it back as a new device."

    static let keepAwakeHelp =
      "While Agent Workspace is joined to a hub, your Mac stays awake so your phone can reach it. The display can still sleep. A Mac with its lid closed on battery power sleeps anyway."

    /// The relay link in a few words: connected since when, or reconnecting with its last error.
    static func linkLine(joined: Bool, link: HubLinkStatus?, now: Date = Date()) -> String {
      guard joined else { return "Not joined to a hub" }
      guard let link else { return "Joined to the hub" }
      switch link.state {
      case .connected:
        guard let since = link.since.flatMap(Timestamp.date(from:)) else { return "Connected to the hub" }
        return "Connected since \(HostNoticeMessage.lastSeen(since, now: now))"
      case .connecting:
        guard let error = link.lastError, !error.isEmpty else { return "Connecting to the hub…" }
        return "Reconnecting to the hub… last error: \(error)"
      case .offline:
        guard let error = link.lastError, !error.isEmpty else { return "Offline" }
        return "Offline: \(error)"
      }
    }

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: LLA.Space.xl) {
          LLASectionHead(
            "Pair an iPhone",
            intro: "Scan a code with the Agent Workspace app to work on this Mac's threads from your phone.")
          LLACard {
            VStack(alignment: .leading, spacing: LLA.Space.m) {
              HStack(spacing: LLA.Space.s) {
                LLABadge(badgeText, tone: badgeTone)
                Text(Self.linkLine(joined: model.hubJoined, link: model.hubLink))
                  .llaSmall()
                  .lineLimit(2)
                  .textSelection(.enabled)
                  .accessibilityIdentifier("relay-link-status")
              }
              HStack(spacing: LLA.Space.m) {
                Button("Add your iPhone…") { pairing = true }
                  .buttonStyle(.llaPrimary)
                  .disabled(!model.canPair)
                  .accessibilityIdentifier("pair-iphone")
                if model.link == .ready, !model.hubJoined {
                  Text("Join a hub first").llaSmallMuted()
                }
              }
            }
          }
          LLASectionHead("Staying reachable")
          LLACard {
            VStack(alignment: .leading, spacing: LLA.Space.s) {
              Toggle(
                "Keep the Mac awake",
                isOn: Binding(
                  get: { model.keepAwake },
                  set: { value in Task { await model.setKeepAwake(value) } })
              )
              .font(LLAFont.body)
              .foregroundStyle(LLA.Color.ink)
              .disabled(model.link != .ready || model.busy)
              .accessibilityIdentifier("keep-awake")
              Text(Self.keepAwakeHelp).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
            }
          }
          LLASectionHead("This Mac")
          LLACard {
            VStack(alignment: .leading, spacing: LLA.Space.s) {
              Text(
                "Log out from the profile menu to keep this Mac in your account. Removing it revokes it at the hub."
              )
              .llaSmallMuted()
              .fixedSize(horizontal: false, vertical: true)
              Button(Self.removeButton) { confirmingRemove = true }
                .buttonStyle(.llaDanger)
                .disabled(model.link != .ready || !model.hubJoined || model.busy)
                .accessibilityIdentifier("remove-this-mac")
            }
          }
          if let error = model.lastError, model.settingsVisible, model.settingsPage == .remoteAccess {
            Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
          }
        }
        .padding(LLA.Space.xl)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(LLA.Color.bg)
      .navigationTitle("Remote access")
      .sheet(isPresented: $pairing) { AddPhoneView(model: model) }
      .alert(Self.removeTitle, isPresented: $confirmingRemove) {
        Button("Remove", role: .destructive) { Task { await model.removeThisMac() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(Self.removeMessage)
      }
      .task(id: model.link) {
        guard model.link == .ready else { return }
        await model.refreshRemoteAccess()
        // The link comes and goes while the page is open; keep its line current.
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(5))
          if !Task.isCancelled { await model.refreshAccount() }
        }
      }
    }

    private var badgeText: String {
      guard model.hubJoined else { return "Off" }
      switch model.hubLink?.state {
      case .connected?: return "On"
      case .offline?: return "Offline"
      default: return "Starting"
      }
    }

    private var badgeTone: LLABadge.Tone {
      guard model.hubJoined else { return .muted }
      switch model.hubLink?.state {
      case .connected?: return .neutral
      case .offline?: return .danger
      default: return .muted
      }
    }
  }
#endif
