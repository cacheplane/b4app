import Foundation
import UIKit
import XCTest

extension BannerLayoutTests {
  @MainActor private func back(_ app: XCUIApplication) {
    app.navigationBars.buttons.element(boundBy: 0).tap()
    // All callers return to the list. Wait for that state before the next navigation action,
    // as checkLayout does on other journeys; a tap alone does not prove the pop has settled.
    XCTAssertTrue(app.buttons["new-thread-dock"].appears(within: 60), app.debugDescription)
  }

  @MainActor func testWorkspaceNavigationJourney() {
    let app = launch("list")
    checkLayout(
      app, screen: "list")
    app.buttons["thread-row"].firstMatch.tap()
    checkLayout(
      app, screen: "detail")
    back(app)
    checkLayout(app, screen: "list")
    // The list keeps no search field of its own (D-201): the button opens the Search sheet.
    // The sheet is the palette (D-207), opened for Find; its field says what Find searches.
    XCTAssertFalse(app.searchFields.firstMatch.exists)
    app.buttons["list-search"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["search-palette"].firstMatch.appears(within: 5))
    let search = app.searchFields["Threads, environments, commands"]
    XCTAssertTrue(search.appears(within: 5))
    XCTAssertTrue(search.isHittable)
    app.terminate()

    let scrolling = launch("scrolling")
    checkLayout(scrolling, screen: "scrolling")
    scrolling.swipeUp()
    checkLayout(scrolling, screen: "scrolling")
    scrolling.swipeDown()
    scrolling.swipeDown()
    checkLayout(scrolling, screen: "scrolling")
    scrolling.terminate()
  }

  @MainActor func testHealthyComposerJourney() {
    let app = launch("list", notice: "healthy")
    checkLayout(
      app, screen: "list", hasBanner: false)
    let dock = app.buttons["new-thread-dock"]
    XCTAssertEqual(dock.frame.minX, 16, accuracy: 0.5)
    XCTAssertEqual(app.frame.maxX - dock.frame.maxX, 16, accuracy: 0.5)
    app.buttons["thread-row"].firstMatch.tap()
    checkLayout(
      app, screen: "detail", hasBanner: false)
    checkComposerAlignment(app)
    back(app)
    app.buttons["new-thread-dock"].tap()
    checkLayout(
      app, screen: "new-thread", hasBanner: false)
    checkComposerAlignment(app)
    checkPlaceSheet(app)
    app.terminate()
  }

  @MainActor func testNotificationOpenJourneys() {
    for (index, screen) in ["notification-cold", "notification-warm"].enumerated() {
      let app = launch(screen, notice: "healthy")
      if screen == "notification-warm" { app.buttons["fixture.open-notification"].tap() }
      XCTAssertTrue(
        app.descendants(matching: .any)["thread-opening"].firstMatch.appears(within: 10))
      let loading = XCTAttachment(screenshot: app.screenshot())
      loading.name = "\(screen)-loading"
      loading.lifetime = .keepAlways
      add(loading)
      XCTAssertFalse(app.staticTexts["New thread"].isHittable)
      app.buttons["fixture.finish-sync"].tap()
      XCTAssertTrue(app.navigationBars.staticTexts["Fix the login bug"].appears(within: 10))
      checkLayout(
        app, screen: "detail", hasBanner: false)
      app.terminate()
    }
  }
}
