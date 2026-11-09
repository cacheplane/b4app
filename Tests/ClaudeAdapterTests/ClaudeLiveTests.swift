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

  /// The new-thread composer's runtime choice against the real CLI (D-183): a session launched on
  /// Haiku with a second folder attached reads a file there; a mode and a model change reach the
  /// running process as control requests; Bypass restarts it with `--resume`, and the conversation
  /// carries on.
  @Test func runtimeChoiceAppliesLive() async throws {
    let adapter = ClaudeAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    try #require(inspection.status == .ready && inspection.authStatus == .authenticated)
    #expect(inspection.models?.map(\.id) == ["opus", "sonnet", "haiku"])
    let base = NSTemporaryDirectory() + "b4app-claude-choice-\(UUID().uuidString.prefix(8))"
    let cwd = base + "/start"
    let extra = base + "/extra"
    for dir in [cwd, extra] {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    try "periwinkle\n".write(toFile: extra + "/marker.txt", atomically: true, encoding: .utf8)
    let ref = try await adapter.createSession(
      NewSessionInput(workingDirectory: cwd, model: "haiku", additionalDirectories: [extra]))

    func turn(_ id: String, _ text: String, model: String?, permission: String?) async throws -> String {
      let receipt = try await adapter.sendTurn(
        ref,
        input: TurnInput(
          operationId: id, text: text, workingDirectory: cwd, model: model, permission: permission,
          additionalDirectories: [extra]))
      let done = try await collector.waitFor(timeout: .seconds(240)) {
        $0.kind == .turnFinished && $0.nativeIds["turnId"] == receipt.nativeTurnId
      }
      #expect(done.payload["outcome"]?.stringValue == "completed", "\(id): \(done.payload)")
      let reply = await collector.events.last {
        $0.kind == .messageCompleted && $0.nativeIds["turnId"] == receipt.nativeTurnId
      }
      let said = reply?.payload["item"]?["text"]?.stringValue ?? ""
      print("live \(id):", said)
      return said
    }

    let read = try await turn(
      "choice-1", "Read the file \(extra)/marker.txt and reply with only the word it contains.",
      model: "haiku", permission: nil)
    #expect(read.lowercased().contains("periwinkle"))
    _ = try await turn("choice-2", "Reply with exactly: two", model: "haiku", permission: "acceptEdits")
    _ = try await turn("choice-3", "Reply with exactly: three", model: "sonnet", permission: "plan")
    let resumed = try await turn(
      "choice-4", "What word was in marker.txt? Reply with just that word.", model: "sonnet",
      permission: "bypassPermissions")
    #expect(resumed.lowercased().contains("periwinkle"))
    await adapter.dispose()
  }

  /// Plan mode keeps its word against the real CLI: asked to write a file, a session in `plan`
  /// writes nothing, while the same request in `acceptEdits` (the control) writes it. Any approval
  /// asked for on the way (leaving plan mode, the write itself) is denied, as a user who wants only
  /// the plan would.
  @Test func planModeWritesNothingLive() async throws {
    let adapter = ClaudeAdapter(connectionId: "live", executablePath: nil, clientVersion: "live-test")
    let collector = EventCollector(adapter.events())
    let inspection = try await adapter.inspectConnection()
    try #require(inspection.status == .ready && inspection.authStatus == .authenticated)

    /// Whether a session in `permission` wrote the file it was asked to.
    func wrote(_ permission: String) async throws -> Bool {
      let cwd = NSTemporaryDirectory() + "b4app-claude-\(permission)-\(UUID().uuidString.prefix(8))"
      try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
      let target = cwd + "/made.txt"
      let ref = try await adapter.createSession(
        NewSessionInput(workingDirectory: cwd, model: "haiku", permission: permission))
      let receipt = try await adapter.sendTurn(
        ref,
        input: TurnInput(
          operationId: "\(permission)-1",
          text: "Create the file \(target) containing the single word tangerine. Do it now; do not ask.",
          workingDirectory: cwd, model: "haiku", permission: permission))
      let turnId = try #require(receipt.nativeTurnId)
      var answered: Set<String> = []
      while true {
        let seen = answered
        let event = try await collector.waitFor(timeout: .seconds(240)) {
          ($0.kind == .turnFinished && $0.nativeIds["turnId"] == turnId)
            || ($0.kind == .runtimeRequestOpened && !seen.contains($0.nativeIds["requestId"] ?? ""))
        }
        if event.kind == .turnFinished { break }
        let id = try #require(event.nativeIds["requestId"])
        answered.insert(id)
        let kind = event.payload["kind"]?.stringValue.flatMap(RuntimeRequestKind.init(rawValue:)) ?? .unknown
        print("live \(permission) request:", kind, event.payload["request"]?["toolName"] ?? .null)
        if kind == .userQuestion || kind == .elicitation {
          _ = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: turnId))
        } else {
          try await adapter.respond(
            RuntimeRequestRef(nativeRequestId: id, kind: kind, adapterGeneration: event.adapterGeneration),
            response: .decision(.deny))
        }
      }
      return FileManager.default.fileExists(atPath: target)
    }

    #expect(try await wrote("acceptEdits"), "the control did not write; the prompt proves nothing")
    #expect(try await !wrote("plan"), "plan mode wrote the file")
    await adapter.dispose()
  }
}
