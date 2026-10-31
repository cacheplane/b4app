import Darwin
import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

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
      paths = PlatformPaths(runtimeDir: base + "/rt", dataDir: base + "/data")
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
