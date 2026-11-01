import Foundation
import WorkspaceProtocol

/// An in-memory hub for tests of the readers and writers that sit above `HubAPI`. It models the parts
/// of the real hub those layers depend on: single-use enrollment codes, per-device idempotency on
/// `deviceSeq`, a feed ordered by `hubSeq`, long-poll wake-up, revocation, and injected failures. It is
/// not a hub: it does not apply changes to tables and does not check tokens.
public actor FakeHubAPI: HubAPI {
  /// Codes the fake will redeem, each once.
  public private(set) var enrollmentCodes: [String: EnrollResponse]
  /// The feed, oldest first.
  public private(set) var stored: [StoredChange]
  /// Every batch `push` received, including repeats the feed ignored.
  public private(set) var pushed: [[SyncChange]] = []
  /// Fails the next call of any method once, then clears itself.
  public private(set) var failNext: HubError?
  /// Set by `revokeSelf`; every later call except `enroll` answers 401 `unauthorized`.
  public private(set) var revoked = false
  /// How many times `enroll` was called, redeemed or not.
  public private(set) var enrollCalls = 0

  private var device: EnrollResponse?
  private var deviceName = "Fake device"
  private var platform = "macos"
  private var acceptedSeqs: Set<Int> = []
  private var snapshotOverride: SnapshotResponse?
  private var devicesOverride: [DeviceInfo]?

  /// The hub refuses a `value` over this many bytes of serialised JSON.
  private static let maxValueBytes = 2_097_152

  public init(enrollmentCodes: [String: EnrollResponse] = [:], stored: [StoredChange] = []) {
    self.enrollmentCodes = enrollmentCodes
    self.stored = stored
  }

  public func setFailNext(_ error: HubError?) { failNext = error }

  /// Sets the platform of the fake's device, which decides what `push` refuses: `macos` may write
  /// anything, `ios` and `cli` only the phone's columns. `enroll` sets it from its request.
  public func setPlatform(_ platform: String) { self.platform = platform }

  /// What `snapshot()` answers. Without it the fake answers an empty snapshot at the feed's tip.
  public func setSnapshot(_ snapshot: SnapshotResponse?) { snapshotOverride = snapshot }

  /// What `devices()` answers. Without it the fake lists the enrolled device alone.
  public func setDevices(_ devices: [DeviceInfo]?) { devicesOverride = devices }

  public func addEnrollmentCode(_ code: String, _ response: EnrollResponse) {
    enrollmentCodes[code] = response
  }

  /// Adds changes to the feed as if another device had pushed them.
  public func append(_ changes: [StoredChange]) { stored.append(contentsOf: changes) }

  public func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    enrollCalls += 1
    try consumeFailure()
    guard let response = enrollmentCodes.removeValue(forKey: request.code) else {
      throw Self.error("invalid_code", "The enrollment code is not valid.", status: 401)
    }
    device = response
    deviceName = request.deviceName
    platform = request.platform
    revoked = false
    return response
  }

  public func me() async throws -> MeResponse {
    try authorize()
    let device =
      device
      ?? EnrollResponse(
        deviceId: "fake-device", token: "fake-token", org: OrgInfo(slug: "fake", name: "Fake"),
        user: UserInfo(username: "fake", displayName: "Fake"))
    return MeResponse(
      deviceId: device.deviceId, deviceName: deviceName, platform: platform, org: device.org,
      user: device.user, createdAt: "2026-10-31T12:00:00.000000Z")
  }

  public func push(_ changes: [SyncChange]) async throws -> PushResponse {
    try authorize()
    pushed.append(changes)
    let deviceId = device?.deviceId ?? "fake-device"
    var rejected: [RejectedChange] = []
    for change in changes where !acceptedSeqs.contains(change.deviceSeq) {
      if let code = refusal(for: change) {
        rejected.append(RejectedChange(deviceSeq: change.deviceSeq, code: code))
        continue
      }
      acceptedSeqs.insert(change.deviceSeq)
      stored.append(
        StoredChange(
          hubSeq: (stored.last?.hubSeq ?? 0) + 1, deviceId: deviceId, deviceSeq: change.deviceSeq,
          wall: change.wall, table: change.table, rowId: change.rowId, op: change.op, column: change.column,
          value: change.value, hlc: change.hlc))
    }
    return PushResponse(
      acceptedThrough: changes.map(\.deviceSeq).max() ?? acceptedSeqs.max() ?? 0, rejected: rejected)
  }

  public func snapshot() async throws -> SnapshotResponse {
    try authorize()
    return snapshotOverride ?? SnapshotResponse(changes: [], clocks: [], next: stored.last?.hubSeq ?? 0)
  }

  public func devices() async throws -> [DeviceInfo] {
    try authorize()
    if let devicesOverride { return devicesOverride }
    guard let device else { return [] }
    return [DeviceInfo(id: device.deviceId, name: deviceName, platform: platform)]
  }

  public func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try authorize()
    let deadline = ContinuousClock.now + .seconds(max(wait, 0))
    while true {
      let newer = stored.filter { $0.hubSeq > after }
      if !newer.isEmpty || ContinuousClock.now >= deadline {
        let page = Array(newer.prefix(max(1, min(limit, 1000))))
        return PullResponse(
          changes: page, next: page.last?.hubSeq ?? after, more: newer.count > page.count)
      }
      try await Task.sleep(for: .milliseconds(10))
      try authorize()
    }
  }

  public func revokeSelf() async throws {
    try authorize()
    revoked = true
  }

  // MARK: - Helpers

  /// The hub's per-change refusal, or `nil` when the change is accepted. A `macos` device may write
  /// anything; any other platform may only update phone-writable columns or insert a draft.
  private func refusal(for change: SyncChange) -> String? {
    if let hlc = change.hlc, HLC(rawValue: hlc) == nil { return "invalid_clock" }
    if platform != "macos" {
      let phoneUpdate =
        change.op == "update"
        && change.column.map { SyncColumns.isPhoneWritable(table: change.table, column: $0) } == true
      let draftInsert = change.op == "insert" && change.table == "drafts"
      if !phoneUpdate && !draftInsert { return "column_not_writable" }
    }
    if let value = change.value,
      let encoded = try? JSONCoding.encoder.encode(value), encoded.count > Self.maxValueBytes
    {
      return "payload_too_large"
    }
    return nil
  }

  private func consumeFailure() throws {
    if let failure = failNext {
      failNext = nil
      throw failure
    }
  }

  private func authorize() throws {
    try consumeFailure()
    if revoked { throw Self.error("unauthorized", "Unauthorized.", status: 401) }
  }

  private static func error(_ code: String, _ message: String, status: Int) -> HubError {
    HubError(kind: "request_error", code: code, message: message, status: status)
  }
}
