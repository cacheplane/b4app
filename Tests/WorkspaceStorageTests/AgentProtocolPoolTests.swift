import Foundation
import Synchronization
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private final class PoolObservation: Sendable {
  let bodyCalls = Mutex(0)
  let borrowerEntered = Mutex(false)
  let waiterEntered = Mutex(false)
  let waiterFinished = Mutex(false)
  let closeFinished = Mutex(false)
}

@Suite(.serialized) struct AgentProtocolPoolTests {
  // Suspend the retained Task while its synchronous gate runs outside the cooperative executor.
  private static func onDedicatedPoolThread<T: Sendable>(
    _ operation: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      Thread { continuation.resume(returning: operation()) }.start()
    }
  }

  private static func onDedicatedPoolThread<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await onDedicatedPoolThread { Result<T, any Error> { try operation() } }.get()
  }

  private func observed(_ signal: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !signal(), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return signal()
  }

  @Test func queuedCheckoutCannotRunAfterPoolClose() async throws {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let pool = try ConnectionPool(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)",
      size: 1)
    defer { pool.close() }
    let releaseBorrower = DispatchSemaphore(value: 0)
    let releaseWaiter = DispatchSemaphore(value: 0)
    let observation = PoolObservation()
    let borrower = Task.detached {
      try await Self.onDedicatedPoolThread {
        try pool.withConnection { _ in
          observation.borrowerEntered.withLock { $0 = true }
          releaseBorrower.wait()
        }
      }
    }
    let borrowerReady = await observed { observation.borrowerEntered.withLock { $0 } }
    #expect(borrowerReady)
    let waiter = Task.detached { () -> Bool in
      await Self.onDedicatedPoolThread {
        defer { observation.waiterFinished.withLock { $0 = true } }
        do {
          try pool.withConnection(
            beforeWaiting: {
              observation.waiterEntered.withLock { $0 = true }
              releaseWaiter.wait()
            }
          ) { _ in observation.bodyCalls.withLock { $0 += 1 } }
          return false
        } catch let error as WorkspaceError {
          return error.code == .endpointUnavailable
        } catch { return false }
      }
    }
    let waiterReady = await observed { observation.waiterEntered.withLock { $0 } }
    #expect(waiterReady)
    // The waiter has deterministically passed its initial closed check, while the sole slot remains
    // borrowed. Release every gate and join all tasks before any assertion can leave the fixture.
    let pendingBeforeClose = !observation.waiterFinished.withLock { $0 }
    let closer = Task.detached {
      pool.close()
      observation.closeFinished.withLock { $0 = true }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while !observation.closeFinished.withLock({ $0 }), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(10)) } catch {}
    }
    let ordinaryCloseDidNotWait = observation.closeFinished.withLock { $0 }
    releaseWaiter.signal()
    releaseBorrower.signal()
    let borrowerResult = await borrower.result
    let refused = await waiter.value
    await closer.value
    _ = try borrowerResult.get()
    #expect(pendingBeforeClose)
    #expect(ordinaryCloseDidNotWait)
    #expect(refused)
    #expect(observation.bodyCalls.withLock { $0 } == 0)
  }
}
