import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceClient

@Suite struct RecordingSessionTests {
  @Test func keepsDeltasAndAdvancesAcrossUnrelatedEvents() throws {
    var recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 100_000)
    recording.begin(epoch: "epoch", sequence: 0)
    try recording.accept(envelope(1, kind: .environmentChanged, thread: nil), elapsedMs: 0)
    try recording.accept(envelope(2, kind: .messageDelta, payload: ["delta": "hello"]), elapsedMs: 1)
    try recording.accept(envelope(2, kind: .messageDelta, payload: ["delta": "hello"]), elapsedMs: 1)
    #expect(recording.events.count == 1)
    #expect(recording.events[0].sourceSequence == 2)
    #expect(recording.events[0].fields["delta"] == "hello")
  }

  @Test func rejectsGapEpochAndAccountChanges() throws {
    for event in [
      envelope(2, kind: .environmentChanged, thread: nil),
      EventEnvelope(
        epoch: "other", sequence: 1, event: AdapterEvent(kind: .environmentChanged, connectionId: "")),
      envelope(1, kind: .accountChanged, thread: nil),
    ] {
      var recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 100_000)
      recording.begin(epoch: "epoch", sequence: 0)
      #expect(throws: RecordingFailure.self) { try recording.accept(event, elapsedMs: 0) }
    }
  }

  @Test func rejectsOverflowAndUnsupportedSemanticEvents() throws {
    var recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 10)
    recording.begin(epoch: "epoch", sequence: 0)
    #expect(throws: RecordingFailure.self) {
      try recording.accept(envelope(1, kind: .messageDelta, payload: ["delta": "hello"]), elapsedMs: 0)
    }
    recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 100_000)
    recording.begin(epoch: "epoch", sequence: 0)
    #expect(throws: RecordingFailure.self) {
      try recording.accept(envelope(1, kind: .reconciliationSnapshot), elapsedMs: 0)
    }
  }

  @Test func excludesRequestGrantsAndNativeScope() throws {
    let request = RuntimeRequest(
      id: "request", nativeRequestId: "native", threadId: "thread", turnId: "turn",
      adapterGeneration: 0, kind: .toolPermission,
      payload: [
        "request": ["grant": "private-grant", "toolName": "fileFlightPlan", "detail": ["argsPreview": "{}"]]
      ])
    var recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 100_000)
    recording.begin(epoch: "epoch", sequence: 0)
    try recording.accept(
      envelope(1, kind: .runtimeRequestOpened, payload: ["runtimeRequest": try JSONValue(encoding: request)]),
      elapsedMs: 0)
    let text = String(decoding: try JSONCoding.encoder.encode(recording.events), as: UTF8.self)
    #expect(!text.contains("private-grant"))
    #expect(!text.contains("nativeRequestId"))
    #expect(text.contains("fileFlightPlan"))
    #expect(!recording.isSettled)
  }

  @Test func retainsDisplayedCapabilityDataAndToolLabels() throws {
    let item = DisplayItem(
      id: "item", threadId: "thread", turnId: "turn", nativeItemId: "native-item",
      role: .tool, type: "subagent.step",
      payload: ["event": "subagent.step", "data": ["label": "Checking performance"], "label": "Performance"],
      sequence: 0, provenance: .live)
    var recording = RecordingBuffer(threadId: "thread", connectionId: "connection", maxBytes: 100_000)
    recording.begin(epoch: "epoch", sequence: 0)
    try recording.accept(
      envelope(1, kind: .toolCompleted, payload: ["displayItem": try JSONValue(encoding: item)]), elapsedMs: 0
    )
    #expect(recording.events[0].fields["data"] == ["label": "Checking performance"])
    #expect(recording.events[0].fields["event"] == "subagent.step")
    #expect(recording.events[0].fields["label"] == "Performance")
  }

  private func envelope(
    _ sequence: Int, kind: EventKind, thread: String? = "thread", payload: JSONValue = [:]
  ) -> EventEnvelope {
    EventEnvelope(
      epoch: "epoch", sequence: sequence,
      event: AdapterEvent(
        kind: kind, connectionId: "connection", threadId: thread, turnId: "turn",
        nativeIds: ["itemId": "native-item"], payload: payload))
  }
}

@Suite struct RecordingLifecycleTests {
  @Test func freshThreadBecomesReadyAndTimesOutWithoutTraffic() async throws {
    let (transport, client) = try await makeClient()
    let deadline = AsyncStream<Void>.makeStream()
    let session = RecordingSession(
      client: client, threadId: "thread",
      waitForDeadline: { _ in
        for await _ in deadline.stream { return }
        throw CancellationError()
      })
    let starting = Task { try await session.start() }
    try await prepare(transport)
    try await starting.value
    #expect(await session.status == .ready)
    deadline.continuation.yield(())
    for _ in 0..<100 where await session.failure == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await session.failure == .timedOut)
    await client.close()
  }

  @Test func rejectsAnAlreadyUsedThread() async throws {
    let (transport, client) = try await makeClient()
    let session = RecordingSession(client: client, threadId: "thread")
    let starting = Task { try await session.start() }
    try await prepare(transport, nonempty: true)
    await #expect(throws: RecordingFailure.nonemptyThread) { try await starting.value }
    await client.close()
  }

  @Test func rejectsSelectedActivityDuringSetup() async throws {
    let (transport, client) = try await makeClient()
    let session = RecordingSession(client: client, threadId: "thread")
    let starting = Task { try await session.start() }
    try await prepare(
      transport,
      replay: [
        EventEnvelope(
          epoch: "epoch", sequence: 1,
          event: AdapterEvent(
            kind: .messageDelta, connectionId: "connection", threadId: "thread", turnId: "turn",
            nativeIds: ["itemId": "native"], payload: ["delta": "raced"]))
      ])
    await #expect(throws: RecordingFailure.setupActivity) { try await starting.value }
    await client.close()
  }

  @Test func finishesOnlyOnExplicitRequestAndRejectsDisconnectedSession() async throws {
    let (transport, client) = try await makeClient()
    let session = RecordingSession(client: client, threadId: "thread")
    let starting = Task { try await session.start() }
    try await prepare(transport)
    try await starting.value
    let finishing = Task { try await session.finish() }
    try await respond(transport, index: 3, result: EventsReplay.Result(events: []))
    try await respond(
      transport, index: 4,
      result: ThreadRead.Result(
        thread: ConversationThread(id: "thread", connectionId: "connection", nativeThreadId: "private"),
        turns: [], items: [], requests: []))
    let result = try await finishing.value
    #expect(result.isEmpty)
    #expect(await session.status == .finished)
    await client.close()
  }

  @Test(arguments: [TurnStatus.running, .terminal])
  func finishAuditsTheThreadBeforeReturningARecording(status: TurnStatus) async throws {
    let (transport, client) = try await makeClient()
    let session = RecordingSession(client: client, threadId: "thread")
    let starting = Task { try await session.start() }
    try await prepare(transport)
    try await starting.value
    let finishing = Task { try await session.finish() }
    try await respond(transport, index: 3, result: EventsReplay.Result(events: []))
    let sent = await transport.sent(atLeast: 5, timeout: .milliseconds(100))
    #expect(sent.count == 5)
    if sent.count == 5 {
      let thread = ConversationThread(id: "thread", connectionId: "connection", nativeThreadId: "private")
      try await respond(
        transport, index: 4,
        result: ThreadRead.Result(
          thread: thread,
          turns: [Turn(id: "turn", threadId: "thread", operationId: "op", status: status)], items: [],
          requests: []))
      await #expect(throws: RecordingFailure.unsettled) { try await finishing.value }
    } else {
      _ = try? await finishing.value
    }
    await client.close()
  }

  private func makeClient() async throws -> (FakeTransport, WorkspaceClient) {
    let transport = FakeTransport()
    let client = WorkspaceClient(transport: transport)
    try transport.receive(
      .hello(
        HelloEnvelope(
          epoch: "epoch", sequence: 0,
          coordinator: CoordinatorIdentity(version: "test", pid: 1))))
    _ = try await client.ready()
    return (transport, client)
  }

  private func prepare(
    _ transport: FakeTransport, nonempty: Bool = false, replay: [EventEnvelope] = []
  ) async throws {
    let thread = ConversationThread(id: "thread", connectionId: "connection", nativeThreadId: "private")
    try await respond(
      transport, index: 0,
      result: EventsSnapshot.Result(
        epoch: "epoch", sequence: 0,
        connections: [Connection(id: "connection", kind: .b4, label: "Demo", target: "private-url")],
        threads: [thread]))
    try await respond(
      transport, index: 1,
      result: ThreadRead.Result(
        thread: thread,
        turns: nonempty ? [Turn(id: "old", threadId: "thread", operationId: "private")] : [], items: [],
        requests: []))
    if !nonempty { try await respond(transport, index: 2, result: EventsReplay.Result(events: replay)) }
  }

  private func respond<R: Encodable>(_ transport: FakeTransport, index: Int, result: R) async throws {
    let sent = await transport.sent(atLeast: index + 1)
    let request = try JSONCoding.decoder.decode(CommandEnvelope.self, from: sent[index])
    try transport.receive(.response(.success(request.requestId, result: try JSONValue(encoding: result))))
  }
}
