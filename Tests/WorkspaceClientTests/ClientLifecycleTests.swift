import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceClient

@Suite struct ClientLifecycleTests {
  @Test func workspaceClientClosesTransportOnce() async throws {
    let transport = CloseCountingTransport()
    let client = WorkspaceClient(transport: transport)
    do {
      try await transport.receiveHello()
      _ = try await client.ready()
    } catch {
      await client.close()
      await transport.waitForIncomingTermination()
      throw error
    }

    await client.close()
    await client.close()
    await transport.waitForIncomingTermination()
    #expect(await transport.closeCount == 1)
  }
}

/// The real client's delegation count is the oracle; this fixture owns no reader task.
private actor CloseCountingTransport: WorkspaceTransport {
  nonisolated let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let incomingTerminated: AsyncStream<Void>
  private(set) var closeCount = 0

  init() {
    let (incoming, continuation) = AsyncStream<Data>.makeStream()
    let (terminated, termination) = AsyncStream<Void>.makeStream()
    self.incoming = incoming
    self.continuation = continuation
    incomingTerminated = terminated
    continuation.onTermination = { _ in termination.finish() }
  }

  func receiveHello() throws {
    let hello = HelloEnvelope(
      epoch: "lifecycle-test", sequence: 0, coordinator: CoordinatorIdentity(version: "test", pid: 0))
    continuation.yield(try NDJSON.encodeLine(hello))
  }

  func send(_ line: Data) async throws {}

  func close() async {
    closeCount += 1
    continuation.finish()
  }

  func waitForIncomingTermination() async {
    for await _ in incomingTerminated {}
  }
}

@Suite struct ClientClosePreservationTests {
  @Test func closeFailsPendingBeforeTransportTeardownCompletes() async throws {
    let transport = HeldCloseTransport()
    let client = WorkspaceClient(transport: transport)
    let request = Task { try await client.request(SystemPing.self, EmptyParams()) }
    await transport.sendEntered.wait()
    let closing = Task { await client.close() }
    await transport.closeEntered.wait()
    do {
      _ = try await request.value
      Issue.record("A pending request must fail when close begins.")
    } catch {
      #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
    await transport.allowClose.release()
    await closing.value
    await transport.allowSend.release()
    await transport.sendFinished.wait()
    #expect(await transport.closeCount == 1)
  }

  @Test func closeDoesNotJoinAnUncooperativeCustomSend() async throws {
    let transport = HeldCloseTransport()
    let client = WorkspaceClient(transport: transport)
    let request = Task { try await client.request(SystemPing.self, EmptyParams()) }
    await transport.sendEntered.wait()
    let closing = Task { await client.close() }
    await transport.closeEntered.wait()
    await transport.allowClose.release()
    await closing.value
    #expect(await transport.sendCount == 1)
    do {
      _ = try await request.value
      Issue.record("An interrupted request must fail.")
    } catch {
      #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
    do {
      _ = try await client.request(SystemPing.self, EmptyParams())
      Issue.record("A closed client must refuse new requests.")
    } catch {
      #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
    #expect(await transport.sendCount == 1)
    await transport.allowSend.release()
    await transport.sendFinished.wait()
    await client.close()
    #expect(await transport.closeCount == 1)
  }

  @Test func aLateHelloCannotReopenAClosedClient() async throws {
    let transport = HeldCloseTransport()
    let client = WorkspaceClient(transport: transport)
    let closing = Task { await client.close() }
    await transport.closeEntered.wait()
    do {
      try await transport.receiveHello()
    } catch {
      await transport.allowClose.release()
      await closing.value
      throw error
    }
    await transport.allowClose.release()
    await closing.value
    do {
      _ = try await client.ready()
      Issue.record("A late hello must not reopen the closed protocol.")
    } catch {
      #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
  }
}

/// A one-shot causal gate. Every test releases its held operations and joins its own tasks.
private actor ClientGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if released { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }
}

private actor HeldCloseTransport: WorkspaceTransport {
  nonisolated let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  nonisolated let sendEntered = ClientGate()
  nonisolated let sendFinished = ClientGate()
  nonisolated let closeEntered = ClientGate()
  nonisolated let allowClose = ClientGate()
  nonisolated let allowSend = ClientGate()
  private(set) var closeCount = 0
  private(set) var sendCount = 0

  init() {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    incoming = stream
    self.continuation = continuation
  }
  func receiveHello() throws {
    continuation.yield(
      try NDJSON.encodeLine(
        HelloEnvelope(
          epoch: "late", sequence: 0, coordinator: CoordinatorIdentity(version: "test", pid: 0))))
  }
  func send(_ line: Data) async throws {
    sendCount += 1
    await sendEntered.release()
    await allowSend.wait()  // Deliberately ignores cancellation, like an arbitrary custom transport.
    await sendFinished.release()
  }
  func close() async {
    closeCount += 1
    await closeEntered.release()
    await allowClose.wait()
    continuation.finish()
  }
}

@Suite struct ClientConcurrentCloseTests {
  @Test func concurrentClosersWaitForCleanupEvenWhenOneCloserIsCancelled() async {
    let transport = HeldCloseTransport()
    let observations = ClientCloseObservations()
    let client = WorkspaceClient(
      transport: transport,
      lifecycleObserver: { event in
        await observations.record(event.rawValue)
        if event == .cleanupFinished, Task.isCancelled {
          await observations.record("cleanupCancelled")
        }
      })
    let first = Task {
      await client.close()
      await observations.record("returned:first")
    }
    await transport.closeEntered.wait()
    let second = Task {
      await client.close()
      await observations.record("returned:second")
    }
    await observations.waitFor("existingCompletion")
    first.cancel()
    #expect(await transport.closeCount == 1)
    await transport.allowClose.release()
    await first.value
    await second.value
    await client.close()
    await observations.record("returned:third")
    #expect(await transport.closeCount == 1)
    let events = await observations.events
    #expect(events.filter { $0 == "cleanupStarted" }.count == 1)
    #expect(events.filter { $0 == "cleanupFinished" }.count == 1)
    #expect(!events.contains("cleanupCancelled"))
    if let finished = events.firstIndex(of: "cleanupFinished"),
      let firstReturn = events.firstIndex(of: "returned:first"),
      let secondReturn = events.firstIndex(of: "returned:second")
    {
      #expect(finished < firstReturn && finished < secondReturn)
    } else {
      Issue.record("Both close returns must follow actual cleanup completion.")
    }
    if let finished = events.firstIndex(of: "cleanupFinished") {
      for (index, event) in events.enumerated() where event.hasPrefix("returned:") {
        #expect(finished < index)
      }
    }
  }
}

private actor ClientCloseObservations {
  private(set) var events: [String] = []
  private var waiters: [(String, CheckedContinuation<Void, Never>)] = []
  func record(_ event: String) {
    events.append(event)
    let ready = waiters.filter { $0.0 == event }
    waiters.removeAll { $0.0 == event }
    for waiter in ready { waiter.1.resume() }
  }
  func waitFor(_ event: String) async {
    if events.contains(event) { return }
    await withCheckedContinuation { waiters.append((event, $0)) }
  }
}
