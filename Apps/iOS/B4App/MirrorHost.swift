import Foundation
import Observation
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI

/// The phone's side of the hub (M8a, M8b): the SQLite mirror, the device token in the Keychain, and the
/// loop that keeps the mirror and the hub in step (it pulls the Mac's changes and pushes the phone's own
/// edits). The shared `WorkspaceModel` reads and writes the mirror through a `MirrorTransport`, exactly
/// as the Mac's talks to the coordinator through its socket; the UI never sees the store, the token, or
/// the network.
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

  @ObservationIgnored private let store: MirrorStore?
  @ObservationIgnored private let secrets: any SecretStore = KeychainSecretStore(service: "b4app")
  @ObservationIgnored private var sync: MirrorSync?
  @ObservationIgnored private var transport: MirrorTransport?

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
        store: store, version: Self.version, onLocalWrite: { Task { await MirrorHost.shared.nudge() } })
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

  /// A local write was made: have the sync loop push it now.
  private func nudge() async {
    await sync?.nudge()
  }

  private func publish(_ batch: AppliedBatch) {
    transport?.publish(batch)
  }

  /// While pulls succeed only the time moves, so nothing is redrawn until a pull fails or recovers.
  private func update(_ status: MirrorSyncStatus) {
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
  }

  /// Leaves the hub: stops pulling, revokes this device (best effort), removes the token, and forgets
  /// the link. Not reachable from the UI in M8a; deleting the app is the way to disconnect.
  func disconnect() async {
    await sync?.stop()
    sync = nil
    syncStatus = MirrorSyncStatus()
    if let store, let link = try? store.link() {
      if let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef) {
        try? await Self.api(base: base, ref: ref, secrets: secrets).revokeSelf()
        _ = try? await secrets.remove(ref)
      }
      try? store.clearLink()
    }
    isLinked = false
  }

  private func startSync(_ link: MirrorLink, fromSnapshot: Bool) {
    guard let store, let base = try? HubURL.validate(link.hubURL),
      let ref = SecretRef(rawValue: link.tokenRef)
    else { return }
    let sync = MirrorSync(
      store: store, api: Self.api(base: base, ref: ref, secrets: secrets),
      onBatch: { batch in await MirrorHost.shared.publish(batch) },
      onStatus: { status in await MirrorHost.shared.update(status) }, startFromSnapshot: fromSnapshot)
    self.sync = sync
    syncStatus = MirrorSyncStatus()
    Task { await sync.run() }
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
