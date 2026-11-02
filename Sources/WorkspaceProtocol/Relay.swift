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
/// implementation for both apps; the Mac builds it here, and the phone's parser joins it with its
/// validation rules.
public enum PairLink {
  public static let scheme = "b4app"
  public static let host = "pair"

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
    let text = "\(scheme)://\(host)?hub=\(escaped(url))&code=\(escaped(code))"
    guard let link = URL(string: text) else {
      // Unreachable: the prefix is fixed and both values are escaped to unreserved characters.
      preconditionFailure("a pairing link built from escaped parts is always a URL")
    }
    return link
  }
}
