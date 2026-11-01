import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceClient

/// In-memory transport: records sent lines and lets the test inject server frames.
final class FakeTransport: WorkspaceTransport, @unchecked Sendable {
  let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var sentLines: [Data] = []

  init() {
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    incoming = stream
    self.continuation = continuation
  }

  private var sentWaiters: [(count: Int, continuation: CheckedContinuation<[Data], Never>)] = []

  var sent: [Data] {
    lock.withLock { sentLines }
  }

  /// The lines sent so far, as soon as there are at least `count`. The timeout only ends a test that
  /// would otherwise hang; it then returns what was sent.
  func sent(atLeast count: Int, timeout: Duration = .seconds(60)) async -> [Data] {
    let alarm = Task { [weak self] in
      guard (try? await Task.sleep(for: timeout)) != nil else { return }
      self?.resumeWaiters(all: true)
    }
    defer { alarm.cancel() }
    return await withCheckedContinuation { continuation in
      let ready: [Data]? = lock.withLock {
        if sentLines.count >= count { return sentLines }
        sentWaiters.append((count, continuation))
        return nil
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }

  func send(_ line: Data) async throws {
    lock.withLock { sentLines.append(line) }
    resumeWaiters(all: false)
  }

  private func resumeWaiters(all: Bool) {
    let (lines, due): ([Data], [CheckedContinuation<[Data], Never>]) = lock.withLock {
      let due = sentWaiters.filter { all || sentLines.count >= $0.count }.map(\.continuation)
      sentWaiters.removeAll { all || sentLines.count >= $0.count }
      return (sentLines, due)
    }
    for waiter in due { waiter.resume(returning: lines) }
  }

  func receive(_ envelope: ServerEnvelope) throws {
    continuation.yield(try envelope.encoded())
  }

  func close() async { continuation.finish() }
}

private let hello = HelloEnvelope(
  epoch: "e1", sequence: 0, coordinator: CoordinatorIdentity(version: "0.0.0", pid: 1))

@Suite struct EventCursorTests {
  @Test func acceptsFirstEventAtAnyPosition() {
    var cursor = EventCursor()
    #expect(cursor.advance(epoch: "e1", sequence: 5) == .ok)
    #expect(cursor.sequence == 5)
  }

  @Test func reportsDuplicatesGapsAndEpochChangesWithoutMoving() {
    var cursor = EventCursor()
    cursor.reset(epoch: "e1", sequence: 10)
    #expect(cursor.advance(epoch: "e1", sequence: 10) == .duplicate)
    #expect(cursor.advance(epoch: "e1", sequence: 12) == .gap)
    #expect(cursor.advance(epoch: "e2", sequence: 11) == .epochChanged)
    #expect(cursor.sequence == 10)
    #expect(cursor.advance(epoch: "e1", sequence: 11) == .ok)
  }
}

@Suite struct WorkspaceClientTests {
  private func waitForSent(_ transport: FakeTransport, count: Int) async throws -> [Data] {
    await transport.sent(atLeast: count)
  }

  @Test func sendsCommandEnvelopeAndDecodesTypedResult() async throws {
    let transport = FakeTransport()
    let client = WorkspaceClient(transport: transport)
    try transport.receive(.hello(hello))
    _ = try await client.ready()
    async let pending = client.request(SystemPing.self, EmptyParams())
    let sent = try await waitForSent(transport, count: 1)
    let envelope = try JSONCoding.decoder.decode(CommandEnvelope.self, from: sent[0])
    #expect(envelope.method == "system.ping")
    let result = SystemPing.Result(epoch: "e1", sequence: 0, coordinator: hello.coordinator, startedAt: "x")
    try transport.receive(.response(.success(envelope.requestId, result: try JSONValue(encoding: result))))
    let pong = try await pending
    #expect(pong.pong == true)
    #expect(pong.epoch == "e1")
  }

  @Test func surfacesCoordinatorErrorCodes() async throws {
    let transport = FakeTransport()
    let client = WorkspaceClient(transport: transport)
    let pending = Task { try await client.request(ThreadList.self, ThreadList.Params()) }
    let sent = try await waitForSent(transport, count: 1)
    let envelope = try JSONCoding.decoder.decode(CommandEnvelope.self, from: sent[0])
    try transport.receive(
      .response(.failure(envelope.requestId, error: WorkspaceError(.notImplemented, "later"))))
    do {
      _ = try await pending.value
      Issue.record("expected failure")
    } catch let error as WorkspaceError {
      #expect(error.code == .notImplemented)
    }
  }

  @Test func deliversOrderedEventsAndSignalsDesyncOnGap() async throws {
    let transport = FakeTransport()
    let client = WorkspaceClient(transport: transport)
    try transport.receive(.hello(hello))
    _ = try await client.ready()
    let events = await client.events()
    let desync = await client.desync()
    let event = AdapterEvent.connectionChanged(
      connectionId: "c", status: .ready, authStatus: .unknown, transport: .connected)
    try transport.receive(.event(EventEnvelope(epoch: "e1", sequence: 1, event: event)))
    try transport.receive(.event(EventEnvelope(epoch: "e1", sequence: 3, event: event)))
    var iterator = events.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.sequence == 1)
    var desyncIterator = desync.makeAsyncIterator()
    let reason = await desyncIterator.next()
    #expect(reason == .gap)
  }

  @Test func failsPendingRequestsWhenTransportCloses() async throws {
    let transport = FakeTransport()
    let client = WorkspaceClient(transport: transport)
    async let pending = client.request(SystemPing.self, EmptyParams())
    _ = try await waitForSent(transport, count: 1)
    await transport.close()
    do {
      _ = try await pending
      Issue.record("expected failure")
    } catch let error as WorkspaceError {
      #expect(error.code == .endpointUnavailable)
    }
  }

  @Test func unavailableTransportRejectsImmediately() async {
    let client = WorkspaceClient(transport: UnavailableTransport(reason: "No relay yet."))
    do {
      _ = try await client.request(
        SystemPing.self, EmptyParams(), options: RequestOptions(timeout: .seconds(2)))
      Issue.record("expected failure")
    } catch let error as WorkspaceError {
      #expect(error.code == .endpointUnavailable)
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }
}
