import Foundation
import Testing

@testable import WorkspaceStorage

/// Temporary diagnostic harness, archived with the evidence and removed before final validation.
@Suite(.serialized) struct ScratchScanMeasurementTests {
  @Test func actualSweepReadOnly() throws {
    let root = try #require(ProcessInfo.processInfo.environment["B4APP_SCAN_ROOT"])
    for repetition in 0..<3 {
      let start = ContinuousClock.now
      // A live owner prevents removal; a time before any file existed protects legacy names.
      let removed = EphemeralPostgres.sweepStale(
        in: [root], ownPid: ProcessInfo.processInfo.processIdentifier, now: .distantPast,
        isAlive: { _ in true }, stopOrphan: { _, _ in Issue.record("Unexpected stop"); return false })
      let duration = start.duration(to: .now)
      #expect(removed.isEmpty)
      print("SCAN_SAMPLE repetition=\(repetition) seconds=\(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)")
    }
  }
}
