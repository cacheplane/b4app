import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Usage, checks that retry, and editing a connection (settings connections design). Plan readings and
/// per-turn token counts are kept on this Mac (migration 0006); each connection's current usage is
/// copied to the synced `connectionUsage` table (migration 0007), which reaches the phone.
extension SessionService {
  // MARK: - Usage

  public func usageRead() throws -> UsageRead.Result {
    let readings = try db.usageReadings()
    let now = Date()
    return UsageRead.Result(
      usage: try db.listConnections().map { try usageEntry($0, readings: readings, now: now) })
  }

  /// One connection's usage: its plan reading (Codex, Claude) or its token totals for the local day and
  /// week (B4).
  func usageEntry(
    _ connection: Connection, readings: [String: UsageReading], now: Date
  ) throws
    -> ConnectionUsage
  {
    switch connection.kind {
    case .codex, .claude:
      return ConnectionUsage(connectionId: connection.id, reading: readings[connection.id])
    case .b4, .agentProtocol:
      // A server that has never reported tokens has no figure, rather than zero (D-082).
      guard try db.hasTokenUsage(connectionId: connection.id) else {
        return ConnectionUsage(connectionId: connection.id)
      }
      let (today, week) = Self.tokenBoundaries(now: now)
      let local = UsageDay.local(now)
      return ConnectionUsage(
        connectionId: connection.id,
        tokens: TokenTotals(
          today: try db.tokenTotals(connectionId: connection.id, since: today),
          week: try db.tokenTotals(connectionId: connection.id, since: week), day: local.day,
          weekStart: local.weekStart))
    }
  }

  /// Bring the synced `connectionUsage` row in step with the local tables, so the phone sees the same
  /// usage through the hub. Written only when it moved.
  func syncUsage(connectionId: String) {
    guard let connection = try? db.connection(id: connectionId),
      let readings = try? db.usageReadings(),
      let entry = try? usageEntry(connection, readings: readings, now: Date()),
      entry.reading != nil || entry.tokens != nil
    else { return }
    do {
      try db.saveSyncedUsage(entry)
    } catch {
      logger.error("usage for sync failed: \(String(describing: error), privacy: .public)")
    }
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
    syncUsage(connectionId: event.connectionId)
  }

  /// A finished B4 turn's summed token count (`turn.finished.usage`), counted once per turn.
  func recordTokens(_ event: AdapterEvent, turn: Turn, connectionId: String) throws {
    guard let total = event.payload["usage"]?["usage_metadata"]?["total_tokens"]?.numberValue,
      try db.connection(id: connectionId)?.kind == .b4
    else { return }
    try db.recordTokens(turnId: turn.id, connectionId: connectionId, total: Int(total), at: Timestamp.now())
    syncUsage(connectionId: connectionId)
  }

  /// After a check that found the runtime signed in, ask it for its plan windows when it can answer on
  /// demand (Codex). A failed read leaves the last reading in place.
  func refreshUsage(connectionId: String, adapter: any AgentAdapter) async {
    guard let reporter = adapter as? any UsageReporting,
      let reading = try? await reporter.readUsage(),
      (try? db.saveUsage(connectionId: connectionId, reading: reading)) != nil,
      let event = try? AdapterEvent.usageChanged(connectionId: connectionId, reading: reading)
    else { return }
    syncUsage(connectionId: connectionId)
    await context.eventLog.publish(event)
  }

  // MARK: - Runtime commands

  /// The commands to store after a check; nil keeps what is stored. A runtime that names its
  /// commands in the check (Codex) replaces the list. One that reports them only from a session
  /// (Claude Code) is asked once, while the connection has no list; its sessions keep it after that.
  func commandsToStore(
    _ connection: Connection, inspection: ConnectionInspection, adapter: any AgentAdapter
  ) async -> [RuntimeCommand]? {
    guard inspection.status == .ready, inspection.authStatus == .authenticated else { return nil }
    if let commands = inspection.commands { return RuntimeCommand.normalized(commands) }
    guard connection.commands == nil, let lister = adapter as? any CommandListing else { return nil }
    return try? await lister.readCommands()
  }

  /// Coordinator start: a Codex or Claude Code connection with no command list (one added before the
  /// list existed, so after an upgrade) is checked in the background, which reads it. One that has a
  /// list is left alone; its checks and sessions keep it.
  func readMissingCommands() {
    let missing =
      (try? db.listConnections(includeDisabled: false))?.filter {
        ($0.kind == .codex || $0.kind == .claude) && $0.commands == nil
      }
      ?? []
    for connection in missing { _ = inspectInBackground(connection) }
  }

  /// A session reported what it can run (`commands.changed`). Stored when it names a command the
  /// connection's list does not have (`RuntimeCommand.replacement`), and announced with the connection.
  func storeCommands(_ event: AdapterEvent) async throws {
    guard let reported = try event.payload["commands"]?.decode([RuntimeCommand].self),
      let connection = try db.connection(id: event.connectionId),
      let commands = RuntimeCommand.replacement(stored: connection.commands, reported: reported),
      let updated = try db.updateConnection(id: connection.id, { $0.commands = commands })
    else { return }
    await context.eventLog.publish(
      try AdapterEvent.connectionChanged(
        connectionId: updated.id, status: updated.status, authStatus: updated.authStatus,
        transport: .disconnected
      ).carrying(updated))
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
    do {
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
    } catch {
      // A check that ends early (the runtime threw, or the wait was cancelled) still closes, so no card
      // is left spinning: the connection goes back to what was stored.
      await context.eventLog.publish(
        AdapterEvent.connectionChanged(
          connectionId: connection.id, status: connection.status, authStatus: connection.authStatus,
          transport: .disconnected, message: WorkspaceError.from(error).message))
      throw error
    }
  }

  /// A check the caller does not wait for: it answers with the stored connection at once and reports
  /// through `connection.changed` and `usage.changed`. One check per connection runs at a time.
  func inspectInBackground(_ connection: Connection) -> ConnectionAdd.Result {
    if !runningChecks.contains(connection.id) {
      runningChecks.insert(connection.id)
      Task {
        _ = try? await self.connectionInspect(ConnectionInspect.Params(connectionId: connection.id))
        self.finishCheck(connection.id)
      }
    }
    return ConnectionAdd.Result(
      connection: connection, inspection: ConnectionInspection(status: connection.status))
  }

  private func finishCheck(_ connectionId: String) { runningChecks.remove(connectionId) }

  // MARK: - Editing

  /// Rename a connection without changing its identity or credentials. Retired B4 credential
  /// requests refuse before any secret access or saved edit.
  public func connectionUpdate(_ params: ConnectionUpdate.Params) async throws -> ConnectionAdd.Result {
    guard let connection = try db.connection(id: params.connectionId) else {
      throw WorkspaceError(.notFound, "Connection \(params.connectionId) does not exist.")
    }
    if params.authReference != nil || params.clearAuth == true {
      if connection.kind == .b4 { throw Self.legacyProtocolReadOnlyError }
      throw WorkspaceError(.protocolInvalid, "Credential changes are not available for this connection.")
    }
    let label = params.label?.trimmingCharacters(in: .whitespacesAndNewlines)
    let newLabel = (label?.isEmpty == false) ? label! : connection.label
    guard newLabel != connection.label else {
      return ConnectionAdd.Result(
        connection: connection, inspection: ConnectionInspection(status: connection.status))
    }
    let updated =
      try db.updateConnection(id: connection.id) {
        $0.label = newLabel
        $0.profileRevision += 1
      } ?? connection
    await context.eventLog.publish(
      try AdapterEvent.connectionChanged(
        connectionId: updated.id, status: updated.status, authStatus: updated.authStatus,
        transport: .disconnected
      ).carrying(updated))
    return ConnectionAdd.Result(connection: updated, inspection: ConnectionInspection(status: updated.status))
  }

  /// Delete a credential no connection uses (a key the form stored before an add or edit that then
  /// failed). One a connection uses, even a disabled one, is kept.
  public func credentialRemove(_ params: CredentialRemove.Params) async throws -> CredentialRemove.Result {
    guard let ref = SecretRef(rawValue: params.reference) else {
      throw WorkspaceError(.protocolInvalid, "reference must be a secret: reference.")
    }
    if try db.listConnections(includeDisabled: true).contains(where: { $0.authReference == ref.rawValue }) {
      return CredentialRemove.Result(removed: false)
    }
    return CredentialRemove.Result(removed: try await context.secretStore.remove(ref))
  }

  /// Close a connection's adapter so the next use builds one from the stored profile.
  func evictAdapter(connectionId: String) async {
    pumps.removeValue(forKey: connectionId)?.cancel()
    if let adapter = adapters.removeValue(forKey: connectionId) { await adapter.dispose() }
  }
}
