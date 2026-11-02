import Foundation

/// Create a thread and send its first turn in one step. Reachable only through the relay (the phone
/// mints `threadId`; the command id is the turn's operationId), so a retry lands on the same thread and
/// the same turn. `folder` is required for Codex and Claude and must be one of the project's folders;
/// it is absent for a local B4 connection, whose thread is bound to its route.
public enum ThreadStart: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var projectId: String
    public var connectionId: String
    public var folder: String?
    public var text: String
    public init(
      threadId: String, projectId: String, connectionId: String, folder: String? = nil, text: String
    ) {
      self.threadId = threadId
      self.projectId = projectId
      self.connectionId = connectionId
      self.folder = folder
      self.text = text
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var thread: ConversationThread
    public var turn: Turn
    public init(thread: ConversationThread, turn: Turn) {
      self.thread = thread
      self.turn = turn
    }
  }
  public static let method = Method.threadStart
}

/// Settle a send whose reply never came: `in_flight` while the Mac is still running it, `found` with
/// the turn once a turn has that operationId, otherwise `none`. Read-only, and only relayed.
public enum TurnLookup: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var operationId: String
    public var threadId: String
    public init(operationId: String, threadId: String) {
      self.operationId = operationId
      self.threadId = threadId
    }
  }
  public enum State: String, Codable, Sendable, Equatable {
    case found
    case inFlight = "in_flight"
    case none
  }
  public struct Result: Codable, Sendable, Equatable {
    public var state: State
    public var turn: Turn?
    public init(state: State, turn: Turn? = nil) {
      self.state = state
      self.turn = turn
    }
  }
  public static let method = Method.turnLookup
}

// MARK: - Presence (M8c)

/// One Mac as the phone sees it, from the hub's `presence` frame. `lastSeenAt` is the last frame the hub
/// heard from it, already moved onto the phone's clock (the hub's time less the link's measured offset),
/// so the phone can compare it with its own `Date()`.
public struct HostPresence: Codable, Sendable, Equatable {
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

/// Presence as `events.snapshot` carries it, so a model that connects after the events were emitted
/// still knows them: the phone's link, and every Mac last reported while it was `connected`.
public struct PresenceSnapshot: Codable, Sendable, Equatable {
  public var link: HubLinkStatus.State
  public var hosts: [HostPresence]

  public init(link: HubLinkStatus.State, hosts: [HostPresence]) {
    self.link = link
    self.hosts = hosts
  }
}

extension AdapterEvent {
  /// `host.presence`. `payload.link` is the phone's own hub link (`connected`, `connecting`, or
  /// `offline`); `payload.host` is one Mac's presence, absent when the event only reports the link (or
  /// carries the whole set as `payload.hosts`). While the link is not `connected`, every host's presence
  /// is unknown.
  public static func hostPresence(_ host: HostPresence?, link: HubLinkStatus.State) throws -> AdapterEvent {
    var payload: [String: JSONValue] = ["link": .string(link.rawValue)]
    if let host { payload["host"] = try JSONValue(encoding: host) }
    return AdapterEvent(kind: .hostPresence, connectionId: "", payload: .object(payload))
  }

  /// `host.presence` for a whole presence frame: `payload.hosts` is every Mac of the user's the hub
  /// reported, so a Mac missing from it (revoked) is no longer known.
  public static func hostPresence(hosts: [HostPresence], link: HubLinkStatus.State) throws -> AdapterEvent {
    AdapterEvent(
      kind: .hostPresence, connectionId: "",
      payload: ["link": .string(link.rawValue), "hosts": try JSONValue(encoding: hosts)])
  }

  /// The whole set of Macs a `host.presence` event reports, when it reports one.
  public var presenceHosts: [HostPresence]? {
    guard kind == .hostPresence else { return nil }
    return try? payload["hosts"]?.decode([HostPresence].self)
  }

  /// The Mac a `host.presence` event is about, if any.
  public var presenceHost: HostPresence? {
    guard kind == .hostPresence else { return nil }
    return try? payload["host"]?.decode(HostPresence.self)
  }

  /// The phone's hub link a `host.presence` event reports.
  public var presenceLink: HubLinkStatus.State? {
    guard kind == .hostPresence else { return nil }
    return payload["link"]?.stringValue.flatMap(HubLinkStatus.State.init(rawValue:))
  }
}

// MARK: - Pairing and settings (M8c)

/// Mint a code that pairs a phone and start watching for the phone to use it. The answer is the only
/// place the code appears: the coordinator does not log it, store it, or answer it again (the router
/// never caches this method's answer, even under an `operationId`). `url` is the hub's public URL, or
/// the URL this Mac joined with. Refused with `protocol_invalid` "Join a hub first" when the Mac has not
/// joined, and `rate_limited` (`details.retryAfterMs`) past ten codes an hour.
public enum HubPair: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var url: String
    public var code: String
    public var expiresAt: String
    public init(url: String, code: String, expiresAt: String) {
      self.url = url
      self.code = code
      self.expiresAt = expiresAt
    }
    /// Never prints the code.
    public var description: String { "HubPair.Result(url: \(url), expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
  }
  public static let method = Method.hubPair
}

/// Where the latest `hub.pair` stands: `waiting` for the phone, `paired` once a new iOS device has
/// appeared at the hub (with its name), `expired` once the code's five minutes have passed, `none`
/// when no code has been minted since the coordinator started or since `hub leave`.
public enum HubPairStatus: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
      case waiting, paired, expired, none

      /// A state this build does not know (a newer coordinator's) reads as `none`.
      public init(from decoder: Decoder) throws {
        self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .none
      }
    }
    public var state: State
    public var deviceName: String?
    public init(state: State, deviceName: String? = nil) {
      self.state = state
      self.deviceName = deviceName
    }
  }
  public static let method = Method.hubPairStatus
}

/// The Mac's own preferences, kept in the coordinator's local `settings` table and never synced.
/// `keepAwake` is on until set off.
public enum SettingsRead: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var keepAwake: Bool
    public init(keepAwake: Bool) {
      self.keepAwake = keepAwake
    }
  }
  public static let method = Method.settingsRead
}

/// Change a preference; a field left out is left alone. The answer is the settings as they now stand.
public enum SettingsUpdate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var keepAwake: Bool?
    public init(keepAwake: Bool? = nil) {
      self.keepAwake = keepAwake
    }
  }
  public typealias Result = SettingsRead.Result
  public static let method = Method.settingsUpdate
}

// MARK: - The pairing link (M8c)

/// The link a Mac shows as a QR code and the phone opens: `b4app://pair?hub=<URL>&code=<code>`. One
/// implementation for both apps; the Mac builds it with `make`, and the phone reads it with `parse`.
///
/// A parsed link is only an offer: the phone asks before it enrolls (the code is a credential, so a
/// `PairLink` is held in view state only, never logged).
public struct PairLink: Sendable, Equatable {
  public static let linkScheme = "b4app"
  public static let linkHost = "pair"
  /// The enrollment code's alphabet (no vowels, `Y`, `0`, or `1`), as the hub mints it.
  public static let codeAlphabet = Set("BCDFGHJKLMNPQRSTVWXZ23456789")
  public static let codeLength = 8

  /// The hub's base URL, as `HubURL.validate` returns it.
  public let hub: URL
  /// The one-time enrollment code, upper case.
  public let code: String

  public init(hub: URL, code: String) {
    self.hub = hub
    self.code = code
  }

  /// The hub's host, for the confirmation prompt.
  public var host: String { hub.host(percentEncoded: false) ?? hub.absoluteString }

  /// Everything but RFC 3986's unreserved characters is escaped, so the hub's `:`, `/`, `?`, `&`, `#`
  /// and `%` stay inside the one `hub` value.
  private static let unreserved: CharacterSet = {
    var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    set.insert(charactersIn: "-._~")
    return set
  }()

  private static func escaped(_ value: String) -> String {
    // Escaping with a fixed ASCII set cannot fail.
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }

  /// The pairing link for a hub's URL and a one-time code. The code is a credential: the caller must not
  /// log the result.
  public static func make(url: String, code: String) -> URL {
    let text = "\(linkScheme)://\(linkHost)?hub=\(escaped(url))&code=\(escaped(code))"
    guard let link = URL(string: text) else {
      // Unreachable: the prefix is fixed and both values are escaped to unreserved characters.
      preconditionFailure("a pairing link built from escaped parts is always a URL")
    }
    return link
  }

  /// `b4app://pair`, whatever it carries: the links `parse` is the judge of. Other `b4app` links (a
  /// `b4app://thread/<id>`, which is `ThreadLink`'s) are not.
  public static func isPairLink(_ url: URL) -> Bool {
    url.scheme?.lowercased() == linkScheme && url.host(percentEncoded: false)?.lowercased() == linkHost
  }

  /// The offer a pairing link makes, or nil when it is not one this phone may act on: another scheme or
  /// host, a user, port, or path on the link; a missing, repeated, or malformed hub or code; a hub that
  /// `HubURL.validate` refuses (https only, http for localhost, `127.0.0.1`, and `::1`) or that carries
  /// credentials. Nothing here makes a request.
  public static func parse(_ url: URL) -> PairLink? {
    guard isPairLink(url), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty || parts.path == "/",
      parts.fragment == nil
    else { return nil }
    let items = parts.queryItems ?? []
    func only(_ name: String) -> String? {
      let values = items.filter { $0.name == name }
      guard values.count == 1, let value = values[0].value, !value.isEmpty else { return nil }
      return value
    }
    guard let hubText = only("hub"), let codeText = only("code"),
      let hub = try? HubURL.validate(hubText)
    else { return nil }
    guard let hubParts = URLComponents(url: hub, resolvingAgainstBaseURL: false),
      hubParts.user == nil, hubParts.password == nil
    else { return nil }
    // Checked before upper-casing, which can lengthen a string ("ß" becomes "SS"): exactly eight ASCII
    // scalars, whose upper case is then the same length.
    let scalars = codeText.unicodeScalars
    guard scalars.count == codeLength, scalars.allSatisfy(\.isASCII) else { return nil }
    let code = codeText.uppercased()
    guard code.count == codeLength, code.allSatisfy(codeAlphabet.contains) else { return nil }
    return PairLink(hub: hub, code: code)
  }
}
