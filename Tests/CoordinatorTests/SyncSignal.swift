import Foundation
import Synchronization
import WorkspaceProtocol
import WorkspaceSync

/// Wakes waiters whenever something a hub-sync test can observe may have changed: a hub call starting
/// or ending (`ProbedHub`), or whatever else a test fires it from (an event it recorded, a callback).
/// The pull changes the store only before its next hub call, so `until` re-checks its condition when
/// it can have become true, not on a clock. (WorkspaceMirrorTests has the same helper for the phone.)
final class SyncSignal: Sendable {
  private struct State {
    var generation = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())

  func fire() {
    let waiters = state.withLock { state in
      state.generation += 1
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Returns true once `condition` holds, checking it now and after each signal, or false at the
  /// timeout. The timeout is only a guard so a failing test ends; the expected path never waits on it.
  func until(timeout: Duration = .seconds(60), _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    let alarm = Task { [self] in
      guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
      fire()
    }
    defer { alarm.cancel() }
    while true {
      let seen = state.withLock { $0.generation }
      if try await condition() { return true }
      if ContinuousClock.now >= deadline { return false }
      await next(after: seen)
    }
  }

  /// Suspends until a signal after generation `seen` (at once if one has already come).
  private func next(after seen: Int) async {
    await withCheckedContinuation { continuation in
      let fired = state.withLock { state in
        if state.generation != seen { return true }
        state.waiters.append(continuation)
        return false
      }
      if fired { continuation.resume() }
    }
  }
}

/// Forwards to `base`, firing `signal` as each call starts and ends.
final class ProbedHub: HubAPI {
  let base: any HubAPI
  let signal: SyncSignal

  init(_ base: any HubAPI, _ signal: SyncSignal) {
    self.base = base
    self.signal = signal
  }

  private func probe<T>(_ call: () async throws -> T) async rethrows -> T {
    signal.fire()
    defer { signal.fire() }
    return try await call()
  }

  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try await probe { try await base.enroll(request) }
  }
  func me() async throws -> MeResponse { try await probe { try await base.me() } }
  func push(_ changes: [SyncChange]) async throws -> PushResponse {
    try await probe { try await base.push(changes) }
  }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await probe { try await base.pull(after: after, limit: limit, wait: wait) }
  }
  func snapshot() async throws -> SnapshotResponse { try await probe { try await base.snapshot() } }
  func devices() async throws -> [DeviceInfo] { try await probe { try await base.devices() } }
  func revokeSelf() async throws { try await probe { try await base.revokeSelf() } }
}

/// A one-shot latch: `wait()` returns once `open()` has been called, at once if it already has.
final class Gate: Sendable {
  private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

  func open() {
    let waiters = state.withLock { state in
      state.open = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let open = state.withLock { state in
        if !state.open { state.waiters.append(continuation) }
        return state.open
      }
      if open { continuation.resume() }
    }
  }
}
