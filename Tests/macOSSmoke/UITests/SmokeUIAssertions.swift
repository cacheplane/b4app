import AppKit
import XCTest

extension XCTestCase {
  @MainActor func setDetails(
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

  /// Launches the harness and waits for its window, opening one with New Window only when none comes.
  /// The harness presents a window at launch (`defaultLaunchBehavior(.presented)`), but on a slow
  /// runner it can come a few seconds late: a check that did not wait opened a second window beside
  /// it, which had no command centre, and the palette test then opened the palette where it would
  /// sit without one and dragged it into the Dock.
  @MainActor func launchWithWindow(_ app: XCUIApplication) throws {
    app.launch()
    app.activate()
    if !app.windows.firstMatch.waitForExistence(timeout: 15) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    try requireElement(app.windows.firstMatch, in: app)
  }

  @MainActor func requireElement(_ element: XCUIElement, in app: XCUIApplication, timeout: Double = 10) throws
  {
    guard element.waitForExistence(timeout: timeout) else {
      XCTFail("Missing \(element)\n\(app.debugDescription)")
      throw NSError(domain: "SmokeAssertion", code: 1)
    }
  }

  @MainActor func checkContentSize(
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
        XCTAssertEqual(
          geometry["windowFitsScreen"], 1, "Fixture window must fit its usable screen: \(geometry)")
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Fixture window geometry did not settle")
    throw NSError(domain: "SmokeAssertion", code: 2)
  }

  @MainActor func checkRecovery(
    _ app: XCUIApplication, expanded: Bool, draft: String = SmokeFixture.draft
  ) throws {
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
    XCTAssertEqual(app.textViews["composer"].value as? String, draft)
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
