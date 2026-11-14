import UIKit
import XCTest

final class BannerLayoutTests: XCTestCase {
  let coverage = JourneyCoverage()
  @MainActor
  func launch(
    _ screen: String, notice: String = "sync", accessibility: Bool = false, dark: Bool = false,
    recover: Bool = false, withSyncFailure: Bool = false,
    syncError: String? = nil, lastSyncAt: String? = nil, holdThreadOpen: Bool = false
  ) -> XCUIApplication {
    continueAfterFailure = false
    coverage.beforeLaunch(in: self)
    // Only when it is not portrait already. Asking for the orientation the device has waits for a
    // change that may never be confirmed: on main acef750 that wait timed out and failed a journey
    // that never leaves portrait (run 43534874181).
    if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = [
      "LAYOUT_SCREEN": screen, "LAYOUT_NOTICE": notice, "LAYOUT_DARK": dark ? "1" : "0",
      "LAYOUT_RECOVER": recover ? "1" : "0",
      "LAYOUT_SYNC_FAILURE": withSyncFailure ? "1" : "0",
    ]
    if let syncError { app.launchEnvironment["LAYOUT_SYNC_ERROR"] = syncError }
    if let lastSyncAt { app.launchEnvironment["LAYOUT_LAST_SYNC"] = lastSyncAt }
    if holdThreadOpen { app.launchEnvironment["LAYOUT_HOLD_THREAD_OPEN"] = "1" }
    if accessibility {
      app.launchArguments = [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    app.launch()
    coverage.didLaunch(in: self)
    return app
  }

  @MainActor
  func checkLayout(
    _ app: XCUIApplication, screen: String, hasBanner: Bool = true,
    covering checkpoints: [String] = []
  ) {
    // Settle on the screen before judging its banner. A detail launch shows the list and then pushes
    // the thread, and mid-push a banner exists in accessibility before it is hittable; one snapshot
    // taken then misreads the settled screen.
    let title =
      screen == "detail"
      ? "Fix the login bug"
      : screen == "new-thread" ? "New thread" : "Threads"
    let heading =
      screen == "connect-mac"
      ? app.staticTexts["Connect your Mac"] : app.navigationBars.staticTexts[title].firstMatch
    // Slow CI app/Simulator startup can stall accessibility queries beyond ten seconds while the
    // requested detail is still opening. Wait for that screen before judging layout; every
    // rendered-title, banner and control assertion below remains required.
    XCTAssertTrue(heading.waitForExistence(timeout: 60), app.debugDescription)
    let banners = app.descendants(matching: .any).matching(identifier: "sync.banner")
    let banner = hasBanner ? waitForVisible(banners) : visible(banners)
    XCTAssertEqual(banner != nil, hasBanner, app.debugDescription)
    let tree = XCTAttachment(
      string: app.debugDescription + "\nBANNERS:\n"
        + banners.allElementsBoundByIndex.map {
          "\($0.elementType) \($0.frame) hittable=\($0.isHittable) \($0.label)"
        }
        .joined(separator: "\n"))
    tree.name = "\(screen)-accessibility"
    tree.lifetime = .keepAlways
    add(tree)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = screen
    shot.lifetime = .keepAlways
    add(shot)
    if screen == "connect-mac" {
      if !app.buttons["Scan the code"].isHittable { app.scrollViews.firstMatch.swipeUp() }
      XCTAssertTrue(app.buttons["Scan the code"].isHittable)
    } else {
      XCTAssertGreaterThan(heading.frame.height, 0)
      let titleShot = XCTAttachment(screenshot: heading.screenshot())
      titleShot.name = "\(screen)-title"
      titleShot.lifetime = .keepAlways
      add(titleShot)
      XCTAssertGreaterThan(
        foregroundFraction(
          heading.screenshot().image, dark: app.launchEnvironment["LAYOUT_DARK"] == "1"),
        0.01, "The navigation title exists in accessibility but its text is not drawn")
      if let banner {
        XCTAssertLessThanOrEqual(
          heading.frame.maxY, contentFrame(banner).minY, "Banner covers \(title)")
      }
      if !["detail", "new-thread", "no-ready-detail"].contains(screen) {
        XCTAssertTrue(app.buttons["sidebar-more"].isHittable)
        XCTAssertTrue(app.buttons["list-search"].isHittable)
        XCTAssertTrue(app.buttons["new-thread-dock"].exists)
      }
    }
    for button in app.navigationBars.buttons.allElementsBoundByIndex {
      if let banner {
        XCTAssertFalse(
          button.frame.intersects(contentFrame(banner)), "Banner covers \(button.identifier)")
      }
    }
    if !["detail", "new-thread", "no-ready-detail"].contains(screen) {
      XCTAssertTrue(app.buttons["profile-button"].isHittable)
    }
    coverage.layout(in: self, covering: checkpoints)
  }

  /// The first element of `query` that is drawn and hittable, waiting up to `timeout` for one.
  /// Existence alone does not show that a navigation transition has finished.
  @MainActor
  func waitForVisible(_ query: XCUIElementQuery, timeout: TimeInterval = 10) -> XCUIElement? {
    let deadline = Date.now.addingTimeInterval(timeout)
    repeat {
      if let shown = visible(query) { return shown }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
    } while Date.now < deadline
    return nil
  }

  @MainActor
  func visible(_ query: XCUIElementQuery) -> XCUIElement? {
    query.allElementsBoundByIndex.first { $0.exists && $0.frame.height > 0 && $0.isHittable }
  }

  // A safe-area background's combined accessibility frame may extend all the way to y=0, even
  // though its text and controls are below the navigation bar. Judge those actual contents.
  @MainActor
  func contentFrame(_ element: XCUIElement) -> CGRect {
    let contents =
      element.descendants(matching: .staticText).allElementsBoundByIndex
      + element.descendants(matching: .button).allElementsBoundByIndex
    let frames = contents.filter { $0.isHittable && $0.frame.height > 0 }.map(\.frame)
    return frames.isEmpty ? element.frame : frames.reduce(CGRect.null) { $0.union($1) }
  }

  // UIKit can expose an obscured large title to accessibility even when none of its text is drawn.
  // Check the title's own screenshot too; geometry and `exists` alone missed the home-screen bug.
  @MainActor
  private func foregroundFraction(_ image: UIImage, dark: Bool) -> Double {
    guard let image = image.cgImage else { return 0 }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard rendered else { return 0 }
    let count = stride(from: 0, to: pixels.count, by: 4).filter { index in
      let rgb = pixels[index...index + 2]
      return dark ? rgb.allSatisfy { $0 > 190 } : rgb.allSatisfy { $0 < 80 }
    }.count
    return Double(count) / Double(image.width * image.height)
  }

  @MainActor
  func checkComposerAlignment(_ app: XCUIApplication) {
    let editor = app.textFields["composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.frame.minX, 32, accuracy: 0.5, "Draft text uses the page and field insets")
    let environment = app.descendants(matching: .any).matching(identifier: "picker-place").firstMatch
    let runtime = app.descendants(matching: .any).matching(identifier: "picker-runtime").firstMatch
    XCTAssertEqual(
      inkBounds(environment).minX, editor.frame.minX, accuracy: 1.5, "Environment text aligns with draft text"
    )
    XCTAssertEqual(
      app.frame.maxX - inkBounds(runtime).maxX, 32, accuracy: 1.5,
      "Trailing control ink uses the same inner and outer insets")
    XCTAssertTrue(app.buttons["picker-permission"].isHittable)
    XCTAssertTrue(runtime.isHittable)
  }

  /// The place picker opens the "Start in" sheet (D-209): the environment, then "No folder" (checked,
  /// the fresh default), and no "Choose folder…". Choosing the environment closes it and names it.
  @MainActor
  func checkPlaceSheet(_ app: XCUIApplication) {
    let place = app.descendants(matching: .any).matching(identifier: "picker-place").firstMatch
    XCTAssertEqual(place.value as? String, "No folder")
    place.tap()
    let sheet = app.descendants(matching: .any).matching(identifier: "place-sheet").firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The place opens the Start in sheet")
    XCTAssertTrue(app.navigationBars["Start in"].exists)
    let environment = app.buttons["place-row-project-1"]
    XCTAssertTrue(environment.exists)
    XCTAssertTrue(app.buttons["no-folder"].isSelected)
    XCTAssertFalse(app.buttons["choose-folder"].exists)
    environment.tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Choosing closes the sheet")
    XCTAssertEqual(place.value as? String, "Layout environment")
  }

  // Menu labels expose different accessibility bounds from plain labels. Measure rendered ink so
  // their extra hit areas cannot hide a visible alignment error. These cases use the light theme.
  @MainActor
  private func inkBounds(_ element: XCUIElement) -> CGRect {
    guard let image = element.screenshot().image.cgImage else { return .null }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard rendered else { return .null }
    var first = image.width
    var last = -1
    for index in stride(from: 0, to: pixels.count, by: 4) {
      if pixels[index...index + 2].allSatisfy({ $0 < 190 }) {
        let x = (index / 4) % image.width
        first = min(first, x)
        last = max(last, x)
      }
    }
    guard last >= first else { return .null }
    let frame = element.frame
    let scale = frame.width / CGFloat(image.width)
    return CGRect(
      x: frame.minX + CGFloat(first) * scale, y: frame.minY,
      width: CGFloat(last - first + 1) * scale, height: frame.height)
  }

  @MainActor
  func visibleSyncBanner(_ app: XCUIApplication) -> XCUIElement {
    let query = app.descendants(matching: .any).matching(identifier: "sync.banner")
    let banner = waitForVisible(query)
    XCTAssertNotNil(banner, app.debugDescription)
    return banner ?? query.firstMatch
  }

}
