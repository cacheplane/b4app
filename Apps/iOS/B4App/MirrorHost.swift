import Foundation
import Observation
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI

/// The phone's side of the hub (M8a): the SQLite mirror, the device token in the Keychain, and the
/// pull loop that keeps the mirror current. The shared `WorkspaceModel` reads the mirror through a
/// `MirrorTransport`, exactly as the Mac's reads the coordinator through its socket; the UI never
/// sees the store, the token, or the network.
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
    var link: MirrorLink?
    do {
      let store = try MirrorStore(path: try Self.directory().appendingPathComponent("mirror.sqlite").path)
      link = try store.link()
      self.store = store
    } catch {
      self.store = nil
      storeError = Self.describe(error)
    }
    if let link {
      isLinked = true
      startSync(link)
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
    guard let store else {
      throw WorkspaceError(.endpointUnavailable, storeError ?? "The mirror could not be opened.")
    }
    let transport = MirrorTransport(store: store, version: Self.version)
    self.transport = transport
    return transport
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
    startSync(link)
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

  private func startSync(_ link: MirrorLink) {
    guard let store, let base = try? HubURL.validate(link.hubURL),
      let ref = SecretRef(rawValue: link.tokenRef)
    else { return }
    let sync = MirrorSync(
      store: store, api: Self.api(base: base, ref: ref, secrets: secrets),
      onBatch: { batch in await MirrorHost.shared.publish(batch) },
      onStatus: { status in await MirrorHost.shared.update(status) })
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
