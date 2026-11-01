import Foundation

/// The hub's HTTP API, one method per route in `Hub/API.md`. Failures are `HubError`s (or
/// `CancellationError` when the calling task is cancelled).
public protocol HubAPI: Sendable {
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse
  func me() async throws -> MeResponse
  func push(_ changes: [SyncChange]) async throws -> PushResponse
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse
  /// `GET /v1/snapshot`: the user's state, for a reader whose cursor the hub has pruned past.
  func snapshot() async throws -> SnapshotResponse
  /// `GET /v1/devices`: this user's devices, oldest enrolled first, revoked ones included.
  func devices() async throws -> [DeviceInfo]
  func revokeSelf() async throws
}
