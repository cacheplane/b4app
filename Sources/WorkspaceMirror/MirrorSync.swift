import Foundation
import WorkspaceProtocol
import WorkspaceSync
import os

/// Keeps a `MirrorStore` and the hub in step. Each turn of the loop pushes the phone's queued edits
/// (`MirrorStore.nextUpload`, at most 500 rows and 8 MiB a request), then long-polls the change feed after the cursor,
/// applies the page, advances the cursor to the page's `next`, and reports the batch.
///
/// - A push removes the outbox through `acceptedThrough` only; the hub's `rejected` changes are covered
///   by it, so they go too and are counted (`MirrorStore.refusedUploads`) for Diagnostics.
/// - Once per `run()`, before any push, an empty push asks the hub for the highest `deviceSeq` it has
///   recorded for this device; the store's counter is raised to it if lower, so a counter lost to a
///   restored backup never reissues a number.
/// - `nudge()` (a local write was made) wakes the loop: it cancels a long-poll in flight and goes round
///   again, so the edit is pushed at once. A nudge while a push is in flight is not lost; the loop
///   pushes again before it waits.
/// - `resync_required` (the cursor fell behind the hub's retention) fetches the hub's snapshot and
///   replaces the mirror with it, keeping unsent edits. A mirror that was just rebuilt starts the same
///   way (`startFromSnapshot`) rather than pulling the whole feed from 0.
/// - The device list is refreshed at most once a minute.
/// - Any other failure is recorded on the link as `lastError` and retried after a backoff that starts at
///   two seconds and doubles to a minute. The device token stays inside `api`. Each outcome is also
///   handed to `onStatus` (when given), so the app can say that what it shows is stale.
public actor MirrorSync {
  private let store: MirrorStore
  private let api: any HubAPI
  private let onBatch: @Sendable (AppliedBatch) async -> Void
  private let onStatus: (@Sendable (MirrorSyncStatus) async -> Void)?
  private let initialBackoff: Duration
  private let maxBackoff: Duration
  private var loop: Task<Void, Never>?
  private var pulling: Task<PullResponse, any Error>?
  private var stopped = false
  private var nudged = false
  private var needsSnapshot: Bool
  private var sequenceChecked = false
  private var resyncsInARow = 0
  private var devicesFetchedAt: ContinuousClock.Instant?
  /// The last failure, nil after a successful pull.
  public private(set) var lastError: String?
  /// When a pull last succeeded (`Timestamp`), starting from the stored link's value.
  public private(set) var lastSyncAt: String?

  private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "mirror")
  static let pageLimit = 1000
  static let pushLimit = 500
  /// The most encoded change JSON one push carries (the Mac's `HubSync.batchBytes`), well under the
  /// hub's 32 MiB body limit, whose 413 would otherwise refuse the same backlog on every retry.
  static let pushBytes = 8 * 1024 * 1024
  static let waitSeconds = 25
  static let devicesInterval: Duration = .seconds(60)

  public init(
    store: MirrorStore, api: any HubAPI, onBatch: @escaping @Sendable (AppliedBatch) async -> Void,
    onStatus: (@Sendable (MirrorSyncStatus) async -> Void)? = nil,
    initialBackoff: Duration = .seconds(2), maxBackoff: Duration = .seconds(60),
    startFromSnapshot: Bool = false
  ) {
    self.store = store
    self.api = api
    self.onBatch = onBatch
    self.onStatus = onStatus
    self.lastSyncAt = try? store.link()?.lastSyncAt
    self.initialBackoff = initialBackoff
    self.maxBackoff = maxBackoff
    self.needsSnapshot = startFromSnapshot
  }

  /// Syncs until `stop()`. A second call while running, or a call after `stop()`, returns at once.
  public func run() async {
    guard loop == nil, !stopped else { return }
    let task = Task { await self.syncLoop() }
    loop = task
    await task.value
  }

  /// Ends the loop, cancelling a long-poll in flight.
  public func stop() {
    stopped = true
    loop?.cancel()
    pulling?.cancel()
  }

  /// A local write was made: push it now rather than after the long-poll ends.
  public func nudge() {
    nudged = true
    pulling?.cancel()
  }

  private func syncLoop() async {
    var backoff = initialBackoff
    while !stopped, !Task.isCancelled {
      // Cleared before the outbox is read, so a write made after the read sets it again.
      nudged = false
      do {
        try await checkSequence()
        try await pushOutbox()
        if needsSnapshot { try await fetchSnapshot() }
        await refreshDevices()
        let page = try await pull()
        let batch = try store.apply(page.changes)
        try store.setCursor(page.next)
        await record(error: nil)
        backoff = initialBackoff
        resyncsInARow = 0
        if batch.undecodableRows > 0 {
          Self.logger.warning(
            "mirror batch through \(page.next, privacy: .public) holds \(batch.undecodableRows, privacy: .public) rows this build cannot read"
          )
        }
        if !page.changes.isEmpty { await onBatch(batch) }
      } catch let error as HubError where error.code == "resync_required" {
        // A hub that asks again straight after a snapshot is failing; do not spin on it.
        resyncsInARow += 1
        if resyncsInARow > 1 { await failed(error, backoff: &backoff) }
        needsSnapshot = true
      } catch {
        if stopped || Task.isCancelled { break }
        // A nudge cancelled the long-poll: not a failure, go round and push.
        if error is CancellationError, nudged { continue }
        if error is CancellationError { break }
        await failed(error, backoff: &backoff)
      }
    }
  }

  /// The pull for this turn. With a nudge already waiting it does not wait for news.
  private func pull() async throws -> PullResponse {
    let cursor = store.cursor
    let wait = nudged ? 0 : Self.waitSeconds
    let api = api
    let task = Task { try await api.pull(after: cursor, limit: Self.pageLimit, wait: wait) }
    pulling = task
    defer { pulling = nil }
    return try await task.value
  }

  /// Once per `run()`: an empty push answers with the highest `deviceSeq` the hub has for this device.
  private func checkSequence() async throws {
    guard !sequenceChecked else { return }
    let response = try await api.push([])
    try store.raiseLastDeviceSeq(to: response.acceptedThrough)
    sequenceChecked = true
  }

  /// Uploads the outbox, oldest first, in requests of at most 500 rows and 8 MiB, until it is empty.
  private func pushOutbox() async throws {
    while true {
      let batch = try store.nextUpload(rows: Self.pushLimit, bytes: Self.pushBytes)
      guard let first = batch.first else { return }
      let response = try await api.push(batch)
      // Nothing was taken (a hub that answers with a number below the batch): retrying at once would
      // spin, so it is a failure like any other and waits out the backoff.
      guard response.acceptedThrough >= first.deviceSeq else {
        throw WorkspaceError(
          .internalError,
          "The hub accepted nothing of the edits from \(first.deviceSeq) (it answered \(response.acceptedThrough))."
        )
      }
      let covered = response.rejected.filter { $0.deviceSeq <= response.acceptedThrough }.count
      try store.completeUpload(through: response.acceptedThrough, refused: covered)
      if covered > 0 {
        Self.logger.warning("the hub refused \(covered, privacy: .public) edits")
      }
    }
  }

  private func fetchSnapshot() async throws {
    let snapshot = try await api.snapshot()
    let batch = try store.applySnapshot(snapshot)
    needsSnapshot = false
    await onBatch(batch)
  }

  /// At most once a minute, and never a reason to stop syncing.
  private func refreshDevices() async {
    let now = ContinuousClock.now
    if let last = devicesFetchedAt, now - last < Self.devicesInterval { return }
    devicesFetchedAt = now
    if let devices = try? await api.devices() { try? store.saveDevices(devices) }
  }

  private func failed(_ error: any Error, backoff: inout Duration) async {
    await record(error: (error as? HubError)?.description ?? WorkspaceError.from(error).message)
    try? await Task.sleep(for: backoff)
    backoff = min(backoff * 2, maxBackoff)
  }

  /// Notes the outcome of a pull here, on the link (when there is one), and through `onStatus`.
  private func record(error: String?) async {
    lastError = error
    if error == nil { lastSyncAt = Timestamp.now() }
    if var link = try? store.link() {
      if error == nil { link.lastSyncAt = lastSyncAt }
      link.lastError = error
      try? store.saveLink(link)
    }
    await onStatus?(MirrorSyncStatus(lastError: lastError, lastSyncAt: lastSyncAt))
  }
}

/// The outcome of the most recent pull: `lastError` is nil once a pull has succeeded, and
/// `lastSyncAt` (a `Timestamp`) is when one last did, nil if none ever has.
public struct MirrorSyncStatus: Sendable, Equatable {
  public var lastError: String?
  public var lastSyncAt: String?

  public init(lastError: String? = nil, lastSyncAt: String? = nil) {
    self.lastError = lastError
    self.lastSyncAt = lastSyncAt
  }
}
