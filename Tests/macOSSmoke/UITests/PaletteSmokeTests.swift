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
