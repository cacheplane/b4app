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

  public init(
    deviceSeq: Int, wall: Int, table: String, rowId: String, op: String, column: String? = nil,
    value: JSONValue? = nil
  ) {
    self.deviceSeq = deviceSeq
    self.wall = wall
    self.table = table
    self.rowId = rowId
    self.op = op
    self.column = column
    self.value = value
  }

  private enum CodingKeys: String, CodingKey {
    case deviceSeq, wall, table, rowId, op, column, value
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
  }
}

/// A change in the feed: a `SyncChange` plus its position in the org's feed and the device that wrote
/// it. `value` distinguishes JSON `null` (`.null`) from an absent key (`nil`), as on `SyncChange`.
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

  public init(
    hubSeq: Int, deviceId: String, deviceSeq: Int, wall: Int, table: String, rowId: String, op: String,
    column: String? = nil, value: JSONValue? = nil
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
  }

  private enum CodingKeys: String, CodingKey {
    case hubSeq, deviceId, deviceSeq, wall, table, rowId, op, column, value
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

public struct PushResponse: Codable, Sendable, Equatable {
  public var acceptedThrough: Int

  public init(acceptedThrough: Int) {
    self.acceptedThrough = acceptedThrough
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
