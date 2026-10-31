import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

private func temporaryPaths() throws -> PlatformPaths {
  let base = NSTemporaryDirectory() + "b4c-\(UUID().uuidString.prefix(8))"
  try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
  return PlatformPaths(runtimeDir: base + "/rt", dataDir: base + "/data")
}

/// Isolated environment: no PATH lookups succeed and HOME has no fallback installs, so the
/// provider inspections report "missing" deterministically.
private func isolatedEnvironment(_ paths: PlatformPaths) -> [String: String] {
  ["PATH": "/nonexistent", "HOME": paths.dataDir, "B4APP_NODE_PATH": "/nonexistent/node"]
}

private func startIsolated() async throws -> RunningCoordinator {
  let paths = try temporaryPaths()
  let outcome = try await Coordinator.start(
    options: CoordinatorOptions(
      paths: paths, environment: isolatedEnvironment(paths), secretStore: MemorySecretStore()))
  guard case .running(let coordinator) = outcome else {
    throw WorkspaceError(.internalError, "expected running")
  }
  return coordinator
}

private func connect(_ coordinator: RunningCoordinator) async throws -> WorkspaceClient {
  try await UnixSocketTransport.client(path: coordinator.paths.socketPath)
}

@Suite(.serialized) struct CoordinatorSocketTests {
  @Test func answersPingWithItsEpochAndRejectsUnknownMethods() async throws {
    let coordinator = try await startIsolated()
    defer { Task { await coordinator.close() } }
    let client = try await connect(coordinator)
    let pong = try await client.request(SystemPing.self, EmptyParams())
    #expect(pong.pong)
    #expect(pong.epoch == coordinator.epoch)
    // Hand-crafted unknown method through the raw router.
    let response = await coordinator.router.dispatch(
      line: Data(
        #"{"protocolVersion":1,"kind":"command","requestId":"x","method":"process.kill","params":{}}"#.utf8))
    #expect(response.ok == false)
    #expect(response.error?.code == .methodUnknown)
    await client.close()
    await coordinator.close()
  }

  @Test func reportsDiagnosticsWithMissingProvidersInIsolation() async throws {
    let coordinator = try await startIsolated()
    let client = try await connect(coordinator)
    let report = try await client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    #expect(report.coordinator.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(report.coordinator.socketPath == coordinator.paths.socketPath)
    #expect(report.runtimes.map(\.kind) == [.node, .codex, .claude])
    #expect(report.runtimes[1].status == .error)
    #expect(report.runtimes[2].status == .error)
    await client.close()
    await coordinator.close()
  }

  @Test func persistsDraftMutationAndDeduplicatesByOperationId() async throws {
    let coordinator = try await startIsolated()
    let db = coordinator.database
    _ = try db.insertConnection(
      Connection(id: "c1", kind: .claude, label: "Claude", target: "/usr/local/bin/claude"))
    _ = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "sess_1", nativeScope: "me", title: "First"))
    let client = try await connect(coordinator)
    do {
      _ = try await client.request(DraftSave.self, DraftSave.Params(threadId: "t1", text: "x"))
      Issue.record("mutation without operationId must fail")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    let first = try await client.request(
      DraftSave.self, DraftSave.Params(threadId: "t1", text: "hello"),
      options: RequestOptions(operationId: "op1"))
    _ = try db.saveDraft(threadId: "t1", text: "changed behind the scenes")
    let replay = try await client.request(
      DraftSave.self, DraftSave.Params(threadId: "t1", text: "ignored"),
      options: RequestOptions(operationId: "op1"))
    #expect(replay.draft == first.draft)
    #expect(
      try await client.request(DraftRead.self, DraftRead.Params(threadId: "t1")).draft?.text
        == "changed behind the scenes")
    do {
      _ = try await client.request(
        DraftSave.self, DraftSave.Params(threadId: "missing", text: "x"),
        options: RequestOptions(operationId: "op2"))
      Issue.record("expected not_found")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    #expect(snapshot.threads.map(\.id) == ["t1"])
    #expect(snapshot.connections.map(\.id) == ["c1"])
    await client.close()
    await coordinator.close()
  }

  @Test func streamsEventsInOrderAndReplaysOrDemandsSnapshot() async throws {
    let coordinator = try await startIsolated()
    let client = try await connect(coordinator)
    let events = await client.events()
    let event = AdapterEvent.connectionChanged(
      connectionId: "c1", status: .ready, authStatus: .unknown, transport: .connected)
    for _ in 0..<3 { await coordinator.publish(event) }
    var seen: [Int] = []
    var iterator = events.makeAsyncIterator()
    for _ in 0..<3 {
      if let envelope = await iterator.next() { seen.append(envelope.sequence) }
    }
    #expect(seen == [1, 2, 3])
    let replay = try await client.request(
      EventsReplay.self, EventsReplay.Params(epoch: coordinator.epoch, afterSequence: 1))
    #expect(replay.events.map(\.sequence) == [2, 3])
    do {
      _ = try await client.request(
        EventsReplay.self, EventsReplay.Params(epoch: "old-epoch", afterSequence: 1))
      Issue.record("expected snapshot_required")
    } catch let error as WorkspaceError {
      #expect(error.code == .snapshotRequired)
    }
    await client.close()
    await coordinator.close()
  }

  @Test func refusesSecondCoordinatorWhileLockIsHeld() async throws {
    let coordinator = try await startIsolated()
    let second = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: coordinator.paths, environment: isolatedEnvironment(coordinator.paths),
        secretStore: MemorySecretStore()))
    guard case .alreadyRunning(let record, _) = second else {
      Issue.record("expected alreadyRunning")
      return
    }
    #expect(record?.pid == ProcessInfo.processInfo.processIdentifier)
    #expect(FileManager.default.fileExists(atPath: coordinator.paths.lockPath))
    let client = try await connect(coordinator)
    #expect(try await client.request(SystemPing.self, EmptyParams()).epoch == coordinator.epoch)
    await client.close()
    await coordinator.close()
    #expect(!FileManager.default.fileExists(atPath: coordinator.paths.lockPath))
    #expect(!FileManager.default.fileExists(atPath: coordinator.paths.socketPath))
  }

  @Test func restartsWithANewEpochAfterClose() async throws {
    let coordinator = try await startIsolated()
    let paths = coordinator.paths
    let firstEpoch = coordinator.epoch
    await coordinator.close()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: isolatedEnvironment(paths), secretStore: MemorySecretStore()))
    guard case .running(let restarted) = outcome else {
      Issue.record("expected running")
      return
    }
    #expect(restarted.epoch != firstEpoch)
    await restarted.close()
  }
}

@Suite struct EventLogTests {
  @Test func demandsSnapshotOnceBufferRolledPastRequestedPosition() async {
    let log = EventLog(epoch: "e", bufferSize: 2)
    let event = AdapterEvent(kind: .sessionCreated, connectionId: "c", payload: ["nativeSessionId": "s"])
    for _ in 0..<3 { await log.publish(event) }
    #expect(await log.replay(epoch: "e", afterSequence: 0) == nil)
    #expect(await log.replay(epoch: "e", afterSequence: 1)?.map(\.sequence) == [2, 3])
    #expect(await log.replay(epoch: "e", afterSequence: 3) == [])
    #expect(await log.replay(epoch: "e", afterSequence: 9) == nil)
    #expect(await log.replay(epoch: "other", afterSequence: 2) == nil)
  }
}
