import Darwin
import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator
@testable import WorkspacePlatform

/// Closed case labels; neither the collector nor formatter accepts request or executable text.
enum ServerNodeProbeLabel: String, Sendable {
  case addsAProjectAndInspectsItsRoutes
  case startsToReadyInSourceModeAndIsIdempotent
  case logsAreTailedRedactedAndFollowable
  case managedConnectionRefusesWhileStopped
  case removingRefusesWhileATurnIsRunningUnlessForced
  case localB4ThreadsUseTheServerEnvironmentAndRemoteHaveNone
}

private func nodeProbeLine(
  label: ServerNodeProbeLabel, observation: NodeVersionProbeObservation
) -> String {
  func flag(_ value: Bool?) -> String {
    guard let value else { return "unavailable" }
    return value ? "true" : "false"
  }
  func number(_ value: Int32?) -> String {
    guard let value else { return "unavailable" }
    return String(value)
  }
  return "node-explicit-probe case=\(label.rawValue)"
    + " commandThrew=\(flag(observation.commandThrew))"
    + " returnedTimedOut=\(flag(observation.returnedTimedOut))"
    + " returnedExitCode=\(number(observation.returnedExitCode))"
    + " returnedSignal=\(number(observation.returnedSignal))"
    + " returnedSucceeded=\(flag(observation.returnedSucceeded))"
    + " stdoutShape=\(observation.stdoutShape.rawValue)"
    + " versionPrefixAccepted=\(flag(observation.versionPrefixAccepted))"
    + " minimumAccepted=\(flag(observation.minimumAccepted))"
    + " resolveAccepted=\(flag(observation.resolveAccepted))"
    + " callerCancelledAtReturn=\(flag(observation.callerCancelledAtReturn))"
    + " probeParentElapsedMilliseconds=\(observation.probeParentElapsedMilliseconds)"
}

private final class ServerNodeProbeCollector: Sendable {
  private let records = Mutex<[NodeVersionProbeObservation]>([])
  private let label: ServerNodeProbeLabel

  init(label: ServerNodeProbeLabel) { self.label = label }

  func append(_ observation: NodeVersionProbeObservation) {
    records.withLock { $0.append(observation) }
  }

  func emitSnapshot() {
    let snapshot = records.withLock { $0 }
    for observation in snapshot { print(nodeProbeLine(label: label, observation: observation)) }
  }
}

struct NodeProbeDiagnosticFormattingTests {
  @Test func rawPrivateTextIsDroppedByTheSameProjectionBeforeFixedFormatting() {
    let rawError = "error: TOKEN=private-example /private/example/stderr"
    let samples: [(String, NodeVersionProbeObservation.StdoutShape)] = [
      ("/private/example/node TOKEN=private-example", .other),
      ("error: private-example --private-argument", .other),
      ("v/private/example/version", .vPrefixOther),
      ("v24.0.0\n", .exactFake24),
    ]
    for (rawStdout, expectedShape) in samples {
      let result = CommandResult(stdout: rawStdout, stderr: rawError, exitCode: 0)
      let shape = NodeVersionProbeObservation.classifyStdout(of: result)
      #expect(shape == expectedShape)
      let observation = NodeVersionProbeObservation(
        commandThrew: false, returnedTimedOut: result.timedOut, returnedExitCode: result.exitCode,
        returnedSignal: result.signal, returnedSucceeded: result.succeeded, stdoutShape: shape,
        versionPrefixAccepted: nil, minimumAccepted: nil, resolveAccepted: false,
        callerCancelledAtReturn: false, probeParentElapsedMilliseconds: 123)
      let line = nodeProbeLine(label: .addsAProjectAndInspectsItsRoutes, observation: observation)
      let leakedRawText = line.contains(rawStdout) || line.contains(rawError)
      #expect(!leakedRawText)
    }
  }

  @Test func formatterUsesOnlyClosedLabelsShapesAndPrimitiveFacts() {
    let shapes: [NodeVersionProbeObservation.StdoutShape] = [
      .unavailable, .empty, .exactFake24, .vPrefixOther, .other,
    ]
    for shape in shapes {
      let observation = NodeVersionProbeObservation(
        commandThrew: false, returnedTimedOut: false, returnedExitCode: 0, returnedSignal: nil,
        returnedSucceeded: true, stdoutShape: shape, versionPrefixAccepted: true,
        minimumAccepted: true, resolveAccepted: true, callerCancelledAtReturn: false,
        probeParentElapsedMilliseconds: 123)
      let line = nodeProbeLine(label: .addsAProjectAndInspectsItsRoutes, observation: observation)
      #expect(
        line == "node-explicit-probe case=addsAProjectAndInspectsItsRoutes"
          + " commandThrew=false returnedTimedOut=false returnedExitCode=0 returnedSignal=unavailable"
          + " returnedSucceeded=true stdoutShape=\(shape.rawValue) versionPrefixAccepted=true"
          + " minimumAccepted=true resolveAccepted=true callerCancelledAtReturn=false"
          + " probeParentElapsedMilliseconds=123")
    }
  }
}

/// A coordinator on scratch directories whose Node is the fake shim, plus a scratch B4 project.
struct ServerHarness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let paths: PlatformPaths
  let base: String
  let events: EventCollector
  private let nodeProbeCollector: ServerNodeProbeCollector?

  static func start(
    paths existing: PlatformPaths? = nil, nodeProbeLabel: ServerNodeProbeLabel? = nil,
    adapterFactory: SessionService.AdapterFactory? = nil
  ) async throws -> ServerHarness {
    let base: String
    let paths: PlatformPaths
    if let existing {
      paths = existing
      base = (existing.runtimeDir as NSString).deletingLastPathComponent
    } else {
      base = NSTemporaryDirectory() + "b4srv-\(UUID().uuidString.prefix(8))"
      paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    }
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = fakeNodePath()
    let collector = nodeProbeLabel.map { ServerNodeProbeCollector(label: $0) }
    var options = CoordinatorOptions(
      paths: paths, environment: env, secretStore: MemorySecretStore(), adapterFactory: adapterFactory)
    if let collector { options.nodeVersionProbeObservation = { collector.append($0) } }
    let outcome = try await Coordinator.startSignedIn(options: options)
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let events = EventCollector(await client.events())
    return ServerHarness(
      coordinator: coordinator, client: client, paths: paths, base: base, events: events,
      nodeProbeCollector: collector)
  }

  /// Snapshot only; the existing deferred Task cleanup is not joined by this method.
  func emitNodeProbeObservations() { nodeProbeCollector?.emitSnapshot() }

  func project(
    _ name: String = "proj", cliVersion: String? = "0.15.8", withConfig: Bool = true
  ) throws
    -> String
  {
    try FakeB4Project.make(root: base + "/" + name, cliVersion: cliVersion, withConfig: withConfig)
  }

  func mutation(_ timeout: Duration = .seconds(60)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString, timeout: timeout)
  }

  func add(
    _ path: String, name: String? = nil, mode: LocalServerLaunchMode? = nil, envFile: String? = nil,
    port: Int? = nil
  ) async throws -> LocalServer {
    try await client.request(
      ServerAdd.self,
      ServerAdd.Params(projectPath: path, name: name, launchMode: mode, envFilePath: envFile, port: port),
      options: mutation()
    ).server
  }

  func start(_ server: LocalServer) async throws -> LocalServer {
    try await client.request(
      ServerStart.self, ServerRef(serverId: server.id), options: mutation(.seconds(150))
    )
    .server
  }

  func stop(_ server: LocalServer, force: Bool? = nil) async throws -> LocalServer {
    try await client.request(
      ServerStop.self, ServerLifecycleParams(serverId: server.id, force: force), options: mutation()
    ).server
  }

  func status(_ server: LocalServer) async throws -> LocalServer {
    try await client.request(ServerStatus.self, ServerRef(serverId: server.id)).server
  }

  func logs(
    _ server: LocalServer, lines: Int? = nil, afterOffset: Int? = nil
  ) async throws -> ServerLogs.Result {
    try await client.request(
      ServerLogs.self, ServerLogs.Params(serverId: server.id, lines: lines, afterOffset: afterOffset))
  }

  func failure(_ body: () async throws -> some Sendable) async -> WorkspaceError? {
    do {
      _ = try await body()
      return nil
    } catch {
      return WorkspaceError.from(error)
    }
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }
}

@Suite(.serialized) struct LocalServerRegistryTests {
  @Test func addsAProjectAndInspectsItsRoutes() async throws {
    let h = try await ServerHarness.start(nodeProbeLabel: .addsAProjectAndInspectsItsRoutes)
    defer { h.emitNodeProbeObservations() }
    defer { Task { await h.close() } }
    let path = try h.project("research-agent")
    let server = try await h.add(path)
    #expect(server.name == "research-agent")
    #expect(server.projectPath == path)
    #expect(server.cliVersion == "0.15.8")
    #expect(server.cliPath == path + "/node_modules/@b4run/cli/dist/index.js")
    #expect(server.nodePath == fakeNodePath())
    #expect(server.launchMode == .source)
    #expect((server.requestedPort ?? 0) > 1024)
    #expect(server.health == .stopped)
    #expect(server.pid == nil)
    #expect(server.routes.map(\.key) == ["/chat#agent", "/dispatch#workflow"])
    #expect(server.logPath == h.paths.logDir + "/servers/research-agent.log")
    let listed = try await h.client.request(ServerList.self, EmptyParams()).servers
    #expect(listed == [server])
    try await h.events.waitFor {
      $0.kind == .serverChanged && $0.payload["server"]?["id"]?.stringValue == server.id
    }
    let inspected = try await h.client.request(
      ServerInspect.self, ServerRef(serverId: server.id), options: h.mutation()
    ).server
    #expect(inspected.routes == server.routes)
  }

  @Test func refusesProjectsWithoutTheCliOrWithAnOldOne() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let noCli = try h.project("no-cli", cliVersion: nil)
    #expect(await h.failure { try await h.add(noCli) }?.code == .missingExecutable)
    let old = try h.project("old", cliVersion: "0.15.6")
    #expect(await h.failure { try await h.add(old) }?.code == .incompatibleVersion)
    let noConfig = try h.project("no-config", withConfig: false)
    #expect(await h.failure { try await h.add(noConfig) }?.code == .protocolInvalid)
    #expect(await h.failure { try await h.add(h.base + "/missing") }?.code == .protocolInvalid)
    #expect(try await h.client.request(ServerList.self, EmptyParams()).servers.isEmpty)
  }

  @Test func inspectionFailureOutputIsRedacted() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    try "OPENAI_API_KEY=sk-proj-abcdefghijklmnop\nFAKE_B4_ROUTES_FAIL=1\n".write(
      toFile: path + "/.env", atomically: true, encoding: .utf8)
    let failure = await h.failure { try await h.add(path) }
    #expect(failure?.code == .incompatibleVersion)
    #expect(failure?.message.contains("OPENAI_API_KEY=[redacted]") == true)
    #expect(failure?.message.contains("sk-proj-") == false)
  }

  @Test func reAddingTheSameProjectReturnsTheSameRowOrUpdatesTheProfile() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    let first = try await h.add(path, port: 3321)
    let again = try await h.add(path, port: 3321)
    #expect(again.id == first.id)
    #expect(again.generation == first.generation)
    let moved = try await h.add(path, mode: .development, port: 3322)
    #expect(moved.id == first.id)
    #expect(moved.launchMode == .development)
    #expect(moved.requestedPort == 3322)
    let clash = try h.project("other")
    #expect(await h.failure { try await h.add(clash, name: "proj") }?.code == .protocolInvalid)
  }

  @Test func envFileIsRequiredToExistAndIsNeverEchoed() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    #expect(await h.failure { try await h.add(path, envFile: path + "/nope.env") }?.code == .protocolInvalid)
    try "FAKE_B4_MARK=secret-mark\n".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
    let server = try await h.add(path)
    #expect(server.envFilePath == path + "/.env")
    let encoded = String(decoding: try JSONCoding.encoder.encode(server), as: UTF8.self)
    #expect(!encoded.contains("secret-mark"))
  }
}

/// Owned-server lifecycle against the fake project CLI.
@Suite(.serialized) struct LocalServerLifecycleTests {
  /// The server's row once a `server.changed` event has moved it from the health it had in `server` to
  /// `health` (every change to a managed server is published). Events are ordered, so a match after
  /// the one that reported `server.health` is the change the caller waits for, not an older one.
  private func waitForHealth(
    _ h: ServerHarness, _ server: LocalServer, _ health: LocalServerHealth
  ) async throws -> LocalServer {
    let id = server.id
    let from = server.health.rawValue
    let to = health.rawValue
    _ = await h.events.until { events in
      let healths = events.compactMap { event -> String? in
        guard event.kind == .serverChanged, event.payload["server"]?["id"]?.stringValue == id else {
          return nil
        }
        return event.payload["server"]?["health"]?.stringValue
      }
      guard let left = healths.firstIndex(of: from) else { return false }
      return healths[(left + 1)...].contains(to)
    }
    return try await h.status(server)
  }

  @Test func startsToReadyInSourceModeAndIsIdempotent() async throws {
    let h = try await ServerHarness.start(nodeProbeLabel: .startsToReadyInSourceModeAndIsIdempotent)
    defer { h.emitNodeProbeObservations() }
    defer { Task { await h.close() } }
    let added = try await h.add(try h.project())
    let started = try await h.start(added)
    #expect(started.health == .ready)
    #expect(started.actualPort == added.requestedPort)
    #expect((started.pid ?? 0) > 0)
    #expect(started.ownershipVerified)
    #expect(started.generation == 1)
    #expect(started.statusMessage?.contains("ready on http://127.0.0.1:\(added.requestedPort ?? 0)") == true)
    let log = try String(contentsOfFile: started.logPath!, encoding: .utf8)
    #expect(log.contains("b4 start listening on http://127.0.0.1:\(added.requestedPort ?? 0)"))
    let again = try await h.start(started)
    #expect(again.generation == 1 && again.pid == started.pid)
    let stopped = try await h.stop(started)
    #expect(stopped.health == .stopped && stopped.pid == nil)
    #expect(Ports.isFree(added.requestedPort!))
    #expect(!ProcessInspector.isAlive(pid: started.pid!))
    try await h.events.waitFor {
      $0.kind == .serverChanged && $0.payload["server"]?["health"]?.stringValue == "stopped"
    }
  }

  @Test func startsInDevelopmentModeWithTheEnvFile() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    try "FAKE_B4_MARK=mark-1\n".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
    let added = try await h.add(path, mode: .development)
    let started = try await h.start(added)
    #expect(started.health == .ready)
    let log = try String(contentsOfFile: started.logPath!, encoding: .utf8)
    #expect(log.contains("Loaded 1 variable(s)"))
    #expect(log.contains("FAKE_B4_MARK=mark-1"))
    #expect(log.contains("B4.run dev ready at http://127.0.0.1:\(added.requestedPort ?? 0)"))
    for row in [added, started, try await h.status(started)] {
      let encoded = String(decoding: try JSONCoding.encoder.encode(row), as: UTF8.self)
      #expect(!encoded.contains("mark-1"))
    }
    _ = try await h.stop(started)
  }

  @Test func portConflictIsReportedAndNothingIsKilled() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    // Bind port 0 and read back the port the system chose. Allocating a port first and binding it
    // after raced parallel tests, whose connections can take a just-released port (CI run 42074403076).
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    try #require(bound == 0 && listen(fd, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    try #require(named == 0)
    let port = Int(in_port_t(bigEndian: address.sin_port))
    let added = try await h.add(try h.project(), port: port)
    let failure = await h.failure { try await h.start(added) }
    #expect(failure?.code == .ownedProcessConflict)
    #expect(failure?.message.contains("nothing was stopped") == true)
    #expect(try await h.status(added).health == .stopped)
    #expect(!Ports.isFree(port))
  }

  @Test func restartKeepsTheGenerationSequence() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let started = try await h.start(try await h.add(try h.project()))
    let restarted = try await h.client.request(
      ServerRestart.self, ServerLifecycleParams(serverId: started.id), options: h.mutation(.seconds(150))
    ).server
    #expect(restarted.health == .ready)
    #expect(restarted.generation == 2)
    #expect(restarted.pid != started.pid)
    _ = try await h.stop(restarted)
  }

  @Test func concurrentStartsJoinTheSameLaunch() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let added = try await h.add(try h.project())
    async let first = h.start(added)
    async let second = h.start(added)
    let (a, b) = try await (first, second)
    #expect(a.health == .ready && b.health == .ready)
    #expect(a.generation == 1 && b.generation == 1)
    #expect(a.pid == b.pid)
    _ = try await h.stop(a)
  }

  @Test func exitIsDetectedByTheMonitor() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let started = try await h.start(try await h.add(try h.project()))
    kill(started.pid!, SIGKILL)
    let stopped = try await waitForHealth(h, started, .stopped)
    #expect(stopped.health == .stopped)
    #expect(stopped.pid == nil)
    #expect(stopped.statusMessage?.contains("exited") == true)
  }

  @Test func stopReachesARuntimeGrandchild() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    try "FAKE_B4_GRANDCHILD=1\nFAKE_B4_HANG_ON_TERM=30\n".write(
      toFile: path + "/.env", atomically: true, encoding: .utf8)
    let added = try await h.add(path, mode: .development)
    let started = try await h.start(added)
    #expect(started.health == .ready)
    let clock = ContinuousClock()
    let elapsed = try await clock.measure { _ = try await h.stop(started) }
    #expect(elapsed < .seconds(20))
    #expect(Ports.isFree(added.requestedPort!))
    #expect(!ProcessInspector.isAlive(pid: started.pid!))
  }

  /// An account signing out stops its servers side by side, within the budget, even when they ignore
  /// SIGTERM (Task 9's review: one after another, each with its 10 s grace, had no bound).
  @Test func stopAllStopsServersSideBySideWithinItsBudget() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    var started: [LocalServer] = []
    for name in ["one", "two"] {
      let path = try h.project(name)
      try "FAKE_B4_HANG_ON_TERM=30\n".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
      started.append(try await h.start(try await h.add(path, name: name)))
    }
    let clock = ContinuousClock()
    var finished = false
    let elapsed = await clock.measure { finished = await h.coordinator.servers.stopAll(within: .seconds(4)) }
    #expect(finished)
    #expect(elapsed < .seconds(6), "the stops were not bounded: \(elapsed)")
    for server in started {
      #expect(!ProcessInspector.isAlive(pid: server.pid!))
      #expect(try await h.status(server).health == .stopped)
    }
  }

  @Test func liveServerIsReAdoptedAfterACoordinatorRestart() async throws {
    let h = try await ServerHarness.start()
    let started = try await h.start(try await h.add(try h.project()))
    await h.close()
    #expect(ProcessInspector.isAlive(pid: started.pid!))
    let h2 = try await ServerHarness.start(paths: h.paths)
    defer { Task { await h2.close() } }
    let adopted = try await h2.status(started)
    #expect(adopted.health == .ready)
    #expect(adopted.ownershipVerified)
    #expect(adopted.pid == started.pid)
    let stopped = try await h2.stop(adopted)
    #expect(stopped.health == .stopped)
    #expect(!ProcessInspector.isAlive(pid: started.pid!))
  }

  @Test func stalePidIsLeftAloneOnCoordinatorStart() async throws {
    let h = try await ServerHarness.start()
    let added = try await h.add(try h.project())
    let sleeper = try ManagedProcess.spawn(
      executable: "/bin/sleep", arguments: ["60"], environment: ["PATH": "/bin"], workingDirectory: "/",
      outputPath: h.base + "/sleeper.log")
    _ = try h.coordinator.database.updateLocalServer(id: added.id) {
      $0.pid = sleeper.pid
      $0.processStartedAt = sleeper.identity.startedAt - 100
      $0.health = .ready
      $0.ownershipVerified = true
    }
    await h.close()
    let h2 = try await ServerHarness.start(paths: h.paths)
    defer {
      Task {
        await h2.close()
        _ = await ManagedProcess.terminateGroup(pid: sleeper.pid, gracePeriod: .seconds(1))
      }
    }
    let row = try await h2.status(added)
    #expect(row.health == .stopped)
    #expect(row.pid == nil)
    #expect(row.ownershipVerified == false)
    #expect(row.statusMessage?.contains("left untouched") == true)
    #expect(ProcessInspector.isAlive(pid: sleeper.pid))
  }

  @Test func startOnAnUnhealthyOwnedServerRefusesAndKeepsItStoppable() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let started = try await h.start(try await h.add(try h.project()))
    _ = try h.coordinator.database.updateLocalServer(id: started.id) { $0.health = .unhealthy }
    let refused = await h.failure { try await h.start(started) }
    #expect(refused?.code == .ownedProcessConflict)
    #expect(refused?.message.contains("pid \(started.pid!)") == true)
    #expect(refused?.message.contains("restart") == true)
    #expect(ProcessInspector.isAlive(pid: started.pid!))
    let stopped = try await h.stop(started)
    #expect(stopped.health == .stopped)
    #expect(!ProcessInspector.isAlive(pid: started.pid!))
    #expect(stopped.statusMessage == "stopped")
  }

  @Test func stopRacingStartNeverOrphansAnOwnedServer() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    try "FAKE_B4_HANG_ON_TERM=1\n".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
    let started = try await h.start(try await h.add(path))
    async let stopping = h.stop(started)
    // Timed on purpose: lets the stop reach the coordinator first. A stop publishes nothing until it
    // has finished, so there is no "stopping" event to await.
    try await Task.sleep(for: .milliseconds(50))
    async let starting = h.start(started)
    let (afterStop, afterStart) = try await (stopping, starting)
    #expect(afterStop.health == .stopped)
    #expect(afterStart.health == .ready)
    #expect(afterStart.generation == 2)
    let row = try await h.status(started)
    #expect(row.health == .ready && row.pid == afterStart.pid)
    #expect(ProcessInspector.isAlive(pid: row.pid!))
    #expect(!ProcessInspector.isAlive(pid: started.pid!))
    let final = try await h.stop(row)
    #expect(final.health == .stopped)
    #expect(!ProcessInspector.isAlive(pid: row.pid!))
    #expect(Ports.isFree(started.requestedPort!))
  }

  @Test func unreadyServerFailsHonestly() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let path = try h.project()
    try "FAKE_B4_FAIL_START=1\n".write(toFile: path + "/.env", atomically: true, encoding: .utf8)
    let added = try await h.add(path)
    let failure = await h.failure { try await h.start(added) }
    #expect(failure?.code == .endpointUnavailable)
    #expect(failure?.message.contains("exited with status 2") == true)
    #expect(
      failure?.details?["logTail"]?.arrayValue?.contains { $0.stringValue?.contains("boot failed") == true }
        == true)
    #expect(try await h.status(added).health == .stopped)
  }
}

@Suite(.serialized) struct LocalServerLogTests {
  @Test func logsAreTailedRedactedAndFollowable() async throws {
    let h = try await ServerHarness.start(nodeProbeLabel: .logsAreTailedRedactedAndFollowable)
    defer { h.emitNodeProbeObservations() }
    defer { Task { await h.close() } }
    let path = try h.project()
    try "OPENAI_API_KEY=sk-proj-abcdefghijklmnop\nFAKE_B4_ECHO_ENV=1\n".write(
      toFile: path + "/.env", atomically: true, encoding: .utf8)
    let started = try await h.start(try await h.add(path))
    let first = try await h.logs(started)
    #expect(first.logPath == started.logPath)
    #expect(first.lines.contains("OPENAI_API_KEY=[redacted]"))
    #expect(!first.lines.joined(separator: "\n").contains("sk-proj-"))
    #expect(first.lines.contains("b4 start listening on http://127.0.0.1:\(started.actualPort ?? 0)"))
    #expect(first.offset > 0 && !first.truncated)
    let raw = try String(contentsOfFile: started.logPath!, encoding: .utf8)
    #expect(raw.contains("sk-proj-abcdefghijklmnop"))
    // No wait: the server's output goes straight to the log file, and the fixture writes the request
    // line there before it sends the response.
    _ = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(started.actualPort ?? 0)/readyz")!)
    let more = try await h.logs(started, afterOffset: first.offset)
    #expect(more.lines == ["fake-b4: GET /readyz"])
    #expect(more.offset > first.offset)
    let two = try await h.logs(started, lines: 2)
    #expect(two.lines.count == 2 && two.truncated)
    _ = try await h.stop(started)
  }

  @Test func doctorListsManagedServers() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let added = try await h.add(try h.project("doctor-proj"))
    let report = try await h.client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    let row = try #require(
      report.runtimes.first { $0.kind == .b4 && $0.message?.hasPrefix("doctor-proj:") == true })
    #expect(row.status == .offline)
    #expect(row.version == "0.15.8")
    #expect(row.executablePath == added.cliPath)
    #expect(row.message?.contains("stopped on port \(added.requestedPort ?? 0)") == true)
  }
}

@Suite(.serialized) struct ManagedConnectionTests {
  private func connect(
    _ h: ServerHarness, _ server: LocalServer, route: String = "/chat#agent"
  ) async throws -> ConnectionAdd.Result {
    try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: route, serverId: server.id),
      options: h.mutation())
  }

  private func thread(_ h: ServerHarness, _ connection: Connection) async throws -> ConversationThread {
    try await h.client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: connection.id), options: h.mutation()
    ).thread
  }

  private func send(_ h: ServerHarness, _ thread: ConversationThread, _ text: String) async throws -> Turn {
    try await h.client.request(
      TurnSend.self, TurnSend.Params(threadId: thread.id, text: text), options: h.mutation()
    ).turn
  }

  @Test func managedConnectionRefusesWhileStopped() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(
      nodeProbeLabel: .managedConnectionRefusesWhileStopped, adapterFactory: witness.makeFactory())
    defer { h.emitNodeProbeObservations() }
    defer { Task { await h.close() } }
    let server = try await h.add(try h.project())
    for mixedURL in [false, true, false] {
      let refused = await h.failure {
        try await h.client.request(
          ConnectionAdd.self,
          .init(
            kind: .b4, url: mixedURL ? "http://127.0.0.1:1" : nil, route: "/chat#agent", serverId: server.id),
          options: h.mutation())
      }
      #expect(refused?.code == .unsupportedCapability)
      #expect(refused?.details?["reason"]?.stringValue == "agent_protocol_cutover")
    }
    #expect(try h.coordinator.database.listConnections().isEmpty)
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let before = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection)
    try await HistoricalCoordinatorFixture.expectCutover { _ = try await thread(h, connection) }
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await send(h, before.thread, "never dispatch")
    }
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await h.client.request(
        ConnectionInspect.self, .init(connectionId: connection.id), options: h.mutation())
    }
    let unchanged =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: before.thread.id) == before
    #expect(unchanged)
    #expect(try h.coordinator.database.listThreads().map(\.id) == [before.thread.id])
    #expect(try h.coordinator.database.listAppFolders().isEmpty)
    #expect(try await h.status(server).health == .stopped)
    #expect(witness.count == 0)
  }

  @Test func ownedManagedLifecyclePreservesHistoricalCache() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(adapterFactory: witness.makeFactory())
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    #expect(server.health == .ready)
    #expect(server.ownershipVerified)
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection)
    let read = try await h.client.request(ThreadRead.self, .init(threadId: history.thread.id))
    let retainedFacts1 = read.items == history.items
    #expect(retainedFacts1)
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await h.client.request(
        ConnectionInspect.self, .init(connectionId: connection.id), options: h.mutation())
    }
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await send(h, history.thread, "never dispatch")
    }
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await h.client.request(
        RequestRespond.self, .init(requestId: history.requests[0].id, decision: .allowOnce),
        options: h.mutation())
    }
    #expect(try await h.stop(server).health == .stopped)
    let retainedFacts2 =
      try await h.client.request(ThreadRead.self, .init(threadId: history.thread.id)).items == history.items
    #expect(retainedFacts2)
    let restarted = try await h.start(server)
    #expect(restarted.health == .ready)
    let unchanged =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: history.thread.id)
      == history
    #expect(unchanged)
    _ = try await h.stop(restarted)
    // Owned process readiness is real. Historical cache is not a managed conversation integration.

    #expect(witness.count == 0)
  }

  @Test func stopRefusesWhileATurnIsRunningUnlessForced() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(adapterFactory: witness.makeFactory())
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection, status: .running)
    let created = history.thread
    let turn = history.turns[0]
    let refused = await h.failure { try await h.stop(server) }
    #expect(refused?.code == .ownedProcessConflict)
    #expect(refused?.details?["reason"]?.stringValue == "turn_active")
    #expect(refused?.details?["threadIds"]?.arrayValue?.first?.stringValue == created.id)
    #expect(try await h.status(server).health == .ready)
    let stopped = try await h.stop(server, force: true)
    #expect(stopped.health == .stopped)
    let read = try await h.client.request(
      ThreadRead.self, .init(threadId: created.id), options: RequestOptions(timeout: .seconds(30)))
    let final = try #require(read.turns.first { $0.id == turn.id })
    #expect(final.status == .running)
    #expect(final.submission == .unknown)
    #expect(final.outcome == nil)
    let unchanged =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: created.id) == history
    #expect(unchanged)
    // A stopped registration is idempotent; restart still works with retained unknown history.
    #expect(try await h.stop(server).health == .stopped)
    let restarted = try await h.client.request(
      ServerRestart.self, ServerLifecycleParams(serverId: server.id),
      options: h.mutation(.seconds(150))
    ).server
    #expect(restarted.health == .ready)
    _ = try await h.stop(restarted, force: true)
    #expect(witness.count == 0)
  }

  @Test func serverExitProjectsCurrentNotificationAndLeavesHistoryUntouched() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(adapterFactory: witness.makeFactory())
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection, status: .running)
    // TEST SEAM, matching AgentProtocolLegacyManagedTests: a synthetic current-kind row linked to
    // the owned registration exercises the generic notification projection. Shipped Codex does not
    // execute through a B4 server, and no such routing claim is made here.
    let current = try h.coordinator.database.insertConnection(
      Connection(
        id: "notification-current", kind: .codex, label: "Notification projection fixture",
        target: "/fixture/codex", localServerId: server.id, commands: [], status: .ready))
    let currentThread = try h.coordinator.database.insertThread(
      ConversationThread(
        id: "notification-thread", connectionId: current.id, nativeThreadId: "notification-native",
        title: "Projection only"))
    let currentTurn = try h.coordinator.database.insertTurn(
      Turn(
        id: "notification-turn", threadId: currentThread.id, operationId: "notification-op",
        nativeTurnId: "1", status: .running, submission: .acknowledged))
    kill(server.pid!, SIGKILL)
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == current.id
        && $0.payload["status"]?.stringValue == "offline"
    }
    try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == currentTurn.id
        && $0.payload["status"]?.stringValue == "reconciling"
    }
    #expect(try await h.status(server).health == .stopped)
    #expect(try h.coordinator.database.connection(id: current.id)?.status == .offline)
    #expect(try h.coordinator.database.turn(id: currentTurn.id)?.status == .reconciling)
    #expect(try h.coordinator.database.turn(id: currentTurn.id)?.outcome == nil)
    let unchanged =
      try HistoricalCoordinatorFixture.snapshot(h.coordinator.database, threadId: history.thread.id)
      == history
    #expect(unchanged)
    #expect(
      !(await h.events.events.map(\.event)).contains {
        $0.kind == .connectionChanged && $0.connectionId == connection.id
      })
    try await HistoricalCoordinatorFixture.expectCutover {
      _ = try await send(h, history.thread, "never dispatch")
    }

    #expect(witness.count == 0)
  }

  @Test func managedLegacyRoutesRefuseBeforeCompatibilityDiscovery() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(adapterFactory: witness.makeFactory())
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    for route in ["/dispatch#workflow", "/nope#agent"] {
      let refused = await h.failure { try await connect(h, server, route: route) }
      #expect(refused?.code == .unsupportedCapability)
      #expect(refused?.details?["reason"]?.stringValue == "agent_protocol_cutover")
    }
    #expect(try h.coordinator.database.listConnections().isEmpty)
    #expect(try await h.status(server).health == .ready)
    _ = try await h.stop(server)
    // Route discovery/parsing remains covered by registry/B4 adapter fixtures, not legacy admission.

    #expect(witness.count == 0)
  }
}

/// Taking a project off the Mac (D-231).
@Suite(.serialized) struct LocalServerRemoveTests {
  private func connect(_ h: ServerHarness, _ server: LocalServer) async throws -> Connection {
    try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: "/chat#agent", serverId: server.id),
      options: h.mutation()
    ).connection
  }

  private func remove(
    _ h: ServerHarness, _ server: LocalServer, force: Bool? = nil
  ) async throws
    -> ServerRemove.Result
  {
    try await h.client.request(
      ServerRemove.self, ServerLifecycleParams(serverId: server.id, force: force), options: h.mutation())
  }

  private func connections(_ h: ServerHarness, includeDisabled: Bool) async throws -> [Connection] {
    try await h.client.request(
      ConnectionList.self, ConnectionList.Params(includeDisabled: includeDisabled)
    ).connections
  }

  @Test func removingARunningProjectStopsItAndDisablesItsConnections() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(adapterFactory: witness.makeFactory())
    defer { Task { await h.close() } }
    let path = try h.project()
    let server = try await h.start(try await h.add(path))
    let pid = try #require(server.pid)
    let logPath = try #require(server.logPath)
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection, status: .reconciling)
    let thread = history.thread
    #expect(try await remove(h, server).serverId == server.id)

    #expect(try await h.client.request(ServerList.self, EmptyParams()).servers.isEmpty)
    #expect(kill(pid_t(pid), 0) != 0)
    #expect(!FileManager.default.fileExists(atPath: logPath))
    // The project's own folder is left as it was.
    #expect(FileManager.default.fileExists(atPath: path + "/package.json"))
    try await h.events.waitFor {
      $0.kind == .serverRemoved && $0.payload["serverId"]?.stringValue == server.id
    }
    // The connection is kept for its thread, disabled and with no server behind it.
    #expect(try await connections(h, includeDisabled: false).isEmpty)
    let kept = try #require(try await connections(h, includeDisabled: true).first)
    #expect(kept.id == connection.id && !kept.enabled && kept.localServerId == nil)
    #expect(kept.status == .offline)
    // Its thread is still read, and a message to it says why it cannot go.
    let read = try await h.client.request(ThreadRead.self, ThreadRead.Params(threadId: thread.id))
    #expect(read.thread.id == thread.id)
    let retainedFacts3 = read.turns == history.turns
    #expect(retainedFacts3)
    let retainedFacts4 = read.items == history.items
    #expect(retainedFacts4)
    let retainedFacts5 = read.requests == history.requests
    #expect(retainedFacts5)
    let retainedFacts6 = try h.coordinator.database.draft(threadId: thread.id) == history.draft
    #expect(retainedFacts6)
    let refused = await h.failure {
      try await h.client.request(
        TurnSend.self, TurnSend.Params(threadId: thread.id, text: "hello"), options: h.mutation())
    }
    #expect(refused?.code == .unsupportedCapability)
    #expect(refused?.details?["reason"]?.stringValue == "agent_protocol_cutover")
    // The same folder can be added again, as a new project with its own connections.
    let again = try await h.add(path)
    #expect(again.id != server.id)
    let retiredAdd = await h.failure { try await connect(h, again) }
    #expect(retiredAdd?.code == .unsupportedCapability)
    #expect(try h.coordinator.database.connection(id: connection.id)?.localServerId == nil)
    var expectedConnection = connection
    expectedConnection.enabled = false
    expectedConnection.localServerId = nil
    expectedConnection.status = .offline
    expectedConnection.updatedAt = kept.updatedAt
    let retainedIdentity = kept == expectedConnection
    #expect(retainedIdentity)
    #expect(witness.count == 0)
  }

  @Test func removingRefusesWhileATurnIsRunningUnlessForced() async throws {
    let witness = HistoricalFactoryWitness()
    let h = try await ServerHarness.start(
      nodeProbeLabel: .removingRefusesWhileATurnIsRunningUnlessForced,
      adapterFactory: witness.makeFactory())
    defer { h.emitNodeProbeObservations() }
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let connection = try await HistoricalCoordinatorFixture.seedEarlierManagedConnection(h, server: server)
    let history = try HistoricalCoordinatorFixture.seedEarlierConversation(
      h.coordinator.database, connection: connection, status: .running)
    let thread = history.thread
    let refused = await h.failure { try await remove(h, server) }
    #expect(refused?.code == .ownedProcessConflict)
    #expect(refused?.details?["reason"]?.stringValue == "turn_active")
    #expect(try await h.status(server).health == .ready)
    #expect(try await connections(h, includeDisabled: false).count == 1)

    _ = try await remove(h, server, force: true)
    #expect(try await h.client.request(ServerList.self, EmptyParams()).servers.isEmpty)
    let read = try await h.client.request(
      ThreadRead.self, ThreadRead.Params(threadId: thread.id), options: RequestOptions(timeout: .seconds(30)))
    let retainedFacts7 = read.turns == history.turns
    #expect(retainedFacts7)
    let retainedFacts8 = read.items == history.items
    #expect(retainedFacts8)
    let retainedFacts9 = read.requests == history.requests
    #expect(retainedFacts9)
    let retainedFacts10 = try h.coordinator.database.draft(threadId: thread.id) == history.draft
    #expect(retainedFacts10)
    let kept = try #require(try h.coordinator.database.connection(id: connection.id))
    #expect(!kept.enabled && kept.localServerId == nil && kept.status == .offline)
    var expectedConnection = connection
    expectedConnection.enabled = false
    expectedConnection.localServerId = nil
    expectedConnection.status = .offline
    expectedConnection.updatedAt = kept.updatedAt
    let retainedIdentity = kept == expectedConnection
    #expect(retainedIdentity)
    #expect(witness.count == 0)
  }

  @Test func removingAnUnknownProjectIsNotFound() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let failure = await h.failure {
      try await h.client.request(
        ServerRemove.self, ServerLifecycleParams(serverId: "nope"), options: h.mutation())
    }
    #expect(failure?.code == .notFound)
  }
}
