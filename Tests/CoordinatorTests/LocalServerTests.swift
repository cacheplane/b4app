import Darwin
import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

/// A coordinator on scratch directories whose Node is the fake shim, plus a scratch B4 project.
struct ServerHarness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let paths: PlatformPaths
  let base: String
  let events: EventCollector

  static func start(paths existing: PlatformPaths? = nil) async throws -> ServerHarness {
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
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let events = EventCollector(await client.events())
    return ServerHarness(coordinator: coordinator, client: client, paths: paths, base: base, events: events)
  }

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
    let h = try await ServerHarness.start()
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
    let h = try await ServerHarness.start()
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
    let port = try Ports.allocate()
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    #expect(bound == 0 && listen(fd, 1) == 0)
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
    let h = try await ServerHarness.start()
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
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.add(try h.project())
    let result = try await connect(h, server)
    #expect(result.connection.b4Mode == .managedLocal)
    #expect(result.connection.localServerId == server.id)
    #expect(result.connection.target == "http://127.0.0.1:\(server.requestedPort ?? 0)")
    #expect(result.connection.routeKey == "/chat#agent")
    #expect(result.connection.status == .offline)
    #expect(result.inspection.message?.contains("server start proj") == true)
    let failure = await h.failure { try await thread(h, result.connection) }
    #expect(failure?.code == .endpointUnavailable)
    #expect(failure?.message.contains("agent-workspace server start proj") == true)
    #expect(try await h.client.request(ThreadList.self, ThreadList.Params()).threads.isEmpty)
    let both = await h.failure {
      try await h.client.request(
        ConnectionAdd.self,
        ConnectionAdd.Params(kind: .b4, url: "http://127.0.0.1:1", route: "/chat#agent", serverId: server.id),
        options: h.mutation())
    }
    #expect(both?.code == .protocolInvalid)
    let again = try await connect(h, server)
    #expect(again.connection.id == result.connection.id)
  }

  @Test func conversesThroughAManagedServer() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let result = try await connect(h, server)
    #expect(result.connection.status == .ready)
    let inspected = try await h.client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: result.connection.id),
      options: h.mutation()
    )
    #expect(inspected.connection.status == .ready)
    let created = try await thread(h, result.connection)
    #expect(created.context == "/chat#agent")
    let turn = try await send(h, created, "hello there")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let read = try await h.client.request(ThreadRead.self, ThreadRead.Params(threadId: created.id))
    #expect(read.items.contains { $0.payload["text"]?.stringValue == "Hello from fake B4." })
    _ = try await h.stop(server)
    let offline = try await h.client.request(ConnectionList.self, ConnectionList.Params()).connections
    #expect(offline.first { $0.id == result.connection.id }?.status == .offline)
  }

  @Test func stopRefusesWhileATurnIsRunningUnlessForced() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let connection = try await connect(h, server).connection
    let created = try await thread(h, connection)
    let turn = try await send(h, created, "hang around")
    try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    let refused = await h.failure { try await h.stop(server) }
    #expect(refused?.code == .ownedProcessConflict)
    #expect(refused?.details?["reason"]?.stringValue == "turn_active")
    #expect(refused?.details?["threadIds"]?.arrayValue?.first?.stringValue == created.id)
    #expect(try await h.status(server).health == .ready)
    let stopped = try await h.stop(server, force: true)
    #expect(stopped.health == .stopped)
    // The lost turn's next state is published: reconciling (a state change) or a terminal outcome.
    try await h.events.waitFor {
      $0.turnId == turn.id
        && ($0.kind == .turnFinished
          || ($0.kind == .turnStateChanged && $0.payload["status"]?.stringValue == "reconciling"))
    }
    let read = try await h.client.request(
      ThreadRead.self, ThreadRead.Params(threadId: created.id), options: RequestOptions(timeout: .seconds(30))
    )
    let final = try #require(read.turns.first { $0.id == turn.id })
    #expect(final.outcome != .completed)
    #expect(final.status == .reconciling || final.outcome == .failed || final.outcome == .cancelled)
    // Nothing more can be lost: a stopped server stops again without force, and a reconciling turn
    // does not block a restart.
    #expect(try await h.stop(server).health == .stopped)
    let restarted = try await h.client.request(
      ServerRestart.self, ServerLifecycleParams(serverId: server.id), options: h.mutation(.seconds(150))
    ).server
    #expect(restarted.health == .ready)
    _ = try await h.stop(restarted, force: true)
  }

  @Test func serverExitMarksRouteConnectionsOffline() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let connection = try await connect(h, server).connection
    let created = try await thread(h, connection)
    let turn = try await send(h, created, "hang around")
    try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    kill(server.pid!, SIGKILL)
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == connection.id
        && $0.payload["status"]?.stringValue == "offline"
    }
    #expect(try await h.status(server).health == .stopped)
    let read = try await h.client.request(
      ThreadRead.self, ThreadRead.Params(threadId: created.id), options: RequestOptions(timeout: .seconds(30))
    )
    let final = try #require(read.turns.first { $0.id == turn.id })
    #expect(final.status == .reconciling || final.outcome == .failed)
    let failure = await h.failure { try await send(h, created, "again") }
    #expect(failure?.code == .endpointUnavailable)
    #expect(failure?.details?["reason"]?.stringValue == "server_stopped")
  }

  @Test func workflowRouteOnAManagedServerIsIncompatible() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project()))
    let result = try await connect(h, server, route: "/dispatch#workflow")
    #expect(result.connection.status == .incompatible)
    #expect(result.inspection.message?.contains("workflow") == true)
    let unknown = await h.failure { try await connect(h, server, route: "/nope#agent") }
    #expect(unknown?.code == .notFound)
    _ = try await h.stop(server)
  }
}
