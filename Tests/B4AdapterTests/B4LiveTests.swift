import Foundation
import Testing
import WorkspaceProtocol

@testable import B4Adapter

/// Opt-in: a real B4 server the owner runs (for example `examples/chat` with `OPENAI_API_KEY`).
/// `B4APP_LIVE_B4_URL=http://127.0.0.1:3001 B4APP_LIVE_B4_ROUTE=/chat#agent swift test --filter B4Live`.
/// Optional `B4APP_LIVE_B4_SECRET` is sent as a bearer. Never runs in CI.
@Suite(.serialized) struct B4LiveTests {
  static var url: String? { ProcessInfo.processInfo.environment["B4APP_LIVE_B4_URL"] }

  @Test(.enabled(if: B4LiveTests.url != nil))
  func streamsInterruptsAndReopensAgainstARealServer() async throws {
    let env = ProcessInfo.processInfo.environment
    let route = env["B4APP_LIVE_B4_ROUTE"] ?? "/chat#agent"
    let secret = env["B4APP_LIVE_B4_SECRET"]
    let adapter = B4Adapter(
      connectionId: "live", baseURL: Self.url!, routeKey: route,
      authorization: { secret.map(B4HTTPClient.authorizationHeader(secret:)) }, authConfigured: secret != nil,
      clientVersion: "live")
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    print("live B4 inspection:", inspection.status, inspection.message ?? "")
    #expect(inspection.status == .ready)

    let ref = try await adapter.createSession(NewSessionInput(routeKey: route))
    print("live B4 thread:", ref.nativeSessionId)
    let receipt = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: UUID().uuidString, text: "Reply with exactly the word pong and nothing else."))
    #expect(receipt.acknowledged)
    let finished = try await collector.waitFor(timeout: .seconds(120)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == receipt.nativeTurnId
    }
    let reply = await collector.deltas(turnId: receipt.nativeTurnId ?? "")
    print("live B4 reply:", reply, "outcome:", finished.payload["outcome"]?.stringValue ?? "")
    #expect(finished.payload["outcome"]?.stringValue == "completed")

    let long = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: UUID().uuidString, text: "Count slowly from one to two hundred, one number per line."))
    try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .messageDelta && $0.nativeIds["turnId"] == long.nativeTurnId
    }
    let stop = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: long.nativeTurnId!))
    print("live B4 interrupt:", stop)
    let stopped = try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == long.nativeTurnId
    }
    print("live B4 stopped outcome:", stopped.payload["outcome"]?.stringValue ?? "")
    #expect(stopped.payload["outcome"]?.stringValue == "cancelled")

    let snapshot = try await adapter.loadSession(ref)
    print("live B4 history items:", snapshot.items.map(\.type))
    #expect(snapshot.items.contains { $0.type == "userMessage" })
    let reconciled = try await adapter.reconcile(
      ref, turn: ActiveTurnRef(nativeTurnId: receipt.nativeTurnId!))
    print("live B4 reconcile of the first turn:", reconciled.activeTurnOutcome.map { "\($0)" } ?? "nil")
    await adapter.dispose()
  }
}
