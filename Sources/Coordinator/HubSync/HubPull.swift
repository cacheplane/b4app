import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// Pulls other devices' edits from the hub into this Mac's store (M8b): long-poll after
/// `hubLink.cursor`, merge the page through `WorkspaceDatabase.applyRemote` (which advances the cursor
/// in the same transaction), and publish `thread.updated` and `project.changed` for what it touched so
/// the app refreshes as it does for local writes. Owned and started by `HubSync`.
///
/// - Nothing is applied until `GET /v1/devices` has answered once: its `macos` devices, revoked ones
///   included, are this Mac's own history (an old device id after `hub leave` and `hub join`), and
///   `applyRemote` skips them. The list is refreshed at most once a minute.
/// - `resync_required` (the cursor fell behind the hub's retention) fetches `GET /v1/snapshot` and
///   merges its phone-writable values (`remoteChanges(fromSnapshot:)`), continuing from its `next`.
///   Local rows stay; only newer clocks win.
/// - A 401 ends the loop and is reported through `onUnauthorized`; any other failure is reported
///   through `onError` and retried after a backoff that starts at two seconds and doubles to a minute.
///   `onError(nil)` follows the first success after a failure.
/// - `stop()` cancels a long-poll in flight and waits for the loop to end. A batch is one database
///   transaction, so stopping never leaves half a batch applied.
public actor HubPull {
  static let pageLimit = 1000
  static let waitSeconds = 25
  static let devicesRefresh: Duration = .seconds(60)

  private let database: WorkspaceDatabase
  private let api: any HubAPI
  private let eventLog: EventLog
  private let ownDeviceId: String
  private let initialBackoff: Duration
  private let maxBackoff: Duration
  private let onError: @Sendable (String?) async -> Void
  private let onUnauthorized: @Sendable (String) async -> Void
  private let logger = Log.logger("hub")

  private var loop: Task<Void, Never>?
  private var stopped = false
  /// `nil` until `devices()` first succeeds; nothing is applied before then.
  private var macDeviceIds: Set<String>?
  private var devicesLoadedAt: ContinuousClock.Instant?
  /// The last failure, nil after a successful pull.
  public private(set) var lastError: String?

  public init(
    database: WorkspaceDatabase, api: any HubAPI, eventLog: EventLog, ownDeviceId: String,
    initialBackoff: Duration = .seconds(2), maxBackoff: Duration = .seconds(60),
    onError: @escaping @Sendable (String?) async -> Void = { _ in },
    onUnauthorized: @escaping @Sendable (String) async -> Void = { _ in }
  ) {
    self.database = database
    self.api = api
    self.eventLog = eventLog
    self.ownDeviceId = ownDeviceId
    self.initialBackoff = initialBackoff
    self.maxBackoff = maxBackoff
    self.onError = onError
    self.onUnauthorized = onUnauthorized
  }

  /// Pulls until `stop()`, a 401, or the link is gone. A second call while running, or a call after
  /// `stop()`, returns at once.
  public func run() async {
    guard loop == nil, !stopped else { return }
    let task = Task { await self.pullLoop() }
    loop = task
    await task.value
  }

  /// Start `run()` without waiting for it.
  func launch() {
    guard loop == nil, !stopped else { return }
    loop = Task { await self.pullLoop() }
  }

  /// Ends the loop, cancelling a long-poll in flight, and waits until it has.
  public func stop() async {
    stopped = true
    loop?.cancel()
    await loop?.value
  }

  private func pullLoop() async {
    var backoff = initialBackoff
    while !stopped, !Task.isCancelled {
      do {
        guard let link = try database.hubLink() else { break }
        let macs = try await knownMacs()
        do {
          let page = try await api.pull(after: link.cursor, limit: Self.pageLimit, wait: Self.waitSeconds)
          guard !stopped, !Task.isCancelled else { break }
          let applied = try database.applyRemote(
            page.changes.map(Self.remoteChange), ownDeviceId: ownDeviceId, macDeviceIds: macs,
            cursor: page.next)
          await publish(applied)
        } catch let error as HubError where error.code == "resync_required" {
          let snapshot = try await api.snapshot()
          guard !stopped, !Task.isCancelled else { break }
          let applied = try database.applyRemote(
            Self.remoteChanges(fromSnapshot: snapshot), ownDeviceId: ownDeviceId, macDeviceIds: macs,
            cursor: snapshot.next)
          logger.info("resynced from the hub's snapshot at \(snapshot.next, privacy: .public)")
          await publish(applied)
        }
        if lastError != nil {
          lastError = nil
          await onError(nil)
        }
        backoff = initialBackoff
      } catch let error as HubError where error.code == "unauthorized" {
        lastError = error.description
        logger.warning("pull refused: \(error.description, privacy: .public)")
        await onUnauthorized(error.description)
        break
      } catch {
        if stopped || Task.isCancelled || error is CancellationError { break }
        let message = (error as? HubError)?.description ?? WorkspaceError.from(error).message
        lastError = message
        logger.warning("pull failed: \(message, privacy: .public)")
        await onError(message)
        try? await Task.sleep(for: backoff)
        backoff = min(backoff * 2, maxBackoff)
      }
    }
  }

  /// The user's `macos` devices, revoked ones included, from a list at most a minute old. Throws until
  /// the first list loads; a failed refresh after that keeps the last list.
  private func knownMacs() async throws -> Set<String> {
    if let macDeviceIds, let loaded = devicesLoadedAt, ContinuousClock.now - loaded < Self.devicesRefresh {
      return macDeviceIds
    }
    do {
      let devices = try await api.devices()
      let macs = Set(devices.filter { $0.platform == "macos" }.map(\.id))
      macDeviceIds = macs
      devicesLoadedAt = .now
      return macs
    } catch let error as HubError where error.code != "unauthorized" {
      guard let macDeviceIds else { throw error }
      logger.warning("could not refresh the hub's devices: \(error.description, privacy: .public)")
      devicesLoadedAt = .now
      return macDeviceIds
    }
  }

  private func publish(_ applied: RemoteApplied) async {
    for id in applied.touchedThreadIds.union(applied.touchedDraftThreadIds).sorted() {
      if let thread = try? database.thread(id: id), let event = try? AdapterEvent.threadUpdated(thread) {
        await eventLog.publish(event)
      }
    }
    for id in applied.touchedProjectIds.sorted() {
      await eventLog.publish(.projectChanged(projectId: id))
    }
  }

  static func remoteChange(_ stored: StoredChange) -> RemoteChange {
    RemoteChange(
      deviceId: stored.deviceId, hlc: stored.hlc, table: stored.table, rowId: stored.rowId, op: stored.op,
      column: stored.column, value: stored.value)
  }

  /// A snapshot's synthetic inserts as the changes that could have produced its phone-writable values.
  /// A row's `deviceId` is its owner (normally this Mac) and says nothing about who wrote a column, so
  /// each value is attributed to the device of its own column clock:
  ///
  /// - a `threads` or `projects` row becomes one update per phone-writable column that has a clock (a
  ///   column without one was never edited since clocks began, and the Mac's value stands);
  /// - a `drafts` row travels whole, at its newest column clock and as that clock's device, so a draft
  ///   only the phone has is created and an existing one merges column by column;
  /// - every other table is dropped (`applyRemote` would skip it anyway).
  static func remoteChanges(fromSnapshot snapshot: SnapshotResponse) -> [RemoteChange] {
    var clocks: [String: [String: String]] = [:]
    for clock in snapshot.clocks {
      clocks[clock.table + "\u{0}" + clock.rowId, default: [:]][clock.column] = clock.hlc
    }
    func device(_ hlc: String, else fallback: String) -> String { HLC(rawValue: hlc)?.deviceId ?? fallback }

    var changes: [RemoteChange] = []
    for row in snapshot.changes where row.op == "insert" {
      guard let value = row.value?.objectValue, let writable = SyncColumns.phoneWritable[row.table] else {
        continue
      }
      let rowClocks = clocks[row.table + "\u{0}" + row.rowId] ?? [:]
      if row.table == "drafts" {
        let newest =
          rowClocks.values.max { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) } ?? row.hlc
        changes.append(
          RemoteChange(
            deviceId: device(newest, else: row.deviceId), hlc: newest, table: row.table, rowId: row.rowId,
            op: "insert", value: row.value))
        continue
      }
      for column in writable.sorted() {
        guard let columnValue = value[column], let hlc = rowClocks[column] else { continue }
        changes.append(
          RemoteChange(
            deviceId: device(hlc, else: row.deviceId), hlc: hlc, table: row.table, rowId: row.rowId,
            op: "update", column: column, value: columnValue))
      }
    }
    return changes
  }
}
