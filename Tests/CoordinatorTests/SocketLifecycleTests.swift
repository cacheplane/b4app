import Darwin
import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator
@testable import NIOTransport

@Suite struct SocketLifecycleTests {
  @Test func repeatedUnixTransportCloseCompletesWithoutLateScheduling() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var peer = try RawLifecyclePeer(path: directory + "/s")
    defer { peer.finish() }
    let transport = try await UnixSocketTransport.connect(path: peer.path)
    do {
      try peer.acceptOnce()
    } catch {
      peer.finish()
      await transport.close()
      throw error
    }

    await transport.close()
    peer.finish()
    try lifecycleMarker("repeatedUnixTransportCloseCompletesWithoutLateScheduling:first-close-returned")
    await transport.close()
    var incoming = transport.incoming.makeAsyncIterator()
    let finalLine = await incoming.next()
    #expect(finalLine == nil)
    try lifecycleMarker("repeatedUnixTransportCloseCompletesWithoutLateScheduling:second-close-returned")
  }

  @Test func aCompletedTransportCloseRefusesLaterSends() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var peer = try RawLifecyclePeer(path: directory + "/s")
    defer { peer.finish() }
    let transport = try await UnixSocketTransport.connect(path: peer.path)
    do {
      try peer.acceptOnce()
    } catch {
      peer.finish()
      await transport.close()
      throw error
    }
    await transport.close()
    peer.finish()
    do {
      try await transport.send(Data("{}".utf8))
      Issue.record("A closed transport must refuse a send without visiting the stopped event loop.")
    } catch {
      #expect((error as? WorkspaceError)?.code == .endpointUnavailable)
    }
    await transport.close()
  }

  @Test func repeatedSocketServerCloseCompletesWithoutLateScheduling() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var paths = PlatformPaths(runtimeDir: directory, dataDir: directory)
    // This normal fixture registers and acknowledges one private PostgreSQL instance.
    paths.postgres = try AgentProtocolResourceFixture.endpoint()
    let binDir = try #require(paths.postgres.binDir)
    let registry = try AccountRegistry(
      endpoint: paths.postgres, binDir: binDir,
      databaseName: AccountManager.registryDatabaseName(for: paths.postgres))
    let events = EventLog()
    let secrets = MemorySecretStore()
    let startedAt = "lifecycle-test"
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: paths, startedAt: startedAt, environment: [:], secretStore: secrets, eventLog: events))
    let accounts = AccountManager(
      context: .init(
        cluster: StoreCluster(endpoint: paths.postgres, binDir: binDir), registry: registry,
        scope: .init(
          paths: paths, environment: [:], secretStore: secrets, eventLog: events,
          diagnostics: diagnostics)))
    let router = Router(
      context: .init(
        eventLog: events, diagnostics: diagnostics, accounts: accounts, startedAt: startedAt, paths: paths))
    do {
      let server = try await SocketServer.start(
        socketPath: paths.socketPath, router: router, eventLog: events)
      await server.close()
      try lifecycleMarker("repeatedSocketServerCloseCompletesWithoutLateScheduling:first-close-returned")
      await server.close()
      #expect(!FileManager.default.fileExists(atPath: paths.socketPath))
      try lifecycleMarker("repeatedSocketServerCloseCompletesWithoutLateScheduling:second-close-returned")
    } catch {
      await accounts.shutdown()
      await events.finish()
      throw error
    }
    await accounts.shutdown()
    await events.finish()
  }
}

private func lifecycleDirectory() throws -> String {
  let directory = AgentProtocolResourceFixture.temporaryDirectory + "sl-\(UUID().uuidString.prefix(8))"
  try PrivateFiles.ensurePrivateDirectory(directory)
  return directory
}

/// A local stdio handle makes the flush explicit without accessing shared Swift stdio globals.
private func lifecycleMarker(_ marker: String) throws {
  let descriptor = Darwin.dup(STDERR_FILENO)
  guard descriptor >= 0 else { throw lifecyclePOSIXError() }
  guard let output = Darwin.fdopen(descriptor, "w") else {
    let error = lifecyclePOSIXError()
    Darwin.close(descriptor)
    throw error
  }
  defer { Darwin.fclose(output) }
  guard Darwin.fputs(marker + "\n", output) >= 0, Darwin.fflush(output) == 0 else {
    throw lifecyclePOSIXError()
  }
}

private func lifecyclePOSIXError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// Synchronous descriptor ownership: no detached accept/reader task needs cancellation or joining.
private struct RawLifecyclePeer {
  let path: String
  private var listener: Int32
  private var accepted: Int32 = -1

  init(path: String) throws {
    self.path = path
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw lifecyclePOSIXError() }
    do {
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let bytes = Array(path.utf8) + [UInt8(0)]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
      }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw lifecyclePOSIXError() }
      let flags = Darwin.fcntl(listener, F_GETFL)
      guard flags >= 0, Darwin.fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw lifecyclePOSIXError()
      }
    } catch {
      finish()
      throw error
    }
  }

  mutating func acceptOnce() throws {
    // A successful transport connect has queued this connection. Nonblocking accept makes a
    // violated fixture assumption fail immediately rather than park a cooperative executor.
    accepted = Darwin.accept(listener, nil, nil)
    guard accepted >= 0 else { throw lifecyclePOSIXError() }
    Darwin.close(listener)
    listener = -1
    guard Darwin.unlink(path) == 0 else { throw lifecyclePOSIXError() }
  }

  mutating func finish() {
    if listener >= 0 {
      Darwin.close(listener)
      listener = -1
    }
    if accepted >= 0 {
      Darwin.close(accepted)
      accepted = -1
    }
    Darwin.unlink(path)
  }
}

@Suite(.serialized, .timeLimit(.minutes(3))) struct UnixOwnedCloseConcurrencyTests {
  @Test func concurrentTransportClosersJoinTheReaderDespiteCallerCancellation() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var peer = try RawLifecyclePeer(path: directory + "/s")
    defer { peer.finish() }
    let log = CloseProbe<String>()
    let readerHeld = CloseGate()
    let readerRelease = CloseGate()
    let transport = try await UnixSocketTransport.connect(
      path: peer.path, timeout: .seconds(3),
      lifecycleObserver: { event in
        log.record(transportEventName(event))
        if event == .cleanupFinished, Task.isCancelled { log.record("cleanupCancelled") }
        if event == .readerFinished {
          readerHeld.release()
          await readerRelease.wait()
        }
      }, sendSettlementObserver: { log.record(transportEventName($0)) })
    do { try peer.acceptOnce() } catch {
      readerRelease.release(); peer.finish(); await transport.close(); throw error
    }
    let first = Task {
      await transport.close()
      log.record("returned:first")
    }
    await readerHeld.wait()
    let second = Task {
      await transport.close()
      log.record("returned:second")
    }
    _ = await log.wait { $0 == "existingCompletion" }
    first.cancel()
    #expect(!log.events.contains("groupShutdownStarted"))
    readerRelease.release()
    await first.value
    await second.value
    await transport.close()
    log.record("returned:third")
    expectSharedCleanup(log.events)
  }

  @Test func closeInterruptsIOBeforeDrainingAnAdmittedSend() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var peer = try RawLifecyclePeer(path: directory + "/s")
    defer { peer.finish() }
    let log = CloseProbe<String>()
    let sendRelease = CloseGate()
    let transport = try await UnixSocketTransport.connect(
      path: peer.path, timeout: .seconds(3),
      lifecycleObserver: { event in
        log.record(transportEventName(event))
        if case .sendAdmitted = event { await sendRelease.wait() }
      }, sendSettlementObserver: { log.record(transportEventName($0)) })
    do { try peer.acceptOnce() } catch {
      sendRelease.release(); peer.finish(); await transport.close(); throw error
    }
    let sending = Task { try await transport.send(Data("{}".utf8)) }
    _ = await log.wait { $0 == "sendAdmitted:1" }
    let closing = Task { await transport.close() }
    _ = await log.wait { $0 == "ioInterrupted" }
    #expect(!log.events.contains("groupShutdownStarted"))
    #expect(!log.events.contains("writeStarted"))
    do {
      try await transport.send(Data("{\"late\":true}".utf8))
      Issue.record("Close must reject new send admission.")
    } catch { #expect((error as? WorkspaceError)?.code == .endpointUnavailable) }
    #expect(log.events.filter { $0 == "sendRejected" }.count == 1)
    #expect(!log.events.contains("writeStarted"))
    sendRelease.release()
    _ = await sending.result
    await closing.value
    let events = log.events
    if let settled = events.firstIndex(of: "sendSettled:0"),
      let reader = events.firstIndex(of: "readerFinished"),
      let shutdown = events.firstIndex(of: "groupShutdownStarted"),
      let finished = events.firstIndex(of: "cleanupFinished")
    {
      #expect(settled < shutdown && reader < shutdown && shutdown < finished)
    } else {
      Issue.record("Actual sends and reader must settle before group shutdown and close return.")
    }
    #expect(events.filter { $0 == "writeStarted" }.count == 1)
    await transport.close()
  }

  @Test func peerEOFStillRequiresOneLocalResourceClose() async throws {
    let directory = try lifecycleDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var peer = try RawLifecyclePeer(path: directory + "/s")
    defer { peer.finish() }
    let log = CloseProbe<String>()
    let transport = try await UnixSocketTransport.connect(
      path: peer.path, timeout: .seconds(3),
      lifecycleObserver: { log.record(transportEventName($0)) },
      sendSettlementObserver: { log.record(transportEventName($0)) })
    do { try peer.acceptOnce() } catch { peer.finish(); await transport.close(); throw error }
    peer.finish()
    var incoming = transport.incoming.makeAsyncIterator()
    #expect(await incoming.next() == nil)
    _ = await log.wait { $0 == "readerFinished" }
    #expect(!log.events.contains("cleanupStarted"))
    await transport.close()
    await transport.close()
    #expect(log.events.filter { $0 == "cleanupStarted" }.count == 1)
    #expect(log.events.filter { $0 == "groupShutdownStarted" }.count == 1)
    #expect(log.events.filter { $0 == "cleanupFinished" }.count == 1)
  }
}

private func transportEventName(_ event: TransportLifecycleEvent) -> String {
  switch event {
  case .sendAdmitted(let count): return "sendAdmitted:\(count)"
  case .sendSettled(let count): return "sendSettled:\(count)"
  case .sendRejected: return "sendRejected"
  case .writeStarted: return "writeStarted"
  case .ioInterrupted: return "ioInterrupted"
  case .readerFinished: return "readerFinished"
  case .groupShutdownStarted: return "groupShutdownStarted"
  case .existingCompletion: return "existingCompletion"
  case .cleanupStarted: return "cleanupStarted"
  case .cleanupFinished: return "cleanupFinished"
  }
}
