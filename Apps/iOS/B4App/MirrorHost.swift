import Foundation
import Observation
import UIKit
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI

/// The phone's account is the shared model's host (sign-in plan, Task 14): the model signs in,
/// onboards, logs out, and runs Settings → Account through it, exactly as the Mac's model does through
/// the coordinator. `MirrorAccount` already has every method `AccountHost` asks for.
extension MirrorAccount: @retroactive AccountHost {}

/// The phone's side of the hub (M8a, M8b, M8c, and the sign-in plan): the SQLite mirror, the phone's
/// account (`MirrorAccount`: the sign-in, the device token in the Keychain, and the sync that keeps the
/// mirror and the hub in step), and the relay that carries the phone's chat commands to the Mac and its
/// live events back. The shared `WorkspaceModel` reads and writes the mirror through a
/// `MirrorTransport`, exactly as the Mac's talks to the coordinator through its socket; the UI never
/// sees the store, the token, or the network.
///
/// The mirror's folder and the Keychain service are the flavour's (`PhoneFlavor`): prod keeps `b4app`,
/// so nothing moves; beta and local use `b4app-beta` and `b4app-local`, so a TestFlight build and an App
/// Store build on one phone never share a mirror or a token meant for another hub.
///
/// The relay's link is held only while the app is active (`RelayLifecycle`): background closes it, and
/// the next active opens it again with the same watched threads.
@MainActor @Observable final class MirrorHost {
  static let shared = MirrorHost()
  static let flavor = PhoneFlavor.current

  /// A fresh `MirrorTransport` over the shared store for each (re)connect of the model; the newest
  /// one receives the pull loop's batches. A transport is single use, so one is never handed out twice.
  static let transportProvider: WorkspaceModel.TransportProvider = {
    try await MirrorHost.shared.makeTransport()
  }

  /// Why the mirror could not be opened, if it could not.
  private(set) var storeError: String?
  /// Set when the mirror file is a schema this build cannot read but holds edits not yet uploaded: the
  /// file is kept as it is, nothing syncs, and Diagnostics and the status line say so.
  @ObservationIgnored private var unreadableReason: String?
  /// The pull loop's last outcome; `lastError` is set while the mirror is not keeping up with the hub.
  private(set) var syncStatus = MirrorSyncStatus()
  /// Set when the hub refused the relay's link (`unauthorized`, `revoked`): the link stays closed until
  /// this phone signs in again, and the banner says so.
  private(set) var relayRefused: String?

  @ObservationIgnored private let store: MirrorStore?
  @ObservationIgnored private let secrets: any SecretStore = KeychainSecretStore(
    service: MirrorHost.flavor.keychainService)
  /// The phone's account over the mirror; nil when the mirror could not be opened or read.
  @ObservationIgnored let account: MirrorAccount?
  @ObservationIgnored private var transport: MirrorTransport?
  /// The phone's link to the hub for chat (M8c), made while signed in; nil before, and after log-out.
  @ObservationIgnored private var relay: MirrorRelay?
  /// The token reference of the link the relay was made for.
  @ObservationIgnored private var relayTokenRef: String?
  /// Whether the relay should be running, from the scene phase and the sign-in.
  @ObservationIgnored private var lifecycle = RelayLifecycle(enrolled: false)
  /// The relay's start and stop calls, chained so they reach it in the order they were decided.
  @ObservationIgnored private var relayControl: Task<Void, Never>?
  /// Watches the relay for the stops it makes on its own.
  @ObservationIgnored private var relayWatch: Task<Void, Never>?
  /// The copy for a refused link.
  static let relayRefusedMessage = "The hub no longer accepts this iPhone. Log out, then sign in again."
  /// The shell's model, once made.
  @ObservationIgnored private weak var model: WorkspaceModel?

  private static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  /// Who the phone is signed in as (the account's own state, as the root and Settings read it).
  var accountStatus: AccountStatus.Result? { account?.accountStatus }

  private init() {
    var opened: MirrorStore?
    var fromSnapshot = false
    var unreadable: String?
    var failure: String?
    var directory: URL?
    do {
      let folder = try Self.directory()
      directory = folder
      let path = folder.appendingPathComponent("mirror.sqlite").path
      do {
        opened = try MirrorStore(path: path)
      } catch MirrorStoreError.needsRebuild(outboxEmpty: true) {
        // Nothing unsent is lost. The rebuilt file keeps the link and the sequence counter, and its
        // rows come from the hub's snapshot rather than a pull of the whole feed.
        opened = try MirrorStore.rebuild(path: path)
        fromSnapshot = true
      } catch let error as MirrorStoreError {
        // Unsent edits are in a file this build cannot read: keep it and do not sync. It can only
        // have been linked, so the shell shows over an empty mirror, with the reason in Diagnostics.
        unreadable = error.description
      }
    } catch {
      failure = Self.describe(error)
    }
    store = opened
    unreadableReason = unreadable
    storeError = unreadable ?? failure
    if let unreadable { syncStatus = MirrorSyncStatus(lastError: unreadable) }
    if let opened {
      account = MirrorAccount(
        store: opened, secrets: secrets,
        configuration: MirrorAccount.Configuration(
          hubURL: Self.flavor.hubURL, deviceName: UIDevice.current.name),
        memory: MirrorDeviceMemory(url: directory?.appendingPathComponent("device.json")),
        onBatch: { batch in await MirrorHost.shared.publish(batch) },
        onSyncStatus: { status in await MirrorHost.shared.update(status) })
    } else {
      account = nil
    }
    account?.onChange = { status in MirrorHost.shared.accountChanged(status) }
    if let account, let link = account.link {
      makeRelay(link)
      account.startSync(fromSnapshot: fromSnapshot)
    }
    lifecycle = RelayLifecycle(enrolled: relay != nil, hasRelay: relay != nil)
  }

  /// The shared shell's model, with the phone's account as its host and the flavour's sign-in screen.
  func makeModel() -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: Self.transportProvider, accountSource: .host)
    model.signInConfiguration = SignInConfiguration(
      siteDomain: Self.flavor.siteDomain, appleSignIn: Self.flavor.appleSignIn, badge: Self.flavor.badge)
    model.accountHost = account
    self.model = model
    refreshHostState()
    return model
  }

  /// `<Application Support>/<flavour's folder>`, readable once the device has been unlocked after boot
  /// so the pull loop keeps working while the screen is locked.
  private static func directory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent(flavor.directoryName, isDirectory: true)
    let protection: [FileAttributeKey: Any] = [
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: protection)
    try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
    return directory
  }

  private func makeTransport() throws -> any WorkspaceTransport {
    let transport: MirrorTransport
    if let store {
      transport = MirrorTransport(
        store: store, version: Self.version, onLocalWrite: { Task { await MirrorHost.shared.nudge() } },
        relay: relay)
    } else if let unreadableReason {
      // An empty stand-in that answers reads, refuses writes, and puts the reason in Diagnostics.
      transport = MirrorTransport(
        store: try MirrorStore.inMemory(), version: Self.version, unavailable: unreadableReason)
    } else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    self.transport = transport
    return transport
  }

  // MARK: - The account

  /// The account changed (a sign-in, onboarding, a log-out, or the hub refusing the token). The relay
  /// follows the link first, so the model's next transport carries the new one; then the model.
  private func accountChanged(_ status: AccountStatus.Result) {
    let link = status.state == .signedOut ? nil : account?.link
    if link?.tokenRef != relayTokenRef {
      if let old = relay { retire(old) }
      // Down first, so a new relay is started even when the old one was running.
      _ = lifecycle.setEnrolled(false, hasRelay: false)
      if let link {
        makeRelay(link)
        control(lifecycle.setEnrolled(true, hasRelay: relay != nil))
      }
    }
    if status.state == .signedOut { syncStatus = MirrorSyncStatus() }
    refreshHostState()
    model?.applyHostAccount(status)
  }

  /// Join a hub with a one-time enrollment code (an operator's hub, or a pairing link): validates the
  /// URL before any request, enrolls as an `ios` device, and signs in. The code is not kept.
  func connect(url: String, code: String, deviceName: String) async throws {
    guard let account else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    _ = try await account.enroll(url: url, code: code, deviceName: deviceName)
  }

  /// The mirror's devices table names no joined Mac. Empty (not fetched yet) is not disconnected.
  private func refreshHostState() {
    model?.hostDisconnected = (try? store?.devices())?.hostDisconnected ?? false
  }

  // MARK: - The relay's link (M8c)

  /// The scene's phase changed: active holds the link, background closes it, inactive changes nothing.
  func enter(_ phase: RelayLifecycle.Phase) {
    control(lifecycle.enter(phase))
  }

  /// What a `b4app://` link opened on this phone may do. Deciding sends nothing.
  func pairLink(_ url: URL) -> RelayLifecycle.PairLinkDecision {
    lifecycle.pairLink(url)
  }

  /// A relay for `link`'s hub, asking the Keychain for the token on every attempt; the read runs on a
  /// thread of its own (D-052), and the token is never kept or logged here.
  private func makeRelay(_ link: MirrorLink) {
    guard let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef) else {
      return
    }
    let relay = MirrorRelay(url: base, token: { [secrets] in try await secrets.read(ref) })
    self.relay = relay
    relayTokenRef = link.tokenRef
    relayRefused = nil
    relayWatch?.cancel()
    relayWatch = Task {
      for await update in relay.updates() {
        if case .link(.stopped(let reason)) = update {
          MirrorHost.shared.relayStopped(relay, reason: reason)
        }
      }
    }
  }

  /// Stop a relay whose link has ended, after whatever was decided for it before.
  private func retire(_ old: MirrorRelay) {
    relayWatch?.cancel()
    relayWatch = nil
    relay = nil
    relayTokenRef = nil
    relayRefused = nil
    let previous = relayControl
    relayControl = Task {
      await previous?.value
      await old.stop()
    }
  }

  /// The relay stopped itself. A refusal keeps it closed (and says so) until the phone signs in again.
  private func relayStopped(_ stopped: MirrorRelay, reason: String) {
    guard stopped === relay else { return }
    control(lifecycle.linkStopped(reason: reason))
    if lifecycle.refused { relayRefused = Self.relayRefusedMessage }
  }

  private func control(_ action: RelayLifecycle.Action?) {
    // The lifecycle decides only while a relay exists (`hasRelay`), so this guard never drops a decision.
    guard let action, let relay else { return }
    let previous = relayControl
    relayControl = Task {
      await previous?.value
      switch action {
      case .start: await relay.start()
      case .stop: await relay.stop()
      }
    }
  }

  // MARK: - The sync's reports

  /// A local write was made: have the sync loop push it now.
  private func nudge() async {
    await account?.sync?.nudge()
  }

  private func publish(_ batch: AppliedBatch) {
    transport?.publish(batch)
    refreshHostState()
  }

  /// While pulls succeed only the time moves, so nothing is redrawn until a pull fails or recovers.
  private func update(_ status: MirrorSyncStatus) {
    // Each cycle may have refreshed the devices list, whether or not the status changed.
    refreshHostState()
    guard status.lastError != nil || syncStatus.lastError != nil, status != syncStatus else { return }
    syncStatus = status
  }

  /// A failure in words for the enrollment sheet. `HubError` is not `LocalizedError`; its description
  /// carries the status, code, and the hub's message.
  static func describe(_ error: any Error) -> String {
    if let error = error as? HubError { return error.description }
    if let error = error as? WorkspaceError { return error.message }
    if let error = error as? KeychainError { return error.description }
    return error.localizedDescription
  }
}
