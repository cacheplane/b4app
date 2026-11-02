import Foundation
import Synchronization

/// Run work for at most a given time (sign-in plan, Task 10: log-out's bounded steps).
///
/// The work runs in a task of its own, so a step returns at its bound even when the work does not
/// honour cancellation (a hung request, a process that ignores its signal): at the bound the work is
/// cancelled and left to finish on its own, and the caller goes on.
enum Bounded {
  /// The work's result, or nil when `timeout` passed first.
  static func run<T: Sendable>(
    within timeout: Duration, _ work: @escaping @Sendable () async throws -> T
  ) async -> Result<T, any Error>? {
    let once = Once<Result<T, any Error>?>()
    let task = Task {
      do { once.resolve(.success(try await work())) } catch { once.resolve(.failure(error)) }
    }
    let timer = Task {
      try? await Task.sleep(for: timeout)
      once.resolve(nil)
    }
    let outcome = await once.value()
    timer.cancel()
    if outcome == nil { task.cancel() }
    return outcome
  }

  /// `run(within:)` for work with nothing to answer: whether it finished in time.
  @discardableResult
  static func run(within timeout: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    await run(within: timeout) { () async throws -> Bool in
      await work()
      return true
    } != nil
  }

  /// The time left until `deadline`, never negative.
  static func remaining(until deadline: ContinuousClock.Instant) -> Duration {
    max(.zero, deadline - .now)
  }
}

/// A value set once, by whichever party gets there first; `value()` waits for it.
private final class Once<T: Sendable>: Sendable {
  private struct State {
    var value: T?
    var set = false
    var waiters: [CheckedContinuation<T, Never>] = []
  }

  private let state = Mutex(State())

  func resolve(_ value: T) {
    let waiters = state.withLock { state -> [CheckedContinuation<T, Never>] in
      guard !state.set else { return [] }
      state.set = true
      state.value = value
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume(returning: value) }
  }

  func value() async -> T {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> T? in
        guard state.set, let value = state.value else {
          state.waiters.append(continuation)
          return nil
        }
        return value
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }
}

/// A first-come lock for async code, whose waiters may give up after a time.
final class AsyncLock: Sendable {
  private struct Waiter {
    var id: UUID
    var continuation: CheckedContinuation<Bool, Never>
  }

  private struct State {
    var held = false
    var waiters: [Waiter] = []
  }

  private let state = Mutex(State())

  func lock() async { _ = await lock(within: nil) }

  /// Whether the lock is now held: false when `timeout` passed first, and then nothing is held.
  func lock(within timeout: Duration?) async -> Bool {
    let id = UUID()
    return await withCheckedContinuation { continuation in
      let now = state.withLock { state -> Bool in
        if !state.held {
          state.held = true
          return true
        }
        state.waiters.append(Waiter(id: id, continuation: continuation))
        return false
      }
      if now {
        continuation.resume(returning: true)
      } else if let timeout {
        Task { [weak self] in
          try? await Task.sleep(for: timeout)
          self?.giveUp(id)
        }
      }
    }
  }

  /// Hand the lock to the next waiter, or free it.
  func unlock() {
    let next = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard !state.waiters.isEmpty else {
        state.held = false
        return nil
      }
      return state.waiters.removeFirst().continuation
    }
    next?.resume(returning: true)
  }

  private func giveUp(_ id: UUID) {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
      return state.waiters.remove(at: index).continuation
    }
    waiter?.resume(returning: false)
  }
}
