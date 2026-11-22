import AppKit
import WorkspaceClient
import WorkspaceProtocol
import XCTest

/// Current fake-native interactions and historical B4 cache reads share no execution authority.
final class HistoricalCacheSmokeTests: XCTestCase {
  private static let historicalDraft = "  Keep this historical draft exactly.  "
  private static let editedDraft = "  Keep this historical draft exactly.  edited"
  private static let continuation = "continue same native thread"

  @MainActor func testDesktopDarkHistoricalCacheAndCurrentNative() async throws {
    continueAfterFailure = false
    let width = try XCTUnwrap(Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_WIDTH"] ?? "1200"))
    let height = try XCTUnwrap(Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_HEIGHT"] ?? "600"))
    let fixture = try await SmokeFixture.start(in: self, historicalB4: true)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let currentId = try XCTUnwrap(fixture.currentThreadId)
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground {
        if app.windows.firstMatch.exists { self.capture(app, name: "historical-current-final-window") }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "historical-current-accessibility"
        tree.lifetime = .keepAlways
        self.add(tree)
      }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": String(width), "SMOKE_HEIGHT": String(height),
      "SMOKE_DARK": "1", "SWIFTNIO_STRICT": "1",
    ]
    let seed = try fixture.databaseSnapshot("historical-database-seed.json")
    let historical = try await read(fixture, id: fixture.threadId)
    try assertHistorical(historical, seed: seed)
    try await assertDraft(Self.historicalDraft, fixture: fixture, id: fixture.threadId)
    let profiles = try await fixture.client.request(ConnectionList.self, .init()).connections
    let old = try XCTUnwrap(profiles.first { $0.id == historical.thread.connectionId })
    XCTAssertEqual(old.kind, .b4)
    XCTAssertEqual(old.status, .ready, "A ready historical row must still be read-only")
    XCTAssertEqual(old.nativeScope, "opaque/old-scope#b4")
    XCTAssertTrue(old.isProtocolReadOnly)

    try launchWithWindow(app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    try select("Current native fixture", draft: "partial", app: app)
    let composer = app.textViews["composer"]
    try requireElement(composer, in: app)
    XCTAssertEqual(composer.value as? String, "partial")
    let initial = try await read(fixture, id: currentId)
    XCTAssertTrue(initial.turns.isEmpty)
    let nativeId = initial.thread.nativeThreadId
    XCTAssertEqual(nativeId, "thr_1")
    try assertJournal(fixture, nativeId: nativeId, prompts: [], interrupted: false)

    // The fixture emits real deltas and then holds, so visibility is independent of runner speed.
    try send(app)
    let partial = text("Partial reply so far", in: app)
    try requireElement(partial, in: app, timeout: 20)
    let transcript = app.scrollViews["transcript"].firstMatch
    try requireElement(transcript, in: app)
    XCTAssertTrue(partial.isHittable)
    XCTAssertTrue(transcript.frame.contains(partial.frame))
    let streaming = try await read(fixture, id: currentId)
    XCTAssertEqual(streaming.turns.count, 1)
    XCTAssertEqual(streaming.turns.first?.status, .running)
    XCTAssertNil(streaming.turns.first?.outcome)
    XCTAssertEqual(streaming.turns.first?.nativeTurnId, "turn_1")
    let stop = app.buttons["stop"]
    try requireElement(stop, in: app)
    XCTAssertTrue(stop.isEnabled)
    stop.click()
    let cancelled = try await waitForTurns(fixture, id: currentId, completed: 0, cancelled: 1)
    XCTAssertEqual(cancelled.turns.first?.outcome, .cancelled)
    try requireElement(text("Partial reply so far", in: app), in: app)
    try assertJournal(fixture, nativeId: nativeId, prompts: ["partial"], interrupted: true)

    // This command row comes from an actual native approval response and completed item, never a seed.
    try type("approve", into: composer, app: app)
    try send(app)
    let allow = app.buttons["allow-once"]
    try requireElement(allow, in: app, timeout: 15)
    XCTAssertTrue(allow.isEnabled)
    let pending = try await read(fixture, id: currentId)
    XCTAssertEqual(pending.requests.count, 1)
    let request = try XCTUnwrap(pending.requests.first)
    XCTAssertEqual(request.kind, .commandApproval)
    XCTAssertEqual(request.state, .pending)
    XCTAssertEqual(request.nativeRequestId, "7")
    XCTAssertEqual(request.payload["request"]?["command"]?.stringValue, "ls -la")
    XCTAssertEqual(request.turnId, pending.turns.first { $0.nativeTurnId == "turn_2" }?.id)
    XCTAssertEqual(request.payload["request"]?["allowScope"]?.stringValue, "session")
    let allowWider = app.buttons["allow-wider"]
    try requireElement(allowWider, in: app)
    XCTAssertTrue(allowWider.isEnabled)
    allow.click()
    let toolState = try await waitForTurns(fixture, id: currentId, completed: 1, cancelled: 1)
    try requireElement(text("Command completed.", in: app), in: app)
    // The turn's work is one closed line; its step is a row once the line is opened.
    let line = app.buttons["activity-line"].firstMatch
    try requireElement(line, in: app)
    line.click()
    let tool = app.descendants(matching: .any).matching(identifier: "step-row").matching(
      NSPredicate(format: "label CONTAINS %@", "ls -la"))
    try requireElement(tool.firstMatch, in: app)
    XCTAssertEqual(tool.count, 1)
    tool.firstMatch.click()
    try requireElement(text("total 0", in: app), in: app)
    XCTAssertTrue(toolState.requests.isEmpty)
    try assertCurrentItems(toolState, prompts: ["partial", "approve"])
    try type(Self.continuation, into: composer, app: app)
    try await assertDraft(Self.continuation, fixture: fixture, id: currentId)
    // Reading the old cache never resumes, retries, cancels or abandons its unknown turn.
    try select("Historical B4 cache fixture", draft: Self.historicalDraft, app: app)
    let historicalLine = app.buttons["activity-line"].firstMatch
    try requireElement(historicalLine, in: app)
    historicalLine.click()
    try requireElement(text("Historical cached text remains readable.", in: app), in: app)
    try requireElement(app.descendants(matching: .any).matching(identifier: "task-list").firstMatch, in: app)
    try requireElement(
      app.descendants(matching: .any).matching(identifier: "step-row").matching(
        NSPredicate(format: "label CONTAINS %@", "cached lookup")
      ).firstMatch,
      in: app)
    XCTAssertEqual(composer.value as? String, Self.historicalDraft)
    XCTAssertTrue(composer.isEnabled)
    try type(Self.editedDraft, into: composer, app: app)
    try await assertDraft(Self.editedDraft, fixture: fixture, id: fixture.threadId)
    XCTAssertTrue(composer.isEnabled)

    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("window.json"))
    try launchWithWindow(app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    try select("Historical B4 cache fixture", draft: Self.editedDraft, app: app)
    try requireElement(composer, in: app)
    XCTAssertEqual(composer.value as? String, Self.editedDraft)
    try assertHistorical(try await read(fixture, id: fixture.threadId), seed: seed)
    try await assertDraft(Self.editedDraft, fixture: fixture, id: fixture.threadId)

    try select("Current native fixture", draft: Self.continuation, app: app)
    try requireElement(text("Command completed.", in: app), in: app)
    XCTAssertEqual(composer.value as? String, Self.continuation)
    let reopened = try await read(fixture, id: currentId)
    XCTAssertEqual(reopened.thread.nativeThreadId, nativeId)
    XCTAssertEqual(reopened.turns, toolState.turns)
    XCTAssertEqual(reopened.items, toolState.items)
    try assertCurrentItems(reopened, prompts: ["partial", "approve"])
    // Only this deliberate send adds the third native turn after cache reads and UI relaunch.
    try send(app)
    let final = try await waitForTurns(fixture, id: currentId, completed: 2, cancelled: 1)
    try requireElement(text("Hello from fake Codex.", in: app), in: app)
    XCTAssertEqual(final.thread.nativeThreadId, nativeId)
    XCTAssertEqual(
      Set(final.turns.compactMap(\.nativeTurnId)), Set(["turn_1", "turn_2", "turn_3"]))
    XCTAssertTrue(Set(toolState.turns.map(\.id)).isSubset(of: Set(final.turns.map(\.id))))
    XCTAssertEqual(composer.value as? String, "")
    try await assertDraft("", fixture: fixture, id: currentId)
    try assertCurrentItems(final, prompts: ["partial", "approve", Self.continuation])

    try select("Historical B4 cache fixture", draft: Self.editedDraft, app: app)
    // Historical Check again is an allowed cache read: the coordinator returns before any adapter.
    let checkAgain = app.buttons["check-again"]
    try requireElement(checkAgain, in: app)
    XCTAssertTrue(checkAgain.isEnabled)
    XCTAssertTrue(checkAgain.isHittable)
    checkAgain.click()
    try assertHistorical(try await read(fixture, id: fixture.threadId), seed: seed)
    try await assertDraft(Self.editedDraft, fixture: fixture, id: fixture.threadId)
    XCTAssertEqual(composer.value as? String, Self.editedDraft)
    let reason = app.staticTexts["historical-read-only-reason"]
    try requireElement(reason, in: app)
    XCTAssertTrue(reason.isHittable)
    XCTAssertEqual(reason.value as? String, "This historical conversation is read-only.")
    // If local answer entry remains editable, make it nonempty before testing Submit answers.
    // Otherwise an empty-answer predicate alone could make the historical question check vacuous.
    let answer = app.textFields["Answer"]
    try requireElement(answer, in: app)
    if answer.isEnabled {
      let requests = app.scrollViews["runtime-requests"]
      requests.scroll(byDeltaX: 0, deltaY: -300)
      answer.click()
      answer.typeText("retained answer")
      XCTAssertEqual(answer.value as? String, "retained answer")
    }
    try requireElement(
      app.buttons.matching(identifier: "check-again").matching(NSPredicate(format: "enabled == true"))
        .firstMatch,
      in: app)
    XCTAssertTrue(
      checkAgain.isEnabled,
      "Historical cache refresh must be settled and available while execution controls stay disabled")
    XCTAssertFalse(app.buttons["allow-wider"].exists)
    XCTAssertFalse(app.buttons["Allow for session"].exists)
    for button in [
      app.buttons["stop"], app.buttons["abandon"],
      app.buttons["allow-once"], app.buttons["deny"],
      app.buttons["Submit answers"],
    ] {
      try requireElement(button, in: app)
      XCTAssertFalse(button.isEnabled, "Historical execution control must be disabled: \(button)")
    }
    XCTAssertFalse(app.buttons["send"].exists, "The unresolved historical turn is preserved")
    try assertJournal(
      fixture, nativeId: nativeId, prompts: ["partial", "approve", Self.continuation], interrupted: true)
  }

  @MainActor private func select(_ title: String, draft: String, app: XCUIApplication) throws {
    let row = app.buttons.matching(identifier: "thread-row").matching(
      NSPredicate(format: "label CONTAINS %@", title)
    ).firstMatch
    try requireElement(row, in: app, timeout: 30)
    row.click()
    try requireElement(app.staticTexts[title], in: app)
    let settled = NSPredicate(format: "value == %@", draft)
    let matchingComposer = app.textViews.matching(identifier: "composer").matching(settled).firstMatch
    try requireElement(matchingComposer, in: app)
  }

  @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
    ).firstMatch
  }

  @MainActor private func send(_ app: XCUIApplication) throws {
    let button = app.buttons["send"]
    try requireElement(button, in: app)
    XCTAssertTrue(button.isEnabled)
    XCTAssertTrue(button.isHittable)
    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
  }

  @MainActor private func type(_ text: String, into composer: XCUIElement, app: XCUIApplication) throws {
    composer.click()
    app.typeKey("a", modifierFlags: .command)
    composer.typeText(text)
    XCTAssertEqual(composer.value as? String, text)
  }

  @MainActor private func read(_ fixture: SmokeFixture, id: String) async throws -> ThreadRead.Result {
    try await fixture.client.request(ThreadRead.self, .init(threadId: id))
  }

  @MainActor private func waitForTurns(
    _ fixture: SmokeFixture, id: String, completed: Int, cancelled: Int
  ) async throws -> ThreadRead.Result {
    let deadline = ContinuousClock.now + .seconds(45)
    while ContinuousClock.now < deadline {
      let state = try await read(fixture, id: id)
      if state.turns.count == completed + cancelled,
        state.turns.allSatisfy({ $0.status == .terminal }),
        state.turns.filter({ $0.outcome == .completed }).count == completed,
        state.turns.filter({ $0.outcome == .cancelled }).count == cancelled
      {
        return state
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(
      domain: "HistoricalCacheSmoke", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Expected terminal turn outcomes were not reached"])
  }

  @MainActor private func assertDraft(_ text: String, fixture: SmokeFixture, id: String) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      let saved = try await fixture.client.request(DraftRead.self, .init(threadId: id))
      if (saved.draft?.text ?? "") == text { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Composer draft was not persisted exactly")
    throw NSError(domain: "HistoricalCacheSmoke", code: 2)
  }

  private func assertHistorical(_ read: ThreadRead.Result, seed: JSONValue) throws {
    let expected = try JSONDecoder().decode(
      ThreadRead.Result.self, from: JSONEncoder().encode(try XCTUnwrap(seed["read"])))
    XCTAssertEqual(read.thread.nativeThreadId, "opaque/native/thread#old")
    XCTAssertEqual(read.thread.nativeScope, "opaque/old-scope#b4")
    XCTAssertEqual(read.thread.context, "/cached#agent")
    XCTAssertEqual(read.thread.continuity, .available)
    XCTAssertEqual(read.turns, expected.turns)
    XCTAssertEqual(read.items, expected.items)
    XCTAssertEqual(read.requests.sorted { $0.id < $1.id }, expected.requests.sorted { $0.id < $1.id })
    XCTAssertEqual(read.turns.count, 1)
    XCTAssertEqual(read.turns.first?.nativeTurnId, "opaque/native/turn#old")
    XCTAssertEqual(read.turns.first?.status, .reconciling)
    XCTAssertEqual(read.turns.first?.submission, .unknown)
    XCTAssertNil(read.turns.first?.outcome)
    XCTAssertEqual(read.requests.count, 2)
    XCTAssertTrue(read.requests.allSatisfy { $0.state == .pending && $0.adapterGeneration == 17 })
    XCTAssertEqual(Set(read.requests.map(\.createdAt)).count, 2)
    XCTAssertEqual(
      read.requests.first { $0.kind == .commandApproval }?.createdAt, "2026-11-01T00:00:01.000Z")
    XCTAssertEqual(
      read.requests.first { $0.kind == .userQuestion }?.createdAt, "2026-11-01T00:00:02.000Z")
    XCTAssertTrue(read.requests.allSatisfy { $0.createdAt == $0.updatedAt })
    XCTAssertEqual(read.items.count, 3)
    XCTAssertTrue(read.items.allSatisfy { $0.provenance == .cache })
    XCTAssertEqual(Set(read.items.map(\.id)).count, read.items.count)
  }

  private func assertCurrentItems(_ read: ThreadRead.Result, prompts: [String]) throws {
    XCTAssertEqual(Set(read.items.map(\.id)).count, read.items.count)
    let nativeItems = read.items.compactMap(\.nativeItemId)
    XCTAssertEqual(Set(nativeItems).count, nativeItems.count)
    let commands = read.items.filter { $0.type == "commandExecution" }
    XCTAssertEqual(commands.count, 1)
    let command = try XCTUnwrap(commands.first)
    XCTAssertEqual(command.nativeItemId, "item_cmd")
    XCTAssertEqual(command.role, .tool)
    XCTAssertEqual(command.provenance, .live)
    XCTAssertEqual(command.payload["command"]?.stringValue, "ls -la")
    XCTAssertEqual(command.payload["status"]?.stringValue, "completed")
    XCTAssertEqual(command.payload["exitCode"]?.numberValue, 0)
    XCTAssertEqual(command.payload["aggregatedOutput"]?.stringValue, "total 0\n")
    for (index, prompt) in prompts.enumerated() {
      let turn = try XCTUnwrap(read.turns.first { $0.nativeTurnId == "turn_\(index + 1)" })
      let user = read.items.filter { $0.role == .user && $0.turnId == turn.id }
      XCTAssertEqual(user.count, 1, "One user item per deliberate send")
      XCTAssertEqual(user.first?.payload["text"]?.stringValue, prompt)
      let reply = read.items.filter { $0.role == .assistant && $0.turnId == turn.id }
      XCTAssertEqual(reply.count, 1)
      XCTAssertEqual(reply.first?.nativeItemId, "item_turn_\(index + 1)_msg")
      XCTAssertEqual(
        reply.first?.payload["text"]?.stringValue,
        ["Partial reply so far", "Command completed.", "Hello from fake Codex."][index])
    }
    XCTAssertEqual(read.items.filter { $0.role == .user }.count, prompts.count)
    XCTAssertEqual(read.items.filter { $0.role == .assistant }.count, prompts.count)
  }

  @MainActor private func assertJournal(
    _ fixture: SmokeFixture, nativeId: String, prompts: [String], interrupted: Bool
  ) throws {
    let path = fixture.root.appendingPathComponent("runtime-requests.jsonl")
    let journal = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let starts = journal.filter { $0["method"]?.stringValue == "thread/start" }
    XCTAssertEqual(starts.count, 1, "Historical reads never create native threads")
    XCTAssertEqual(
      starts.first?["params"]?["cwd"]?.stringValue, fixture.root.appendingPathComponent("work").path)
    let turns = journal.filter { $0["method"]?.stringValue == "turn/start" }
    XCTAssertEqual(turns.count, prompts.count, "Cache reads, checks and relaunch never resend")
    XCTAssertEqual(
      turns.compactMap { $0["params"]?["threadId"]?.stringValue },
      Array(repeating: nativeId, count: prompts.count))
    XCTAssertEqual(
      turns.compactMap { $0["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue }, prompts)
    let stops = journal.filter { $0["method"]?.stringValue == "turn/interrupt" }
    XCTAssertEqual(stops.count, interrupted ? 1 : 0)
    if interrupted {
      XCTAssertEqual(stops.first?["params"]?["threadId"]?.stringValue, nativeId)
      XCTAssertEqual(stops.first?["params"]?["turnId"]?.stringValue, "turn_1")
    }
    // Incidental account, limits and local read RPCs are not inference. Reject other native mutations.
    let otherMutations = ["review/start", "thread/compact/start", "thread/delete"]
    XCTAssertTrue(journal.allSatisfy { !otherMutations.contains($0["method"]?.stringValue ?? "") })
    // Resume/load is not inference. This already-loaded fixture needs none for cache reads/relaunch.
    XCTAssertFalse(
      journal.contains { $0["method"]?.stringValue == "thread/resume" },
      "This fixture must not unnecessarily resume a current or historical native thread")
  }

  @MainActor private func capture(_ app: XCUIApplication, name: String) {
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
