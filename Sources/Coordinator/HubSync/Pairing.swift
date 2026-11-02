import Foundation
import WorkspaceProtocol
import WorkspaceSync

/// Pairing a phone (M8c): mints a single-use code at the hub and watches for the phone to use it.
///
/// `mint` records the ids of the user's devices, asks the hub for a code, and starts a watcher that polls
/// `GET /v1/devices` every two seconds until a device that was not in the recorded set appears with
/// platform `ios` (the phone enrolled with the code) or the code's expiry passes. `status` says which.
/// One pairing is tracked at a time: a new `mint` ends the watch of the previous one.
///
/// The code is a short-lived credential shown on purpose (D-058). It exists only in the `HubPair.Result`
/// `mint` returns: the watcher is not given it, `Pairing` keeps only the expiry and the state, and no
/// log line or error message carries it.
actor Pairing {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  /// The code lives five minutes; used when the hub's `expiresAt` cannot be read.
  static let lifetime: TimeInterval = 300

  private let pollInterval: Duration
  private let sleep: Sleep
  private let now: @Sendable () -> Date
  private let logger = Log.logger("pairing")

  private var state = HubPairStatus.Result(state: .none)
  private var watcher: Task<Void, Never>?
  /// Identifies the current pairing, so a watcher that has been replaced cannot write the state.
  private var generation = UUID()

  init(
    pollInterval: Duration = .seconds(2), sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.pollInterval = pollInterval
    self.sleep = sleep
    self.now = now
  }

  func status() -> HubPairStatus.Result { state }

  /// Mints a code through `api` and starts watching. `fallbackURL` is the hub URL the Mac joined with,
  /// for a hub that has no public URL. Throws whatever the hub call throws, leaving the state as it was.
  func mint(api: any HubAPI, fallbackURL: URL) async throws -> HubPair.Result {
    // Recorded before the code exists, so no device enrolled with it can be among them.
    let known = Set(try await api.devices().map(\.id))
    let minted = try await api.mintPairingCode()
    let expiry =
      Timestamp.date(from: minted.expiresAt) ?? now().addingTimeInterval(Self.lifetime)

    watcher?.cancel()
    let generation = UUID()
    self.generation = generation
    state = HubPairStatus.Result(state: .waiting)
    watcher = Task { [weak self] in
      await self?.watch(api: api, known: known, expiry: expiry, generation: generation)
    }
    logger.info("a pairing code was minted; watching for the phone")
    return HubPair.Result(
      url: minted.hubURL ?? fallbackURL.absoluteString, code: minted.code, expiresAt: minted.expiresAt)
  }

  /// Ends any watch and forgets the pairing (`hub leave`, coordinator exit).
  func reset() async {
    generation = UUID()
    state = HubPairStatus.Result(state: .none)
    let watcher = self.watcher
    self.watcher = nil
    watcher?.cancel()
    await watcher?.value
  }

  private func watch(api: any HubAPI, known: Set<String>, expiry: Date, generation: UUID) async {
    while !Task.isCancelled {
      do {
        try await sleep(pollInterval)
      } catch {
        return
      }
      guard generation == self.generation else { return }
      // The devices come first: a phone that enrolled just before the expiry still counts.
      if let devices = try? await api.devices(), generation == self.generation,
        let phone = devices.first(where: {
          $0.platform == "ios" && $0.revokedAt == nil && !known.contains($0.id)
        })
      {
        state = HubPairStatus.Result(state: .paired, deviceName: phone.name)
        logger.info("a phone paired")
        return
      }
      guard generation == self.generation else { return }
      if now() >= expiry {
        state = HubPairStatus.Result(state: .expired)
        logger.info("the pairing code expired")
        return
      }
    }
  }
}
