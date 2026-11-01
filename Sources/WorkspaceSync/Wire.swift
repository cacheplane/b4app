import Foundation
import WorkspaceProtocol

/// A change as uploaded: the shape of `Change` in `Hub/API.md`. The wire carries no device id; the hub
/// attributes every change to the authenticated device.
///
/// `value` keeps JSON `null` and an absent key apart: an `update` that clears a column carries
/// `value: .null` (present), while a `delete` carries `nil` (absent). The hub treats both as "set the
/// column to NULL" for an update, and the Mac's trigger records a cleared column as JSON null, so a
/// plain `Optional` decode (which folds `null` into `nil`) would lose information. The decoder below
/// decodes a present `null` as `.null`; the encoder omits `nil` and writes `.null` as `null`.
public struct SyncChange: Codable, Sendable, Equatable {
  public var deviceSeq: Int
  public var wall: Int
  public var table: String
  public var rowId: String
  public var op: String
  public var column: String?
  public var value: JSONValue?
  /// The hybrid logical clock the device stamped on the change. Omitted from the wire when `nil`, in
  /// which case the hub stamps `wall` with counter `0000` and the pushing device's id.
  public var hlc: String?

  public init(
    deviceSeq: Int, wall: Int, table: String, rowId: String, op: String, column: String? = nil,
    value: JSONValue? = nil, hlc: String? = nil
  ) {
    self.deviceSeq = deviceSeq
    self.wall = wall
    self.table = table
    self.rowId = rowId
    self.op = op
    self.column = column
    self.value = value
    self.hlc = hlc
  }

  private enum CodingKeys: String, CodingKey {
    case deviceSeq, wall, table, rowId, op, column, value, hlc
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceSeq = try container.decode(Int.self, forKey: .deviceSeq)
    wall = try container.decode(Int.self, forKey: .wall)
    table = try container.decode(String.self, forKey: .table)
    rowId = try container.decode(String.self, forKey: .rowId)
    op = try container.decode(String.self, forKey: .op)
    column = try container.decodeIfPresent(String.self, forKey: .column)
    value = try container.decodePresentValue(forKey: .value)
    hlc = try container.decodeIfPresent(String.self, forKey: .hlc)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceSeq, forKey: .deviceSeq)
    try container.encode(wall, forKey: .wall)
    try container.encode(table, forKey: .table)
    try container.encode(rowId, forKey: .rowId)
    try container.encode(op, forKey: .op)
    try container.encodeIfPresent(column, forKey: .column)
    try container.encodeIfPresent(value, forKey: .value)
    try container.encodeIfPresent(hlc, forKey: .hlc)
  }
}

/// A change in the feed: a `SyncChange` plus its position in the org's feed and the device that wrote
/// it. `value` distinguishes JSON `null` (`.null`) from an absent key (`nil`), as on `SyncChange`.
///
/// `hlc` is the clock the hub kept. A feed that predates clocks omits it, and then it is derived the
/// way the hub derives it for a change pushed without one: `wall` (clamped at 0) as 12 hex digits,
/// counter `0000`, and the device id.
public struct StoredChange: Codable, Sendable, Equatable {
  public var hubSeq: Int
  public var deviceId: String
  public var deviceSeq: Int
  public var wall: Int
  public var table: String
  public var rowId: String
  public var op: String
  public var column: String?
  public var value: JSONValue?
  public var hlc: String

  public init(
    hubSeq: Int, deviceId: String, deviceSeq: Int, wall: Int, table: String, rowId: String, op: String,
    column: String? = nil, value: JSONValue? = nil, hlc: String? = nil
  ) {
    self.hubSeq = hubSeq
    self.deviceId = deviceId
    self.deviceSeq = deviceSeq
    self.wall = wall
    self.table = table
    self.rowId = rowId
    self.op = op
    self.column = column
    self.value = value
    self.hlc = hlc ?? Self.derivedClock(wall: wall, deviceId: deviceId)
  }

  /// `Hlc::derived` in the hub: the wall as a zero-counter clock of the device.
  static func derivedClock(wall: Int, deviceId: String) -> String {
    HLC(millis: UInt64(max(0, wall)), counter: 0, deviceId: deviceId).rawValue
  }

  private enum CodingKeys: String, CodingKey {
    case hubSeq, deviceId, deviceSeq, wall, table, rowId, op, column, value, hlc
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hubSeq = try container.decode(Int.self, forKey: .hubSeq)
    deviceId = try container.decode(String.self, forKey: .deviceId)
    deviceSeq = try container.decode(Int.self, forKey: .deviceSeq)
    wall = try container.decode(Int.self, forKey: .wall)
    table = try container.decode(String.self, forKey: .table)
    rowId = try container.decode(String.self, forKey: .rowId)
    op = try container.decode(String.self, forKey: .op)
    column = try container.decodeIfPresent(String.self, forKey: .column)
    value = try container.decodePresentValue(forKey: .value)
    hlc =
      try container.decodeIfPresent(String.self, forKey: .hlc)
      ?? Self.derivedClock(wall: wall, deviceId: deviceId)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hubSeq, forKey: .hubSeq)
    try container.encode(deviceId, forKey: .deviceId)
    try container.encode(deviceSeq, forKey: .deviceSeq)
    try container.encode(wall, forKey: .wall)
    try container.encode(table, forKey: .table)
    try container.encode(rowId, forKey: .rowId)
    try container.encode(op, forKey: .op)
    try container.encodeIfPresent(column, forKey: .column)
    try container.encodeIfPresent(value, forKey: .value)
    try container.encode(hlc, forKey: .hlc)
  }
}

extension KeyedDecodingContainer {
  /// `nil` when the key is absent, `.null` when it is present as JSON null, otherwise the value.
  fileprivate func decodePresentValue(forKey key: Key) throws -> JSONValue? {
    guard contains(key) else { return nil }
    return try decode(JSONValue.self, forKey: key)
  }
}

public struct EnrollRequest: Codable, Sendable, Equatable {
  public var code: String
  public var deviceName: String
  public var platform: String

  public init(code: String, deviceName: String, platform: String) {
    self.code = code
    self.deviceName = deviceName
    self.platform = platform
  }
}

public struct OrgInfo: Codable, Sendable, Equatable {
  public var slug: String
  public var name: String

  public init(slug: String, name: String) {
    self.slug = slug
    self.name = name
  }
}

public struct UserInfo: Codable, Sendable, Equatable {
  public var username: String
  public var displayName: String

  public init(username: String, displayName: String) {
    self.username = username
    self.displayName = displayName
  }
}

/// The only response that carries the device token; the caller stores it in a `SecretStore`.
public struct EnrollResponse: Codable, Sendable, Equatable {
  public var deviceId: String
  public var token: String
  public var org: OrgInfo
  public var user: UserInfo

  public init(deviceId: String, token: String, org: OrgInfo, user: UserInfo) {
    self.deviceId = deviceId
    self.token = token
    self.org = org
    self.user = user
  }
}

public struct MeResponse: Codable, Sendable, Equatable {
  public var deviceId: String
  public var deviceName: String
  public var platform: String
  public var org: OrgInfo
  public var user: UserInfo
  /// RFC 3339 in UTC with microseconds, exactly as the hub sent it.
  public var createdAt: String

  public init(
    deviceId: String, deviceName: String, platform: String, org: OrgInfo, user: UserInfo, createdAt: String
  ) {
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.platform = platform
    self.org = org
    self.user = user
    self.createdAt = createdAt
  }
}

/// A change the hub refused: final, not recorded in the feed, and covered by `acceptedThrough`. `code`
/// is `column_not_writable`, `payload_too_large`, or `invalid_clock`.
public struct RejectedChange: Codable, Sendable, Equatable {
  public var deviceSeq: Int
  public var code: String

  public init(deviceSeq: Int, code: String) {
    self.deviceSeq = deviceSeq
    self.code = code
  }
}

public struct PushResponse: Codable, Sendable, Equatable {
  public var acceptedThrough: Int
  /// Empty when the hub refused nothing; the hub omits the key then, and so does the encoder.
  public var rejected: [RejectedChange]

  public init(acceptedThrough: Int, rejected: [RejectedChange] = []) {
    self.acceptedThrough = acceptedThrough
    self.rejected = rejected
  }

  private enum CodingKeys: String, CodingKey { case acceptedThrough, rejected }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    acceptedThrough = try container.decode(Int.self, forKey: .acceptedThrough)
    rejected = try container.decodeIfPresent([RejectedChange].self, forKey: .rejected) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(acceptedThrough, forKey: .acceptedThrough)
    if !rejected.isEmpty { try container.encode(rejected, forKey: .rejected) }
  }
}

public struct PullResponse: Codable, Sendable, Equatable {
  public var changes: [StoredChange]
  public var next: Int
  public var more: Bool

  public init(changes: [StoredChange], next: Int, more: Bool) {
    self.changes = changes
    self.next = next
    self.more = more
  }
}

/// One per-row, per-column clock from `GET /v1/snapshot`, so the reader keeps merging by clock after it
/// restores.
public struct ColumnClock: Codable, Sendable, Equatable {
  public var table: String
  public var rowId: String
  public var column: String
  public var hlc: String

  public init(table: String, rowId: String, column: String, hlc: String) {
    self.table = table
    self.rowId = rowId
    self.column = column
    self.hlc = hlc
  }
}

/// `GET /v1/snapshot`: the user's whole mirror as synthetic inserts (`hubSeq` 0), the clocks of their
/// columns, and the cursor to pull from afterwards.
public struct SnapshotResponse: Codable, Sendable, Equatable {
  public var changes: [StoredChange]
  public var clocks: [ColumnClock]
  public var next: Int

  public init(changes: [StoredChange], clocks: [ColumnClock], next: Int) {
    self.changes = changes
    self.clocks = clocks
    self.next = next
  }
}

/// One entry of `GET /v1/devices`. The timestamps are RFC 3339 in UTC with microseconds, exactly as
/// the hub sent them; `nil` means never seen, or not revoked.
public struct DeviceInfo: Codable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var platform: String
  public var lastSeenAt: String?
  public var revokedAt: String?

  public init(id: String, name: String, platform: String, lastSeenAt: String? = nil, revokedAt: String? = nil)
  {
    self.id = id
    self.name = name
    self.platform = platform
    self.lastSeenAt = lastSeenAt
    self.revokedAt = revokedAt
  }
}

/// The `{"devices": [...]}` envelope of `GET /v1/devices`.
struct DevicesResponse: Codable, Sendable, Equatable {
  var devices: [DeviceInfo]
}

/// B4's error envelope as the hub sends it: `{"error":{"kind","message","details":{"code"}}}`.
public struct HubErrorBody: Codable, Sendable, Equatable {
  public struct Details: Codable, Sendable, Equatable {
    public var code: String?
  }

  public struct Body: Codable, Sendable, Equatable {
    public var kind: String
    public var message: String
    public var details: Details?
  }

  public var error: Body
}

/// A failure talking to the hub. `code` is the hub's `details.code` (`invalid_request`, `invalid_code`,
/// `unauthorized`, `resync_required`, `payload_too_large`, `shutting_down`, ...) or `transport` when
/// the request never completed or its answer could not be read. `status` is the HTTP status, or 0 when
/// there was none.
public struct HubError: Error, Sendable, Equatable, CustomStringConvertible {
  public var kind: String
  public var code: String
  public var message: String
  public var status: Int

  public init(kind: String, code: String, message: String, status: Int) {
    self.kind = kind
    self.code = code
    self.message = message
    self.status = status
  }

  public var description: String { "Hub error \(status) \(code): \(message)" }
}
