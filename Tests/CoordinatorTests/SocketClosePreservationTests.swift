import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import Coordinator

@Suite(.serialized, .timeLimit(.minutes(3))) struct SocketClosePreservationTests {
  @Test(arguments: ["peer-before-ack", "local-before-ack", "peer-after-ack"])
  func acceptedTurnSurvivesViewerDisconnectBeforeAcknowledgement(_ ordering: String) async throws {
    let control = AcknowledgementControl()
    let inspectionObservation: InspectionRequestObservation? =
      ordering == "peer-before-ack"
      ? InspectionRequestObservation(caseID: .historicalSocketPeerBeforeAck) : nil
    let h = try await Harness.start(
      adapterFactory: { connection, environment, version, secrets in
        GatedAcknowledgementAdapter(
          inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
          connectionID: connection.id, control: control)
      }, inspectionObservation: inspectionObservation)
    var server: SocketServer?
    var viewer: WorkspaceClient?
    var request: Task<TurnSend.Result, any Error>?
    do {
      let connection = try await h.addCodex()
      let thread = try await h.newThread(connection)
      let scope = try h.coordinator.accounts.scope()
      let scopeBefore = scope.admittedWorkCount
      let observations = SocketObservations()
      let observed = try await SocketServer.start(
        socketPath: h.coordinator.paths.runtimeDir + "/held", router: h.coordinator.router,
        eventLog: h.coordinator.eventLog, lifecycleObserver: { await observations.record($0) })
      server = observed
      let client = try await UnixSocketTransport.client(path: observed.socketPath)
      viewer = client
      let operationID = "held-viewer-operation"
      let sending = Task {
        try await client.request(
          TurnSend.self, TurnSend.Params(threadId: thread.id, text: "held native acceptance"),
          options: RequestOptions(operationId: operationID, timeout: .seconds(60)))
      }
      request = sending
      await control.accepted.wait()
      let admission = await observations.admission()
      #expect(observed.invocationSnapshot.tokens.contains(admission.token))
      #expect(scope.admittedWorkCount == scopeBefore + 1)
      let prepared = try #require(try h.coordinator.database.turn(operationId: operationID))
      #expect(prepared.status == .submitting)
      #expect(prepared.submission == .prepared)
      #expect(try await h.read(thread).items.filter { $0.role == .user }.count == 1)

      if ordering == "peer-after-ack" {
        control.acknowledge.release()
        _ = try await sending.value
        await observations.finished(token: admission.token)
      }
      if ordering == "local-before-ack" {
        await observed.close()
      } else {
        await client.close()
      }
      await observations.connectionFinished(admission.connectionID)
      #expect(control.counts.cancelled == 0)
      #expect(control.counts.interrupted == 0)
      #expect(control.counts.disposed == 0)
      if ordering != "peer-after-ack" {
        #expect(observed.invocationSnapshot.tokens.contains(admission.token))
        #expect(scope.admittedWorkCount == scopeBefore + 1)
        #expect(await observations.hasFinished(token: admission.token) == false)
        #expect(try h.coordinator.database.turn(id: prepared.id)?.status == .submitting)
        control.acknowledge.release()
        await observations.finished(token: admission.token)
        #expect(await observations.responseDropped(token: admission.token) == true)
      }
      #expect(!observed.invocationSnapshot.tokens.contains(admission.token))
      #expect(scope.admittedWorkCount == scopeBefore)
      // Closing the old socket owner/group must not cancel or join the admitted Router handler.
      await observed.close()
      let read = try await h.read(thread)
      #expect(read.turns.count == 1)
      let running = try #require(read.turns.first)
      #expect(running.id == prepared.id)
      #expect(running.operationId == operationID)
      #expect(running.nativeTurnId == "held-native-turn")
      #expect(running.status == .running)
      #expect(running.submission == .acknowledged)
      #expect(running.outcome == nil)
      let retried = try await h.send(thread, "held native acceptance", operationId: operationID)
      #expect(retried.id == running.id)
      #expect(control.counts.sent == 1)
      #expect(control.operationIDs == [operationID])
      try control.complete()
      _ = try await h.events.waitFor {
        $0.kind == .turnFinished && $0.turnId == running.id
          && $0.payload["outcome"]?.stringValue == "completed"
      }
      #expect(try await h.read(thread).turns.first?.outcome == .completed)
      #expect(control.counts.cancelled == 0)
      #expect(control.counts.interrupted == 0)
      #expect(control.counts.disposed == 0)
    } catch {
      control.acknowledge.release()
      if let viewer { await viewer.close() }
      if let server { await server.close() }
      if let request { _ = await request.result }
      await h.stop()
      throw error
    }
    control.acknowledge.release()
    if let viewer { await viewer.close() }
    if let server { await server.close() }
    if let request { _ = await request.result }
    await h.stop()
  }

  @Test func serverWaitsForItsAcceptOwnerBeforeGroupShutdown() async throws {
    let h = try await Harness.start()
    let observations = SocketObservations()
    let ownerReached = LifecycleGate()
    let allowOwnerReturn = LifecycleGate()
    let server: SocketServer
    do {
      server = try await SocketServer.start(
        socketPath: h.coordinator.paths.runtimeDir + "/ordered", router: h.coordinator.router,
        eventLog: h.coordinator.eventLog,
        lifecycleObserver: { event in
          await observations.record(event)
          if case .acceptFinished = event {
            ownerReached.release()
            await allowOwnerReturn.wait()
          }
        })
    } catch {
      await h.stop()
      throw error
    }
    let closing = Task { await server.close() }
    await ownerReached.wait()
    #expect(await observations.groupShutdownHasStarted == false)
    allowOwnerReturn.release()
    await closing.value
    #expect(await observations.groupShutdownHasStarted)
    await server.close()
    await h.stop()
  }
}

private final class LifecycleGate: Sendable {
  private struct State {
    var released = false
    var continuation: CheckedContinuation<Void, any Error>?
    var cancelled = false
  }
  private let state = Mutex(State())
  func release() {
    let continuation = state.withLock { state in
      state.released = true
      let continuation = state.continuation
      state.continuation = nil
      return continuation
    }
    continuation?.resume()
  }
  func wait() async { try? await waitThrowing() }
  func waitThrowing() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let result: Result<Void, any Error>? = state.withLock { state in
          if state.cancelled || Task.isCancelled { return .failure(CancellationError()) }
          if state.released { return .success(()) }
          precondition(state.continuation == nil)
          state.continuation = continuation
          return nil
        }
        if let result { continuation.resume(with: result) }
      }
    } onCancel: {
      let continuation = self.state.withLock { state in
        state.cancelled = true
        let continuation = state.continuation
        state.continuation = nil
        return continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

private final class AcknowledgementControl: Sendable {
  struct Counts {
    var sent = 0
    var cancelled = 0
    var interrupted = 0
    var disposed = 0
  }
  private struct State {
    var counts = Counts()
    var operationIDs: [String] = []
    var connectionID: String?
    var nativeThreadID: String?
  }
  private let state = Mutex(State())
  let accepted = LifecycleGate()
  let acknowledge = LifecycleGate()
  let events: AsyncStream<AdapterEvent>
  private let continuation: AsyncStream<AdapterEvent>.Continuation
  init() {
    let (stream, continuation) = AsyncStream<AdapterEvent>.makeStream()
    events = stream
    self.continuation = continuation
  }
  var counts: Counts { state.withLock { $0.counts } }
  var operationIDs: [String] { state.withLock { $0.operationIDs } }
  func accept(connectionID: String, ref: NativeSessionRef, operationID: String) {
    state.withLock {
      $0.counts.sent += 1
      $0.operationIDs.append(operationID)
      $0.connectionID = connectionID
      $0.nativeThreadID = ref.nativeSessionId
    }
    accepted.release()
  }
  func cancel() { state.withLock { $0.counts.cancelled += 1 } }
  func interrupt() { state.withLock { $0.counts.interrupted += 1 } }
  func dispose() {
    state.withLock { $0.counts.disposed += 1 }
    continuation.finish()
  }
  func complete() throws {
    let ids = state.withLock { ($0.connectionID, $0.nativeThreadID) }
    let connection = try #require(ids.0)
    let thread = try #require(ids.1)
    continuation.yield(
      AdapterEvent(
        kind: .turnFinished, connectionId: connection,
        nativeIds: ["threadId": thread, "turnId": "held-native-turn"], payload: ["outcome": "completed"]))
  }
}

private struct GatedAcknowledgementAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let connectionID: String
  let control: AcknowledgementControl
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    control.accept(connectionID: connectionID, ref: ref, operationID: input.operationId)
    do {
      try await control.acknowledge.waitThrowing()
      return SubmissionReceipt(nativeTurnId: "held-native-turn", acknowledged: true)
    } catch {
      control.cancel()
      throw error
    }
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    control.interrupt()
    return try await inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { control.events }
  func dispose() async {
    control.dispose()
    await inner.dispose()
  }
}

private actor SocketObservations {
  private var events: [SocketLifecycleEvent] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func record(_ event: SocketLifecycleEvent) {
    events.append(event)
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }
  func admission() async -> (token: UUID, connectionID: UUID) {
    while true {
      for case .handlerAdmitted(let token, let connectionID) in events { return (token, connectionID) }
      await withCheckedContinuation { waiters.append($0) }
    }
  }
  func connectionFinished(_ id: UUID) async {
    while !events.contains(where: {
      if case .connectionFinished(id) = $0 { return true }
      return false
    }) {
      await withCheckedContinuation { waiters.append($0) }
    }
  }
  func hasFinished(token: UUID) -> Bool {
    events.contains {
      if case .handlerFinished(token, _) = $0 { return true }
      return false
    }
  }
  func finished(token: UUID) async {
    while !hasFinished(token: token) { await withCheckedContinuation { waiters.append($0) } }
  }
  func responseDropped(token: UUID) -> Bool {
    events.contains {
      if case .handlerFinished(token, true) = $0 { return true }
      return false
    }
  }
  var groupShutdownHasStarted: Bool {
    events.contains {
      if case .groupShutdownStarted = $0 { return true }
      return false
    }
  }
}
