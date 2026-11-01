import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol

/// The device token for one hub link, read from the secret store when a request first needs it and
/// then kept in memory, so the Keychain is asked once per coordinator run instead of once per request.
///
/// Concurrent requests share one read. A read that finds no token, or fails, is not kept: the next
/// request asks again. While a read is outstanding, which is a Keychain prompt nobody has answered
/// when it lasts, `waitingSince` says since when, and `hub status` reports it instead of the push and
/// the pull looking stuck. The value never leaves this object except to `HTTPHubAPI`'s header.
final class HubToken: Sendable {
  private struct State {
    var value: String?
    var read: Task<String?, any Error>?
    var waitingSince: String?
  }

  private let store: any SecretStore
  private let ref: SecretRef
  private let state: Mutex<State>

  init(store: any SecretStore, ref: SecretRef) {
    self.store = store
    self.ref = ref
    state = Mutex(State())
  }

  /// Keep a token the caller already holds (a join that just stored it), so nothing reads it back.
  func remember(_ value: String) {
    state.withLock { $0.value = value }
  }

  /// When the outstanding read started (`Timestamp` form), or nil when none is outstanding.
  var waitingSince: String? { state.withLock { $0.waitingSince } }

  func value() async throws -> String? {
    enum Next {
      case cached(String)
      case wait(Task<String?, any Error>)
    }
    let next: Next = state.withLock { state in
      if let value = state.value { return .cached(value) }
      if let read = state.read { return .wait(read) }
      // Detached: the read must not run on whichever actor asked first.
      let read = Task.detached { [store, ref] in try await store.read(ref) }
      state.read = read
      state.waitingSince = Timestamp.now()
      return .wait(read)
    }
    switch next {
    case .cached(let value):
      return value
    case .wait(let read):
      let result = await read.result
      state.withLock { state in
        guard state.read == read else { return }
        state.read = nil
        state.waitingSince = nil
        if case .success(let value?) = result { state.value = value }
      }
      return try result.get()
    }
  }
}
