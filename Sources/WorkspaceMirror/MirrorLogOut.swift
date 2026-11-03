import Foundation
import Synchronization
import WorkspaceSync

extension MirrorStore {
  /// Everything an account left on the phone: the link, every mirrored row and clock, the outbox of
  /// unsent edits, and the devices list. The schema and the device sequence counter stay.
  public func forgetAccount() throws {
    try locked {
      try transaction {
        try run(#"UPDATE "syncState" SET "link" = NULL, "cursor" = 0 WHERE "id" = 1"#)
        try deleteRows()
        try exec(#"DELETE FROM "outbox""#)
        try exec(#"DELETE FROM "devices""#)
      }
      clock.deviceId = "local"
    }
  }
}

/// The phone's Log out: end this device's session at the hub (`DELETE /v1/sessions/self`, best effort
/// and bounded), forget its token, and empty the mirror. The device stays enrolled at the hub, so the
/// next sign-in reuses it. Unsent edits are discarded rather than uploaded under whatever link comes
/// next.
public enum MirrorLogOut {
  /// How long a log-out waits for the hub.
  public static let standardTimeout: Duration = .seconds(10)

  /// Returns whether the hub confirmed the session ended. The token is forgotten and the mirror
  /// emptied either way, within `timeout` of the hub not answering, so an unreachable hub cannot keep
  /// the phone signed in. `stillCurrent` is asked after the wait: when it answers false (another
  /// account signed in meanwhile), the token is still forgotten but the mirror, now the other
  /// account's, is left alone.
  @discardableResult
  public static func run(
    store: MirrorStore, api: (any HubAPI)?, timeout: Duration = standardTimeout,
    forgetToken: @Sendable () async -> Void,
    stillCurrent: @Sendable () async -> Bool = { true }
  ) async -> Bool {
    var ended = false
    if let api {
      ended = await Bounded.run(within: timeout) { try await api.endSession() }
    }
    await forgetToken()
    if await stillCurrent() { try? store.forgetAccount() }
    return ended
  }
}

/// Runs work for at most a given time, whether or not the work notices cancellation.
enum Bounded {
  /// True when `work` finished without throwing within `timeout`. Past it the work is cancelled and
  /// left to end on its own; its answer is ignored.
  static func run(within timeout: Duration, _ work: @escaping @Sendable () async throws -> Void) async -> Bool
  {
    let deadline = ContinuousClock.now + timeout
    let once = Once()
    return await withCheckedContinuation { continuation in
      once.set(continuation)
      let job = Task {
        do {
          try await work()
          once.finish(ContinuousClock.now < deadline)
        } catch {
          once.finish(false)
        }
      }
      let timer = Task {
        try? await Task.sleep(until: deadline, clock: .continuous)
        once.finish(false)
        job.cancel()
      }
      once.onFinish { timer.cancel() }
    }
  }

  /// Resumes its continuation exactly once.
  private final class Once: Sendable {
    private let state = Mutex<(CheckedContinuation<Bool, Never>?, (@Sendable () -> Void)?)>((nil, nil))

    func set(_ continuation: CheckedContinuation<Bool, Never>) { state.withLock { $0.0 = continuation } }
    func onFinish(_ body: @escaping @Sendable () -> Void) {
      let finished = state.withLock { state -> Bool in
        if state.0 == nil { return true }
        state.1 = body
        return false
      }
      if finished { body() }
    }

    func finish(_ value: Bool) {
      let (continuation, after) = state.withLock { state in
        defer { state = (nil, nil) }
        return state
      }
      continuation?.resume(returning: value)
      after?()
    }
  }
}
