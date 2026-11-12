import Foundation
import UIKit
import XCTest

extension BannerLayoutTests {
  private func id(_ method: String, _ index: Int = 1) -> String { "\(method)#\(index)" }
  private func point(_ method: String, _ index: Int = 1, _ layout: Int = 1) -> String {
    id(method, index) + "/layout#\(layout)"
  }
  @MainActor private func done(_ identifiers: String...) { coverage.complete(identifiers, in: self) }
  @MainActor private func back(_ app: XCUIApplication) {
    app.navigationBars.buttons.element(boundBy: 0).tap()
    // All callers return to the list. Wait for that state before the next navigation action,
    // as checkLayout does on other journeys; a tap alone does not prove the pop has settled.
    XCTAssertTrue(app.buttons["new-thread-dock"].waitForExistence(timeout: 60), app.debugDescription)
  }

  @MainActor func testWorkspaceNavigationJourney() {
    let app = launch("list")
    checkLayout(
      app, screen: "list",
      covering: [
        point("testListBannerKeepsLargeTitleAndToolbarVisible"),
        point("testNavigateIntoThreadAndBackWithBannerPresent"),
      ])
    done(id("testListBannerKeepsLargeTitleAndToolbarVisible"))
    app.buttons["thread-row"].firstMatch.tap()
    checkLayout(
      app, screen: "detail", covering: [point("testNavigateIntoThreadAndBackWithBannerPresent", 1, 2)])
    back(app)
    checkLayout(
      app, screen: "list", covering: [point("testNavigateIntoThreadAndBackWithBannerPresent", 1, 3)])
    done(id("testNavigateIntoThreadAndBackWithBannerPresent"))
    checkLayout(app, screen: "list", covering: [point("testSearchWithBannerPresent")])
    // The list keeps no search field of its own (D-201): the button opens the Search sheet.
    // The sheet is the palette (D-207), opened for Find; its field says what Find searches.
    XCTAssertFalse(app.searchFields.firstMatch.exists)
    app.buttons["list-search"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["search-palette"].firstMatch.waitForExistence(timeout: 5))
    let search = app.searchFields["Threads, environments, commands"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    XCTAssertTrue(search.isHittable)
    done(id("testSearchWithBannerPresent"))
    app.terminate()

    let scrolling = launch("scrolling")
    checkLayout(scrolling, screen: "scrolling", covering: [point("testExpandedAndCollapsedListTitles")])
    scrolling.swipeUp()
    checkLayout(scrolling, screen: "scrolling", covering: [point("testExpandedAndCollapsedListTitles", 1, 2)])
    scrolling.swipeDown()
    scrolling.swipeDown()
    checkLayout(scrolling, screen: "scrolling", covering: [point("testExpandedAndCollapsedListTitles", 1, 3)])
    done(id("testExpandedAndCollapsedListTitles"))
    scrolling.terminate()
  }

  @MainActor func testHealthyComposerJourney() {
    let app = launch("list", notice: "healthy")
    checkLayout(
      app, screen: "list", hasBanner: false,
      covering: [
        point("testHomeComposerUsesPageGutters"), point("testHealthyLayoutsHaveNoSyncBanner", 1),
      ])
    let dock = app.buttons["new-thread-dock"]
    XCTAssertEqual(dock.frame.minX, 16, accuracy: 0.5)
    XCTAssertEqual(app.frame.maxX - dock.frame.maxX, 16, accuracy: 0.5)
    done(id("testHomeComposerUsesPageGutters"), id("testHealthyLayoutsHaveNoSyncBanner", 1))
    app.buttons["thread-row"].firstMatch.tap()
    checkLayout(
      app, screen: "detail", hasBanner: false,
      covering: [
        point("testThreadComposerAndControlsAlign"), point("testHealthyLayoutsHaveNoSyncBanner", 2),
      ])
    checkComposerAlignment(app)
    done(id("testThreadComposerAndControlsAlign"), id("testHealthyLayoutsHaveNoSyncBanner", 2))
    back(app)
    app.buttons["new-thread-dock"].tap()
    checkLayout(
      app, screen: "new-thread", hasBanner: false, covering: [point("testNewThreadComposerAndControlsAlign")])
    checkComposerAlignment(app)
    done(id("testNewThreadComposerAndControlsAlign"))
    app.terminate()
  }

  @MainActor func testSyncCopyJourneys() {
    let cases: [(String, String, String?)] = [
      (
        "testInitialSyncFailureUsesPlainLanguage", "sync",
        "Hub error 0 transport: Could not connect to the server."
      ),
      (
        "testStaleSyncFailureKeepsLastSuccessTime", "stale", "Hub error 503 maintenance: Service unavailable."
      ),
      ("testRefusedLinkAsksForSignInInsteadOfRetrying", "refused", nil),
      ("testBlockedMirrorDoesNotPromiseRetry", "blocked", nil),
    ]
    for (method, notice, raw) in cases {
      let app = launch("list", notice: notice, syncError: raw)
      for (index, screen) in ["list", "detail"].enumerated() {
        if index == 1 { app.buttons["thread-row"].firstMatch.tap() }
        checkLayout(app, screen: screen, covering: [point(method, index + 1)])
        let label = visibleSyncBanner(app).label
        switch notice {
        case "sync": XCTAssertEqual(label, "Not synced yet. Retrying…")
        case "stale":
          XCTAssertTrue(label.hasPrefix("Last synced "), label)
          XCTAssertTrue(label.hasSuffix(". Retrying…"), label)
          XCTAssertFalse(label.contains("Hub error"))
          XCTAssertFalse(label.contains("Offline"), "A server failure does not mean the phone is offline")
        case "refused": XCTAssertEqual(label, "Log out, then sign in to reconnect.")
        case "blocked": XCTAssertEqual(label, "Sync paused. Check Diagnostics.")
        default: XCTFail("Unmapped copy case")
        }
        done(id(method, index + 1))
      }
      app.terminate()
    }
  }

  @MainActor private func assertSecondary(
    _ app: XCUIApplication, screen: String, notice: String, identifier: String,
    syncFailure: Bool, legacyIndex: Int
  ) {
    let query = app.descendants(matching: .any).matching(identifier: identifier)
    guard waitForVisible(query) != nil else {
      XCTFail("\(identifier) is missing or obscured\n\(app.debugDescription)")
      return
    }
    checkLayout(
      app, screen: screen, hasBanner: syncFailure,
      covering: [point("testOtherNoticeImplementations", legacyIndex)])
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
      // Re-query after dismissal; an indexed handle is not an immutable snapshot.
      XCTAssertTrue(query.firstMatch.waitForNonExistence(timeout: 5))
      checkLayout(
        app, screen: screen, hasBanner: syncFailure,
        covering: [point("testOtherNoticeImplementations", legacyIndex, 2)])
    }
    done(id("testOtherNoticeImplementations", legacyIndex))
  }

  @MainActor func testSecondaryNoticeJourneys() {
    for (flag, sync) in [false, true].enumerated() {
      let account = launch("list", notice: "account", withSyncFailure: sync)
      assertSecondary(
        account, screen: "list", notice: "account", identifier: "account-notice",
        syncFailure: sync, legacyIndex: flag + 1)
      account.terminate()
      let offline = launch("list", notice: "host-offline", withSyncFailure: sync)
      assertSecondary(
        offline, screen: "list", notice: "host-offline", identifier: "host-notice",
        syncFailure: sync, legacyIndex: flag + 3)
      offline.buttons["thread-row"].firstMatch.tap()
      assertSecondary(
        offline, screen: "detail", notice: "host-offline", identifier: "host-notice",
        syncFailure: sync, legacyIndex: flag + 5)
      offline.terminate()
      let error = launch("list", notice: "action-error", withSyncFailure: sync)
      assertSecondary(
        error, screen: "list", notice: "action-error", identifier: "sidebar-error",
        syncFailure: sync, legacyIndex: flag + 7)
      error.terminate()
      // Keep the original cold error detail: a warm refresh can clear a fixture-injected error.
      let detail = launch("detail", notice: "action-error", withSyncFailure: sync)
      assertSecondary(
        detail, screen: "detail", notice: "action-error", identifier: "error-banner",
        syncFailure: sync, legacyIndex: flag + 9)
      detail.terminate()
    }
    let stale = launch("list", notice: "stale")
    checkLayout(stale, screen: "list", covering: [point("testOtherNoticeImplementations", 11)])
    done(id("testOtherNoticeImplementations", 11))
    stale.buttons["thread-row"].firstMatch.tap()
    checkLayout(stale, screen: "detail", covering: [point("testOtherNoticeImplementations", 12)])
    done(id("testOtherNoticeImplementations", 12))
    stale.terminate()
  }

  @MainActor func testConnectionNoticeJourney() {
    let app = launch("list", notice: "connecting", withSyncFailure: true)
    for (screen, identifier, method) in [
      ("list", "new-thread-dock-reason", "testHomeConnectionNoticeUsesPageGutter"),
      ("detail", "hub-link", "testThreadConnectionNoticeUsesPageGutter"),
    ] {
      if screen == "detail" { app.buttons["thread-row"].firstMatch.tap() }
      let notice = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
      XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
      checkLayout(app, screen: screen, covering: [point(method)])
      XCTAssertEqual(notice.frame.minX, 16, accuracy: 0.5, "Connection notice uses one page gutter")
      done(id(method))
    }
    app.terminate()
  }

  @MainActor func testStartupAndEmptyJourneys() {
    for (screen, index) in [
      // Ordinal 3 was the unmatched in-list search, which main removed with that field (D-201).
      ("empty", 1), ("archived", 2), ("detail", 4), ("new-thread", 5), ("no-ready-detail", 6),
      ("connect-mac", 7),
    ] {
      let app = launch(screen)
      var checkpoints = [point("testEveryWorkspaceSurfaceWithSyncFailure", index)]
      if screen == "detail" { checkpoints.append(point("testDetailBannerKeepsInlineTitleAndToolbarVisible")) }
      checkLayout(app, screen: screen, covering: checkpoints)
      done(id("testEveryWorkspaceSurfaceWithSyncFailure", index))
      if screen == "detail" { done(id("testDetailBannerKeepsInlineTitleAndToolbarVisible")) }
      app.terminate()
    }
  }

  @MainActor func testLandscapeJourney() {
    for (screen, index) in [("list", 1), ("empty", 2), ("connect-mac", 4)] {
      let app = launch(screen)
      XCUIDevice.shared.orientation = .landscapeLeft
      checkLayout(app, screen: screen, covering: [point("testLandscapeLayouts", index)])
      done(id("testLandscapeLayouts", index))
      if screen == "list" {
        app.buttons["thread-row"].firstMatch.tap()
        checkLayout(app, screen: "detail", covering: [point("testLandscapeLayouts", 3)])
        done(id("testLandscapeLayouts", 3))
      }
      app.terminate()
      XCUIDevice.shared.orientation = .portrait
    }
  }

  @MainActor func testMaximumTextJourneys() {
    for (screen, index) in [("list", 1), ("empty", 2), ("connect-mac", 4)] {
      let app = launch(screen, accessibility: true)
      checkLayout(app, screen: screen, covering: [point("testAccessibilityTextLayouts", index)])
      done(id("testAccessibilityTextLayouts", index))
      if screen == "list" {
        app.buttons["thread-row"].firstMatch.tap()
        checkLayout(app, screen: "detail", covering: [point("testAccessibilityTextLayouts", 3)])
        done(id("testAccessibilityTextLayouts", 3))
      }
      app.terminate()
    }
    let earlier = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-172800))
    let app = launch(
      "list", notice: "stale", accessibility: true,
      syncError: "Hub error 0 transport: A long diagnostic message that should never fill the banner.",
      lastSyncAt: earlier)
    for (index, screen) in ["list", "detail"].enumerated() {
      if index == 1 { app.buttons["thread-row"].firstMatch.tap() }
      checkLayout(
        app, screen: screen, covering: [point("testOlderSyncTimeAndLargeTextRemainReadable", index + 1)])
      let label = visibleSyncBanner(app).label
      XCTAssertTrue(label.hasPrefix("Last synced "), label)
      XCTAssertTrue(label.hasSuffix(". Retrying…"), label)
      XCTAssertFalse(label.contains("diagnostic"))
      done(id("testOlderSyncTimeAndLargeTextRemainReadable", index + 1))
    }
    app.terminate()
  }

  @MainActor func testDarkRefusalJourney() {
    for (screen, index) in [("list", 1), ("no-ready-detail", 4), ("connect-mac", 5)] {
      let app = launch(screen, notice: "refused", dark: true)
      checkLayout(app, screen: screen, covering: [point("testRefusalBannerInDarkMode", index)])
      done(id("testRefusalBannerInDarkMode", index))
      if screen == "list" {
        app.buttons["thread-row"].firstMatch.tap()
        checkLayout(app, screen: "detail", covering: [point("testRefusalBannerInDarkMode", 2)])
        done(id("testRefusalBannerInDarkMode", 2))
        back(app)
        app.buttons["new-thread-dock"].tap()
        checkLayout(app, screen: "new-thread", covering: [point("testRefusalBannerInDarkMode", 3)])
        done(id("testRefusalBannerInDarkMode", 3))
      }
      app.terminate()
    }
  }

  @MainActor func testRecoveryJourneys() {
    for (index, screen) in ["list", "detail"].enumerated() {
      let app = launch(screen, recover: true)
      checkLayout(app, screen: screen, covering: [point("testBannerClearsOnHomeAndDetail", index + 1)])
      let recover = app.buttons["fixture.recover"]
      recover.tap()
      // The Simulator can lose a tap: on main f4ca23d it left this button pressed and the status
      // unchanged. The control exists only in the fixture, so a second tap checks no less of the app.
      if !recover.waitForNonExistence(timeout: 3), recover.isHittable { recover.tap() }
      // The control goes once the fixture's status has changed, so a lost tap fails here, not as a
      // banner that seemed not to clear.
      XCTAssertTrue(recover.waitForNonExistence(timeout: 10), "The fixture did not take the tap")
      let banners = app.descendants(matching: .any).matching(identifier: "sync.banner")
      XCTAssertTrue(banners.firstMatch.waitForNonExistence(timeout: 10), app.debugDescription)
      checkLayout(
        app, screen: screen, hasBanner: false,
        covering: [point("testBannerClearsOnHomeAndDetail", index + 1, 2)])
      done(id("testBannerClearsOnHomeAndDetail", index + 1))
      app.terminate()
    }
  }

  @MainActor func testEntryRootJourneys() {
    for (index, screen) in ["sign-in", "sign-in-no-camera", "onboarding"].enumerated() {
      let app = launch(screen)
      if screen == "onboarding" {
        XCTAssertTrue(app.staticTexts["onboarding.title"].waitForExistence(timeout: 10))
      } else if screen == "sign-in-no-camera" {
        XCTAssertTrue(app.buttons["Sign in with a passkey"].waitForExistence(timeout: 10))
      } else {
        XCTAssertTrue(app.buttons["Other ways to sign in"].waitForExistence(timeout: 10))
      }
      XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sync.banner").firstMatch.exists)
      done(id("testSignInAndOnboardingDoNotShowWorkspaceNotices", index + 1))
      app.terminate()
    }
  }

  @MainActor func testNotificationOpenJourneys() {
    for (index, screen) in ["notification-cold", "notification-warm"].enumerated() {
      let app = launch(screen, notice: "healthy")
      if screen == "notification-warm" { app.buttons["fixture.open-notification"].tap() }
      XCTAssertTrue(
        app.descendants(matching: .any)["thread-opening"].firstMatch.waitForExistence(timeout: 10))
      let loading = XCTAttachment(screenshot: app.screenshot())
      loading.name = "\(screen)-loading"
      loading.lifetime = .keepAlways
      add(loading)
      XCTAssertFalse(app.staticTexts["New thread"].isHittable)
      app.buttons["fixture.finish-sync"].tap()
      XCTAssertTrue(app.navigationBars.staticTexts["Fix the login bug"].waitForExistence(timeout: 10))
      checkLayout(
        app, screen: "detail", hasBanner: false,
        covering: [point("testNotificationWaitsForThreadToSync", index + 1)])
      done(id("testNotificationWaitsForThreadToSync", index + 1))
      app.terminate()
    }
  }

  @MainActor func testNotificationCancelJourney() {
    // The app gives up on a notified thread after 15 s and returns to the list by itself. A runner
    // stall, or a system notification banner XCTest waits out before tapping, can outlast that, and
    // the late Back tap then lands on the list. Holding the wait leaves Back as the only way out.
    let app = launch("notification-warm", notice: "healthy", holdThreadOpen: true)
    app.buttons["fixture.open-notification"].tap()
    let opening = app.descendants(matching: .any)["thread-opening"].firstMatch
    XCTAssertTrue(opening.waitForExistence(timeout: 10))
    back(app)
    XCTAssertTrue(opening.waitForNonExistence(timeout: 10))
    app.buttons["fixture.finish-sync"].tap()
    checkLayout(
      app, screen: "list", hasBanner: false, covering: [point("testBackCancelsNotificationWaitingForSync")])
    XCTAssertFalse(app.navigationBars.staticTexts["Fix the login bug"].isHittable)
    done(id("testBackCancelsNotificationWaitingForSync"))
    app.terminate()
  }
}
