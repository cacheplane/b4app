import Foundation
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceTestSupport

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
  func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  func remove(_ ref: SecretRef) async throws -> Bool {
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
    let h = try await Harness.start()
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

  @Test func b4TurnsSumIntoTodayAndWeek() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    // Nothing reported yet is no figure, not zero.
    #expect(try await h.usage(b4.id)?.tokens == nil)
    let thread = try await h.newB4Thread(b4)
    let failed = try await h.send(thread, "fail please")
    _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == failed.id }
    try await server.waitForRunToEnd(nativeThreadId: thread.nativeThreadId)
    #expect(try await h.usage(b4.id)?.tokens == nil)
    for text in ["hello", "use a tool"] {
      let turn = try await h.send(thread, text)
      _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
      try await server.waitForRunToEnd(nativeThreadId: thread.nativeThreadId)
    }
    #expect(try await h.usage(b4.id)?.tokens == TokenTotals(today: 22, week: 22))
    _ = try await h.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(try await h.usage(b4.id)?.tokens == TokenTotals(today: 22, week: 22))
    await h.stop()
    await server.stop()
  }

  @Test func unreachableB4RetriesThenFails() async throws {
    let h = try await Harness.start()
    let result = try await h.client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(kind: .b4, label: "Gone", url: "http://127.0.0.1:9", route: "/chat#agent"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60)))
    #expect(result.connection.status == .offline || result.connection.status == .error)
    let attempts = await h.events.events.map(\.event)
      .filter { $0.kind == .connectionChanged && $0.connectionId == result.connection.id }
      .compactMap { $0.payload["attempt"]?.numberValue.map(Int.init) }
    #expect(attempts == [1, 2, 3])
    await h.stop()
  }

  @Test func incompatibleRouteDoesNotRetry() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let workflow = try await h.addB4(server, route: "/dispatch#workflow", label: "Workflow")
    #expect(workflow.connection.status == .incompatible)
    let attempts = await h.events.events.map(\.event)
      .filter { $0.kind == .connectionChanged && $0.connectionId == workflow.connection.id }
      .compactMap { $0.payload["attempt"]?.numberValue }
    #expect(attempts == [1])
    await h.stop()
    await server.stop()
  }

  @Test func updateRenamesAndReplacesTheKey() async throws {
    let server = try await FakeB4.start(environment: ["FAKE_B4_TOKEN": "new"])
    let secrets = MemorySecretStore()
    let h = try await Harness.start(secretStore: secrets)
    let old = try await h.storeCredential("old")
    let b4 = try await h.addB4(server, authReference: old, label: "Before").connection
    let thread = try await h.newB4Thread(b4)
    do {
      _ = try await h.send(thread, "hello")
      Issue.record("the old key must be refused")
    } catch let error as WorkspaceError {
      #expect(error.code == .authRequired)
    }
    let replacement = try await h.storeCredential("new")
    let updated = try await h.update(
      ConnectionUpdate.Params(connectionId: b4.id, label: "  After  ", authReference: replacement))
    #expect(updated.connection.label == "After")
    #expect(updated.connection.authReference == replacement)
    #expect(updated.connection.target == b4.target)
    #expect(updated.connection.routeKey == b4.routeKey)
    #expect(updated.connection.profileRevision == b4.profileRevision + 1)
    #expect(try await secrets.read(try #require(SecretRef(rawValue: old))) == nil)
    let turn = try await h.send(thread, "hello")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let cleared = try await h.update(ConnectionUpdate.Params(connectionId: b4.id, clearAuth: true))
    #expect(cleared.connection.authReference == nil)
    #expect(try await secrets.read(try #require(SecretRef(rawValue: replacement))) == nil)
    await h.stop()
    await server.stop()
  }

  @Test func updateRefusesAnUnknownReferenceOrConnection() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    for params in [
      ConnectionUpdate.Params(connectionId: b4.id, authReference: "secret:missing"),
      ConnectionUpdate.Params(connectionId: "missing", label: "x"),
    ] {
      do {
        _ = try await h.update(params)
        Issue.record("\(params) must be refused")
      } catch let error as WorkspaceError {
        #expect(error.code == .notFound)
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
    await server.stop()
  }

  @Test func updateKeepsASharedSecret() async throws {
    let server = try await FakeB4.start()
    let secrets = MemorySecretStore()
    let h = try await Harness.start(secretStore: secrets)
    let shared = try await h.storeCredential("shared")
    let first = try await h.addB4(server, authReference: shared, label: "One").connection
    _ = try await h.addB4(server, route: "/research#agent", authReference: shared, label: "Two")
    _ = try await h.update(ConnectionUpdate.Params(connectionId: first.id, clearAuth: true))
    #expect(try await secrets.read(try #require(SecretRef(rawValue: shared))) == "shared")
    await h.stop()
    await server.stop()
  }

  @Test func aKeyChangeWaitsForTheRunningTurn() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let key = try await h.storeCredential("k")
    let b4 = try await h.addB4(server, label: "B4").connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "hang here")
    _ = try await h.events.waitFor { $0.kind == .messageDelta && $0.threadId == thread.id }
    for params in [
      ConnectionUpdate.Params(connectionId: b4.id, authReference: key),
      ConnectionUpdate.Params(connectionId: b4.id, clearAuth: true),
    ] {
      do {
        _ = try await h.update(params)
        Issue.record("a key change must wait for the running turn")
      } catch let error as WorkspaceError {
        #expect(error.details?["reason"]?.stringValue == "turn_active")
      }
    }
    // A rename does not touch the adapter, so it is allowed mid-turn.
    #expect(
      try await h.update(ConnectionUpdate.Params(connectionId: b4.id, label: "Renamed")).connection.label
        == "Renamed")
    _ = try await h.client.request(
      TurnInterrupt.self, TurnInterrupt.Params(threadId: thread.id),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    await h.stop()
    await server.stop()
  }

  /// A background check answers at once and reports through events, so it never holds the socket (the
  /// coordinator serves one client's requests in order) while it retries.
  @Test func aBackgroundCheckAnswersAtOnce() async throws {
    let h = try await Harness.start(checkRetryDelays: [.seconds(1), .seconds(1)])
    let added = try await h.client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(kind: .b4, label: "Gone", url: "http://127.0.0.1:9", route: "/chat#agent"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60)))
    let clock = ContinuousClock()
    let started = clock.now
    let startedAt = Date()
    let answer = try await h.client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: added.connection.id, background: true),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(clock.now - started < .milliseconds(800))
    #expect(answer.connection.id == added.connection.id)
    // The socket is free: another request answers while the check retries.
    _ = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(clock.now - started < .milliseconds(900))
    // The check's result arrives later, as the closing `connection.changed` after its three tries.
    let attempts = try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == added.connection.id
        && $0.payload["attempt"]?.numberValue == 3
        && (Timestamp.date(from: $0.at) ?? .distantPast) > startedAt
    }
    #expect(attempts.payload["attempts"]?.numberValue == 3)
    #expect(clock.now - started > .seconds(1))
    await h.stop()
  }

  @Test func aRenameCarriesTheConnection() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server, label: "Old").connection
    _ = try await h.update(ConnectionUpdate.Params(connectionId: b4.id, label: "New"))
    // Every client hears the new name, not only the one that asked.
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == b4.id
        && $0.payload["connection"]?["label"]?.stringValue == "New"
    }
    await h.stop()
    await server.stop()
  }

  @Test func credentialRemoveKeepsASecretInUse() async throws {
    let server = try await FakeB4.start()
    let secrets = MemorySecretStore()
    let h = try await Harness.start(secretStore: secrets)
    let used = try await h.storeCredential("used")
    let spare = try await h.storeCredential("spare")
    _ = try await h.addB4(server, authReference: used)
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
    await server.stop()
  }

  /// The edit is saved before the old key is deleted, so a Keychain that refuses the delete does not
  /// turn a saved edit into an error.
  @Test func aSavedKeyChangeIsNotReportedFailedWhenTheOldKeyStays() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start(secretStore: RefusingRemoveStore())
    let old = try await h.storeCredential("old")
    let b4 = try await h.addB4(server, authReference: old).connection
    let replacement = try await h.storeCredential("new")
    let updated = try await h.update(ConnectionUpdate.Params(connectionId: b4.id, authReference: replacement))
    #expect(updated.connection.authReference == replacement)
    await h.stop()
    await server.stop()
  }
}
