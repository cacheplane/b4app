import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceProtocol

@testable import Coordinator

@Suite(.serialized, .timeLimit(.minutes(2))) struct SocketServerShutdownTests {
  @Test func initializedBufferedChildrenReachScopedOwnersBeforeLoopShutdown() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ShutdownProbe()
    let handoff = ShutdownGate()
    let server = try await SocketServer.start(
      socketPath: root.appendingPathComponent("s").path, eventLog: EventLog(),
      dispatch: { _ in ResponseEnvelope.success("unexpected", result: .object([:])) },
      observer: { probe.record($0) }, handoff: { _ in await handoff.holdFirst() })
    var peers: [UnixSocketTransport] = []
    var closing: Task<Void, Never>?
    var failure: (any Error)?
    do {
      peers.append(try await UnixSocketTransport.connect(path: server.socketPath))
      try await waitFor { handoff.reached }
      peers.append(try await UnixSocketTransport.connect(path: server.socketPath))
      try await waitFor { probe.initialized.count == 2 }
      #expect(probe.dequeued.count == 1)
      let task = Task { await server.close() }
      closing = task
      try await waitFor { probe.contains(.listenerClosed) }
      #expect(!probe.contains(.acceptFinished) && !probe.contains(.groupShutdownStarted))
      handoff.release()
      await task.value
    } catch { failure = error }
    handoff.release()
    if let closing { await closing.value } else { await server.close() }
    for peer in peers { await peer.close() }
    await server.close()
    if let failure { throw failure }
    #expect(probe.initialized.count == 2 && probe.dequeued.count == 2)
    #expect(Set(probe.initialized) == Set(probe.dequeued))
    for child in probe.initialized {
      try probe.expectBefore(.dequeued(child), .served(child))
      try probe.expectBefore(.served(child), .acceptFinished)
    }
    try probe.expectBefore(.sourceFinished, .acceptFinished)
    try probe.expectBefore(.acceptFinished, .groupShutdownStarted)
    #expect(probe.count(.groupShutdownStarted) == 1)
  }

  @Test func queuedChildInitializerCompletesBeforeListenerSourceCloses() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ShutdownProbe()
    let rawRead = BlockingShutdownGate()
    let server = try await SocketServer.start(
      socketPath: root.appendingPathComponent("s").path, eventLog: EventLog(),
      dispatch: { _ in ResponseEnvelope.success("unexpected", result: .object([:])) },
      observer: { event in
        probe.record(event)
        if case .rawRead = event { rawRead.holdFirst() }
      })
    let connecting = Task { try await UnixSocketTransport.connect(path: server.socketPath) }
    var closing: Task<Void, Never>?
    var failure: (any Error)?
    do {
      try await waitFor { rawRead.reached }
      let task = Task { await server.close() }
      closing = task
      try await waitFor { probe.contains(.firstCloseTurnQueued) }
      #expect(!probe.contains(.firstCloseTurnExecuting))
      rawRead.release()
      await task.value
    } catch { failure = error }
    rawRead.release()
    if let closing { await closing.value } else { await server.close() }
    let result = await connecting.result
    if case .success(let peer) = result { await peer.close() }
    if let failure { throw failure }
    _ = try result.get()
    #expect(!rawRead.timedOut)
    let child = try #require(probe.initialized.first)
    #expect(probe.initialized.count == 1 && probe.dequeued == [child])
    try probe.expectBefore(.firstCloseTurnExecuting, .initialized(child))
    try probe.expectBefore(.initialized(child), .listenerCloseInvoked)
    try probe.expectBefore(.dequeued(child), .served(child))
    try probe.expectBefore(.served(child), .acceptFinished)
    try probe.expectBefore(.acceptFinished, .groupShutdownStarted)
  }

  @Test func closeJoinsAnActualDispatchBeforeShuttingDownTheLoop() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ShutdownProbe()
    let dispatch = ShutdownGate()
    let server = try await SocketServer.start(
      socketPath: root.appendingPathComponent("s").path, eventLog: EventLog(),
      dispatch: { _ in
        // This actual handler deliberately ignores task cancellation until its owner releases it.
        await dispatch.holdFirst()
        return ResponseEnvelope.success("held", result: .object([:]))
      }, observer: { probe.record($0) })
    var peer: UnixSocketTransport?
    var closing: Task<Void, Never>?
    var failure: (any Error)?
    do {
      let transport = try await UnixSocketTransport.connect(path: server.socketPath)
      peer = transport
      try await transport.send(Data("held request".utf8))
      try await waitFor { dispatch.reached }
      let task = Task { await server.close() }
      closing = task
      try await waitFor { probe.contains(.sourceFinished) }
      #expect(!probe.contains(.acceptFinished) && !probe.contains(.groupShutdownStarted))
      dispatch.release()
      await task.value
    } catch { failure = error }
    dispatch.release()
    if let closing { await closing.value } else { await server.close() }
    if let peer { await peer.close() }
    if let failure { throw failure }
    let child = try #require(probe.dequeued.first)
    try probe.expectBefore(.sourceFinished, .served(child))
    try probe.expectBefore(.served(child), .acceptFinished)
    try probe.expectBefore(.acceptFinished, .groupShutdownStarted)
  }

  private func directory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
      .appendingPathComponent("ss-" + String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  private func waitFor(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw ShutdownTestError.deadline }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private enum ShutdownTestError: Error { case deadline }

private final class ShutdownProbe: Sendable {
  private let state = Mutex<[SocketShutdownEvent]>([])
  func record(_ event: SocketShutdownEvent) { state.withLock { $0.append(event) } }
  var events: [SocketShutdownEvent] { state.withLock { $0 } }
  var initialized: [ObjectIdentifier] {
    events.compactMap { if case .initialized(let id) = $0 { id } else { nil } }
  }
  var dequeued: [ObjectIdentifier] {
    events.compactMap { if case .dequeued(let id) = $0 { id } else { nil } }
  }
  func contains(_ event: SocketShutdownEvent) -> Bool { events.contains(event) }
  func count(_ event: SocketShutdownEvent) -> Int { events.filter { $0 == event }.count }
  func expectBefore(_ first: SocketShutdownEvent, _ second: SocketShutdownEvent) throws {
    let events = events
    let a = try #require(events.firstIndex(of: first))
    let b = try #require(events.firstIndex(of: second))
    #expect(a < b)
  }
}

private final class ShutdownGate: Sendable {
  private struct State {
    var reached = false
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
  }
  private let state = Mutex(State())
  var reached: Bool { state.withLock { $0.reached } }
  func holdFirst() async {
    let first = state.withLock { state in
      guard !state.reached else { return false }
      state.reached = true
      return true
    }
    guard first else { return }
    await withCheckedContinuation { continuation in
      let resume = state.withLock { state in
        if state.released { return true }
        state.continuation = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }
  func release() {
    let continuation = state.withLock { state in
      state.released = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume()
  }
}

/// The event loop is held before forwarding one raw accept. The test queues close's first turn,
/// then releases this callback: Bootstrap's child initializer must run between close's two turns.
private final class BlockingShutdownGate: Sendable {
  private let state = Mutex((reached: false, timedOut: false))
  private let semaphore = DispatchSemaphore(value: 0)
  var reached: Bool { state.withLock { $0.reached } }
  var timedOut: Bool { state.withLock { $0.timedOut } }
  func holdFirst() {
    let first = state.withLock { state in
      guard !state.reached else { return false }
      state.reached = true
      return true
    }
    if first, semaphore.wait(timeout: .now() + 30) == .timedOut {
      state.withLock { $0.timedOut = true }
    }
  }
  func release() { semaphore.signal() }
}
