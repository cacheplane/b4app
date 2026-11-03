import Foundation
import Synchronization
import Testing
import WorkspaceTestSupport

@testable import Coordinator

@Suite(BlockingDatabaseWork()) struct BoundedDeadlineTests {
  @Test func expiredBudgetsCannotReportSuccess() async {
    let started = Mutex(0)
    let (starts, continuation) = AsyncStream<Void>.makeStream()
    let guardTask = Task {
      try? await Task.sleep(for: .seconds(60))
      continuation.finish()
    }
    defer { guardTask.cancel() }
    var answered = 0
    for _ in 0..<100 {
      let result = await Bounded.run(within: .zero) {
        started.withLock { $0 += 1 }
        continuation.yield(())
      }
      if result { answered += 1 }
    }
    var observedStarts = 0
    for await _ in starts {
      observedStarts += 1
      if observedStarts == 100 { break }
    }
    continuation.finish()
    #expect(started.withLock { $0 } == 100, "Best-effort cleanup still runs after the wait expires")
    #expect(answered == 0)
  }
}
