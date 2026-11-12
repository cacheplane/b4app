import Dispatch
import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

@Suite(.serialized, .timeLimit(.minutes(3))) struct OwnedCloseConcurrencyTests {
  @Test func concurrentServerClosersAwaitTheAcceptOwnerAndSharedCleanup() async throws {
    let h = try await Harness.start()
    let log = CloseProbe<String>()
    let ownerHeld = CloseGate()
    let ownerRelease = CloseGate()
    let server: SocketServer
    do {
      server = try await SocketServer.start(
        socketPath: h.coordinator.paths.runtimeDir + "/concurrent", router: h.coordinator.router,
        eventLog: h.coordinator.eventLog,
        lifecycleObserver: { event in
          switch event {
          case .acceptFinished:
            log.record("acceptFinished")
            ownerHeld.release()
            await ownerRelease.wait()
          case .existingCompletion: log.record("existingCompletion")
          case .cleanupStarted: log.record("cleanupStarted")
          case .cleanupFinished:
            log.record("cleanupFinished")
            if Task.isCancelled { log.record("cleanupCancelled") }
          case .groupShutdownStarted: log.record("groupShutdownStarted")
          default: break
          }
        })
    } catch {
      await h.stop()
      throw error
    }
    let first = Task {
      await server.close()
      log.record("returned:first")
    }
    await ownerHeld.wait()
    let second = Task {
      await server.close()
      log.record("returned:second")
    }
    _ = await log.wait { $0 == "existingCompletion" }
    first.cancel()
    #expect(!server.invocationSnapshot.accepting)
    #expect(!log.events.contains("groupShutdownStarted"))
    ownerRelease.release()
    await first.value
    await second.value
    await server.close()
    log.record("returned:third")
    expectSharedCleanup(log.events)
    await h.stop()
  }

  /// Revises v3's unrun accept-cancellation control to the graceful source-finish/drain contract.
  @Test func initializedActiveBufferedChildrenDrainToStructuredOwnersBeforeGroupShutdown() async throws {
    let directory =
      AgentProtocolResourceFixture.temporaryDirectory + "dr-\(UUID().uuidString.prefix(8))"
    try PrivateFiles.ensurePrivateDirectory(directory)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let events = EventLog()
    let acceptance = CloseProbe<SocketAcceptanceEvent>()
    let lifecycle = CloseProbe<SocketLifecycleEvent>()
    let firstHandoff = FirstSocketHandoff()
    defer { firstHandoff.release() }
    let server = try await SocketServer.start(
      socketPath: directory + "/s", eventLog: events,
      plainDispatch: { _ in
        Issue.record("The acceptance drain control sends no command.")
        return ResponseEnvelope.success("unexpected", result: .object([:]))
      },
      lifecycleObserver: { event in
        lifecycle.record(event)
        if case .connectionDequeued(let id) = event { await firstHandoff.holdIfFirst(id) }
      }, acceptanceObserver: { acceptance.record($0) })
    var peers: [UnixSocketTransport] = []
    do {
      let firstPeer = try await UnixSocketTransport.connect(path: server.socketPath)
      peers.append(firstPeer)
      await firstHandoff.held.wait()
      let firstDequeued = await acceptance.wait {
        if case .dequeued = $0 { return true }
        return false
      }
      let firstChild: ObjectIdentifier
      let firstConnection: UUID
      switch firstDequeued {
      case .dequeued(let child, let connection):
        firstChild = child
        firstConnection = connection
      default: preconditionFailure("The predicate selected an actual dequeued child.")
      }
      _ = await acceptance.wait { $0 == .active(firstChild) }
      #expect(acceptance.events.contains(.initialized(firstChild)))
      let secondPeer = try await UnixSocketTransport.connect(path: server.socketPath)
      peers.append(secondPeer)
      let secondInitialized = await acceptance.wait {
        if case .initialized(let child) = $0 { return child != firstChild }
        return false
      }
      let secondChild: ObjectIdentifier
      switch secondInitialized {
      case .initialized(let child): secondChild = child
      default: preconditionFailure("The predicate selected the second initialized child.")
      }
      _ = await acceptance.wait { $0 == .active(secondChild) }
      // The first dequeue is still held. The second initialized+active wrapper has been yielded
      // by the pinned synchronous initializer path, but no second next()/handoff has occurred.
      let dequeuedCount = acceptance.events.filter {
        if case .dequeued = $0 { return true }
        return false
      }.count
      #expect(dequeuedCount == 1)
      let eof = peers.map { peer in Task { for await _ in peer.incoming {} } }
      let closing = Task { await server.close() }
      _ = await acceptance.wait { $0 == .listenerClosed }
      #expect(!lifecycle.events.contains(.acceptFinished))
      #expect(!lifecycle.events.contains(.groupShutdownStarted))
      #expect(!lifecycle.events.contains(.connectionFinished(firstConnection)))
      firstHandoff.release()
      await closing.value
      for task in eof { await task.value }
      let secondDequeued = await acceptance.wait {
        if case .dequeued(let child, _) = $0 { return child == secondChild }
        return false
      }
      let secondConnection: UUID
      switch secondDequeued {
      case .dequeued(_, let connection): secondConnection = connection
      default: preconditionFailure("The predicate selected the second child handoff.")
      }
      expectSocketOwnersBeforeGroup(
        lifecycle.events, connections: [firstConnection, secondConnection])
      #expect(acceptance.events.filter { $0 == .initialized(firstChild) }.count == 1)
      #expect(acceptance.events.filter { $0 == .initialized(secondChild) }.count == 1)
      let initializedCount = acceptance.events.filter {
        if case .initialized = $0 { return true }
        return false
      }.count
      #expect(initializedCount == 2)
      for peer in peers { await peer.close() }
      await server.close()
      await events.finish()
    } catch {
      firstHandoff.release()
      for peer in peers { await peer.close() }
      await server.close()
      await events.finish()
      throw error
    }
  }

  @Test func nestedListenerCloseFollowsAChildTransformQueuedAfterTheCloseRequest() async throws {
    let directory =
      AgentProtocolResourceFixture.temporaryDirectory + "qt-\(UUID().uuidString.prefix(8))"
    try PrivateFiles.ensurePrivateDirectory(directory)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let events = EventLog()
    let acceptance = CloseProbe<SocketAcceptanceEvent>()
    let lifecycle = CloseProbe<SocketLifecycleEvent>()
    let firstHandoff = FirstSocketHandoff()
    let rawRead = SocketFixtureBlockingGate()
    // This is the only blocking event-loop fixture. No Mutex is held during wait, and every
    // ordinary error/teardown path releases it synchronously before any await cleanup.
    defer {
      rawRead.release()
      firstHandoff.release()
    }
    let server = try await SocketServer.start(
      socketPath: directory + "/s", eventLog: events,
      plainDispatch: { _ in
        Issue.record("The queued-transform control sends no command.")
        return ResponseEnvelope.success("unexpected", result: .object([:]))
      },
      lifecycleObserver: { event in
        lifecycle.record(event)
        if case .connectionDequeued(let id) = event { await firstHandoff.holdIfFirst(id) }
      },
      acceptanceObserver: { event in
        acceptance.record(event)
        if case .rawRead = event { rawRead.wait() }
      })
    let peer: UnixSocketTransport
    do { peer = try await UnixSocketTransport.connect(path: server.socketPath) } catch {
      rawRead.release()
      firstHandoff.release()
      await server.close()
      await events.finish()
      throw error
    }
    let raw = await acceptance.wait {
      if case .rawRead = $0 { return true }
      return false
    }
    let child: ObjectIdentifier
    switch raw {
    case .rawRead(let id): child = id
    default: preconditionFailure("The predicate selected the actual raw child read.")
    }
    let eof = Task { for await _ in peer.incoming {} }
    let closing = Task { await server.close() }
    _ = await acceptance.wait { $0 == .firstCloseTurnQueued }
    // The real close marker is now queued while the raw read callback is still held upstream
    // of Bootstrap's transformation queueing. This is causal queue ordering, not elapsed absence.
    #expect(!acceptance.events.contains(.initialized(child)))
    rawRead.release()
    _ = await acceptance.wait { $0 == .listenerClosed }
    _ = await acceptance.wait { $0 == .active(child) }
    await firstHandoff.held.wait()
    #expect(!lifecycle.events.contains(.acceptFinished))
    #expect(!lifecycle.events.contains(.groupShutdownStarted))
    firstHandoff.release()
    await closing.value
    await eof.value
    let observations = acceptance.events
    let dequeued = await acceptance.wait {
      if case .dequeued(let id, _) = $0 { return id == child }
      return false
    }
    let connection: UUID
    switch dequeued {
    case .dequeued(_, let id): connection = id
    default: preconditionFailure("The predicate selected the actual child handoff.")
    }
    if let read = observations.firstIndex(of: .rawRead(child)),
      let queued = observations.firstIndex(of: .firstCloseTurnQueued),
      let forwarded = observations.firstIndex(of: .rawReadForwarded(child)),
      let marker = observations.firstIndex(of: .firstCloseTurnExecuting),
      let initialized = observations.firstIndex(of: .initialized(child)),
      let close = observations.firstIndex(of: .listenerCloseInvoked),
      let finished = observations.firstIndex(of: .listenerClosed)
    {
      #expect(read < queued && queued < forwarded && forwarded < marker && marker < initialized)
      #expect(initialized < close && close < finished)
    } else {
      Issue.record("The queued child transform must finish before the nested actual close.")
    }
    expectSocketOwnersBeforeGroup(lifecycle.events, connections: [connection])
    rawRead.release()
    firstHandoff.release()
    await peer.close()
    await server.close()
    await events.finish()
  }

  @Test func concurrentCoordinatorClosersWaitThroughLockRelease() async throws {
    let h = try await Harness.start()
    let log = CloseProbe<String>()
    let lockHeld = CloseGate()
    let release = CloseGate()
    let observer: CoordinatorLifecycleObserver = { event in
      log.record(event.rawValue)
      if event == .cleanupFinished, Task.isCancelled { log.record("cleanupCancelled") }
      if event == .lockReleased {
        lockHeld.release()
        await release.wait()
      }
    }
    let first = Task {
      await h.coordinator.close(lifecycleObserver: observer)
      log.record("returned:first")
    }
    await lockHeld.wait()
    let second = Task {
      await h.coordinator.close(lifecycleObserver: observer)
      log.record("returned:second")
    }
    _ = await log.wait { $0 == "existingCompletion" }
    second.cancel()
    #expect(!log.events.contains("cleanupFinished"))
    release.release()
    await first.value
    await second.value
    await h.client.close()
    await h.coordinator.close(lifecycleObserver: observer)
    log.record("returned:third")
    expectSharedCleanup(log.events)
    if let released = log.events.firstIndex(of: "lockReleased"),
      let finished = log.events.firstIndex(of: "cleanupFinished")
    {
      #expect(released < finished)
    } else {
      Issue.record("Actual lock release must precede completed coordinator cleanup.")
    }
  }
}

func expectSharedCleanup(_ events: [String]) {
  #expect(events.filter { $0 == "cleanupStarted" }.count == 1)
  #expect(events.filter { $0 == "cleanupFinished" }.count == 1)
  #expect(!events.contains("cleanupCancelled"))
  if let finished = events.firstIndex(of: "cleanupFinished"),
    let first = events.firstIndex(of: "returned:first"),
    let second = events.firstIndex(of: "returned:second")
  {
    #expect(finished < first && finished < second)
  } else {
    Issue.record("Every public close return must follow actual shared cleanup completion.")
  }
  if let finished = events.firstIndex(of: "cleanupFinished") {
    for (index, event) in events.enumerated() where event.hasPrefix("returned:") {
      #expect(finished < index)
    }
  }
}

/// Test-owned, plain event bookkeeping; no tasks and no socket references.
final class CloseProbe<Event: Sendable>: Sendable {
  private struct Waiter {
    let predicate: @Sendable (Event) -> Bool
    let continuation: CheckedContinuation<Event, Never>
  }
  private struct State {
    var events: [Event] = []
    var waiters: [Waiter] = []
  }
  private let state = Mutex(State())
  var events: [Event] { state.withLock { $0.events } }
  func record(_ event: Event) {
    let ready = state.withLock { state in
      state.events.append(event)
      let ready = state.waiters.filter { $0.predicate(event) }
      state.waiters.removeAll { $0.predicate(event) }
      return ready
    }
    for waiter in ready { waiter.continuation.resume(returning: event) }
  }
  func wait(_ predicate: @escaping @Sendable (Event) -> Bool) async -> Event {
    await withCheckedContinuation { continuation in
      let existing: Event? = state.withLock { state in
        if let existing = state.events.first(where: predicate) { return existing }
        state.waiters.append(Waiter(predicate: predicate, continuation: continuation))
        return nil
      }
      if let existing { continuation.resume(returning: existing) }
    }
  }
}

/// Uncancellable one-shot fixture gate: test teardown always releases it and joins its owner.
final class CloseGate: Sendable {
  private struct State {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  func release() {
    let waiters = state.withLock { state in
      state.open = true
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.open { return true }
        state.waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
}

private func expectSocketOwnersBeforeGroup(
  _ events: [SocketLifecycleEvent], connections: [UUID]
) {
  guard let accept = events.firstIndex(of: .acceptFinished),
    let group = events.firstIndex(of: .groupShutdownStarted)
  else { Issue.record("Actual accept completion and group shutdown must be observed."); return }
  #expect(accept < group)
  let finishedConnections = events.compactMap { event -> UUID? in
    if case .connectionFinished(let connection) = event { return connection }
    return nil
  }
  #expect(Set(finishedConnections) == Set(connections))
  #expect(finishedConnections.count == connections.count)
  for connection in connections {
    #expect(events.filter { $0 == .connectionFinished(connection) }.count == 1)
    if let finished = events.firstIndex(of: .connectionFinished(connection)) {
      #expect(finished < accept)
    } else {
      Issue.record("Every exact dequeued child must finish before the accept owner.")
    }
  }
}

private final class FirstSocketHandoff: Sendable {
  private let first = Mutex<UUID?>(nil)
  let held = CloseGate()
  private let proceed = CloseGate()
  func holdIfFirst(_ id: UUID) async {
    let shouldHold = first.withLock { first in
      guard first == nil else { return false }
      first = id
      return true
    }
    if shouldHold {
      held.release()
      await proceed.wait()
    }
  }
  func release() { proceed.release() }
}

/// One fixture-only synchronous event-loop gate. Release never runs under its Mutex.
private final class SocketFixtureBlockingGate: Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let released = Mutex(false)
  func wait() { semaphore.wait() }
  func release() {
    let first = released.withLock { released in
      guard !released else { return false }
      released = true
      return true
    }
    if first { semaphore.signal() }
  }
}
