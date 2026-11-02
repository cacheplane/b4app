import Foundation

/// One plan window as the runtime reported it. `usedPercent` is not clamped: Claude reports use past a
/// window's cap (above 100). `resetsAt` is ISO-8601 UTC.
public struct UsageWindow: Codable, Sendable, Equatable {
  public var usedPercent: Double
  public var windowMinutes: Int?
  public var resetsAt: String?

  public init(usedPercent: Double, windowMinutes: Int? = nil, resetsAt: String? = nil) {
    self.usedPercent = usedPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
  }
}

/// A connection's plan allowance at one moment: the 5-hour and weekly windows Codex and Claude report.
/// `blocked` is the runtime's own word that ordinary use is refused now, whatever the percentages say.
public struct UsageReading: Codable, Sendable, Equatable {
  public var fiveHour: UsageWindow?
  public var weekly: UsageWindow?
  public var blocked: Bool
  public var planType: String?
  /// When the runtime reported it. Claude reports only during a turn, so this can be old.
  public var observedAt: String

  public init(
    fiveHour: UsageWindow? = nil, weekly: UsageWindow? = nil, blocked: Bool = false, planType: String? = nil,
    observedAt: String
  ) {
    self.fiveHour = fiveHour
    self.weekly = weekly
    self.blocked = blocked
    self.planType = planType
    self.observedAt = observedAt
  }
}

/// Tokens a B4 connection used, summed from its finished turns: since local midnight and since the start
/// of the local week (Monday). `day` and `weekStart` name the Mac's local day and week the figures
/// cover (`yyyy-MM-dd`), so a phone that reads them later can tell "today" from an earlier day.
public struct TokenTotals: Codable, Sendable, Equatable {
  public var today: Int
  public var week: Int
  public var day: String?
  public var weekStart: String?

  public init(today: Int, week: Int, day: String? = nil, weekStart: String? = nil) {
    self.today = today
    self.week = week
    self.day = day
    self.weekStart = weekStart
  }
}

/// A local calendar day and the Monday that starts its week, as `yyyy-MM-dd`.
public enum UsageDay {
  public static func local(
    _ date: Date, calendar base: Calendar = .current
  ) -> (day: String, weekStart: String) {
    var calendar = base
    calendar.firstWeekday = 2
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    return (string(date, calendar), string(start, calendar))
  }

  private static func string(_ date: Date, _ calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}

/// What `usage.read` returns for one connection: a plan reading (Codex, Claude) or token totals (B4).
/// Nil means nothing has been reported; the UI never draws a guess.
public struct ConnectionUsage: Codable, Sendable, Equatable, Identifiable {
  public var connectionId: String
  public var reading: UsageReading?
  public var tokens: TokenTotals?
  public var id: String { connectionId }

  public init(connectionId: String, reading: UsageReading? = nil, tokens: TokenTotals? = nil) {
    self.connectionId = connectionId
    self.reading = reading
    self.tokens = tokens
  }
}

/// Every connection's latest usage, stored on the Mac only.
public enum UsageRead: WorkspaceCommand {
  public static let method = Method.usageRead
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var usage: [ConnectionUsage]
    public init(usage: [ConnectionUsage]) { self.usage = usage }
  }
}

/// Change what keeps a connection's identity: its label, and a B4 endpoint's credential reference.
/// Another endpoint or route is another connection (spec 5.2, D-032), so neither can change here.
public enum ConnectionUpdate: WorkspaceCommand {
  public static let method = Method.connectionUpdate
  public struct Params: Codable, Sendable, Equatable {
    public var connectionId: String
    public var label: String?
    /// A `secret:` reference from `credential.add`; B4 connections only.
    public var authReference: String?
    /// Drop the connection's credential; B4 connections only.
    public var clearAuth: Bool?

    public init(
      connectionId: String, label: String? = nil, authReference: String? = nil, clearAuth: Bool? = nil
    ) {
      self.connectionId = connectionId
      self.label = label
      self.authReference = authReference
      self.clearAuth = clearAuth
    }
  }
  public typealias Result = ConnectionAdd.Result
}

/// Delete a credential no connection uses: the form stores a key before it adds or edits the
/// connection, and takes the key back when that fails. A key a connection uses is kept.
public enum CredentialRemove: WorkspaceCommand {
  public static let method = Method.credentialRemove
  public struct Params: Codable, Sendable, Equatable {
    public var reference: String
    public init(reference: String) { self.reference = reference }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var removed: Bool
    public init(removed: Bool) { self.removed = removed }
  }
}

extension AdapterEvent {
  /// The event with the whole connection in `payload["connection"]`, so every client sees a rename or a
  /// new key reference, not only the status.
  public func carrying(_ connection: Connection) throws -> AdapterEvent {
    var event = self
    var payload = event.payload.objectValue ?? [:]
    payload["connection"] = try JSONValue(encoding: connection)
    event.payload = .object(payload)
    return event
  }

  /// A runtime reported its plan allowance (Codex's `account/rateLimits/*`, Claude's `rate_limit_event`).
  public static func usageChanged(
    connectionId: String, reading: UsageReading, adapterGeneration: Int = 0
  ) throws -> AdapterEvent {
    AdapterEvent(
      kind: .usageChanged, connectionId: connectionId, adapterGeneration: adapterGeneration,
      payload: ["reading": try JSONValue(encoding: reading)])
  }
}
