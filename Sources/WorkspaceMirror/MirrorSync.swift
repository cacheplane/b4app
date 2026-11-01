import Foundation
import WorkspaceProtocol
import WorkspaceSync
import os

/// Pulls the hub's change feed into a `MirrorStore`: long-poll after the cursor, apply the page,
/// advance the cursor to the page's `next`, report the batch. `resync_required` (the cursor fell
/// behind the hub's retention) clears the mirrored rows and starts again from 0. Any other failure is
/// recorded on the link as `lastError` and retried after a backoff that starts at two seconds and
/// doubles to a minute. The device token stays inside `api`. Each outcome is also handed to `onStatus`
/// (when given), so the app can say that what it shows is stale.
public actor MirrorSync {
  private let store: MirrorStore
  private let api: any HubAPI
  private let onBatch: @Sendable (AppliedBatch) async -> Void
  private let onStatus: (@Sendable (MirrorSyncStatus) async -> Void)?
  private let initialBackoff: Duration
  private let maxBackoff: Duration
  private var loop: Task<Void, Never>?
  private var stopped = false
  /// The last failure, nil after a successful pull.
  public private(set) var lastError: String?
  /// When a pull last succeeded (`Timestamp`), starting from the stored link's value.
  public private(set) var lastSyncAt: String?

  private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "mirror")
  static let pageLimit = 1000
  static let waitSeconds = 25

  public init(
    store: MirrorStore, api: any HubAPI, onBatch: @escaping @Sendable (AppliedBatch) async -> Void,
    onStatus: (@Sendable (MirrorSyncStatus) async -> Void)? = nil,
    initialBackoff: Duration = .seconds(2), maxBackoff: Duration = .seconds(60)
  ) {
    self.store = store
    self.api = api
    self.onBatch = onBatch
    self.onStatus = onStatus
    self.lastSyncAt = try? store.link()?.lastSyncAt
    self.initialBackoff = initialBackoff
    self.maxBackoff = maxBackoff
  }

  /// Pulls until `stop()`. A second call while running, or a call after `stop()`, returns at once.
  public func run() async {
    guard loop == nil, !stopped else { return }
    let task = Task { await self.pullLoop() }
    loop = task
    await task.value
  }

  /// Ends the loop, cancelling a long-poll in flight.
  public func stop() {
    stopped = true
    loop?.cancel()
  }

  private func pullLoop() async {
    var backoff = initialBackoff
    while !stopped, !Task.isCancelled {
      do {
        let page = try await api.pull(after: store.cursor, limit: Self.pageLimit, wait: Self.waitSeconds)
        let batch = try store.apply(page.changes)
        try store.setCursor(page.next)
        await record(error: nil)
        backoff = initialBackoff
        if batch.undecodableRows > 0 {
          Self.logger.warning(
            "mirror batch through \(page.next, privacy: .public) holds \(batch.undecodableRows, privacy: .public) rows this build cannot read"
          )
        }
        if !page.changes.isEmpty { await onBatch(batch) }
      } catch let error as HubError where error.code == "resync_required" {
        // From 0 there is nothing older to fall behind; a hub that still says so is failing.
        guard store.cursor > 0 else {
          await failed(error, backoff: &backoff)
          continue
        }
        do {
          try store.clearRows()
        } catch {
          await failed(error, backoff: &backoff)
        }
      } catch {
        if stopped || Task.isCancelled || error is CancellationError { break }
        await failed(error, backoff: &backoff)
      }
    }
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
