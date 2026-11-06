import UIKit
import XCTest

final class BannerLayoutTests: XCTestCase {
  let coverage = JourneyCoverage()
  @MainActor
  func launch(
    _ screen: String, notice: String = "sync", accessibility: Bool = false, dark: Bool = false,
    recover: Bool = false, withSyncFailure: Bool = false,
    syncError: String? = nil, lastSyncAt: String? = nil
  ) -> XCUIApplication {
    continueAfterFailure = false
    coverage.beforeLaunch(in: self)
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchEnvironment = [
      "LAYOUT_SCREEN": screen, "LAYOUT_NOTICE": notice, "LAYOUT_DARK": dark ? "1" : "0",
      "LAYOUT_RECOVER": recover ? "1" : "0",
      "LAYOUT_SYNC_FAILURE": withSyncFailure ? "1" : "0",
    ]
    if let syncError { app.launchEnvironment["LAYOUT_SYNC_ERROR"] = syncError }
    if let lastSyncAt { app.launchEnvironment["LAYOUT_LAST_SYNC"] = lastSyncAt }
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
    _ app: XCUIApplication, screen: String, hasBanner: Bool = true, covering checkpoints: [String] = []
  ) {
    let banners = app.descendants(matching: .any).matching(identifier: "sync.banner")
    if hasBanner { waitForVisibleBanner(banners, timeout: 10, positiveHeight: true) }
    let banner = banners.allElementsBoundByIndex.first {
      $0.frame.height > 0 && $0.isHittable
    }
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
      XCTAssertTrue(app.staticTexts["Connect your Mac"].waitForExistence(timeout: 10))
      if !app.buttons["Scan the code"].isHittable { app.scrollViews.firstMatch.swipeUp() }
      XCTAssertTrue(app.buttons["Scan the code"].isHittable)
    } else {
      let title =
        screen == "detail"
        ? "Fix the login bug"
        : screen == "new-thread" ? "New thread" : screen == "archived" ? "Archived" : "Threads"
      let heading = app.navigationBars.staticTexts[title].firstMatch
      XCTAssertTrue(heading.waitForExistence(timeout: 10), app.debugDescription)
      XCTAssertGreaterThan(heading.frame.height, 0)
      let titleShot = XCTAttachment(screenshot: heading.screenshot())
      titleShot.name = "\(screen)-title"
      titleShot.lifetime = .keepAlways
      add(titleShot)
      XCTAssertGreaterThan(
        foregroundFraction(heading.screenshot().image, dark: app.launchEnvironment["LAYOUT_DARK"] == "1"),
        0.01, "The navigation title exists in accessibility but its text is not drawn")
      if let banner {
        XCTAssertLessThanOrEqual(heading.frame.maxY, contentFrame(banner).minY, "Banner covers \(title)")
      }
      if !["detail", "new-thread", "no-ready-detail"].contains(screen) {
        XCTAssertTrue(app.buttons["sidebar-more"].isHittable)
        XCTAssertTrue(app.buttons["list-search"].isHittable)
        XCTAssertTrue(app.buttons["new-thread-dock"].exists)
      }
    }
    for button in app.navigationBars.buttons.allElementsBoundByIndex {
      if let banner {
        XCTAssertFalse(button.frame.intersects(contentFrame(banner)), "Banner covers \(button.identifier)")
      }
    }
    if !["detail", "new-thread", "no-ready-detail"].contains(screen) {
      XCTAssertTrue(app.buttons["profile-button"].isHittable)
    }
    coverage.layout(in: self, covering: checkpoints)
  }

  // Existence can precede the navigation transition finishing. Wait for the same condition the
  // layout assertion requires, inside the original readiness deadline, rather than weakening it.
  @MainActor
  private func waitForVisibleBanner(
    _ query: XCUIElementQuery, timeout: TimeInterval, positiveHeight: Bool
  ) {
    let visible = NSPredicate { _, _ in
      MainActor.assumeIsolated {
        query.allElementsBoundByIndex.contains {
          $0.exists && (!positiveHeight || $0.frame.height > 0) && $0.isHittable
        }
      }
    }
    let ready = XCTNSPredicateExpectation(predicate: visible, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
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
  func testListBannerKeepsLargeTitleAndToolbarVisible() {
    let app = launch("list")
    checkLayout(app, screen: "list")
  }

  @MainActor
  func testDetailBannerKeepsInlineTitleAndToolbarVisible() {
    let app = launch("detail")
    checkLayout(app, screen: "detail")
  }

  @MainActor
  func testHomeConnectionNoticeUsesPageGutter() {
    let app = launch("list", notice: "connecting", withSyncFailure: true)
    let notice = app.descendants(matching: .any).matching(identifier: "new-thread-dock-reason").firstMatch
    XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
    checkLayout(app, screen: "list")
    XCTAssertEqual(notice.frame.minX, 16, accuracy: 0.5, "Home notice must use the page gutter once")
  }

  @MainActor
  func testThreadConnectionNoticeUsesPageGutter() {
    let app = launch("detail", notice: "connecting", withSyncFailure: true)
    let notice = app.descendants(matching: .any).matching(identifier: "hub-link").firstMatch
    XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
    checkLayout(app, screen: "detail")
    XCTAssertEqual(notice.frame.minX, 16, accuracy: 0.5, "Thread notice must use the page gutter once")
  }

  @MainActor
  func testHomeComposerUsesPageGutters() {
    let app = launch("list", notice: "healthy")
    checkLayout(app, screen: "list", hasBanner: false)
    let dock = app.buttons["new-thread-dock"]
    XCTAssertEqual(dock.frame.minX, 16, accuracy: 0.5)
    XCTAssertEqual(app.frame.maxX - dock.frame.maxX, 16, accuracy: 0.5)
  }

  @MainActor
  func testThreadComposerAndControlsAlign() {
    let app = launch("detail", notice: "healthy")
    checkLayout(app, screen: "detail", hasBanner: false)
    checkComposerAlignment(app)
  }

  @MainActor
  func testNewThreadComposerAndControlsAlign() {
    let app = launch("new-thread", notice: "healthy")
    checkLayout(app, screen: "new-thread", hasBanner: false)
    checkComposerAlignment(app)
  }

  @MainActor
  func checkComposerAlignment(_ app: XCUIApplication) {
    let editor = app.textFields["composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.frame.minX, 32, accuracy: 0.5, "Draft text uses the page and field insets")
    let project = app.descendants(matching: .any).matching(identifier: "picker-project").firstMatch
    let runtime = app.descendants(matching: .any).matching(identifier: "picker-runtime").firstMatch
    XCTAssertEqual(
      inkBounds(project).minX, editor.frame.minX, accuracy: 1.5, "Project text aligns with draft text")
    XCTAssertEqual(
      app.frame.maxX - inkBounds(runtime).maxX, 32, accuracy: 1.5,
      "Trailing control ink uses the same inner and outer insets")
    XCTAssertTrue(app.buttons["picker-permission"].isHittable)
    XCTAssertTrue(runtime.isHittable)
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
  func testEveryWorkspaceSurfaceWithSyncFailure() {
    for screen in ["empty", "archived", "no-match", "detail", "new-thread", "no-ready-detail", "connect-mac"]
    {
      let app = launch(screen)
      checkLayout(app, screen: screen)
      app.terminate()
    }
  }

  @MainActor
  func testLandscapeLayouts() {
    for screen in ["list", "empty", "detail", "connect-mac"] {
      let app = launch(screen)
      XCUIDevice.shared.orientation = .landscapeLeft
      checkLayout(app, screen: screen)
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
  }

  @MainActor
  func testAccessibilityTextLayouts() {
    for screen in ["list", "empty", "detail", "connect-mac"] {
      let app = launch(screen, accessibility: true)
      checkLayout(app, screen: screen)
      app.terminate()
    }
  }

  @MainActor
  func testRefusalBannerInDarkMode() {
    for screen in ["list", "detail", "new-thread", "no-ready-detail", "connect-mac"] {
      let app = launch(screen, notice: "refused", dark: true)
      checkLayout(app, screen: screen)
      app.terminate()
    }
  }

  @MainActor
  func testOtherNoticeImplementations() {
    let cases = [
      ("list", "account", "account-notice"),
      ("list", "host-offline", "host-notice"),
      ("detail", "host-offline", "host-notice"),
      ("list", "action-error", "sidebar-error"),
      ("detail", "action-error", "error-banner"),
    ]
    for (screen, notice, identifier) in cases {
      for syncFailure in [false, true] {
        let app = launch(screen, notice: notice, withSyncFailure: syncFailure)
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        guard let shown = query.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
          XCTFail("\(identifier) is missing or obscured")
          return
        }
        checkLayout(app, screen: screen, hasBanner: syncFailure)
        let noticeFrame = query.allElementsBoundByIndex.filter { $0.isHittable }
          .map { contentFrame($0) }.reduce(CGRect.null) { $0.union($1) }
        for button in app.navigationBars.buttons.allElementsBoundByIndex {
          XCTAssertFalse(button.frame.intersects(noticeFrame), "\(identifier) covers navigation")
        }
        if notice == "account" {
          XCTAssertTrue(app.buttons["account-notice.dismiss"].isHittable)
        } else if notice == "action-error" {
          let dismiss = app.buttons["Dismiss"].firstMatch
          XCTAssertTrue(dismiss.isHittable)
          dismiss.tap()
          XCTAssertTrue(shown.waitForNonExistence(timeout: 5))
          checkLayout(app, screen: screen, hasBanner: syncFailure)
        }
        app.terminate()
      }
    }
    for screen in ["list", "detail"] {
      let app = launch(screen, notice: "stale")
      checkLayout(app, screen: screen)
      app.terminate()
    }
  }

  @MainActor
  func testHealthyLayoutsHaveNoSyncBanner() {
    for screen in ["list", "detail"] {
      let app = launch(screen, notice: "healthy")
      checkLayout(app, screen: screen, hasBanner: false)
      app.terminate()
    }
  }

  @MainActor
  func visibleSyncBanner(_ app: XCUIApplication) -> XCUIElement {
    let query = app.descendants(matching: .any).matching(identifier: "sync.banner")
    waitForVisibleBanner(query, timeout: 5, positiveHeight: false)
    let banner = query.allElementsBoundByIndex.first { $0.isHittable }
    XCTAssertNotNil(banner)
    return banner ?? query.firstMatch
  }

  @MainActor
  func testInitialSyncFailureUsesPlainLanguage() {
    for screen in ["list", "detail"] {
      let app = launch(screen, syncError: "Hub error 0 transport: Could not connect to the server.")
      checkLayout(app, screen: screen)
      XCTAssertEqual(visibleSyncBanner(app).label, "Not synced yet. Retrying…")
      app.terminate()
    }
  }

  @MainActor
  func testStaleSyncFailureKeepsLastSuccessTime() {
    for screen in ["list", "detail"] {
      let app = launch(screen, notice: "stale", syncError: "Hub error 503 maintenance: Service unavailable.")
      checkLayout(app, screen: screen)
      let label = visibleSyncBanner(app).label
      XCTAssertTrue(label.hasPrefix("Last synced "), label)
      XCTAssertTrue(label.hasSuffix(". Retrying…"), label)
      XCTAssertFalse(label.contains("Hub error"))
      XCTAssertFalse(label.contains("Offline"), "A server failure does not mean the phone is offline")
      app.terminate()
    }
  }

  @MainActor
  func testOlderSyncTimeAndLargeTextRemainReadable() {
    let earlier = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-172800))
    for screen in ["list", "detail"] {
      let app = launch(
        screen, notice: "stale", accessibility: true,
        syncError: "Hub error 0 transport: A long diagnostic message that should never fill the banner.",
        lastSyncAt: earlier)
      checkLayout(app, screen: screen)
      let label = visibleSyncBanner(app).label
      XCTAssertTrue(label.hasPrefix("Last synced "), label)
      XCTAssertTrue(label.hasSuffix(". Retrying…"), label)
      XCTAssertFalse(label.contains("diagnostic"))
      app.terminate()
    }
  }

  @MainActor
  func testRefusedLinkAsksForSignInInsteadOfRetrying() {
    for screen in ["list", "detail"] {
      let app = launch(screen, notice: "refused")
      checkLayout(app, screen: screen)
      XCTAssertEqual(visibleSyncBanner(app).label, "Log out, then sign in to reconnect.")
      app.terminate()
    }
  }

  @MainActor
  func testBlockedMirrorDoesNotPromiseRetry() {
    for screen in ["list", "detail"] {
      let app = launch(screen, notice: "blocked")
      checkLayout(app, screen: screen)
      XCTAssertEqual(visibleSyncBanner(app).label, "Sync paused. Check Diagnostics.")
      app.terminate()
    }
  }

  @MainActor
  func testSignInAndOnboardingDoNotShowWorkspaceNotices() {
    for screen in ["sign-in", "sign-in-no-camera", "onboarding"] {
      let app = launch(screen)
      if screen == "onboarding" {
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 10))
      } else if screen == "sign-in-no-camera" {
        XCTAssertTrue(app.buttons["Sign in with a passkey"].waitForExistence(timeout: 10))
      } else {
        XCTAssertTrue(app.buttons["Other ways to sign in"].waitForExistence(timeout: 10))
      }
      XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sync.banner").firstMatch.exists)
      app.terminate()
    }
  }

  @MainActor
  func testNavigateIntoThreadAndBackWithBannerPresent() {
    let app = launch("list")
    checkLayout(app, screen: "list")
    app.buttons["thread-row"].firstMatch.tap()
    checkLayout(app, screen: "detail")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    checkLayout(app, screen: "list")
  }

  @MainActor
  func testNotificationWaitsForThreadToSync() {
    for screen in ["notification-cold", "notification-warm"] {
      let app = launch(screen, notice: "healthy")
      if screen == "notification-warm" {
        app.buttons["fixture.open-notification"].tap()
      }
      XCTAssertTrue(
        app.descendants(matching: .any)["thread-opening"].firstMatch.waitForExistence(timeout: 10))
      let loading = XCTAttachment(screenshot: app.screenshot())
      loading.name = "\(screen)-loading"
      loading.lifetime = .keepAlways
      add(loading)
      XCTAssertFalse(app.staticTexts["New thread"].isHittable)
      app.buttons["fixture.finish-sync"].tap()
      XCTAssertTrue(app.navigationBars.staticTexts["Fix the login bug"].waitForExistence(timeout: 10))
      checkLayout(app, screen: "detail", hasBanner: false)
      app.terminate()
    }
  }

  @MainActor
  func testBackCancelsNotificationWaitingForSync() {
    let app = launch("notification-warm", notice: "healthy")
    app.buttons["fixture.open-notification"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["thread-opening"].firstMatch.waitForExistence(timeout: 10))
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["fixture.finish-sync"].tap()
    checkLayout(app, screen: "list", hasBanner: false)
    XCTAssertFalse(app.navigationBars.staticTexts["Fix the login bug"].isHittable)
    app.terminate()
  }

  @MainActor
  func testSearchWithBannerPresent() {
    let app = launch("list")
    checkLayout(app, screen: "list")
    app.buttons["list-search"].tap()
    let search = app.searchFields["Search threads"]
    XCTAssertTrue(search.isHittable)
    search.tap()
    search.typeText("no-such-thread")
    XCTAssertTrue(app.staticTexts["No matching threads."].waitForExistence(timeout: 5))
    let banners = app.descendants(matching: .any).matching(identifier: "sync.banner")
      .allElementsBoundByIndex.filter { $0.isHittable }
    XCTAssertFalse(banners.isEmpty)
    for banner in banners { XCTAssertFalse(contentFrame(banner).intersects(search.frame)) }
  }

  @MainActor
  func testExpandedAndCollapsedListTitles() {
    let app = launch("scrolling")
    checkLayout(app, screen: "scrolling")
    app.swipeUp()
    checkLayout(app, screen: "scrolling")
    app.swipeDown()
    app.swipeDown()
    checkLayout(app, screen: "scrolling")
  }

  @MainActor
  func testBannerClearsOnHomeAndDetail() {
    for screen in ["list", "detail"] {
      let app = launch(screen, recover: true)
      checkLayout(app, screen: screen)
      let banner = app.descendants(matching: .any).matching(identifier: "sync.banner")
        .allElementsBoundByIndex.first { $0.isHittable }!
      app.buttons["fixture.recover"].tap()
      XCTAssertTrue(
        banner.waitForNonExistence(timeout: 15))
      checkLayout(app, screen: screen, hasBanner: false)
      app.terminate()
    }
  }
}
