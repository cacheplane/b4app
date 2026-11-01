import Foundation
import WorkspaceProtocol
import WorkspaceSync

/// Pulls the hub's change feed into a `MirrorStore`: long-poll after the cursor, apply the page,
/// advance the cursor to the page's `next`, report the batch. `resync_required` (the cursor fell
/// behind the hub's retention) clears the mirrored rows and starts again from 0. Any other failure is
/// recorded on the link as `lastError` and retried after a backoff that starts at two seconds and
/// doubles to a minute. The device token stays inside `api`.
public actor MirrorSync {
  private let store: MirrorStore
  private let api: any HubAPI
  private let onBatch: @Sendable (AppliedBatch) async -> Void
  private let initialBackoff: Duration
  private let maxBackoff: Duration
  private var loop: Task<Void, Never>?
  private var stopped = false
  /// The last failure, nil after a successful pull.
  public private(set) var lastError: String?

  static let pageLimit = 1000
  static let waitSeconds = 25

  public init(
    store: MirrorStore, api: any HubAPI, onBatch: @escaping @Sendable (AppliedBatch) async -> Void,
    initialBackoff: Duration = .seconds(2), maxBackoff: Duration = .seconds(60)
  ) {
    self.store = store
    self.api = api
    self.onBatch = onBatch
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
        record(error: nil)
        backoff = initialBackoff
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
    record(error: (error as? HubError)?.description ?? WorkspaceError.from(error).message)
    try? await Task.sleep(for: backoff)
    backoff = min(backoff * 2, maxBackoff)
  }

  /// Notes the outcome of a pull here and on the link (when there is one).
  private func record(error: String?) {
    lastError = error
    guard var link = try? store.link() else { return }
    if error == nil { link.lastSyncAt = Timestamp.now() }
    link.lastError = error
    try? store.saveLink(link)
  }
}
