import XCTest

extension XCUIElement {
  /// Whether the element exists within `timeout`, looking first and then every 0.1 s.
  /// XCTest's `waitForExistence` took at least a second even for an element already on screen: 267 of
  /// the 275 waits in the two UI suites took 0.9 to 1.6 s (main e04f5f8, run 43612368923). The
  /// condition and the timeout are the same; only the time between looks is shorter.
  @MainActor func appears(within timeout: TimeInterval) -> Bool { settles(to: true, within: timeout) }

  /// Whether the element is gone within `timeout`, looked for the same way.
  @MainActor func disappears(within timeout: TimeInterval) -> Bool { settles(to: false, within: timeout) }

  @MainActor private func settles(to wanted: Bool, within timeout: TimeInterval) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    repeat {
      if exists == wanted { return true }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
    } while Date.now < deadline
    // One look after the deadline: a slow look must not end the wait on its own (the gate record
    // 2026-11-14-layout-shards-hosted).
    return exists == wanted
  }
}
