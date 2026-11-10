import AppKit
import WorkspaceClient
import WorkspaceProtocol
import XCTest

final class B4RuntimeSmokeTests: XCTestCase {
  private static let streamed = "Streaming fixture reply arrives in several pieces."
  private static let toolReply = "The real fixture lookup returned fixture-value."
  private static let continued = "The same conversation continued after restart."
  private static let restartDraft = "smoke-after-restart"

  @MainActor func testCompactLightB4Recovery() async throws { try await journey(desktop: false, dark: false) }
  @MainActor func testDesktopDarkB4Recovery() async throws { try await journey(desktop: true, dark: true) }

  @MainActor private func journey(desktop: Bool, dark: Bool) async throws {
    continueAfterFailure = false
    let width =
      desktop ? try XCTUnwrap(Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_WIDTH"] ?? "1200")) : 900
    let height =
      desktop ? try XCTUnwrap(Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_HEIGHT"] ?? "600")) : 600
    let fixture = try await SmokeFixture.start(in: self, realB4: true)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let runtime = try XCTUnwrap(fixture.realRuntime)
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground {
        if app.windows.firstMatch.exists { self.capture(app, name: "b4-final-window") }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "b4-accessibility"
        tree.lifetime = .keepAlways
        self.add(tree)
      }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": String(width), "SMOKE_HEIGHT": String(height),
      "SMOKE_DARK": dark ? "1" : "0", "SWIFTNIO_STRICT": "1",
    ]
    try open(app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    let row = app.buttons["thread-row"].firstMatch
    try requireElement(row, in: app, timeout: 30)
    XCTAssertTrue(row.label.contains("Real B4 recovery fixture"))
    row.click()
    let composer = app.textViews["composer"]
    try requireElement(composer, in: app)
    XCTAssertEqual(composer.value as? String, "smoke-ui-stream")
    let initial = try await read(fixture)
    let nativeId = try XCTUnwrap(initial.thread.nativeThreadId)

    try send(app)
    try requireElement(app.buttons["stop"], in: app, timeout: 15)
    let transcript = app.scrollViews["transcript"].firstMatch
    try requireElement(transcript, in: app)
    let partial = text("Streaming fixture", in: app)
    try requireElement(partial, in: app, timeout: 20)
    XCTAssertTrue(partial.isHittable)
    XCTAssertTrue(
      transcript.frame.contains(partial.frame), "Streaming text must be visible in the transcript")
    let partialText = [partial.label, partial.value as? String ?? ""]
    XCTAssertFalse(
      partialText.contains { $0.contains(Self.streamed) }, "A buffered final answer cannot prove UI streaming"
    )
    let streaming = try await read(fixture)
    XCTAssertTrue(streaming.turns.contains { $0.status == .running })
    capture(app, name: "b4-streaming")
    _ = try await waitForTurns(fixture, completed: 1)
    try requireElement(text(Self.streamed, in: app), in: app)
    try checkJournal(try await runtime.command("snapshot"), requests: 1, tool: false)

    try type("smoke-tool", into: composer, app: app)
    try send(app)
    _ = try await waitForTurns(fixture, completed: 2)
    try requireElement(text(Self.toolReply, in: app), in: app)
    let tool = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture_lookup"))
    try requireElement(tool.firstMatch, in: app)
    XCTAssertEqual(tool.count, 1)
    capture(app, name: "b4-tool-result")
    try checkJournal(try await runtime.command("snapshot"), requests: 3, tool: true)

    try type(Self.restartDraft, into: composer, app: app)
    try await waitForDraft(Self.restartDraft, fixture: fixture)
    try await runtime.command("stop")
    try send(app)
    let message = app.staticTexts["recovery-message"]
    try requireElement(message, in: app, timeout: 15)
    let failed = try await waitForTurns(fixture, completed: 2, failed: 1)
    XCTAssertNil(failed.turns.first { $0.outcome == .failed }?.nativeTurnId)
    XCTAssertEqual(failed.thread.nativeThreadId, nativeId)
    try checkRecovery(app, expanded: false, draft: Self.restartDraft)
    transcript.scroll(byDeltaX: 0, deltaY: 600)
    try requireElement(text(Self.streamed, in: app), in: app)
    XCTAssertTrue(
      transcript.frame.contains(text(Self.streamed, in: app).frame),
      "Cached history must remain readable offline")
    let details = app.disclosureTriangles["recovery-details"]
    try requireElement(details, in: app)
    try await setDetails(details, message: message, expanded: true)
    try checkRecovery(app, expanded: true, draft: Self.restartDraft)
    try checkRenderedMessage(app, root: fixture.root)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    try checkJournal(try await runtime.command("snapshot"), requests: 3, tool: true)

    try await runtime.command("start")
    app.buttons["remediation"].click()
    XCTAssertTrue(app.descendants(matching: .any)["error-banner"].waitForNonExistence(timeout: 15))
    XCTAssertEqual(composer.value as? String, Self.restartDraft)
    try await waitForDraft(Self.restartDraft, fixture: fixture)
    try checkJournal(try await runtime.command("snapshot"), requests: 3, tool: true)
    let checked = try await read(fixture)
    XCTAssertEqual(checked.thread.nativeThreadId, nativeId)
    XCTAssertEqual(checked.turns.count, 3, "Check again must not submit the draft")
    try send(app)
    let final = try await waitForTurns(fixture, completed: 3, failed: 1)
    try requireElement(text(Self.continued, in: app), in: app)
    XCTAssertEqual(composer.value as? String, "")
    try await waitForDraft("", fixture: fixture)
    let manifest = try await runtime.command("snapshot")
    try checkJournal(manifest, requests: 4, tool: true)
    let requests = try XCTUnwrap(manifest["requests"]?.arrayValue)
    let messages = try XCTUnwrap(requests.last?["body"]?["messages"]?.arrayValue)
    XCTAssertEqual(
      messages.filter { $0["role"]?.stringValue == "user" && $0["content"]?.stringValue == Self.restartDraft }
        .count, 1)
    XCTAssertTrue(
      messages.contains {
        $0["role"]?.stringValue == "assistant" && $0["content"]?.stringValue == Self.toolReply
      })
    XCTAssertEqual(final.thread.nativeThreadId, nativeId)
    try assertItems(final)
    capture(app, name: "b4-recovered")
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("window.json"))
    try open(app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    try requireElement(row, in: app)
    row.click()
    try requireElement(text(Self.continued, in: app), in: app)
    let reopened = try await read(fixture)
    XCTAssertEqual(reopened.thread.nativeThreadId, nativeId)
    XCTAssertEqual(Set(reopened.turns.map(\.id)), Set(final.turns.map(\.id)))
    try assertItems(reopened)
    try checkJournal(try await runtime.command("snapshot"), requests: 4, tool: true)
    let attachment = XCTAttachment(
      data: try JSONEncoder().encode(reopened), uniformTypeIdentifier: "public.json")
    attachment.name = "b4-persisted-thread"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
    ).firstMatch
  }

  @MainActor private func open(_ app: XCUIApplication) throws {
    app.launch()
    app.activate()
    if !app.windows.firstMatch.exists {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    try requireElement(app.windows.firstMatch, in: app)
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

  @MainActor private func read(_ fixture: SmokeFixture) async throws -> ThreadRead.Result {
    try await fixture.client.request(ThreadRead.self, .init(threadId: fixture.threadId))
  }

  @MainActor private func waitForTurns(
    _ fixture: SmokeFixture, completed: Int, failed: Int = 0
  ) async throws -> ThreadRead.Result {
    let deadline = ContinuousClock.now + .seconds(45)
    while ContinuousClock.now < deadline {
      let state = try await read(fixture)
      if state.turns.count == completed + failed,
        state.turns.allSatisfy({ $0.status == .terminal }),
        state.turns.filter({ $0.outcome == .completed }).count == completed,
        state.turns.filter({ $0.outcome == .failed }).count == failed
      {
        return state
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(
      domain: "B4Smoke", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Expected terminal turn outcomes were not reached"])
  }

  @MainActor private func waitForDraft(_ text: String, fixture: SmokeFixture) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      let saved = try await fixture.client.request(DraftRead.self, .init(threadId: fixture.threadId))
      if (saved.draft?.text ?? "") == text { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Composer draft was not persisted")
    throw NSError(domain: "B4Smoke", code: 2)
  }

  @MainActor private func checkJournal(_ manifest: JSONValue, requests count: Int, tool: Bool) throws {
    let requests = try XCTUnwrap(manifest["requests"]?.arrayValue)
    XCTAssertEqual(requests.count, count)
    for request in requests {
      XCTAssertEqual(request["matched"]?.boolValue, true)
      XCTAssertEqual(request["status"]?.numberValue, 200)
      XCTAssertEqual(request["path"]?.stringValue, "/v1/chat/completions")
    }
    let expected: JSONValue = tool ? [["query": "fixture-proof"]] : []
    XCTAssertEqual(manifest["toolCalls"], expected)
  }

  private func assertItems(_ read: ThreadRead.Result) throws {
    XCTAssertEqual(Set(read.items.map(\.id)).count, read.items.count)
    for reply in [Self.streamed, Self.toolReply, Self.continued] {
      XCTAssertEqual(
        read.items.filter { $0.role == .assistant && $0.payload["text"]?.stringValue == reply }.count, 1)
    }
    for turn in read.turns {
      XCTAssertEqual(
        read.items.filter { $0.role == .user && $0.turnId == turn.id }.count, 1,
        "Each deliberate attempt has one user item")
    }
  }

  @MainActor private func capture(_ app: XCUIApplication, name: String) {
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
