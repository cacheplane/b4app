import Foundation
import WorkspaceProtocol
import WorkspaceSync

/// Pairing a phone (M8c): mints a single-use code at the hub and watches for the phone to use it.
///
/// `mint` records the ids of the user's devices, asks the hub for a code, and starts a watcher that polls
/// `GET /v1/devices` every two seconds until a device that was not in the recorded set appears with
/// platform `ios` (the phone enrolled with the code) or the code's five minutes (counted from the mint on
/// a monotonic clock) have passed. `status` says which.
/// One pairing is tracked at a time: a new `mint` ends the watch of the previous one.
///
/// The code is a short-lived credential shown on purpose (D-058). It exists only in the `HubPair.Result`
/// `mint` returns: the watcher is not given it, `Pairing` keeps only the expiry and the state, and no
/// log line or error message carries it.
actor Pairing {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  /// The code lives five minutes at the hub. The watch measures that from the moment the mint returned,
  /// on a monotonic clock, never against the Mac's wall clock (which may be minutes off the hub's).
  static let lifetime: Duration = .seconds(300)

  private let pollInterval: Duration
  private let sleep: Sleep
  private let uptime: @Sendable () -> Duration
  private let logger = Log.logger("pairing")

  private var state = HubPairStatus.Result(state: .none)
  private var watcher: Task<Void, Never>?
  /// Identifies the current pairing, so a watcher that has been replaced cannot write the state.
  private var generation = UUID()
  /// Counts `reset`s, so a `mint` that was in flight across one can tell.
  private var resets = 0

  /// `uptime` is a monotonic reading since any fixed origin (default: `ContinuousClock`, which keeps
  /// counting while the Mac sleeps, as the code's lifetime does).
  init(
    pollInterval: Duration = .seconds(2), sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
    uptime: @escaping @Sendable () -> Duration = Pairing.continuousUptime
  ) {
    self.pollInterval = pollInterval
    self.sleep = sleep
    self.uptime = uptime
  }

  private static let origin = ContinuousClock.now
  static let continuousUptime: @Sendable () -> Duration = { origin.duration(to: .now) }

  func status() -> HubPairStatus.Result { state }

  /// Mints a code through `api` and starts watching. `fallbackURL` is the hub URL the Mac joined with,
  /// for a hub that has no public URL. Throws whatever the hub call throws, leaving the state as it was.
  /// A `reset` (leave, stop) while the hub calls are out ends the mint with "Join a hub first": the code
  /// is dropped unused, the state stays `none`, and no watcher starts on the old api.
  func mint(api: any HubAPI, fallbackURL: URL) async throws -> HubPair.Result {
    let resetsAtStart = resets
    // Recorded before the code exists, so no device enrolled with it can be among them.
    let known = Set(try await api.devices().map(\.id))
    let minted = try await api.mintPairingCode()
    guard resets == resetsAtStart else { throw WorkspaceError(.protocolInvalid, "Join a hub first") }
    let expiry = uptime() + Self.lifetime

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
    resets += 1
    generation = UUID()
    state = HubPairStatus.Result(state: .none)
    let watcher = self.watcher
    self.watcher = nil
    watcher?.cancel()
    await watcher?.value
  }

  private func watch(api: any HubAPI, known: Set<String>, expiry: Duration, generation: UUID) async {
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
      if uptime() >= expiry {
        state = HubPairStatus.Result(state: .expired)
        logger.info("the pairing code expired")
        return
      }
    }
  }
}
