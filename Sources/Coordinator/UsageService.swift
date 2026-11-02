import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Usage, checks that retry, and editing a connection (settings connections design). Plan readings
/// and B4 token counts stay on this Mac (migration 0006); nothing here reaches the hub.
extension SessionService {
  // MARK: - Usage

  public func usageRead() throws -> UsageRead.Result {
    let readings = try db.usageReadings()
    let (today, week) = Self.tokenBoundaries(now: Date())
    let usage = try db.listConnections().map { connection -> ConnectionUsage in
      switch connection.kind {
      case .codex, .claude:
        return ConnectionUsage(connectionId: connection.id, reading: readings[connection.id])
      case .b4:
        return ConnectionUsage(
          connectionId: connection.id,
          tokens: TokenTotals(
            today: try db.tokenTotals(connectionId: connection.id, since: today),
            week: try db.tokenTotals(connectionId: connection.id, since: week)))
      }
    }
    return UsageRead.Result(usage: usage)
  }

  /// Local midnight and the start of the local week (Monday), as UTC timestamps the stored ones sort
  /// against.
  static func tokenBoundaries(now: Date, calendar base: Calendar = .current) -> (today: String, week: String)
  {
    var calendar = base
    calendar.firstWeekday = 2
    let today = calendar.startOfDay(for: now)
    let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
    return (Timestamp.string(from: today), Timestamp.string(from: week))
  }

  /// A runtime reported its plan windows: keep the latest per connection.
  func storeUsage(_ event: AdapterEvent) throws {
    guard let reading = try event.payload["reading"]?.decode(UsageReading.self) else { return }
    try db.saveUsage(connectionId: event.connectionId, reading: reading)
  }

  /// A finished B4 turn's summed token count (`turn.finished.usage`), counted once per turn.
  func recordTokens(_ event: AdapterEvent, turn: Turn, connectionId: String) throws {
    guard let total = event.payload["usage"]?["usage_metadata"]?["total_tokens"]?.numberValue,
      try db.connection(id: connectionId)?.kind == .b4
    else { return }
    try db.recordTokens(turnId: turn.id, connectionId: connectionId, total: Int(total), at: Timestamp.now())
  }

  /// After a check that found the runtime signed in, ask it for its plan windows when it can answer on
  /// demand (Codex). A failed read leaves the last reading in place.
  func refreshUsage(connectionId: String, adapter: any AgentAdapter) async {
    guard let reporter = adapter as? any UsageReporting,
      let reading = try? await reporter.readUsage(),
      (try? db.saveUsage(connectionId: connectionId, reading: reading)) != nil,
      let event = try? AdapterEvent.usageChanged(connectionId: connectionId, reading: reading)
    else { return }
    await context.eventLog.publish(event)
  }

  // MARK: - Checks

  /// Inspect, retrying while the runtime is unreachable (offline, or `endpoint_unavailable`), after each
  /// of `checkRetryDelays`. Each try is announced on `connection.changed` with its attempt number, so a
  /// card can show "try 2 of 3". A missing executable, a sign-in state, or an incompatible route is an
  /// answer, not a blip, and is never retried.
  func inspectRetrying(
    _ connection: Connection, adapter: any AgentAdapter
  ) async throws -> ConnectionInspection {
    let delays = context.checkRetryDelays
    let attempts = delays.count + 1
    var attempt = 1
    while true {
      await context.eventLog.publish(
        AdapterEvent.connectionChanged(
          connectionId: connection.id, status: .connecting, authStatus: connection.authStatus,
          transport: .disconnected, message: "Checking…", attempt: attempt, attempts: attempts))
      let inspection = try await adapter.inspectConnection()
      let unreachable = inspection.status == .offline || inspection.error?.code == .endpointUnavailable
      guard unreachable, attempt < attempts else { return inspection }
      try await Task.sleep(for: delays[attempt - 1])
      attempt += 1
    }
  }

  // MARK: - Editing

  /// Change what keeps a connection's identity: the label and, for B4, the credential. Another endpoint
  /// or route is another connection (spec 5.2, D-032). A replaced credential's secret is removed once no
  /// connection uses it, and the cached adapter is dropped so the next turn uses the new one.
  public func connectionUpdate(_ params: ConnectionUpdate.Params) async throws -> ConnectionAdd.Result {
    guard let connection = try db.connection(id: params.connectionId) else {
      throw WorkspaceError(.notFound, "Connection \(params.connectionId) does not exist.")
    }
    let label = params.label?.trimmingCharacters(in: .whitespacesAndNewlines)
    let changesAuth = params.authReference != nil || params.clearAuth == true
    if changesAuth, connection.kind != .b4 {
      throw WorkspaceError(.protocolInvalid, "Only a B4 connection takes a credential reference.")
    }
    if let reference = params.authReference {
      guard let ref = SecretRef(rawValue: reference) else {
        throw WorkspaceError(
          .protocolInvalid, "authReference must be a secret: reference returned by `credential add`.")
      }
      guard try await context.secretStore.read(ref) != nil else {
        throw WorkspaceError(.notFound, "Credential \(reference) is not in the credential store.")
      }
    }
    let newReference = params.clearAuth == true ? nil : (params.authReference ?? connection.authReference)
    let newLabel = (label?.isEmpty == false) ? label! : connection.label
    guard newLabel != connection.label || newReference != connection.authReference else {
      return ConnectionAdd.Result(
        connection: connection, inspection: ConnectionInspection(status: connection.status))
    }
    let updated =
      try db.updateConnection(id: connection.id) {
        $0.label = newLabel
        $0.authReference = newReference
        $0.profileRevision += 1
      } ?? connection
    if newReference != connection.authReference {
      await evictAdapter(connectionId: connection.id)
      if let old = connection.authReference.flatMap(SecretRef.init(rawValue:)),
        try !db.listConnections(includeDisabled: true).contains(where: { $0.authReference == old.rawValue })
      {
        _ = try await context.secretStore.remove(old)
      }
      return try await connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
    }
    await context.eventLog.publish(
      AdapterEvent.connectionChanged(
        connectionId: updated.id, status: updated.status, authStatus: updated.authStatus,
        transport: .disconnected))
    return ConnectionAdd.Result(connection: updated, inspection: ConnectionInspection(status: updated.status))
  }

  /// Close a connection's adapter so the next use builds one from the stored profile.
  func evictAdapter(connectionId: String) async {
    pumps.removeValue(forKey: connectionId)?.cancel()
    if let adapter = adapters.removeValue(forKey: connectionId) { await adapter.dispose() }
  }
}
