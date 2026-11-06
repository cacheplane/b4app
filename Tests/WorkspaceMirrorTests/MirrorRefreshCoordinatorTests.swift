import Foundation
import Synchronization
import Testing

@testable import WorkspaceMirror

@Suite @MainActor struct MirrorRefreshCoordinatorTests {
  @Test func aWakeDuringCleanupRequiresAnotherCycleBeforeEitherCallerCompletes() async throws {
    // Freeze the deadline clock: unrelated full-suite SwiftUI rendering must not change this
    // ordering check into a performance test.
    let start = ContinuousClock.now
    let coordinator = MirrorRefreshCoordinator(now: { start })
    let cleaningUp = Gate()
    let allowPark = Gate()
    var cycles = 0
    let first = Task {
      await coordinator.perform(waitingAtMost: .seconds(120)) { _ in
        cycles += 1
        if cycles == 1 {
          cleaningUp.open()
          await allowPark.wait()
        }
        return true
      }
    }
    await cleaningUp.wait()
    let second = Task {
      await coordinator.perform(waitingAtMost: .seconds(120)) { _ in
        Issue.record("Overlapping wakes should share the cycle owner")
        return false
      }
    }
    let deadline = ContinuousClock.now + .seconds(120)
    while coordinator.generation < 2, ContinuousClock.now < deadline { await Task.yield() }
    try #require(coordinator.generation == 2)
    allowPark.open()
    #expect(await first.value)
    #expect(await second.value)
    #expect(cycles == 2)
    // A wake after the completed task starts new work rather than reusing its result.
    #expect(
      await coordinator.perform(waitingAtMost: .seconds(120)) { _ in
        cycles += 1
        return true
      })
    #expect(cycles == 3)
  }

  @Test func aLateWakeCannotClaimSuccessAfterTheOverallBudgetExpires() async throws {
    let clock = Mutex(ContinuousClock.now)
    let coordinator = MirrorRefreshCoordinator(now: { clock.withLock { $0 } })
    let cleaningUp = Gate()
    let allowPark = Gate()
    let first = Task {
      await coordinator.perform(waitingAtMost: .seconds(1)) { _ in
        cleaningUp.open()
        await allowPark.wait()
        return true
      }
    }
    await cleaningUp.wait()
    let second = Task {
      await coordinator.perform(waitingAtMost: .seconds(1)) { _ in true }
    }
    let deadline = ContinuousClock.now + .seconds(120)
    while coordinator.generation < 2, ContinuousClock.now < deadline { await Task.yield() }
    try #require(coordinator.generation == 2)
    clock.withLock { $0 = $0 + .seconds(2) }
    allowPark.open()
    #expect(await first.value == false)
    #expect(await second.value == false)
  }
}
