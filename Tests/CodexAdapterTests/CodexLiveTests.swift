import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

/// Opt-in live check against the real `codex app-server` on this Mac. Issues one short inference
/// turn and interrupts a second one. Enabled only with `B4APP_LIVE_CODEX=1`; never run in CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_LIVE_CODEX"] == "1"))
struct CodexLiveTests {
  @Test func handshakeAccountThreadTurnInterruptAndReopen() async throws {
    let adapter = CodexAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    print(
      "live inspection:", inspection.status, inspection.authStatus, inspection.version ?? "-",
      inspection.message ?? "")
    try #require(inspection.status == .ready, "Codex must be installed and compatible")
    try #require(inspection.authStatus == .authenticated, "Sign in with `codex login` before the live test")

    let cwd = NSTemporaryDirectory() + "b4app-live-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: cwd))
    print("live thread:", ref.nativeSessionId, "scope:", ref.nativeScope)

    let first = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-1", text: "Reply with exactly the single word: pong", workingDirectory: cwd))
    #expect(first.acknowledged)
    let finished = try await collector.waitFor(timeout: .seconds(180)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == first.nativeTurnId
    }
    #expect(finished.payload["outcome"]?.stringValue == "completed", "\(finished.payload)")
    let reply = await collector.events.last {
      $0.kind == .messageCompleted && $0.nativeIds["turnId"] == first.nativeTurnId
    }
    let text = reply?.payload["item"]?["text"]?.stringValue ?? ""
    print("live reply:", text)
    #expect(text.lowercased().contains("pong"))

    let second = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-2", text: "Count slowly from 1 to 2000, one number per line, no other text.",
        workingDirectory: cwd))
    try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .turnAcknowledged && $0.nativeIds["turnId"] == second.nativeTurnId
    }
    // Timed on purpose (live, opt-in): lets the real model get well into its answer before the stop.
    try await Task.sleep(for: .seconds(3))
    let stop = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: second.nativeTurnId!))
    #expect(stop.confirmed)
    let stopped = try await collector.waitFor(timeout: .seconds(60)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == second.nativeTurnId
    }
    print("live interrupt outcome:", stopped.payload["outcome"]?.stringValue ?? "-")
    #expect(stopped.payload["outcome"]?.stringValue == "cancelled")
    await adapter.dispose()

    let reopened = CodexAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let snapshot = try await reopened.loadSession(ref)
    print("live reopen items:", snapshot.items.map { "\($0.role)/\($0.type)" })
    #expect(
      snapshot.items.contains { $0.payload["text"]?.stringValue?.lowercased().contains("pong") == true })
    #expect(snapshot.activeTurn == nil)
    let kinds = await collector.kinds()
    print("live event kinds:", kinds.map(\.rawValue).joined(separator: ","))
    await reopened.dispose()
  }

  /// A real approval round trip. The owner's configuration is `approval_policy = "never"` with a
  /// full-access sandbox, so this thread alone asks for `on-request` + `workspace-write`; a write
  /// outside the workspace then needs an approval, which is answered through the adapter.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["B4APP_LIVE_CODEX_APPROVALS"] == "1"))
  func commandApprovalRoundTrip() async throws {
    let adapter = CodexAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    await adapter.setThreadPolicy(
      CodexProtocol.ThreadPolicy(approvalPolicy: "on-request", sandbox: "workspace-write"))
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    try #require(inspection.status == .ready && inspection.authStatus == .authenticated)
    let cwd = NSTemporaryDirectory() + "b4app-live-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: cwd))
    let turn = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "live-approval",
        text:
          "Run the shell command `curl -sI https://example.com` and report the first line of its output. The sandbox blocks network access, so request approval to run it outside the sandbox instead of giving up. Do not ask me questions.",
        workingDirectory: cwd))
    let opened = try await collector.waitFor(timeout: .seconds(240)) {
      $0.kind == .runtimeRequestOpened && $0.nativeIds["turnId"] == turn.nativeTurnId
    }
    print(
      "live approval request:", opened.payload["kind"]?.stringValue ?? "-",
      opened.payload["method"]?.stringValue ?? "-")
    print("live approval payload:", opened.payload["request"] ?? .null)
    #expect(opened.payload["kind"]?.stringValue == "command_approval")
    #expect(opened.payload["answerable"]?.boolValue == true)
    try await adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: opened.nativeIds["requestId"]!, kind: .commandApproval,
        adapterGeneration: opened.adapterGeneration),
      response: .decision(.allowOnce))
    let finished = try await collector.waitFor(timeout: .seconds(240)) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == turn.nativeTurnId
    }
    print("live approval outcome:", finished.payload["outcome"]?.stringValue ?? "-")
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let reply = await collector.events.last {
      $0.kind == .messageCompleted && $0.nativeIds["turnId"] == turn.nativeTurnId
    }
    print("live approval reply:", reply?.payload["item"]?["text"]?.stringValue ?? "-")
    #expect(reply?.payload["item"]?["text"]?.stringValue?.contains("HTTP") == true)
    await adapter.dispose()
  }
}
