import AppKit
import XCTest

/// Reading a long thread in the shipped root view over the real coordinator: scrolling back shows
/// "Jump to latest", pressing it returns to the end, and a fenced block's Copy puts exactly its code
/// on the pasteboard (D-233, D-236). Nothing here sends a turn.
final class ReadingSmokeTests: XCTestCase {
  /// What the host seeds between the fences (`SmokeHost.readingCode`).
  private static let code =
    "swift test --filter SyncTests \\\n  --parallel   # two spaces before, three before the comment"

  @MainActor func testJumpToLatestAndCopyCode() async throws {
    continueAfterFailure = false
    let fixture = try await SmokeFixture.start(in: self, reading: .short)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    // The reader's own clipboard comes back when the test ends.
    let clipboard = NSPasteboard.general.string(forType: .string)
    addTeardownBlock { @MainActor in
      NSPasteboard.general.clearContents()
      if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": "1100", "SMOKE_DARK": "0", "SMOKE_HEIGHT": "700",
      "SWIFTNIO_STRICT": "1",
    ]
    try launchWithWindow(app)
    let row = app.buttons.matching(identifier: "thread-row").matching(
      NSPredicate(format: "label CONTAINS %@", "Reading fixture")
    ).firstMatch
    try requireElement(row, in: app, timeout: 30)
    row.click()

    let transcript = app.scrollViews["transcript"].firstMatch
    try requireElement(transcript, in: app)
    let last = text("End of the reading fixture.", in: app)
    let jump = app.buttons["jump-to-latest"]
    // The thread opens at its end: the last line is in view and there is nothing to jump to.
    try requireElement(last, in: app)
    XCTAssertTrue(transcript.frame.intersects(last.frame))
    XCTAssertFalse(jump.exists, "Jump to latest must not show at the end")
    shot(app, "1-opened-at-end")

    // Copy, while the block is in view at the end.
    let copy = app.buttons["copy-code"]
    try requireElement(copy, in: app)
    XCTAssertEqual(copy.label, "Copy code")
    NSPasteboard.general.clearContents()
    copy.click()
    try await wait("the code on the pasteboard") { NSPasteboard.general.string(forType: .string) != nil }
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.code)
    try await wait("Copied") { copy.label == "Copied" }
    shot(app, "2-copied")
    try await wait("Copy again", timeout: .seconds(6)) { copy.label == "Copy code" }

    // Scrolling back: the last line leaves the view and the button appears.
    transcript.scroll(byDeltaX: 0, deltaY: 900)
    try requireElement(jump, in: app)
    try await wait("the last line out of view") { !last.exists || !transcript.frame.intersects(last.frame) }
    XCTAssertTrue(transcript.frame.contains(jump.frame), "the button sits inside the transcript")
    shot(app, "3-scrolled-back")

    // Pressing it, with a real click at its centre: back at the end, and the button is gone.
    jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(jump.disappears(within: 5))
    try await wait("the last line in view") { last.exists && transcript.frame.intersects(last.frame) }
    shot(app, "4-jumped-to-latest")

    // Scrolling back and returning to the end by hand also puts the button away.
    transcript.scroll(byDeltaX: 0, deltaY: 400)
    try requireElement(jump, in: app)
    transcript.scroll(byDeltaX: 0, deltaY: -2_000)
    XCTAssertTrue(jump.disappears(within: 5))
  }

  /// A thread whose history is one reply several windows tall opens at its end, like any other: the
  /// last line is laid out and in view, and nothing says the reader is away from the end.
  @MainActor func testATallFirstMessageOpensAtItsEnd() async throws {
    continueAfterFailure = false
    let fixture = try await SmokeFixture.start(in: self, reading: .tall)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": "1100", "SMOKE_DARK": "0", "SMOKE_HEIGHT": "700",
      "SWIFTNIO_STRICT": "1",
    ]
    try launchWithWindow(app)
    let row = app.buttons.matching(identifier: "thread-row").matching(
      NSPredicate(format: "label CONTAINS %@", "Reading fixture")
    ).firstMatch
    try requireElement(row, in: app, timeout: 30)
    row.click()
    let transcript = app.scrollViews["transcript"].firstMatch
    try requireElement(transcript, in: app)
    let last = text("End of the reading fixture.", in: app)
    let found = last.appears(within: 10)
    shot(app, "tall-opened")
    let tree = XCTAttachment(
      string: app.debugDescription.components(separatedBy: "\n").filter {
        $0.contains("transcript") || $0.contains("StaticText") || $0.contains("ScrollBar")
          || $0.contains("ValueIndicator")
      }.joined(separator: "\n"))
    tree.name = "reading-tree"
    tree.lifetime = .keepAlways
    add(tree)
    XCTAssertTrue(found, "the last message was never laid out")
    XCTAssertTrue(transcript.frame.intersects(last.frame), "the last message is out of view")
    let jump = app.buttons["jump-to-latest"]
    XCTAssertFalse(jump.exists)

    // Scrolling back at once, before anything in the thread has changed: the reader stays in the tall
    // reply and is not taken back to the end.
    transcript.scroll(byDeltaX: 0, deltaY: 700)
    try requireElement(jump, in: app)
    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(jump.exists, "the reader was taken back to the end")
    XCTAssertFalse(
      last.exists && transcript.frame.intersects(last.frame), "the last message is still in view")
    shot(app, "tall-scrolled-back")
    jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    XCTAssertTrue(jump.disappears(within: 5))
    try await wait("the last line in view") { last.exists && transcript.frame.intersects(last.frame) }
  }

  /// A thread with more rows than the transcript draws at once opens at its end with its latest rows;
  /// "Show earlier" at the top draws the rest, and the reader stays among the rows they were reading.
  @MainActor func testALongThreadShowsEarlierRowsOnRequest() async throws {
    continueAfterFailure = false
    let fixture = try await SmokeFixture.start(in: self, reading: .long)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": "1100", "SMOKE_DARK": "0", "SMOKE_HEIGHT": "700",
      "SWIFTNIO_STRICT": "1",
    ]
    try launchWithWindow(app)
    let row = app.buttons.matching(identifier: "thread-row").matching(
      NSPredicate(format: "label CONTAINS %@", "Reading fixture")
    ).firstMatch
    try requireElement(row, in: app, timeout: 30)
    row.click()
    let transcript = app.scrollViews["transcript"].firstMatch
    try requireElement(transcript, in: app)
    let last = text("End of the reading fixture.", in: app)
    try requireElement(last, in: app)
    XCTAssertTrue(transcript.frame.intersects(last.frame), "the thread did not open at its end")
    // 203 rows: the latest 150 are drawn, and the first reply is not among them.
    let earlier = app.buttons["show-earlier"]
    try requireElement(earlier, in: app)
    XCTAssertEqual(earlier.label, "Show earlier, 53 more")
    let firstReply = text("Earlier reply 1 of the reading fixture.", in: app)
    XCTAssertFalse(firstReply.exists)

    // To the top of what is drawn, and press it.
    try await wait("the button in view", timeout: .seconds(30)) {
      if transcript.frame.intersects(earlier.frame) { return true }
      transcript.scroll(byDeltaX: 0, deltaY: 3_000)
      return false
    }
    // The question and replies 1 to 52 are left out: reply 53 is the first row drawn.
    let reading = text("Earlier reply 53 of the reading fixture.", in: app)
    try requireElement(reading, in: app)
    XCTAssertTrue(transcript.frame.intersects(reading.frame))
    shot(app, "long-at-the-top")
    earlier.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    try requireElement(firstReply, in: app)
    XCTAssertTrue(earlier.disappears(within: 5), "nothing is left to show")
    // The row the reader was at is still in view; they were not taken to the top or the end.
    try await wait("the reply the reader was at, still in view") {
      transcript.frame.intersects(reading.frame)
    }
    XCTAssertFalse(transcript.frame.intersects(firstReply.frame), "the reader was taken to the top")
    shot(app, "long-earlier-shown")
    XCTAssertTrue(app.buttons["jump-to-latest"].exists)
  }

  @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)
    ).firstMatch
  }

  @MainActor private func wait(
    _ what: String, timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("Timed out waiting for \(what)")
        throw NSError(domain: "SmokeAssertion", code: 4)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Kept in the result bundle.
  @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = "reading-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
