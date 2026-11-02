import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Deleting threads: the thread is marked deleted (`userDeletedAt`, synced) and hidden everywhere, and
/// the runtime's copy is deleted where the runtime can. A delete marked on the phone arrives by pull;
/// the sweep finds it the same way.
extension SessionService {
  /// The longest wait between tries at deleting a runtime copy that could not be reached.
  static let threadDeleteBackoffCap: TimeInterval = 3600

  /// Delete a thread. A running turn is stopped first (best effort, up to 10 seconds). Deleting a
  /// thread already deleted returns it unchanged.
  public func threadDelete(_ params: ThreadDelete.Params) async throws -> ThreadCreate.Result {
    guard let existing = try db.thread(id: params.threadId) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    if existing.userDeletedAt == nil, try db.activeTurn(threadId: existing.id) != nil {
      await stopBeforeDelete(existing)
    }
    guard let thread = try db.markThreadDeleted(id: existing.id, at: Timestamp.now()) else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    await context.eventLog.publish(try AdapterEvent.threadUpdated(thread))
    await sweepThreadDeletes(only: thread.id)
    return ThreadCreate.Result(thread: thread)
  }

  /// Interrupt the thread's unresolved turn and wait up to 10 seconds for the runtime to end it. A turn
  /// still unresolved after that is ended here as cancelled: its thread is going, and nothing would
  /// ever show or resolve it.
  private func stopBeforeDelete(_ thread: ConversationThread) async {
    _ = try? await turnInterrupt(TurnInterrupt.Params(threadId: thread.id))
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, (try? db.activeTurn(threadId: thread.id)) != nil {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let active = try? db.activeTurn(threadId: thread.id) else { return }
    for request in (try? db.pendingRuntimeRequests(threadId: thread.id)) ?? [] {
      _ = try? db.transitionRuntimeRequest(id: request.id, to: .expired)
    }
    _ = try? db.updateTurn(id: active.id) {
      $0.status = .terminal
      $0.outcome = .cancelled
    }
  }

  /// Try each deleted thread whose runtime copy is due (never tried, or waiting past its next attempt),
  /// or only `threadId`. Outcomes: done (deleted, or already gone), unsupported (final: the runtime has
  /// no delete, or the connection is disabled, missing, or now signed in as someone else), or waiting
  /// (the runtime was unreachable), retried after 30 seconds, doubling to at most an hour.
  public func sweepThreadDeletes(now: Date = Date(), only threadId: String? = nil) async {
    let due: [ConversationThread]
    do {
      due = try db.threadsAwaitingRuntimeDelete(now: Timestamp.string(from: now))
    } catch {
      logger.error("thread delete sweep failed: \(String(describing: error), privacy: .public)")
      return
    }
    for thread in due where threadId == nil || thread.id == threadId {
      guard deletingThreads.insert(thread.id).inserted else { continue }
      await deleteRuntimeCopy(thread, now: now)
      deletingThreads.remove(thread.id)
    }
  }

  private func deleteRuntimeCopy(_ thread: ConversationThread, now: Date) async {
    do {
      guard !thread.nativeThreadId.isEmpty else {
        return try db.recordThreadDelete(threadId: thread.id, outcome: .done, error: nil, nextAttemptAt: nil)
      }
      guard let connection = try db.connection(id: thread.connectionId), connection.enabled,
        !Self.identityChanged(thread: thread, connection: connection)
      else {
        return try db.recordThreadDelete(
          threadId: thread.id, outcome: .unsupported, error: nil, nextAttemptAt: nil)
      }
      let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
      let outcome: ThreadDeleteState
      do {
        switch try await adapter(for: connection).deleteSession(ref) {
        case .deleted, .alreadyGone: outcome = .done
        case .unsupported: outcome = .unsupported
        }
      } catch {
        let attempts = try db.threadDeleteAttempts(threadId: thread.id)
        let wait = min(30 * pow(2, Double(attempts)), Self.threadDeleteBackoffCap)
        try db.recordThreadDelete(
          threadId: thread.id, outcome: .waiting,
          error: LogRedactor.redact(WorkspaceError.from(error).message),
          nextAttemptAt: Timestamp.string(from: now.addingTimeInterval(wait)))
        return
      }
      try db.recordThreadDelete(threadId: thread.id, outcome: outcome, error: nil, nextAttemptAt: nil)
    } catch {
      logger.error("thread delete failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// Retry due runtime deletes now and every `threadDeleteSweep` (none when it is zero).
  func startThreadDeleteSweep() {
    let period = context.threadDeleteSweep
    guard period > .zero else { return }
    pumps["thread-deletes"] = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweepThreadDeletes()
        try? await Task.sleep(for: period)
      }
    }
  }
}
