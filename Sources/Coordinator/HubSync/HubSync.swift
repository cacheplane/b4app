import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// Pushes this Mac's change log to the hub it joined (M8a), and runs `HubPull`, which merges other
/// devices' edits back (M8b). The only owner of the `hubLink` row (the pull moves only its `cursor`) and
/// of the device token in the secret store.
///
/// Pushes run one at a time: after local writes (every published event is a nudge, coalesced over
/// 250 ms), every 30 s, on wake, and once at join. Each push sends the unsynced log in batches of at
/// most 500 rows or 8 MiB of body through `SyncFilter`, and marks rows synced only once the hub's
/// `acceptedThrough` covers them. A failure is recorded as `lastError` and never escapes a background
/// push; a 401 also stops the write- and timer-driven pushes until the next `join`. A change the hub
/// refuses (`rejected`) is covered by `acceptedThrough`, so it is marked synced like the rest and counted
/// in `lastError` ("2 changes refused by the hub: column_not_writable"); it never stalls the queue.
///
/// The pull starts with `start()` (when joined) or with a `join` after it, and stops with `leave()`,
/// `stop()`, or its own 401 (which also suspends background pushes until the next `join`).
///
/// The enrollment code, the token, and the token's `SecretRef` never appear in a log line, a result,
/// or an error message.
public actor HubSync {
  public typealias APIFactory = @Sendable (URL, @escaping @Sendable () async throws -> String?) -> any HubAPI

  static let batchRows = 500
  static let batchBytes = 8 * 1024 * 1024

  private let database: WorkspaceDatabase
  private let secretStore: any SecretStore
  private let eventLog: EventLog
  private let makeAPI: APIFactory
  private let logger = Log.logger("hub")

  private var api: (any HubAPI)?
  /// The link's token, kept in memory once read (`HubToken`); nil when not joined.
  private var token: HubToken?
  /// Set by a 401; cleared by `join`. Background pushes skip while it is set.
  private var suspended = false
  private var joining = false
  private var inFlight: Task<Int, any Error>?
  private var nudgeTask: Task<Void, Never>?
  private var timerTask: Task<Void, Never>?
  private var pendingNudge: Task<Void, Never>?
  private var started = false
  private var pull: HubPull?
  /// Identifies the running pull, so a callback from one that has since been replaced is ignored.
  private var pullGeneration = UUID()
  /// The hub user's display name: from the enrollment, or `/v1/me` once a start finds a link. Kept in
  /// memory only, so the link table needs no migration.
  private var displayName: String?
  private var fetchingName = false

  public init(
    database: WorkspaceDatabase, secretStore: any SecretStore, eventLog: EventLog,
    makeAPI: @escaping APIFactory = { HTTPHubAPI(baseURL: $0, token: $1) }
  ) {
    self.database = database
    self.secretStore = secretStore
    self.eventLog = eventLog
    self.makeAPI = makeAPI
  }

  // MARK: - Lifecycle

  /// Load the link (if this Mac has joined), tag local writes with its device id, and start the
  /// write nudge and the 30 s timer.
  public func start() async {
    do {
      if let link = try database.hubLink() {
        if let url = URL(string: link.url), let ref = SecretRef(rawValue: link.tokenRef) {
          database.deviceId = link.deviceId
          let token = HubToken(store: secretStore, ref: ref)
          self.token = token
          api = makeAPI(url, { try await token.value() })
        } else {
          logger.error("the stored hub link is unreadable; not pushing")
        }
      }
    } catch {
      logger.error("could not load the hub link: \(String(describing: error), privacy: .public)")
    }
    guard nudgeTask == nil else { return }
    started = true
    if let link = try? database.hubLink(), let api {
      startPull(deviceId: link.deviceId)
      fetchDisplayNameIfMissing()
    }
    let events = await eventLog.subscribe()
    nudgeTask = Task { [weak self] in
      for await _ in events {
        guard let self else { return }
        await self.nudge()
      }
    }
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self, !Task.isCancelled else { return }
        await self.backgroundPush(reason: "timer")
      }
    }
  }

  /// Stop the nudge, the timer, and the pull, waiting for the pull to end.
  public func stop() async {
    started = false
    nudgeTask?.cancel()
    timerTask?.cancel()
    pendingNudge?.cancel()
    nudgeTask = nil
    timerTask = nil
    pendingNudge = nil
    await stopPull()
  }

  // MARK: - Commands

  public func join(url: String, code: String, deviceName: String) async throws -> HubStatus.Result {
    let base = try HubURL.validate(url)
    let linked = try database.hubLink() != nil
    if joining || linked {
      throw WorkspaceError(
        .protocolInvalid, "This Mac has already joined a hub; run `agent-workspace hub leave` first.")
    }
    // The actor is reentrant across the enroll call; a second join must not enroll a second device.
    joining = true
    defer { joining = false }
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw WorkspaceError(.protocolInvalid, "The device name is empty.") }
    let ref = SecretRef.make()
    let token = HubToken(store: secretStore, ref: ref)
    let api = makeAPI(base, { try await token.value() })
    let enrolled: EnrollResponse
    do {
      enrolled = try await api.enroll(EnrollRequest(code: code, deviceName: name, platform: "macos"))
    } catch let error as HubError {
      throw Self.workspaceError(error, doing: "join the hub")
    }
    try await secretStore.put(ref, value: enrolled.token)
    do {
      try database.saveHubLink(
        WorkspaceDatabase.HubLink(
          url: base.absoluteString, deviceId: enrolled.deviceId, deviceName: name, tokenRef: ref.rawValue,
          orgSlug: enrolled.org.slug, username: enrolled.user.username, joinedAt: Timestamp.now()))
      try database.saveDevice(id: enrolled.deviceId, name: name)
    } catch {
      _ = try? await secretStore.remove(ref)
      throw error
    }
    database.deviceId = enrolled.deviceId
    // The token was just stored, so it is known without asking the Keychain.
    token.remember(enrolled.token)
    self.token = token
    self.api = api
    displayName = enrolled.user.displayName
    suspended = false
    logger.info(
      "joined \(base.host ?? "hub", privacy: .public) as device \(enrolled.deviceId, privacy: .public)")
    do {
      _ = try await pushNow()
    } catch {
      // Recorded as lastError; the join itself succeeded.
    }
    startPull(deviceId: enrolled.deviceId)
    return try status()
  }

  public func status() throws -> HubStatus.Result {
    let unsynced = try database.unsyncedChangeCount()
    guard let link = try database.hubLink() else {
      return HubStatus.Result(joined: false, unsyncedChanges: unsynced)
    }
    var lastError = link.lastError
    if let since = token?.waitingSince {
      lastError =
        "Waiting since \(since) for Keychain access to the hub token; answer the Keychain prompt on this Mac."
    }
    return HubStatus.Result(
      joined: true, url: link.url, deviceId: link.deviceId, deviceName: link.deviceName,
      orgSlug: link.orgSlug, username: link.username, displayName: displayName, unsyncedChanges: unsynced,
      lastPushAt: link.lastPushAt, lastError: lastError)
  }

  /// Ask `/v1/me` while the name is unknown: at start, and again after each successful push or pull,
  /// so a start before the network was up still gets the name.
  private func fetchDisplayNameIfMissing() {
    guard displayName == nil, !fetchingName, let api else { return }
    fetchingName = true
    Task { await fetchDisplayName(api) }
  }

  private func fetchDisplayName(_ api: any HubAPI) async {
    defer { fetchingName = false }
    do {
      let me = try await api.me()
      // A leave or a new join while the request was out owns the name now.
      guard self.api != nil, displayName == nil else { return }
      displayName = me.user.displayName
    } catch {
      logger.debug("could not read the hub user's name: \(Self.describe(error), privacy: .public)")
    }
  }

  /// Revoke this device at the hub (best effort), forget the token, clear the link, and record later
  /// writes as `local` again.
  public func leave() async throws {
    guard let link = try database.hubLink() else { return }
    await stopPull()
    let api = self.api
    self.api = nil
    displayName = nil
    token = nil
    suspended = false
    await waitForPush()
    if let api {
      do {
        try await api.revokeSelf()
      } catch {
        logger.warning("could not revoke this device at the hub: \(Self.describe(error), privacy: .public)")
      }
    }
    if let ref = SecretRef(rawValue: link.tokenRef) { _ = try await secretStore.remove(ref) }
    try database.clearHubLink()
    database.deviceId = "local"
    logger.info("left the hub")
  }

  /// Push every unsynced change now. Returns the number of rows the hub accepted (0 when this Mac has
  /// not joined). Throws the push failure after recording it as `lastError`.
  @discardableResult
  public func pushNow() async throws -> Int {
    await waitForPush()
    let task = Task { try await self.drain() }
    inFlight = task
    defer { if inFlight == task { inFlight = nil } }
    return try await task.value
  }

  /// Wait until no push is running (one that starts while waiting is waited for too).
  private func waitForPush() async {
    while let running = inFlight {
      _ = try? await running.value
      if inFlight == running { inFlight = nil }
    }
  }

  // MARK: - Pushing

  private func nudge() {
    guard pendingNudge == nil, api != nil, !suspended else { return }
    pendingNudge = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard let self, !Task.isCancelled else { return }
      await self.firePendingNudge()
    }
  }

  private func firePendingNudge() async {
    pendingNudge = nil
    await backgroundPush(reason: "write")
  }

  /// A push nobody waits for: the wake handler, the timer, and the write nudge.
  func backgroundPush(reason: String) async {
    guard api != nil, !suspended else { return }
    do {
      _ = try await pushNow()
    } catch {
      logger.warning("\(reason, privacy: .public) push failed: \(Self.describe(error), privacy: .public)")
    }
  }

  private func drain() async throws -> Int {
    guard let api else { return 0 }
    var accepted = 0
    var pushed = false
    var refused: [RejectedChange] = []
    do {
      while true {
        let records = try database.unsyncedChanges(limit: Self.batchRows)
        guard !records.isEmpty else { break }
        let (batch, through) = Self.batch(records)
        guard let last = batch.last else {
          // Nothing in this window may leave the Mac.
          try database.markSynced(through: through)
          continue
        }
        let response = try await api.push(batch)
        pushed = true
        // `through` also covers filtered rows after the last one sent; they never travel.
        let covered = response.acceptedThrough >= last.deviceSeq ? through : response.acceptedThrough
        guard covered >= records[0].seq else {
          throw HubError(
            kind: "execution_error", code: "not_accepted",
            message: "The hub accepted through \(response.acceptedThrough), before this batch.",
            status: 200)
        }
        // A refused change is final and covered by `acceptedThrough`: it leaves the queue with the rest.
        try database.markSynced(through: covered)
        accepted += batch.filter { $0.deviceSeq <= covered }.count
        refused += response.rejected
      }
      if pushed {
        let message = Self.refusalMessage(refused)
        if let message { logger.warning("\(message, privacy: .public)") }
        try record(error: message, pushed: true)
      }
      return accepted
    } catch {
      if (error as? HubError)?.code == "unauthorized" { suspended = true }
      try? record(error: Self.describe(error), pushed: false)
      throw error
    }
  }

  /// The longest prefix of `records` that fits one push (at most `batchRows` changes and
  /// `batchBytes` of body, but always at least one change), and the last `seq` it covers, filtered
  /// rows included.
  static func batch(_ records: [ChangeRecord]) -> (changes: [SyncChange], through: Int) {
    var changes: [SyncChange] = []
    var bytes = 16  // {"changes":[]}
    var through = records.first.map { $0.seq - 1 } ?? 0
    for record in records {
      guard let change = SyncFilter.outbound(record) else {
        through = record.seq
        continue
      }
      let size = ((try? JSONCoding.encoder.encode(change).count) ?? 0) + 1
      if !changes.isEmpty, changes.count >= batchRows || bytes + size > batchBytes { break }
      changes.append(change)
      bytes += size
      through = record.seq
    }
    return (changes, through)
  }

  /// "2 changes refused by the hub: column_not_writable", or nil when nothing was refused.
  static func refusalMessage(_ rejected: [RejectedChange]) -> String? {
    guard !rejected.isEmpty else { return nil }
    let codes = Set(rejected.map(\.code)).sorted().joined(separator: ", ")
    let noun = rejected.count == 1 ? "change" : "changes"
    return "\(rejected.count) \(noun) refused by the hub: \(codes)"
  }

  // MARK: - Pulling

  /// Start the pull loop for this device, when `start()` has run and none is running.
  private func startPull(deviceId: String) {
    guard started, pull == nil, let api else { return }
    let generation = UUID()
    let pull = HubPull(
      database: database, api: api, eventLog: eventLog, ownDeviceId: deviceId,
      onError: { [weak self] message in await self?.recordPull(error: message, generation: generation) },
      onUnauthorized: { [weak self] message in await self?.pullUnauthorized(message, generation: generation) }
    )
    self.pull = pull
    pullGeneration = generation
    Task { await pull.launch() }
  }

  private func stopPull() async {
    guard let pull else { return }
    self.pull = nil
    await pull.stop()
  }

  private static let pullErrorPrefix = "Pull: "

  /// A pull failure is shown as `lastError` until a pull succeeds again (or a push records its own).
  private func recordPull(error: String?, generation: UUID) {
    guard generation == pullGeneration, pull != nil, var link = try? database.hubLink() else { return }
    if error == nil { fetchDisplayNameIfMissing() }
    if let error {
      link.lastError = Self.pullErrorPrefix + error
    } else if link.lastError?.hasPrefix(Self.pullErrorPrefix) == true {
      link.lastError = nil
    } else {
      return
    }
    try? database.saveHubLink(link)
  }

  /// The pull loop has ended on a 401; it must not be awaited here (it is waiting for this call).
  private func pullUnauthorized(_ message: String, generation: UUID) {
    guard generation == pullGeneration, pull != nil else { return }
    recordPull(error: message, generation: generation)
    pull = nil
    suspended = true
  }

  private func record(error: String?, pushed: Bool) throws {
    guard var link = try database.hubLink() else { return }
    if error == nil, pushed { fetchDisplayNameIfMissing() }
    if pushed { link.lastPushAt = Timestamp.now() }
    link.lastError = error
    try database.saveHubLink(link)
  }

  // MARK: - Helpers

  /// The Mac's name as System Settings shows it, for a join without `--name`.
  public static func defaultDeviceName() -> String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  private static func describe(_ error: any Error) -> String {
    if let hub = error as? HubError { return hub.description }
    return WorkspaceError.from(error).message
  }

  private static func workspaceError(_ error: HubError, doing action: String) -> WorkspaceError {
    let code: ErrorCode =
      switch error.status {
      case 401, 403: .authRequired
      case 0, 500...: .endpointUnavailable
      default: .protocolInvalid
      }
    return WorkspaceError(
      code, "Could not \(action): \(error.description)", details: ["hubCode": .string(error.code)])
  }
}
