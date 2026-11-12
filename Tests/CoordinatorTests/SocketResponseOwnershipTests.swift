import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

@Suite(.serialized, .timeLimit(.minutes(3))) struct SocketResponseOwnershipTests {
  @Test func cancellationBeforeWaiterRegistrationDropsTheResponseOnce() async {
    let reached = CloseGate()
    let release = CloseGate()
    let log = CloseProbe<SocketResponseEvent>()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: {
          reached.release(); await release.wait()
        }, transition: { log.record($0) }))
    let waiter = Task { try await response.wait() }
    await reached.wait()
    waiter.cancel()
    _ = await log.wait { $0 == .abandoned(hadWaiter: false) }
    #expect(response.resolve(plainResponse()) == false)
    release.release()
    expectCancelled(await waiter.result)
    #expect(log.events.filter { $0 == .abandoned(hadWaiter: false) }.count == 1)
    #expect(!log.events.contains(.registered))
    #expect(log.events.filter { $0 == .resolved(.dropped) }.count == 1)
  }

  @Test func cancellationOfARegisteredWaiterDropsALateResponseOnce() async {
    let log = CloseProbe<SocketResponseEvent>()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: nil, transition: { log.record($0) }))
    let waiter = Task { try await response.wait() }
    _ = await log.wait { $0 == .registered }
    waiter.cancel()
    _ = await log.wait { $0 == .abandoned(hadWaiter: true) }
    #expect(response.resolve(plainResponse()) == false)
    expectCancelled(await waiter.result)
    #expect(log.events.filter { $0 == .registered }.count == 1)
    #expect(log.events.filter { $0 == .abandoned(hadWaiter: true) }.count == 1)
    #expect(log.events.filter { $0 == .resolved(.dropped) }.count == 1)
  }

  @Test func aBufferedResponseIsConsumedBeforeLaterCallerCancellation() async {
    let log = CloseProbe<SocketResponseEvent>()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: nil, transition: { log.record($0) }))
    #expect(response.resolve(plainResponse()))
    let waiter = Task { try await response.wait() }
    expectResponse(await waiter.result)
    waiter.cancel()
    #expect(log.events.filter { $0 == .resolved(.buffered) }.count == 1)
    #expect(!log.events.contains(.registered))
    #expect(
      !log.events.contains {
        if case .abandoned = $0 { return true }; return false
      })
  }

  @Test func cancellationBeforeRegistrationCanDiscardAnAlreadyBufferedResponse() async {
    let reached = CloseGate()
    let release = CloseGate()
    let log = CloseProbe<SocketResponseEvent>()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: {
          reached.release(); await release.wait()
        }, transition: { log.record($0) }))
    #expect(response.resolve(plainResponse()))
    let waiter = Task { try await response.wait() }
    await reached.wait()
    waiter.cancel()
    _ = await log.wait { $0 == .abandoned(hadWaiter: false) }
    release.release()
    expectCancelled(await waiter.result)
    #expect(log.events.filter { $0 == .resolved(.buffered) }.count == 1)
    #expect(log.events.filter { $0 == .abandoned(hadWaiter: false) }.count == 1)
    #expect(!log.events.contains(.registered))
  }

  @Test func aRegisteredResponseCompletesOnceBeforeCallerCancellation() async {
    let log = CloseProbe<SocketResponseEvent>()
    let delivered = CloseGate()
    let release = CloseGate()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: nil, transition: { log.record($0) }))
    let waiter = Task {
      let value = try await response.wait()
      delivered.release()
      await release.wait()
      return value
    }
    _ = await log.wait { $0 == .registered }
    #expect(response.resolve(plainResponse()))
    await delivered.wait()
    waiter.cancel()
    release.release()
    expectResponse(await waiter.result)
    #expect(log.events.filter { $0 == .resolved(.delivered) }.count == 1)
    #expect(
      !log.events.contains {
        if case .abandoned = $0 { return true }; return false
      })
  }

  @Test func responseFirstCancellationRunsBeforeTheRegisteredContinuationResumes() async {
    let registrationHeld = CloseGate()
    let registrationRelease = CloseGate()
    let transitions = CloseProbe<SocketResponseEvent>()
    let ordering = CloseProbe<String>()
    let handle = ResponseWaiterHandle()
    let response = SocketResponse(
      witness: SocketResponseWitness(
        beforeRegistration: {
          registrationHeld.release()
          await registrationRelease.wait()
        },
        transition: { event in
          transitions.record(event)
          if event == .resolved(.delivered) {
            ordering.record("delivered")
            // The production latch has already published consumed, and has not resumed its waiter.
            // Cancellation is synchronous here, outside its Mutex, while response.wait is in flight.
            let didCancel = handle.cancel()
            #expect(didCancel)
            #expect(ordering.events.contains("onCancel"))
            ordering.record("cancelReturnedBeforeResume")
          }
        }))
    let waiter = Task {
      try await withTaskCancellationHandler {
        let value = try await response.wait()
        ordering.record("successfulResult")
        return value
      } onCancel: {
        ordering.record("onCancel")
      }
    }
    handle.install(waiter)
    await registrationHeld.wait()
    registrationRelease.release()
    _ = await transitions.wait { $0 == .registered }
    #expect(response.resolve(plainResponse()))
    expectResponse(await waiter.result)
    handle.clear()
    #expect(transitions.events.filter { $0 == .registered }.count == 1)
    #expect(transitions.events.filter { $0 == .resolved(.delivered) }.count == 1)
    #expect(
      !transitions.events.contains {
        if case .abandoned = $0 { return true }
        return false
      })
    #expect(ordering.events.filter { $0 == "onCancel" }.count == 1)
    #expect(ordering.events.filter { $0 == "successfulResult" }.count == 1)
    if let delivery = ordering.events.firstIndex(of: "delivered"),
      let cancelled = ordering.events.firstIndex(of: "onCancel"),
      let beforeResume = ordering.events.firstIndex(of: "cancelReturnedBeforeResume"),
      let result = ordering.events.firstIndex(of: "successfulResult")
    {
      #expect(delivery < cancelled && cancelled < beforeResume && beforeResume < result)
    } else {
      Issue.record("Actual cancellation must run after consumption and before the one result.")
    }
  }

  @Test func publishedHandlerRemainsTrackedUntilDispatchActuallyReturns() async {
    let started = CloseGate()
    let release = CloseGate()
    let log = CloseProbe<SocketInvocationEvent>()
    let lifecycle = CloseProbe<SocketLifecycleEvent>()
    let registry = SocketInvocations(
      observer: { lifecycle.record($0) }, transition: { log.record($0) })
    let response = registry.admit(
      line: Data(), connectionID: UUID(),
      dispatch: { _ in
        started.release()
        await release.wait()
        return plainResponse()
      })
    guard let response else { Issue.record("Open registry must admit a command."); return }
    await started.wait()
    let published = await log.wait {
      if case .published = $0 { return true }; return false
    }
    guard case .published(let token) = published else { release.release(); return }
    let waiter = Task { try await response.wait() }
    registry.stopAdmission()
    registry.stopAdmission()
    expectCancelled(await waiter.result)
    #expect(!registry.snapshot.accepting)
    #expect(registry.snapshot.tokens == [token])
    #expect(!log.events.contains(.removed(token)))
    let refused = registry.admit(
      line: Data(), connectionID: UUID(),
      dispatch: { _ in
        Issue.record("A closed registry must not invoke a later handler.")
        return plainResponse()
      })
    #expect(refused == nil)
    release.release()
    _ = await log.wait { $0 == .removed(token) }
    _ = await lifecycle.wait { $0 == .handlerFinished(token: token, responseDropped: true) }
    #expect(registry.snapshot.tokens.isEmpty)
    #expect(log.events.filter { $0 == .published(token) }.count == 1)
    #expect(log.events.filter { $0 == .removed(token) }.count == 1)
  }

  @Test func admissionAfterCloseNeverPublishesAHandler() {
    let log = CloseProbe<SocketInvocationEvent>()
    let registry = SocketInvocations(observer: nil, transition: { log.record($0) })
    registry.stopAdmission()
    let refused = registry.admit(
      line: Data(), connectionID: UUID(),
      dispatch: { _ in
        Issue.record("Refused work must not start.")
        return plainResponse()
      })
    #expect(refused == nil)
    #expect(!registry.snapshot.accepting)
    #expect(registry.snapshot.tokens.isEmpty)
    #expect(log.events.isEmpty)
  }

  /// A private dispatch fixture requests close through a plain bridge; no built-in Router route does this.
  @Test func aPlainHandlerCanRequestSocketCloseWithoutJoiningItself() async throws {
    let directory = AgentProtocolResourceFixture.temporaryDirectory + "self-\(UUID().uuidString.prefix(8))"
    try PrivateFiles.ensurePrivateDirectory(directory)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let events = EventLog()
    let bridge = PlainCloseBridge()
    let log = CloseProbe<SocketLifecycleEvent>()
    let server = try await SocketServer.start(
      socketPath: directory + "/s", eventLog: events,
      plainDispatch: { [bridge] line in
        let requestID =
          (try? JSONCoding.decoder.decode(JSONValue.self, from: line))?["requestId"]?.stringValue
          ?? "unknown"
        await bridge.requestClose()
        return ResponseEnvelope.success(requestID, result: .object([:]))
      }, lifecycleObserver: { log.record($0) })
    let client: WorkspaceClient
    do { client = try await UnixSocketTransport.client(path: server.socketPath) } catch {
      await server.close(); await events.finish(); throw error
    }
    // This test-owned closer owns the SocketServer reference; the raw handler owns only the bridge.
    let closer = Task {
      var requests = bridge.requests.makeAsyncIterator()
      if await requests.next() != nil {
        await server.close()
        bridge.closed.release()
      }
    }
    let request = Task { try await client.request(SystemPing.self, EmptyParams()) }
    await closer.value
    switch await request.result {
    case .success: Issue.record("The closed viewer must not receive the late raw handler response.")
    case .failure(let error): #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
    let finished = await log.wait {
      if case .handlerFinished = $0 { return true }; return false
    }
    if case .handlerFinished(_, let dropped) = finished { #expect(dropped) }
    if let cleanup = log.events.firstIndex(of: .cleanupFinished),
      let completion = log.events.firstIndex(where: {
        if case .handlerFinished = $0 { return true }
        return false
      })
    {
      #expect(cleanup < completion)
    } else {
      Issue.record("Raw completion must follow actual socket group cleanup in this control.")
    }
    #expect(server.invocationSnapshot.tokens.isEmpty)
    await client.close()
    await server.close()
    await events.finish()
  }
}

private func plainResponse() -> ResponseEnvelope {
  ResponseEnvelope.success("plain", result: .object([:]))
}
private func expectCancelled(_ result: Result<ResponseEnvelope, any Error>) {
  switch result {
  case .success: Issue.record("An abandoned response must complete with cancellation exactly once.")
  case .failure(let error): #expect(error is CancellationError)
  }
}
private func expectResponse(_ result: Result<ResponseEnvelope, any Error>) {
  switch result {
  case .success(let response): #expect(response.requestId == "plain")
  case .failure(let error): Issue.record("Expected one plain response, got \(error).")
  }
}

private final class PlainCloseBridge: Sendable {
  let requests: AsyncStream<Void>
  let closed = CloseGate()
  private let continuation: AsyncStream<Void>.Continuation
  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    requests = stream
    self.continuation = continuation
  }
  func requestClose() async {
    continuation.yield(())
    continuation.finish()
    await closed.wait()
  }
}

/// Plain test-owned handle publication; cancellation occurs after releasing this Mutex.
private final class ResponseWaiterHandle: Sendable {
  private let task = Mutex<Task<ResponseEnvelope, any Error>?>(nil)
  func install(_ waiter: Task<ResponseEnvelope, any Error>) {
    task.withLock {
      precondition($0 == nil)
      $0 = waiter
    }
  }
  func cancel() -> Bool {
    guard let waiter = task.withLock({ $0 }) else { return false }
    waiter.cancel()
    return waiter.isCancelled
  }
  func clear() { task.withLock { $0 = nil } }
}
