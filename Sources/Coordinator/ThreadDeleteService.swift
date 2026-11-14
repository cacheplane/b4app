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

  /// The wait before the next try after `attempts` earlier tries: 30 seconds, doubling, at most an hour.
  static func threadDeleteBackoff(attempts: Int) -> TimeInterval {
    min(30 * pow(2, Double(attempts)), threadDeleteBackoffCap)
  }

  /// Delete a thread: it is marked and announced at once, and answers then. Its running turn is
  /// stopped and the runtime's copy deleted right after, in the background (the same step the sweep
  /// runs for a delete pulled from the phone). Deleting a thread already deleted returns it unchanged.
  public func threadDelete(_ params: ThreadDelete.Params) async throws -> ThreadCreate.Result {
    guard try db.thread(id: params.threadId) != nil,
      let thread = try db.markThreadDeleted(id: params.threadId, at: Timestamp.now())
    else {
      throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
    }
    await context.eventLog.publish(try AdapterEvent.threadUpdated(thread))
    let id = thread.id
    Task { await self.sweepThreadDeletes(only: id) }
    return ThreadCreate.Result(thread: thread)
  }

  /// End the deleted thread's unresolved turn. A live one is interrupted through its adapter (the
  /// thread commands refuse a deleted thread, so not through `turnInterrupt`), asking again once the
  /// runtime has named the turn, and given up to 10 seconds to end. Whatever is still unresolved after
  /// that, or was already `reconciling`, is ended here as cancelled: nothing would ever show or resolve it.
  private func stopTurn(of thread: ConversationThread, connection: Connection?) async {
    guard let active = try? db.activeTurn(threadId: thread.id) else { return }
    if active.status != .reconciling, let connection, connection.enabled,
      let adapter = try? adapter(for: connection)
    {
      let ref = NativeSessionRef(nativeSessionId: thread.nativeThreadId, nativeScope: thread.nativeScope)
      var asked = false
      let deadline = ContinuousClock.now + .seconds(10)
      while ContinuousClock.now < deadline, let current = try? db.activeTurn(threadId: thread.id) {
        if !asked, let native = current.nativeTurnId {
          asked = true
          if let receipt = try? await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: native)),
            let outcome = receipt.outcome
          {
            _ = try? db.updateTurn(id: current.id) {
              if $0.status != .terminal {
                $0.status = .terminal
                $0.outcome = outcome
              }
            }
          }
          continue
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    guard let unresolved = try? db.activeTurn(threadId: thread.id) else { return }
    for request in (try? db.pendingRuntimeRequests(threadId: thread.id)) ?? [] {
      _ = try? db.transitionRuntimeRequest(id: request.id, to: .expired)
    }
    _ = try? db.updateTurn(id: unresolved.id) {
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
    for listed in due where threadId == nil || listed.id == threadId {
      guard deletingThreads.insert(listed.id).inserted else { continue }
      defer { deletingThreads.remove(listed.id) }
      // The list may be stale: another sweep may have finished this thread since it was read.
      guard
        let thread = try? db.threadAwaitingRuntimeDelete(id: listed.id, now: Timestamp.string(from: now))
      else { continue }
      await deleteRuntimeCopy(thread, now: now)
    }
  }

  private func deleteRuntimeCopy(_ thread: ConversationThread, now: Date) async {
    do {
      let connection = try db.connection(id: thread.connectionId)
      // Historical and unavailable protocol rows cannot settle native work through a harness path.
      // This check must precede stopTurn, which has harness-specific terminalization behavior.
      if connection?.isProtocolReadOnly == true || connection?.kind == .agentProtocol {
        return try db.recordThreadDelete(
          threadId: thread.id, outcome: .unsupported, error: nil, nextAttemptAt: nil)
      }
      await stopTurn(of: thread, connection: connection)
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
        // Counted from when this try failed (a request can hang until its timeout), or from the sweep's
        // clock when that is later.
        let wait = Self.threadDeleteBackoff(attempts: attempts)
        try db.recordThreadDelete(
          threadId: thread.id, outcome: .waiting,
          error: LogRedactor.redact(WorkspaceError.from(error).message),
          nextAttemptAt: Timestamp.string(from: max(now, Date()).addingTimeInterval(wait)))
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
