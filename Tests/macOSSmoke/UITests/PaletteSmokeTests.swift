import AppKit
import NIOTransport
import WorkspaceClient
import WorkspaceProtocol
import XCTest

/// The command palette and the composer's `/` list, driven by real keys in the shipped root view
/// over the real coordinator and the fake Codex runtime. Nothing here sends a turn.
final class PaletteSmokeTests: XCTestCase {
  @MainActor func testPaletteAndSlashByKeyboard() async throws {
    continueAfterFailure = false
    let fixture = try await SmokeFixture.start(in: self)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": "1100", "SMOKE_DARK": "0", "SMOKE_HEIGHT": "700",
      "SWIFTNIO_STRICT": "1",
    ]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.exists {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    try requireElement(app.windows.firstMatch, in: app)
    try requireElement(app.buttons.matching(identifier: "thread-row").firstMatch, in: app, timeout: 30)

    let palette = app.descendants(matching: .any)["search-palette"]
    let field = app.textFields["palette-field"]
    let rows = app.buttons.matching(identifier: "palette-row")
    let composer = app.textViews["composer"]
    let draft = SmokeFixture.draft

    // Find: the field has the keyboard as it opens, a typed query selects its best row, Return opens it.
    app.typeKey("k", modifierFlags: .command)
    try requireElement(field, in: app)
    app.typeText("arch")
    try await wait("the thread to be found") { rows.firstMatch.label.contains("Archived recovery fixture") }
    XCTAssertTrue(rows.firstMatch.isSelected)
    snap(app, "find-typed")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
    try requireElement(composer, in: app)
    try await wait("the draft to load") { composer.value as? String == draft }
    // The cursor came back to the composer, at the end of the draft, which was not replaced.
    app.typeText(" ok")
    try await Task.sleep(for: .milliseconds(600))
    snap(app, "after-open")
    XCTAssertEqual(
      composer.value as? String, draft + " ok",
      "focus: \(app.debugDescription.components(separatedBy: "\n").filter { $0.contains("Keyboard Focused") })"
    )
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    XCTAssertEqual(composer.value as? String, draft)

    // Commands: ⇧⌘P, a command runs on Return and the palette closes on its completion.
    app.typeKey("p", modifierFlags: [.command, .shift])
    try requireElement(field, in: app)
    snap(app, "commands-start")
    app.typeText("pin")
    try await wait("Pin to lead") { rows.firstMatch.label.hasPrefix("Pin") }
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
    try await wait("the thread to be pinned") {
      try await fixture.client.request(ThreadRead.self, .init(threadId: fixture.threadId)).thread.pinned
    }
    XCTAssertEqual(composer.value as? String, draft)

    // Arrows move the selection; `>` enters Commands and Delete in the empty field leaves; Escape closes.
    app.typeKey("k", modifierFlags: .command)
    try requireElement(field, in: app)
    try await wait("the start list") { rows.count >= 3 }
    XCTAssertTrue(rows.element(boundBy: 0).isSelected)
    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    try await wait("the selection to move down") { rows.element(boundBy: 1).isSelected }
    app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
    try await wait("the selection to move up") { rows.element(boundBy: 0).isSelected }
    let startCount = rows.count
    app.typeText(">")
    try await wait("Commands to list") {
      rows.matching(NSPredicate(format: "label BEGINSWITH 'Rename'")).count == 1
    }
    XCTAssertEqual(field.value as? String ?? "", "")
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    try await wait("Find to return") { rows.count == startCount }
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 5))

    // Tab shows a thread's actions; Rename turns the field into the title, selected, and Return saves it.
    app.typeKey("k", modifierFlags: .command)
    try requireElement(field, in: app)
    app.typeText("arch")
    try await wait("the thread to be found") { rows.firstMatch.label.contains("Archived recovery fixture") }
    app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    try await wait("the thread's actions") { rows.firstMatch.label.hasPrefix("Open thread") }
    snap(app, "actions")
    app.typeText("ren")
    try await wait("Rename to lead") { rows.firstMatch.label.hasPrefix("Rename") }
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    try await wait("the title in the field") { field.value as? String == "Archived recovery fixture" }
    snap(app, "rename")
    app.typeText("Renamed by keys")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
    try await wait("the new title to be stored") {
      try await fixture.client.request(ThreadRead.self, .init(threadId: fixture.threadId)).thread.title
        == "Renamed by keys"
    }
    XCTAssertEqual(composer.value as? String, draft)

    // The composer's `/`: only in an empty draft; the list follows the token; Codex's commands follow the app's.
    let completions = app.descendants(matching: .any)["slash-completions"]
    let slashRows = app.buttons.matching(identifier: "slash-row")
    try clear(composer, app)
    app.typeText("/")
    try requireElement(completions, in: app)
    try await wait("this thread's commands") { slashRows.count == 8 }
    XCTAssertTrue(slashRows.element(boundBy: 6).label.hasPrefix("/review"))
    XCTAssertTrue(slashRows.element(boundBy: 7).label.hasPrefix("/compact"))
    snap(app, "slash")
    app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    try await wait("the second command to be selected") { slashRows.element(boundBy: 1).isSelected }
    app.typeText("re")
    try await wait("the list to narrow") { slashRows.count == 1 }
    // A command that takes more is completed in the draft; nothing is sent.
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    try await Task.sleep(for: .milliseconds(800))
    snap(app, "slash-picked")
    XCTAssertEqual(
      composer.value as? String, "/review ", "rows: \(slashRows.allElementsBoundByIndex.map(\.label))")
    XCTAssertTrue(completions.waitForNonExistence(timeout: 5))
    app.typeText("the auth change")
    XCTAssertEqual(composer.value as? String, "/review the auth change")

    // A setting lists its values; Escape steps back to the commands, then closes, and never leaves the field.
    try clear(composer, app)
    // One key, then the rest: text that arrives whole (a paste) is a message, by design.
    app.typeText("/")
    try requireElement(completions, in: app)
    app.typeText("mo")
    // `/permissions` answers to "mode" too, so it follows.
    try await wait("the model command") {
      slashRows.count == 2 && slashRows.firstMatch.label.hasPrefix("/model")
    }
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    try await wait("the model's values") {
      composer.value as? String == "" && slashRows.firstMatch.label.contains("Default")
    }
    snap(app, "slash-values")
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    try await wait("the commands again") { composer.value as? String == "/" && slashRows.count == 8 }
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(completions.waitForNonExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "/")
    // A path is a message, not a command.
    app.typeText("usr/local")
    XCTAssertEqual(composer.value as? String, "/usr/local")
    XCTAssertFalse(completions.exists)

    // A row answers the pointer too: clicking `/pin` runs it (the thread was pinned above) and clears the token.
    try clear(composer, app)
    app.typeText("/")
    try await wait("this thread's commands") { slashRows.count == 8 }
    // By position: the pointer lands where the row is drawn, whatever accessibility makes of the list.
    slashRows.element(boundBy: 2).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    try await wait("the thread to be unpinned") {
      try await fixture.client.request(ThreadRead.self, .init(threadId: fixture.threadId)).thread.pinned
        == false
    }
    try await wait("the token to leave the draft") { composer.value as? String ?? "" == "" }
    XCTAssertTrue(completions.waitForNonExistence(timeout: 5))

    // Nothing above reached the runtime as a turn (`resumeCount` rejects any `turn/start`).
    _ = try fixture.resumeCount()
    try clear(composer, app)
    app.typeText(draft)
    try await wait("the draft to be back") { composer.value as? String == draft }
  }

  /// The palette is a panel of its own: it can be dragged by its header (the empty part of the field
  /// included) and its footer, goes back where it opens when released near there or double-clicked,
  /// and its shadow follows it with nothing left behind when the list shrinks.
  @MainActor func testPalettePanelDragsSnapsAndKeepsItsShadow() async throws {
    continueAfterFailure = false
    let fixture = try await SmokeFixture.start(in: self)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    let app = XCUIApplication()
    addTeardownBlock { @MainActor in
      if app.state == .runningForeground || app.state == .runningBackground { app.terminate() }
    }
    app.launchEnvironment = [
      "SMOKE_SOCKET": fixture.socket, "SMOKE_WIDTH": "1100", "SMOKE_DARK": "0", "SMOKE_HEIGHT": "600",
      "SWIFTNIO_STRICT": "1",
    ]
    app.launch()
    app.activate()
    if !app.windows.firstMatch.exists {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["New Window"].click()
    }
    let row = app.buttons.matching(identifier: "thread-row").firstMatch
    try requireElement(row, in: app, timeout: 30)
    row.click()
    try requireElement(app.textViews["composer"], in: app)
    let main = app.windows.containing(.textView, identifier: "composer").firstMatch.frame

    let palette = app.descendants(matching: .any)["search-palette"]
    let field = app.textFields["palette-field"]
    let rows = app.buttons.matching(identifier: "palette-row")
    let closed = XCUIScreen.main.screenshot()

    // Commands, whose list is at its tallest.
    app.typeKey("p", modifierFlags: [.command, .shift])
    try requireElement(field, in: app)
    try await wait("the commands") { rows.count >= 8 }
    try await Task.sleep(for: .milliseconds(400))
    let home = palette.frame
    // Centred on the window, and not cut by it.
    XCTAssertEqual(home.midX, main.midX, accuracy: 1.5)
    XCTAssertEqual(home.width, 600, accuracy: 1)

    // The shadow is the window server's, and follows the card. With the tall list, a point just under
    // the card is darker than it was with the palette closed.
    let tall = XCUIScreen.main.screenshot()
    let under = CGPoint(x: home.midX, y: home.maxY + 5)
    XCTAssertLessThan(
      try luminance(tall, at: under), try luminance(closed, at: under) - 0.004, "no shadow under the card")
    // The list shrinks to one row: where the tall card and its shadow were, the screen is as it was
    // with the palette closed. Nothing trails.
    app.typeText("zzzzqq")
    try await Task.sleep(for: .milliseconds(900))
    snap(app, XCUIScreen.main.screenshot(), "panel-after-typing")
    XCTAssertLessThan(
      palette.frame.height, home.height - 100,
      "home \(home) now \(palette.frame) rows \(rows.count) field \(String(describing: field.value))")
    try await Task.sleep(for: .milliseconds(600))
    let short = palette.frame
    XCTAssertEqual(short.minY, home.minY, accuracy: 1, "the top moved")
    XCTAssertLessThan(short.height, home.height - 100)
    let shrunk = XCUIScreen.main.screenshot()
    snap(app, shrunk, "panel-shrunk")
    for x in stride(from: home.minX + 12, through: home.maxX - 12, by: 48) {
      for y in [home.maxY - 20, home.maxY + 5, home.maxY + 18] where y > short.maxY + 60 {
        let point = CGPoint(x: x, y: y)
        XCTAssertEqual(
          try luminance(shrunk, at: point), try luminance(closed, at: point), accuracy: 0.012,
          "a trace of the taller card at \(point)")
      }
    }
    // And the short card has its own shadow under it.
    let underShort = CGPoint(x: short.midX, y: short.maxY + 5)
    XCTAssertLessThan(try luminance(shrunk, at: underShort), try luminance(closed, at: underShort) - 0.004)
    for _ in 0..<6 { app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: []) }
    try await wait("the commands again") { rows.count >= 8 }

    // Drag by the header, from the empty part of the field: it moves, and the field keeps the keyboard.
    let grip = field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
    grip.press(forDuration: 0.15, thenDragTo: grip.withOffset(CGVector(dx: 180, dy: 130)))
    try await wait("the palette to move") { abs(palette.frame.minX - home.minX - 180) < 6 }
    XCTAssertEqual(palette.frame.minY, home.minY + 130, accuracy: 6)
    app.typeText("arch")
    try await wait("typing to reach the field") { field.value as? String == "arch" }
    snap(app, XCUIScreen.main.screenshot(), "panel-dragged")
    for _ in 0..<4 { app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: []) }

    // A plain click on the same spot is a click, not a nudge.
    let moved = palette.frame
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).click()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(palette.frame.minX, moved.minX, accuracy: 1)
    app.typeText("q")
    try await wait("the click to leave the field focused") { field.value as? String == "q" }
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])

    // Released near where it opens (by the footer this time), it is pulled back onto it.
    // The footer's empty stretch, 20 pt above the card's bottom edge.
    func footerGrip() -> XCUICoordinate {
      palette.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: 300, dy: palette.frame.height - 20))
    }
    let foot = footerGrip()
    foot.press(forDuration: 0.15, thenDragTo: foot.withOffset(CGVector(dx: -168, dy: -121)))
    try await wait("the palette to snap home") {
      abs(palette.frame.minX - home.minX) < 1.5 && abs(palette.frame.minY - home.minY) < 1.5
    }

    // Left far away it stays; a double click on a drag area sends it home.
    let foot2 = footerGrip()
    foot2.press(forDuration: 0.15, thenDragTo: foot2.withOffset(CGVector(dx: -220, dy: 90)))
    try await wait("the palette to stay away") { abs(palette.frame.minX - home.minX + 220) < 6 }
    footerGrip().doubleClick()
    try await wait("the palette to go home") {
      abs(palette.frame.minX - home.minX) < 1.5 && abs(palette.frame.minY - home.minY) < 1.5
    }

    // Dragged away and closed, it opens at home again.
    let foot3 = footerGrip()
    foot3.press(forDuration: 0.15, thenDragTo: foot3.withOffset(CGVector(dx: 200, dy: 60)))
    try await wait("the palette to move") { abs(palette.frame.minX - home.minX - 200) < 6 }
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 5))
    // Closed, nothing of it is left on the screen.
    try await Task.sleep(for: .milliseconds(400))
    let after = XCUIScreen.main.screenshot()
    for point in [under, CGPoint(x: home.minX + 30, y: home.midY)] {
      XCTAssertEqual(try luminance(after, at: point), try luminance(closed, at: point), accuracy: 0.012)
    }
    app.typeKey("k", modifierFlags: .command)
    try requireElement(field, in: app)
    try await wait("the palette at home") {
      abs(palette.frame.minX - home.minX) < 1.5 && abs(palette.frame.minY - home.minY) < 1.5
    }
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
  }

  /// The brightness (0 to 1) of the screen at `point` (screen points, from the top left), averaged
  /// over a few pixels.
  @MainActor private func luminance(_ screenshot: XCUIScreenshot, at point: CGPoint) throws -> Double {
    let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let screen = try XCTUnwrap(NSScreen.screens.first).frame
    let scale = CGFloat(image.width) / screen.width
    let rect = CGRect(x: point.x * scale - 2, y: point.y * scale - 2, width: 4, height: 4).integral
    let cut = try XCTUnwrap(image.cropping(to: rect))
    var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cut, in: CGRect(x: 0, y: 0, width: 4, height: 4))
    var total = 0.0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      total +=
        0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
        + 0.0722 * Double(pixels[index + 2])
    }
    return total / 16 / 255
  }

  @MainActor private func snap(_ app: XCUIApplication, _ screenshot: XCUIScreenshot, _ name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "palette-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor private func clear(_ composer: XCUIElement, _ app: XCUIApplication) throws {
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    XCTAssertEqual(composer.value as? String ?? "", "")
  }

  @MainActor private func snap(_ app: XCUIApplication, _ name: String) {
    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    screenshot.name = "palette-\(name)"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor private func wait(
    _ what: String, timeout: Duration = .seconds(8), _ condition: @MainActor () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !((try? await condition()) ?? false) {
      guard ContinuousClock.now < deadline else {
        XCTFail("Timed out waiting for \(what)")
        throw NSError(domain: "SmokeAssertion", code: 6)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }
}
