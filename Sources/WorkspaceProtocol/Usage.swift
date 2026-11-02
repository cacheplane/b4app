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
/// of the local week (Monday).
public struct TokenTotals: Codable, Sendable, Equatable {
  public var today: Int
  public var week: Int

  public init(today: Int, week: Int) {
    self.today = today
    self.week = week
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

extension AdapterEvent {
  /// A runtime reported its plan allowance (Codex's `account/rateLimits/*`, Claude's `rate_limit_event`).
  public static func usageChanged(
    connectionId: String, reading: UsageReading, adapterGeneration: Int = 0
  ) throws -> AdapterEvent {
    AdapterEvent(
      kind: .usageChanged, connectionId: connectionId, adapterGeneration: adapterGeneration,
      payload: ["reading": try JSONValue(encoding: reading)])
  }
}
