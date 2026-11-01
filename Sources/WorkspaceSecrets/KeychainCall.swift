import Foundation

/// Runs a blocking Security call on a thread of its own, never on the caller's executor.
///
/// The package builds with `NonisolatedNonsendingByDefault`, so a nonisolated async function runs on
/// its caller's actor. `SecItemCopyMatching` blocks for as long as macOS shows a Keychain prompt, and
/// nothing answers it until someone is at the Mac; run inline, it held the coordinator's `HubSync`
/// actor that long, and every `hub.status` timed out behind it. Here a prompt suspends only the task
/// that asked. A thread per call, not a queue: calls are rare, and a prompt must not hold up the next
/// one.
enum KeychainCall {
  static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let thread = Thread { continuation.resume(with: Result { try body() }) }
      thread.name = "b4app.keychain"
      thread.start()
    }
  }
}
