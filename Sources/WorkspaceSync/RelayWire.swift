import Foundation
import WorkspaceProtocol

/// What a relayed command asks the Mac to do. An allowlist on the hub and on the Mac.
public enum RelayMethod: String, Codable, Sendable, CaseIterable {
  case turnSend = "turn.send"
  case turnInterrupt = "turn.interrupt"
  case requestRespond = "request.respond"
  case threadStart = "thread.start"
  case turnLookup = "turn.lookup"
}

/// Which end of the relay a link is. A `macos` device is a host; `ios` and `cli` are clients.
public enum RelayRole: String, Codable, Sendable {
  case host
  case client
}

/// One Mac in a `presence` frame.
public struct RelayHostPresence: Codable, Sendable, Equatable {
  public var deviceId: String
  public var name: String
  public var online: Bool
  public var lastSeenAt: String?

  public init(deviceId: String, name: String, online: Bool, lastSeenAt: String? = nil) {
    self.deviceId = deviceId
    self.name = name
    self.online = online
    self.lastSeenAt = lastSeenAt
  }
}

/// The client a command came from, stamped on it by the hub.
public struct RelayFrom: Codable, Sendable, Equatable {
  public var deviceId: String
  public var name: String

  public init(deviceId: String, name: String) {
    self.deviceId = deviceId
    self.name = name
  }
}

/// The failure of one relayed command, carried in a `reply`. The hub's `WireError`. `code` stays the raw
/// string, so a code this build does not know (a newer hub's, or `invalid_request`) still decodes and
/// round-trips; `errorCode` is the known `ErrorCode`, when there is one.
public struct RelayWireError: Codable, Sendable, Equatable {
  public var code: String
  public var message: String
  public var details: JSONValue?

  public init(code: String, message: String, details: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }

  public init(_ code: ErrorCode, _ message: String, details: JSONValue? = nil) {
    self.init(code: code.rawValue, message: message, details: details)
  }

  /// The code as an `ErrorCode`, or nil when it is not one this build knows.
  public var errorCode: ErrorCode? { ErrorCode(rawValue: code) }

  /// The error as the rest of the app throws it: an unknown code becomes `protocolInvalid`, with the
  /// original string kept in `details.relayCode`.
  public var workspaceError: WorkspaceError {
    if let errorCode { return WorkspaceError(errorCode, message, details: details) }
    var merged: [String: JSONValue] = [:]
    if case .object(let object)? = details { merged = object }
    merged["relayCode"] = .string(code)
    return WorkspaceError(.protocolInvalid, message, details: .object(merged))
  }
}

/// One frame on a relay link: the same shape as the hub's `RelayMessage` in `b4hub-core`, and
/// `Tests/Fixtures/sync/relay.json` is decoded and re-encoded by both. Absent optional fields are
/// omitted when encoding, never written as `null`. `params` and `result` are opaque to the hub.
public enum RelayMessage: Codable, Sendable, Equatable {
  /// Hub to device, first on every link.
  case hello(
    protocol: Int, minClientProtocol: Int, deviceId: String, role: RelayRole, heartbeatSeconds: Int,
    hubTime: String)
  case ping
  case pong(hubTime: String)
  /// Client to hub with `id`, `method` and `params`; hub to host with `deadline` and `from` too.
  case command(
    id: String, method: RelayMethod, params: JSONValue, deadline: String? = nil, from: RelayFrom? = nil)
  /// `result` or `error`, never both.
  case reply(id: String, result: JSONValue? = nil, error: RelayWireError? = nil)
  case watch(threadId: String)
  case unwatch(threadId: String)
  /// Hub to host: the full set of its threads that some client watches.
  case watching(threadIds: [String])
  case event(AdapterEvent)
  /// Hub to client: events for this thread were dropped.
  case streamGap(threadId: String)
  case presence(hosts: [RelayHostPresence])
  /// Hub to device: a problem with the link or a frame, not with a command. `code` is the raw string
  /// (see `RelayWireError`).
  case error(code: String, message: String, details: JSONValue? = nil)

  private enum CodingKeys: String, CodingKey {
    case type, `protocol`, minClientProtocol, deviceId, role, heartbeatSeconds, hubTime, id, method, params
    case deadline, from, result, error, threadId, threadIds, event, hosts, code, message, details
  }

  private enum Kind: String {
    case hello, ping, pong, command, reply, watch, unwatch, watching, event
    case streamGap = "stream_gap"
    case presence, error
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let typeName = try c.decode(String.self, forKey: .type)
    guard let kind = Kind(rawValue: typeName) else {
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "unknown relay message type \(typeName)")
    }
    switch kind {
    case .hello:
      self = .hello(
        protocol: try c.decode(Int.self, forKey: .protocol),
        minClientProtocol: try c.decode(Int.self, forKey: .minClientProtocol),
        deviceId: try c.decode(String.self, forKey: .deviceId),
        role: try c.decode(RelayRole.self, forKey: .role),
        heartbeatSeconds: try c.decode(Int.self, forKey: .heartbeatSeconds),
        hubTime: try c.decode(String.self, forKey: .hubTime))
    case .ping:
      self = .ping
    case .pong:
      self = .pong(hubTime: try c.decode(String.self, forKey: .hubTime))
    case .command:
      self = .command(
        id: try c.decode(String.self, forKey: .id),
        method: try c.decode(RelayMethod.self, forKey: .method),
        params: try c.decode(JSONValue.self, forKey: .params),
        deadline: try c.decodeIfPresent(String.self, forKey: .deadline),
        from: try c.decodeIfPresent(RelayFrom.self, forKey: .from))
    case .reply:
      self = .reply(
        id: try c.decode(String.self, forKey: .id),
        result: try c.decodeIfPresent(JSONValue.self, forKey: .result),
        error: try c.decodeIfPresent(RelayWireError.self, forKey: .error))
    case .watch:
      self = .watch(threadId: try c.decode(String.self, forKey: .threadId))
    case .unwatch:
      self = .unwatch(threadId: try c.decode(String.self, forKey: .threadId))
    case .watching:
      self = .watching(threadIds: try c.decode([String].self, forKey: .threadIds))
    case .event:
      self = .event(try c.decode(AdapterEvent.self, forKey: .event))
    case .streamGap:
      self = .streamGap(threadId: try c.decode(String.self, forKey: .threadId))
    case .presence:
      self = .presence(hosts: try c.decode([RelayHostPresence].self, forKey: .hosts))
    case .error:
      self = .error(
        code: try c.decode(String.self, forKey: .code),
        message: try c.decode(String.self, forKey: .message),
        details: try c.decodeIfPresent(JSONValue.self, forKey: .details))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let version, let minClient, let deviceId, let role, let heartbeat, let hubTime):
      try c.encode(Kind.hello.rawValue, forKey: .type)
      try c.encode(version, forKey: .protocol)
      try c.encode(minClient, forKey: .minClientProtocol)
      try c.encode(deviceId, forKey: .deviceId)
      try c.encode(role, forKey: .role)
      try c.encode(heartbeat, forKey: .heartbeatSeconds)
      try c.encode(hubTime, forKey: .hubTime)
    case .ping:
      try c.encode(Kind.ping.rawValue, forKey: .type)
    case .pong(let hubTime):
      try c.encode(Kind.pong.rawValue, forKey: .type)
      try c.encode(hubTime, forKey: .hubTime)
    case .command(let id, let method, let params, let deadline, let from):
      try c.encode(Kind.command.rawValue, forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(method, forKey: .method)
      try c.encode(params, forKey: .params)
      try c.encodeIfPresent(deadline, forKey: .deadline)
      try c.encodeIfPresent(from, forKey: .from)
    case .reply(let id, let result, let error):
      try c.encode(Kind.reply.rawValue, forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encodeIfPresent(result, forKey: .result)
      try c.encodeIfPresent(error, forKey: .error)
    case .watch(let threadId):
      try c.encode(Kind.watch.rawValue, forKey: .type)
      try c.encode(threadId, forKey: .threadId)
    case .unwatch(let threadId):
      try c.encode(Kind.unwatch.rawValue, forKey: .type)
      try c.encode(threadId, forKey: .threadId)
    case .watching(let threadIds):
      try c.encode(Kind.watching.rawValue, forKey: .type)
      try c.encode(threadIds, forKey: .threadIds)
    case .event(let event):
      try c.encode(Kind.event.rawValue, forKey: .type)
      try c.encode(event, forKey: .event)
    case .streamGap(let threadId):
      try c.encode(Kind.streamGap.rawValue, forKey: .type)
      try c.encode(threadId, forKey: .threadId)
    case .presence(let hosts):
      try c.encode(Kind.presence.rawValue, forKey: .type)
      try c.encode(hosts, forKey: .hosts)
    case .error(let code, let message, let details):
      try c.encode(Kind.error.rawValue, forKey: .type)
      try c.encode(code, forKey: .code)
      try c.encode(message, forKey: .message)
      try c.encodeIfPresent(details, forKey: .details)
    }
  }
}

/// The relay's numbers, equal to the hub's constants in `b4hub-core`'s `relay.rs`.
public enum RelayLimits {
  /// How often a device sends `ping`.
  public static let heartbeatSeconds = 10
  /// A link silent for this long is dead, on either end.
  public static let deadLink = Duration.seconds(30)
  /// How long a command stays valid after the hub stamps it.
  public static let commandDeadline = Duration.seconds(10)
  /// How long the hub waits for a reply to `turn.send` and `thread.start`.
  public static let replyWaitStart = Duration.seconds(30)
  /// How long the hub waits for a reply to every other method.
  public static let replyWaitOther = Duration.seconds(15)
  /// How long `turn.interrupt` and `request.respond` may be held for an offline owner.
  public static let holdWindow = Duration.seconds(60)
  /// How long a `thread.start` result routes by thread id before the synced row exists.
  public static let pendingThreadTTL = Duration.seconds(300)
  /// The largest frame a client may send, in bytes.
  public static let clientFrameMax = 65_536
  /// The largest frame a host may send, in bytes.
  public static let hostFrameMax = 262_144
  /// The most threads one client link may watch.
  public static let watchMax = 4
  /// The most commands held at once for one offline host.
  public static let heldMax = 32
  /// The outbound frames queued for one link before a client's events are dropped.
  public static let linkQueue = 256
  /// The event kinds the hub forwards to watching clients, and no others.
  public static let forwardedEventKinds: [EventKind] = [
    .turnAcknowledged, .turnStateChanged, .turnFinished, .messageStarted, .messageDelta,
    .messageCompleted, .toolStarted, .toolCompleted, .runtimeRequestOpened, .runtimeRequestResolved,
  ]
}
