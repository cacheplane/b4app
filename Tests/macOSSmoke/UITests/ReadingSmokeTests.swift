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
    let fixture = try await SmokeFixture.start(in: self, reading: true)
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
