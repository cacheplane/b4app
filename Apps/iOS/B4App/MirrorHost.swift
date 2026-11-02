import Foundation
import Observation
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI

/// The phone's side of the hub (M8a, M8b, M8c): the SQLite mirror, the device token in the Keychain, the
/// loop that keeps the mirror and the hub in step (it pulls the Mac's changes and pushes the phone's own
/// edits), and the relay that carries the phone's chat commands to the Mac and its live events back.
/// The shared `WorkspaceModel` reads and writes the mirror through a `MirrorTransport`, exactly as the
/// Mac's talks to the coordinator through its socket; the UI never sees the store, the token, or the
/// network.
///
/// The relay's link is held only while the app is active (`RelayLifecycle`): background closes it, and
/// the next active opens it again with the same watched threads.
@MainActor @Observable final class MirrorHost {
  static let shared = MirrorHost()

  /// A fresh `MirrorTransport` over the shared store for each (re)connect of the model; the newest
  /// one receives the pull loop's batches. A transport is single use, so one is never handed out twice.
  static let transportProvider: WorkspaceModel.TransportProvider = {
    try await MirrorHost.shared.makeTransport()
  }

  /// True once this device has joined a hub (a link is stored in the mirror).
  private(set) var isLinked = false
  /// Why the mirror could not be opened, if it could not.
  private(set) var storeError: String?
  /// Set when the mirror file is a schema this build cannot read but holds edits not yet uploaded: the
  /// file is kept as it is, nothing syncs, and Diagnostics and the status line say so.
  @ObservationIgnored private var unreadableReason: String?
  /// The pull loop's last outcome; `lastError` is set while the mirror is not keeping up with the hub.
  private(set) var syncStatus = MirrorSyncStatus()
  /// Set when the hub refused the relay's link (`unauthorized`, `revoked`): the link stays closed until
  /// this phone logs out and pairs again, and the banner says so.
  private(set) var relayRefused: String?

  @ObservationIgnored private let store: MirrorStore?
  @ObservationIgnored private let secrets: any SecretStore = KeychainSecretStore(service: "b4app")
  @ObservationIgnored private var sync: MirrorSync?
  @ObservationIgnored private var transport: MirrorTransport?
  /// The phone's link to the hub for chat (M8c), made once enrolled; nil before, and after log-out.
  @ObservationIgnored private var relay: MirrorRelay?
  /// Whether the relay should be running, from the scene phase and enrollment.
  @ObservationIgnored private var lifecycle = RelayLifecycle(enrolled: false)
  /// The relay's start and stop calls, chained so they reach it in the order they were decided.
  @ObservationIgnored private var relayControl: Task<Void, Never>?
  /// Watches the relay for the stops it makes on its own.
  @ObservationIgnored private var relayWatch: Task<Void, Never>?
  /// The copy for a refused link.
  static let relayRefusedMessage = "The hub no longer accepts this iPhone. Log out, then pair it again."
  /// The shell's model, once `wire` has run: the phone, not a coordinator, supplies its account, its
  /// log-out, and whether the Mac is still joined.
  @ObservationIgnored private weak var model: WorkspaceModel?
  /// The hub user's display name from `/v1/me`, fetched once per sync start.
  @ObservationIgnored private var displayName: String?

  private static var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  private init() {
    var opened: MirrorStore?
    var fromSnapshot = false
    var unreadable: String?
    var failure: String?
    do {
      let path = try Self.directory().appendingPathComponent("mirror.sqlite").path
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
    if let unreadable {
      isLinked = true
      syncStatus = MirrorSyncStatus(lastError: unreadable)
    }
    if let link = try? opened?.link() {
      isLinked = true
      startSync(link, fromSnapshot: fromSnapshot)
    }
    lifecycle = RelayLifecycle(enrolled: isLinked, hasRelay: relay != nil)
  }

  /// `<Application Support>/b4app`, readable once the device has been unlocked after boot so the
  /// pull loop keeps working while the screen is locked.
  private static func directory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("b4app", isDirectory: true)
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

  /// Hand the shell's model the account and log-out, and keep its "Host disconnected" state current.
  func wire(_ model: WorkspaceModel) {
    self.model = model
    model.accountSource = .host
    model.hostLogOut = { await MirrorHost.shared.logOut() }
    refreshAccount()
    refreshHostState()
  }

  /// The stored link's username, with the display name once `/v1/me` has answered.
  private func refreshAccount() {
    guard let model else { return }
    guard let link = try? store?.link() else {
      model.account = nil
      return
    }
    model.account = WorkspaceAccount(username: link.username, displayName: displayName)
  }

  /// The mirror's devices table names no joined Mac. Empty (not fetched yet) is not disconnected.
  private func refreshHostState() {
    model?.hostDisconnected = (try? store?.devices())?.hostDisconnected ?? false
  }

  private func fetchDisplayName(_ api: HTTPHubAPI) async {
    guard let me = try? await api.me() else { return }
    displayName = me.user.displayName
    refreshAccount()
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

  /// The relay stopped itself. A refusal keeps it closed (and says so) until the phone pairs again.
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

  /// Log out from the profile menu: close the relay's link and clear the model's relay state, stop
  /// syncing, then `MirrorLogOut` revokes this device (best effort), forgets the token, and empties the
  /// mirror, unsent edits included. The Connect screen shows next.
  func logOut() async {
    control(lifecycle.setEnrolled(false, hasRelay: false))
    await relayControl?.value
    relayControl = nil
    relayWatch?.cancel()
    relayWatch = nil
    relay = nil
    relayRefused = nil
    await model?.disconnect()
    await sync?.stop()
    sync = nil
    syncStatus = MirrorSyncStatus()
    if let store {
      let link = try? store.link()
      let ref = link.flatMap { SecretRef(rawValue: $0.tokenRef) }
      let base = link.flatMap { try? HubURL.validate($0.hubURL) }
      let api = base.flatMap { base in ref.map { Self.api(base: base, ref: $0, secrets: secrets) } }
      await MirrorLogOut.run(store: store, api: api) { [secrets] in
        if let ref { _ = try? await secrets.remove(ref) }
      }
    }
    displayName = nil
    model?.account = nil
    model?.hostDisconnected = false
    isLinked = false
  }

  /// A local write was made: have the sync loop push it now.
  private func nudge() async {
    await sync?.nudge()
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

  /// Joins the hub: validates the URL before any request, enrolls with the one-time code (platform
  /// `ios`), keeps the device token only in the Keychain under a new reference, stores the link, and
  /// starts pulling. The code is not kept.
  func connect(url: String, code: String, deviceName: String) async throws {
    let base = try HubURL.validate(url)
    guard let store else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let api = HTTPHubAPI(baseURL: base, token: { nil })
    let enrolled = try await api.enroll(
      EnrollRequest(
        code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
        deviceName: name.isEmpty ? "iPhone" : name, platform: "ios"))
    let ref = SecretRef.make()
    let link = MirrorLink(
      hubURL: base.absoluteString, deviceId: enrolled.deviceId, deviceName: name.isEmpty ? "iPhone" : name,
      tokenRef: ref.rawValue, orgSlug: enrolled.org.slug, username: enrolled.user.username)
    do {
      try await secrets.put(ref, value: enrolled.token)
      try store.saveLink(link)
    } catch {
      // The code is spent; revoke the device it made so the hub holds no token nobody can use.
      _ = try? await secrets.remove(ref)
      let token = enrolled.token
      try? await HTTPHubAPI(baseURL: base, token: { token }).revokeSelf()
      throw error
    }
    startSync(link, fromSnapshot: false)
    isLinked = true
    control(lifecycle.setEnrolled(true, hasRelay: relay != nil))
    refreshAccount()
  }

  private func startSync(_ link: MirrorLink, fromSnapshot: Bool) {
    guard let store, let base = try? HubURL.validate(link.hubURL),
      let ref = SecretRef(rawValue: link.tokenRef)
    else { return }
    let api = Self.api(base: base, ref: ref, secrets: secrets)
    // The relay adds `/v1/devices/self/link` itself, and asks for the token on every attempt; the read
    // runs on a thread of its own (D-052), and the token is never kept or logged here.
    let relay = MirrorRelay(url: base, token: { [secrets] in try await secrets.read(ref) })
    self.relay = relay
    relayWatch?.cancel()
    relayWatch = Task {
      for await update in await relay.updates() {
        if case .link(.stopped(let reason)) = update {
          MirrorHost.shared.relayStopped(relay, reason: reason)
        }
      }
    }
    let sync = MirrorSync(
      store: store, api: api,
      onBatch: { batch in await MirrorHost.shared.publish(batch) },
      onStatus: { status in await MirrorHost.shared.update(status) }, startFromSnapshot: fromSnapshot)
    self.sync = sync
    syncStatus = MirrorSyncStatus()
    Task { await sync.run() }
    Task { await fetchDisplayName(api) }
  }

  /// The token is read from the Keychain for each request and never held here.
  private static func api(base: URL, ref: SecretRef, secrets: any SecretStore) -> HTTPHubAPI {
    HTTPHubAPI(baseURL: base, token: { try await secrets.read(ref) })
  }

  /// A failure in words for the Connect screen. `HubError` is not `LocalizedError`; its description
  /// carries the status, code, and the hub's message.
  static func describe(_ error: any Error) -> String {
    if let error = error as? HubError { return error.description }
    if let error = error as? WorkspaceError { return error.message }
    if let error = error as? KeychainError { return error.description }
    return error.localizedDescription
  }
}
