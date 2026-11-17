import AppKit
import XCTest

/// Reading a long thread in the shipped root view over the real coordinator (D-237). Nothing here
/// sends a turn.
final class ReadingSmokeTests: XCTestCase {
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
