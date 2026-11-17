import Foundation
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

extension Harness {
  func usage(_ connectionId: String) async throws -> ConnectionUsage? {
    try await client.request(UsageRead.self, EmptyParams()).usage.first { $0.connectionId == connectionId }
  }

  func update(_ params: ConnectionUpdate.Params) async throws -> ConnectionAdd.Result {
    try await client.request(
      ConnectionUpdate.self, params,
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }

  func storeCredential(_ value: String) async throws -> String {
    try await client.request(
      CredentialAdd.self, CredentialAdd.Params(label: "test", value: value),
      options: RequestOptions(operationId: UUID().uuidString)
    ).reference
  }

  func inspect(_ connectionId: String) async throws -> ConnectionAdd.Result {
    try await client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: connectionId),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }
}

/// A secret store whose delete always fails, as a locked Keychain can.
actor RefusingRemoveStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  private(set) var removals = 0
  func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  func remove(_ ref: SecretRef) async throws -> Bool {
    removals += 1
    throw WorkspaceError(.internalError, "The Keychain refused the delete.")
  }
}

@Suite(.serialized) struct UsageTests {
  @Test func tokenBoundariesAreLocalMidnightAndMonday() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
    // Sunday 2026-11-01 18:00 in Denver, the day daylight time ends: midnight was still UTC-6.
    let now = try #require(Timestamp.date(from: "2026-11-02T01:00:00.000Z"))
    let (today, week) = SessionService.tokenBoundaries(now: now, calendar: calendar)
    #expect(today == "2026-11-01T06:00:00.000Z")
    #expect(week == "2026-10-26T06:00:00.000Z")
  }

  @Test func codexCheckStoresUsage() async throws {
    let h = try await Harness.start(
      inspectionObservation: InspectionRequestObservation(caseID: .codexUsage))
    let codex = try await h.addCodex()
    let usage = try #require(try await h.usage(codex.id))
    #expect(usage.reading?.fiveHour?.usedPercent == 62)
    #expect(usage.reading?.weekly?.usedPercent == 31)
    #expect(usage.reading?.planType == "pro")
    #expect(usage.tokens == nil)
    try await h.events.waitFor { $0.kind == .usageChanged && $0.connectionId == codex.id }
    await h.stop()
  }

  @Test func claudeTurnStoresUsage() async throws {
    let h = try await Harness.start()
    let claude = try await h.addClaude()
    #expect(try await h.usage(claude.id)?.reading == nil)
    let thread = try await h.newThread(claude)
    let turn = try await h.send(thread, "hello")
    _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    try await h.events.waitFor { $0.kind == .usageChanged && $0.connectionId == claude.id }
    let reading = try #require(try await h.usage(claude.id)?.reading)
    #expect(reading.fiveHour?.usedPercent == 91)
    #expect(reading.weekly?.usedPercent == 48)
    await h.stop()
  }

  @Test func storedHistoricalTokensSumIntoTodayAndWeek() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await Harness.start(adapterFactory: witness.makeFactory())
    let db = h.coordinator.database
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(db)
    #expect(try await h.usage(b4.id)?.tokens == nil)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      db, connection: b4, status: .terminal, pending: false)
    // A failed historical turn without a stored token fact still has no reported figure.
    _ = try db.updateTurn(id: history.turns[0].id) { $0.outcome = .failed }
    #expect(try await h.usage(b4.id)?.tokens == nil)
    let at = Timestamp.now()
    try db.recordTokens(turnId: history.turns[0].id, connectionId: b4.id, total: 0, at: at)
    #expect(try await h.usage(b4.id)?.tokens?.today == 0)
    for (id, total) in [("stored-hello", 7), ("stored-tool", 15)] {
      _ = try db.insertTurn(
        Turn(id: id, threadId: history.thread.id, operationId: id, status: .terminal, outcome: .completed))
      try db.recordTokens(turnId: id, connectionId: b4.id, total: total, at: at)
      try db.recordTokens(turnId: id, connectionId: b4.id, total: 999, at: at)
    }
    let before = try HistoricalCoordinatorFixture.snapshot(db, threadId: history.thread.id)
    #expect(try await h.usage(b4.id)?.tokens?.today == 22)
    #expect(try await h.usage(b4.id)?.tokens?.week == 22)
    _ = try await h.client.request(
      ThreadReconcile.self, .init(threadId: history.thread.id),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    let retainedFacts1 = try HistoricalCoordinatorFixture.snapshot(db, threadId: history.thread.id) == before
    #expect(retainedFacts1)
    #expect(try await h.usage(b4.id)?.tokens?.today == 22)
    #expect(try await h.usage(b4.id)?.tokens?.week == 22)
    #expect(witness.count == 0)
    await h.stop()
  }

  @Test func unreachableCurrentRuntimeRetriesThenFails() async throws {
    let state = CurrentCoordinatorFixtureState()
    let witness = HistoricalFactoryWitness()
    let h = try await Harness.start(
      adapterFactory: witness.makeFactory(base: { _, _, _, _ in
        CurrentCoordinatorFixtureAdapter(state: state)
      }))
    let result = try await h.client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(
        kind: .codex, label: "Controlled offline runtime", executablePath: "/fixture/codex"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60)))
    #expect(result.connection.status == .offline || result.connection.status == .error)
    // The command response can reach the client before the collector consumes its last event.
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == result.connection.id
        && $0.payload["attempt"]?.numberValue == 3
    }
    let attempts = await h.events.events.map(\.event)
      .filter { $0.kind == .connectionChanged && $0.connectionId == result.connection.id }
      .compactMap { $0.payload["attempt"]?.numberValue.map(Int.init) }
    #expect(attempts == [1, 2, 3])
    #expect(await state.inspections == 3)
    #expect(try h.coordinator.database.connection(id: result.connection.id)?.status == .offline)
    let historical = try HistoricalCoordinatorFixture.seedEarlierConnection(h.coordinator.database)
    let before = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: historical)
    try await HistoricalCoordinatorFixture.expectCutover { _ = try await h.inspect(historical.id) }
    #expect(await state.inspections == 3)
    #expect(witness.count == 0)
    let noHistoricalRetries = !(await h.events.events).contains {
      $0.event.connectionId == historical.id && $0.event.payload["attempt"] != nil
    }
    #expect(noHistoricalRetries)
    let unchanged =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: before.thread.id) == before
    #expect(unchanged)
    await h.stop()
  }

  @Test func incompatibleCurrentRuntimeDoesNotRetry() async throws {
    let state = CurrentCoordinatorFixtureState(incompatible: true)
    let h = try await Harness.start(adapterFactory: { _, _, _, _ in
      CurrentCoordinatorFixtureAdapter(state: state)
    })
    let workflow = try await h.client.request(
      ConnectionAdd.self,
      .init(kind: .codex, label: "Incompatible fixture", executablePath: "/fixture/codex"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(workflow.connection.status == .incompatible)
    // The command response can reach the client before the collector consumes its events.
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == workflow.connection.id
        && $0.payload["attempt"]?.numberValue == 1
    }
    let attempts = await h.events.events.map(\.event)
      .filter { $0.kind == .connectionChanged && $0.connectionId == workflow.connection.id }
      .compactMap { $0.payload["attempt"]?.numberValue }
    #expect(attempts == [1])
    await h.stop()
    #expect(await state.inspections == 1)
  }

  @Test func labelEditSucceedsAndRetiredKeyEditsAreAtomic() async throws {
    let secrets = FixtureCredentialStore()
    let witness = HistoricalFactoryWitness()
    let h = try await Harness.start(secretStore: secrets, adapterFactory: witness.makeFactory())
    let old = try await h.storeCredential("old")
    let replacement = try await h.storeCredential("new")
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(
      h.coordinator.database, label: "Before", authReference: old)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: b4)
    // Label editing remains a real successful command; endpoint key rotation is retired under D240.
    let updated = try await h.update(.init(connectionId: b4.id, label: "  After  "))
    #expect(updated.connection.label == "After")
    #expect(updated.connection.authReference == old)
    #expect(updated.connection.target == b4.target)
    #expect(updated.connection.routeKey == b4.routeKey)
    #expect(updated.connection.profileRevision == b4.profileRevision + 1)
    let before = try HistoricalCoordinatorFixture.snapshot(
      h.coordinator.database, threadId: history.thread.id)
    for params in [
      ConnectionUpdate.Params(connectionId: b4.id, authReference: replacement),
      .init(connectionId: b4.id, clearAuth: true),
      .init(connectionId: b4.id, label: "Must not partially save", authReference: replacement),
      .init(connectionId: b4.id, label: "Must not partially save", clearAuth: true),
    ] {
      try await HistoricalCoordinatorFixture.expectCutover { _ = try await h.update(params) }
      let retainedFacts2 =
        try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: history.thread.id)
        == before
      #expect(retainedFacts2)
    }
    #expect(await secrets.reads == 0)
    #expect(await secrets.removals == 0)
    #expect(await secrets.value(try #require(SecretRef(rawValue: old))) == "old")
    #expect(await secrets.value(try #require(SecretRef(rawValue: replacement))) == "new")
    #expect(witness.count == 0)
    await h.stop()
  }

  @Test func updateRefusesAnUnknownReferenceOrConnection() async throws {
    let h = try await Harness.start()
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(h.coordinator.database)
    for params in [
      ConnectionUpdate.Params(connectionId: b4.id, authReference: "secret:missing"),
      ConnectionUpdate.Params(connectionId: "missing", label: "x"),
    ] {
      do {
        _ = try await h.update(params)
        Issue.record("\(params) must be refused")
      } catch let error as WorkspaceError {
        #expect(error.code == (params.connectionId == "missing" ? .notFound : .unsupportedCapability))
        if params.connectionId == b4.id {
          #expect(error.details?["reason"]?.stringValue == "agent_protocol_cutover")
        }
      }
    }
    let codex = try await h.addCodex()
    let reference = try await h.storeCredential("k")
    do {
      _ = try await h.update(ConnectionUpdate.Params(connectionId: codex.id, authReference: reference))
      Issue.record("a Codex connection takes no credential reference")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    await h.stop()

  }

  @Test func refusedEditsKeepSharedHistoricalCredentials() async throws {
    let secrets = MemorySecretStore()
    let h = try await Harness.start(secretStore: secrets)
    let shared = try await h.storeCredential("shared")
    let first = try HistoricalCoordinatorFixture.seedEarlierConnection(
      h.coordinator.database, id: "one", authReference: shared)
    let second = try HistoricalCoordinatorFixture.seedEarlierConnection(
      h.coordinator.database, id: "two", authReference: shared, enabled: false)
    for params in [
      ConnectionUpdate.Params(connectionId: first.id, clearAuth: true),
      .init(connectionId: first.id, authReference: "secret:missing"),
    ] {
      try await HistoricalCoordinatorFixture.expectCutover { _ = try await h.update(params) }
    }
    let retainedFacts3 = try h.coordinator.database.connection(id: first.id) == first
    #expect(retainedFacts3)
    let retainedFacts4 = try h.coordinator.database.connection(id: second.id) == second
    #expect(retainedFacts4)
    #expect(
      try await h.client.request(
        CredentialRemove.self, .init(reference: shared),
        options: RequestOptions(operationId: UUID().uuidString)
      ).removed == false)
    #expect(try await secrets.read(try #require(SecretRef(rawValue: shared))) == "shared")
    await h.stop()
  }

  @Test func historicalWorkAllowsRenameAndAlwaysRefusesKeyEdits() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await Harness.start(adapterFactory: witness.makeFactory())
    let key = try await h.storeCredential("k")
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(h.coordinator.database)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: b4, status: .running)
    for params in [
      ConnectionUpdate.Params(connectionId: b4.id, authReference: key),
      .init(connectionId: b4.id, clearAuth: true),
    ] {
      try await HistoricalCoordinatorFixture.expectCutover { _ = try await h.update(params) }
      let retainedFacts5 =
        try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: history.thread.id)
        == history
      #expect(retainedFacts5)
    }
    #expect(try await h.update(.init(connectionId: b4.id, label: "Renamed")).connection.label == "Renamed")
    let retainedFacts6 = try h.coordinator.database.turns(threadId: history.thread.id) == history.turns
    #expect(retainedFacts6)
    let retainedFacts7 =
      try h.coordinator.database.pendingRuntimeRequests(threadId: history.thread.id) == history.requests
    #expect(retainedFacts7)
    #expect(witness.count == 0)
    await h.stop()
  }

  /// A background check answers at once and reports through events, so it never holds the socket (the
  /// coordinator serves one client's requests in order) while it retries.
  @Test func aBackgroundCheckAnswersAtOnce() async throws {
    // Six seconds of retries: the two answers below must come back inside them, and a starved CI
    // runner has taken over a second for each (the bounds were 0.8 s and 0.9 s of a 2 s check).
    let state = CurrentCoordinatorFixtureState()
    let h = try await Harness.start(
      checkRetryDelays: [.seconds(3), .seconds(3)],
      adapterFactory: { _, _, _, _ in CurrentCoordinatorFixtureAdapter(state: state) })
    let added = try await h.client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(kind: .codex, label: "Offline fixture", executablePath: "/fixture/codex"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60)))
    let clock = ContinuousClock()
    let started = clock.now
    let startedAt = Date()
    let answer = try await h.client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: added.connection.id, background: true),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(clock.now - started < .seconds(5))
    #expect(answer.connection.id == added.connection.id)
    _ = try await h.client.request(
      ConnectionInspect.self, .init(connectionId: added.connection.id, background: true),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    // The socket is free: another request answers while the check retries.
    _ = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(clock.now - started < .seconds(5))
    // The check's result arrives later, as the closing `connection.changed` after its three tries.
    let attempts = try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == added.connection.id
        && $0.payload["attempt"]?.numberValue == 3
        && (Timestamp.date(from: $0.at) ?? .distantPast) > startedAt
    }
    #expect(attempts.payload["attempts"]?.numberValue == 3)
    #expect(clock.now - started > .seconds(5))
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == added.connection.id
        && $0.payload["status"]?.stringValue == "offline"
        && $0.payload["connection"] != nil
        && (Timestamp.date(from: $0.at) ?? .distantPast) > startedAt
    }
    #expect(await state.inspections == 6, "one add check plus one shared background check")
    await h.stop()
  }

  @Test func aRenameCarriesTheConnection() async throws {
    let h = try await Harness.start()
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(h.coordinator.database, label: "Old")
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: b4)
    let updated = try await h.update(ConnectionUpdate.Params(connectionId: b4.id, label: "New"))
    // Every client hears the new name, not only the one that asked.
    let event = try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == b4.id
        && $0.payload["connection"]?["label"]?.stringValue == "New"
    }
    let announced = try #require(try event.payload["connection"]?.decode(Connection.self))
    let exactAnnouncement = announced == updated.connection
    #expect(exactAnnouncement)
    var expected = b4
    expected.label = "New"
    expected.profileRevision += 1
    expected.updatedAt = updated.connection.updatedAt
    let expectedHistory = HistoricalCoordinatorFixture.Snapshot(
      connection: expected, thread: history.thread, turns: history.turns, items: history.items,
      requests: history.requests, draft: history.draft)
    let unchangedHistory =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: history.thread.id)
      == expectedHistory
    #expect(unchangedHistory)
    await h.stop()
  }

  @Test func credentialRemoveKeepsASecretInUse() async throws {
    let secrets = MemorySecretStore()
    let h = try await Harness.start(secretStore: secrets)
    let used = try await h.storeCredential("used")
    let spare = try await h.storeCredential("spare")
    _ = try HistoricalCoordinatorFixture.seedEarlierConnection(
      h.coordinator.database, authReference: used, enabled: false)
    func remove(_ reference: String) async throws -> Bool {
      try await h.client.request(
        CredentialRemove.self, CredentialRemove.Params(reference: reference),
        options: RequestOptions(operationId: UUID().uuidString)
      ).removed
    }
    #expect(try await remove(used) == false)
    #expect(try await secrets.read(try #require(SecretRef(rawValue: used))) == "used")
    #expect(try await remove(spare))
    #expect(try await secrets.read(try #require(SecretRef(rawValue: spare))) == nil)
    await h.stop()
  }

  /// D240 retires successful key swaps; refusal must not reach even a failing cleanup store.
  @Test func retiredKeyEditNeverAttemptsOldKeyCleanup() async throws {
    let secrets = RefusingRemoveStore()
    let h = try await Harness.start(secretStore: secrets)
    let old = try await h.storeCredential("old")
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(
      h.coordinator.database, authReference: old)
    let replacement = try await h.storeCredential("new")
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await h.update(.init(connectionId: b4.id, label: "No partial edit", authReference: replacement))
    }
    let retainedFacts8 = try h.coordinator.database.connection(id: b4.id) == b4
    #expect(retainedFacts8)
    #expect(await secrets.removals == 0)
    #expect(try await secrets.read(try #require(SecretRef(rawValue: old))) == "old")
    #expect(try await secrets.read(try #require(SecretRef(rawValue: replacement))) == "new")
    // Instrumentation control on a separate store: this deliberate fixture call is not a
    // production cleanup attempt. The production store must remain untouched above and below.
    let cleanupProbe = RefusingRemoveStore()
    let probeReference = SecretRef.make()
    try await cleanupProbe.put(probeReference, value: "fixture cleanup witness")
    do {
      _ = try await cleanupProbe.remove(probeReference)
      Issue.record("The refusing fixture must throw its fixed safe error.")
    } catch let error as WorkspaceError {
      #expect(error.code == .internalError)
      #expect(error.message == "The Keychain refused the delete.")
    }
    #expect(await cleanupProbe.removals == 1)
    #expect(try await cleanupProbe.read(probeReference) == "fixture cleanup witness")
    #expect(await secrets.removals == 0)
    await h.stop()
  }

  @Test func usageIsWrittenForThePhone() async throws {
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let synced = try #require(try h.coordinator.database.syncedUsage(connectionId: codex.id))
    #expect(synced.reading?.fiveHour?.usedPercent == 62)
    let db = h.coordinator.database
    let b4 = try HistoricalCoordinatorFixture.seedEarlierConnection(db)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      db, connection: b4, status: .terminal, pending: false)
    #expect(try db.syncedUsage(connectionId: b4.id) == nil)
    try db.recordTokens(turnId: history.turns[0].id, connectionId: b4.id, total: 7, at: Timestamp.now())
    // Projection of stored history, not new legacy runtime event ingestion.
    await h.coordinator.sessions.syncUsage(connectionId: b4.id)
    let tokens = try #require(try db.syncedUsage(connectionId: b4.id)?.tokens)
    #expect(tokens.today == 7)
    #expect(tokens.week == 7)
    #expect(tokens.day == UsageDay.local(Date()).day)
    let before = try db.changes(after: 0).filter { $0.table == "connectionUsage" && $0.rowId == b4.id }
    await h.coordinator.sessions.syncUsage(connectionId: b4.id)
    let retainedFacts9 =
      try db.changes(after: 0).filter { $0.table == "connectionUsage" && $0.rowId == b4.id } == before
    #expect(retainedFacts9)
    await h.stop()
  }
}
