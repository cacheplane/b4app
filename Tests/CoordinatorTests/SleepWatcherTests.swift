import Foundation
import Testing

@testable import Coordinator

@Suite struct SleepWatcherTests {
  @Test func gapIsTheTimeAsleepPastTheThreshold() {
    #expect(
      SleepWatcher.gap(
        continuousElapsed: .seconds(5), suspendingElapsed: .seconds(5), threshold: .seconds(20)) == nil)
    #expect(
      SleepWatcher.gap(
        continuousElapsed: .seconds(19), suspendingElapsed: .seconds(5), threshold: .seconds(20)) == nil)
    #expect(
      SleepWatcher.gap(
        continuousElapsed: .seconds(65), suspendingElapsed: .seconds(5), threshold: .seconds(20))
        == .seconds(60))
  }

  @Test func tickFiresOnceForAWakeAndNotForOrdinaryTicks() async {
    let fired = Counter()
    let watcher = SleepWatcher(threshold: .seconds(20), interval: .seconds(5)) { gap in await fired.add(gap) }
    let c0 = ContinuousClock.now
    let s0 = SuspendingClock.now
    await watcher.tick(continuous: c0, suspending: s0)
    // Five seconds pass awake: both clocks advance together.
    #expect(await watcher.tick(continuous: c0 + .seconds(5), suspending: s0 + .seconds(5)) == nil)
    // The Mac sleeps 25 s between ticks: the continuous clock ran, the suspending one did not.
    let gap = await watcher.tick(continuous: c0 + .seconds(35), suspending: s0 + .seconds(10))
    #expect(gap == .seconds(25))
    // The next ordinary tick does not fire again.
    #expect(await watcher.tick(continuous: c0 + .seconds(40), suspending: s0 + .seconds(15)) == nil)
    #expect(await fired.values == [.seconds(25)])
  }
}

private actor Counter {
  var values: [Duration] = []
  func add(_ value: Duration) { values.append(value) }
}
