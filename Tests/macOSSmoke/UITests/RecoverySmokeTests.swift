import AppKit
import NIOTransport
import WorkspaceClient
import WorkspaceProtocol
import XCTest

final class RecoverySmokeTests: XCTestCase {
  @MainActor func testCompactLightRecovery() async throws { try await journey(width: 900, dark: false) }
  @MainActor func testCompactDarkRecovery() async throws { try await journey(width: 900, dark: true) }
  @MainActor func testDesktopLightRecovery() async throws { try await journey(width: 1200, dark: false) }
  @MainActor func testDesktopDarkRecovery() async throws { try await journey(width: 1200, dark: true) }

  @MainActor private func journey(width: Int, dark: Bool) async throws {
    continueAfterFailure = false
    let desktopHeight = try XCTUnwrap(
      Int(ProcessInfo.processInfo.environment["SMOKE_DESKTOP_HEIGHT"] ?? "600"))
    let height = width == 900 ? 600 : desktopHeight
    guard height >= 600 else { throw NSError(domain: "SmokeAssertion", code: 5) }
    let fixture = try await SmokeFixture.start()
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
    XCTAssertTrue(app.staticTexts["Cached transcript remains readable."].exists)
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

  @MainActor private func setDetails(
    _ details: XCUIElement, message: XCUIElement, expanded: Bool
  ) async throws {
    // The native AX frame includes focus padding and expands around its diagnostics. Anchor the
    // actual arrow beside the primary message rather than the center of that changing frame.
    let arrowX = message.frame.minX - details.frame.minX + 4
    details.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: arrowX, dy: 8.5)).click()
    let expected = expanded ? "1" : "0"
    let deadline = ContinuousClock.now + .seconds(5)
    while String(describing: details.value ?? "") != expected {
      guard ContinuousClock.now < deadline else {
        XCTFail("Details did not become \(expanded ? "expanded" : "collapsed")")
        throw NSError(domain: "SmokeAssertion", code: 3)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  @MainActor func requireElement(_ element: XCUIElement, in app: XCUIApplication, timeout: Double = 10) throws
  {
    guard element.waitForExistence(timeout: timeout) else {
      XCTFail("Missing \(element)\n\(app.debugDescription)")
      throw NSError(domain: "SmokeAssertion", code: 1)
    }
  }

  @MainActor private func checkContentSize(
    _ app: XCUIApplication, root: URL, width: Int, height: Int
  ) async throws {
    // Compare a native content measurement with the independently captured window frame.
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let frame = app.windows.firstMatch.frame
      if let data = try? Data(contentsOf: root.appendingPathComponent("window.json")),
        let geometry = try? JSONDecoder().decode([String: Double].self, from: data),
        let frameWidth = geometry["frameWidth"], let frameHeight = geometry["frameHeight"],
        abs(frame.width - frameWidth) <= 1, abs(frame.height - frameHeight) <= 1
      {
        XCTAssertEqual(geometry["contentWidth"], Double(width))
        XCTAssertEqual(geometry["contentHeight"], Double(height))
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Fixture window geometry did not settle")
    throw NSError(domain: "SmokeAssertion", code: 2)
  }

  @MainActor private func checkRecovery(_ app: XCUIApplication, expanded: Bool) throws {
    let notices = app.descendants(matching: .any).matching(identifier: "error-banner")
    XCTAssertEqual(notices.count, 1, app.debugDescription)
    XCTAssertFalse(app.descendants(matching: .any)["continuity-banner"].exists)
    let action = app.buttons["remediation"]
    let dismiss = app.buttons["recovery-dismiss"]
    try requireElement(action, in: app)
    try requireElement(dismiss, in: app)
    XCTAssertTrue(action.isHittable)
    XCTAssertTrue(dismiss.isHittable)
    XCTAssertEqual(action.frame.midY, dismiss.frame.midY, accuracy: 1)
    XCTAssertLessThanOrEqual(action.frame.maxX, dismiss.frame.minX)
    XCTAssertTrue(app.textViews["composer"].isHittable)
    XCTAssertEqual(app.textViews["composer"].value as? String, SmokeFixture.draft)
    let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
    for element in [app.staticTexts["recovery-message"], action, dismiss, app.textViews["composer"]] {
      XCTAssertTrue(window.contains(element.frame), "Recovery controls extend outside the window")
    }
    let diagnostics = notices.firstMatch.scrollViews.firstMatch
    if expanded {
      try requireElement(diagnostics, in: app)
      XCTAssertLessThanOrEqual(diagnostics.frame.height, 121)
    } else {
      XCTAssertFalse(diagnostics.exists, "Collapsing Details must hide the diagnostics")
    }
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = expanded ? "recovery-expanded" : "recovery-collapsed"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
