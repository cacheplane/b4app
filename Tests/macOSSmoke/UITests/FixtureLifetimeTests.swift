import Foundation
import XCTest

final class FixtureLifetimeTests: XCTestCase {
  @MainActor func testHostExitsWhenItsOwnerPipeCloses() async throws {
    let fixture = try await SmokeFixture.start(in: self)
    addTeardownBlock { @MainActor in try await fixture.stop(in: self) }
    try fixture.releaseOwnership()
    let deadline = ContinuousClock.now + .seconds(15)
    while fixture.process.isRunning, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertFalse(fixture.process.isRunning, "Owner loss must stop the fixture without a signal")
  }
}
