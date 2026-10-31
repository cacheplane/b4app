import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

/// Opt-in live check against the installed `claude` CLI: one short inference turn, an interrupt, and
/// a resume. Needs `claude auth login`. Enabled only with `B4APP_LIVE_CLAUDE=1`; never in CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_LIVE_CLAUDE"] == "1"))
struct ClaudeLiveTests {
  @Test func handshakeTurnInterruptAndResume() async throws {
    let adapter = ClaudeAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    print(
      "live inspection:", inspection.status, inspection.authStatus, inspection.version ?? "-",
      inspection.message ?? "")
    try #require(inspection.status == .ready)
    try #require(inspection.authStatus == .authenticated, "Run `claude auth login` before the live test")
    let cwd = NSTemporaryDirectory() + "b4app-claude-live-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: cwd))
    print("live session:", ref.nativeSessionId, "scope:", ref.nativeScope)
    let first = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-1", text: "Reply with exactly the single word: pong", workingDirectory: cwd))
    let finished = try await collector.waitFor(timeout: .seconds(180)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == first.nativeTurnId
    }
    #expect(finished.payload["outcome"]?.stringValue == "completed", "\(finished.payload)")
    let reply = await collector.events.last {
      $0.kind == .messageCompleted && $0.nativeIds["turnId"] == first.nativeTurnId
    }
    print("live reply:", reply?.payload["item"]?["text"]?.stringValue ?? "")
    #expect(reply?.payload["item"]?["text"]?.stringValue?.lowercased().contains("pong") == true)

    let second = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-2", text: "Count slowly from 1 to 2000, one number per line, no other text.",
        workingDirectory: cwd))
    try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .messageDelta && $0.nativeIds["turnId"] == second.nativeTurnId
    }
    let stop = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: second.nativeTurnId!))
    #expect(stop.confirmed)
    let stopped = try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == second.nativeTurnId
    }
    print(
      "live interrupt outcome:", stopped.payload["outcome"]?.stringValue ?? "-",
      stopped.payload["terminalReason"] ?? "")
    #expect(stopped.payload["outcome"]?.stringValue == "cancelled")
    await adapter.dispose()

    let reopened = ClaudeAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let reopenedEvents = EventCollector(reopened.events())
    let third = try await reopened.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-3",
        text: "What single word did I ask you to reply with earlier? Answer with just that word.",
        workingDirectory: cwd))
    let resumed = try await reopenedEvents.waitFor(timeout: .seconds(180)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == third.nativeTurnId
    }
    #expect(resumed.payload["outcome"]?.stringValue == "completed")
    let answer = await reopenedEvents.events.last { $0.kind == .messageCompleted }
    print("live resume answer:", answer?.payload["item"]?["text"]?.stringValue ?? "")
    #expect(answer?.payload["item"]?["text"]?.stringValue?.lowercased().contains("pong") == true)
    let snapshot = try await reopened.loadSession(ref)
    print("live transcript items:", snapshot.items.map { "\($0.role)/\($0.type)" })
    #expect(!snapshot.items.isEmpty)
    await reopened.dispose()
  }
}
