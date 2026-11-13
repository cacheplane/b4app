import AppKit
import NIOTransport
import WorkspaceClient
import WorkspaceProtocol
import XCTest

final class RecoverySmokeTests: XCTestCase {
  @MainActor func testCompactLightRecovery() async throws { try await journey(desktop: false, dark: false) }
  @MainActor func testCompactDarkRecovery() async throws { try await journey(desktop: false, dark: true) }
  @MainActor func testDesktopLightRecovery() async throws { try await journey(desktop: true, dark: false) }
  @MainActor func testDesktopDarkRecovery() async throws { try await journey(desktop: true, dark: true) }

  @MainActor private func journey(desktop: Bool, dark: Bool) async throws {
    continueAfterFailure = false
    let desktopHeight = try XCTUnwrap(
      Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_HEIGHT"] ?? "600"))
    let desktopWidth = try XCTUnwrap(
      Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_WIDTH"] ?? "1200"))
    let width = desktop ? desktopWidth : 900
    let height = desktop ? desktopHeight : 600
    guard height >= 600, desktopWidth >= 1000 else {
      throw NSError(domain: "SmokeAssertion", code: 5)
    }
    let fixture = try await SmokeFixture.start(in: self)
    // XCTest runs teardown blocks in reverse registration order, even when diagnostics fail.
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": String(width), "SMOKE_DARK": dark ? "1" : "0",
      "SMOKE_HEIGHT": String(height),
      "SWIFTNIO_STRICT": "1",
    ]
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground {
        if app.windows.firstMatch.exists {
          let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
          screenshot.name = "recovery-final-window"
          screenshot.lifetime = .keepAlways
          self.add(screenshot)
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "recovery-accessibility"
        tree.lifetime = .keepAlways
        self.add(tree)
      }
    }
    app.launch()
    app.activate()
    // The harness tests workspace interactions, independently of macOS's saved-window policy.
    if !app.windows.firstMatch.exists {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    try requireElement(app.windows.firstMatch, in: app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    let row = app.buttons.matching(identifier: "thread-row").firstMatch
    try requireElement(row, in: app, timeout: 30)
    XCTAssertTrue(row.label.contains("Archived recovery fixture"))
    row.click()
    let composer = app.textViews["composer"]
    try requireElement(composer, in: app)
    XCTAssertEqual(composer.value as? String, SmokeFixture.draft)
    // The transcript draws a moment after the composer: wait for it, as for the other elements.
    try requireElement(app.staticTexts["Cached transcript remains readable."], in: app)
    let send = app.buttons["send"]
    XCTAssertTrue(send.isEnabled)
    XCTAssertTrue(send.isHittable)
    send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    try await fixture.waitForResume(after: 0)
    let message = app.staticTexts["recovery-message"]
    try requireElement(message, in: app, timeout: 15)
    // These are stable identifiers, not localized button labels or injected fixture error state.
    let details = app.disclosureTriangles["recovery-details"]
    try requireElement(details, in: app)
    try await setDetails(details, message: message, expanded: true)
    try checkRecovery(app, expanded: true)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    try checkRenderedMessage(app, root: fixture.root)
    try await setDetails(details, message: message, expanded: false)
    try checkRecovery(app, expanded: false)
    try await setDetails(details, message: message, expanded: true)
    try checkRecovery(app, expanded: true)
    try await fixture.assertFailedAttempt(in: self)
    let resumes = try fixture.resumeCount()
    app.buttons["remediation"].click()
    try await fixture.waitForResume(after: resumes)
    let readyDeadline = ContinuousClock.now + .seconds(10)
    while !app.buttons["send"].isEnabled {
      guard ContinuousClock.now < readyDeadline else { throw NSError(domain: "SmokeAssertion", code: 4) }
      try await Task.sleep(for: .milliseconds(100))
    }
    try checkRecovery(app, expanded: true)
    XCTAssertEqual(composer.value as? String, SmokeFixture.draft)
    try await fixture.assertFailedAttempt(in: self)
    app.buttons["recovery-dismiss"].click()
    XCTAssertTrue(app.descendants(matching: .any)["error-banner"].waitForNonExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, SmokeFixture.draft)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("window.json"))
    app.launch()
    app.activate()
    // The harness tests workspace interactions, independently of macOS's saved-window policy.
    if !app.windows.firstMatch.exists {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    try requireElement(app.windows.firstMatch, in: app)
    try await checkContentSize(app, root: fixture.root, width: width, height: height)
    XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
    row.click()
    try requireElement(composer, in: app)
    XCTAssertEqual(composer.value as? String, SmokeFixture.draft)
    try await fixture.assertFailedAttempt(in: self)
  }

}
