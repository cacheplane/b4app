import Coordinator
import Foundation
import NIOTransport
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Test-only host: its lifetime is independent of the UI, so relaunch must read persisted state.
@main struct SmokeHost {
  static func main() async {
    do {
      try await run()
    } catch {
      FileHandle.standardError.write(Data("Fixture setup failed: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() async throws {
    guard CommandLine.arguments.count == 3 else {
      throw WorkspaceError(.protocolInvalid, "Expected private fixture root and fake executable.")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let fake = CommandLine.arguments[2]
    guard root.deletingLastPathComponent().path == "/tmp", root.lastPathComponent.hasPrefix("b4smk-"),
      FileManager.default.isExecutableFile(atPath: fake)
    else { throw WorkspaceError(.protocolInvalid, "Refusing non-fixture paths.") }
    // SIGTERM closes the coordinator and reaches normal exit (including PostgreSQL's atexit).
    signal(SIGTERM, SIG_IGN)
    let stopped = AsyncStream<Void> { continuation in
      let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
      source.setEventHandler { continuation.yield(()) }
      source.resume()
      continuation.onTermination = { _ in source.cancel() }
      // EOF also ends ownership if the UI test runner crashes before executing teardown.
      DispatchQueue.global(qos: .utility).async {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        continuation.yield(())
      }
    }
    trace("Starting private PostgreSQL")
    let paths = try EphemeralPostgres.paths(
      runtimeDir: root.appendingPathComponent("rt").path,
      dataDir: root.appendingPathComponent("data").path)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
    trace("Seeding fixture account")
    let registry = try AccountRegistry(
      endpoint: paths.postgres, binDir: paths.postgres.binDir!,
      databaseName: AccountManager.registryDatabaseName(for: paths.postgres))
    let account = AccountRow(
      id: AccountRegistry.newId(), hubURL: "http://localhost:8080", hubUserId: "o-smoke/u-smoke",
      deviceId: "local", database: paths.postgres.database, displayName: "Smoke", orgName: "Fixture")
    try registry.insert(account)
    try registry.activate(id: account.id, tokenRef: SecretRef.make().rawValue)
    registry.close()
    // An allowlist prevents credentials or runtime overrides from the caller leaking into fixtures.
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "B4APP_NODE_PATH": "/nonexistent/node"]
    environment["TMPDIR"] = NSTemporaryDirectory()
    environment["FAKE_CODEX_PARAMS"] = root.appendingPathComponent("runtime-requests.jsonl").path
    trace("Starting coordinator")
    guard
      case .running(let coordinator) = try await Coordinator.start(
        options: CoordinatorOptions(
          paths: paths, environment: environment, secretStore: MemorySecretStore(), flavor: .local,
          checkRetryDelays: [.zero], threadDeleteSweep: .zero))
    else { throw WorkspaceError(.internalError, "Fixture coordinator did not start.") }
    do {
      trace("Adding fake runtime and cached thread")
      let client = WorkspaceClient(
        transport: try await UnixSocketTransport.connect(path: paths.socketPath))
      let connection = try await client.request(
        ConnectionAdd.self, .init(kind: .codex, label: "Fixture runtime", executablePath: fake),
        options: .init(operationId: UUID().uuidString)
      ).connection
      guard let database = coordinator.accounts.current?.database else {
        throw WorkspaceError(.internalError, "Fixture account did not open.")
      }
      let thread = try database.insertThread(
        ConversationThread(
          id: "smoke-archived", connectionId: connection.id, nativeThreadId: "thr_archived",
          nativeScope: connection.nativeScope ?? "", title: "Archived recovery fixture",
          context: root.appendingPathComponent("work").path))
      _ = try database.insertDisplayItem(
        DisplayItem(
          id: "smoke-history", threadId: thread.id, role: .assistant, type: "agentMessage",
          payload: ["text": .string(String(repeating: "Earlier cached transcript.\n", count: 100))],
          sequence: 1, provenance: .cache))
      _ = try database.insertDisplayItem(
        DisplayItem(
          id: "smoke-cached", threadId: thread.id, role: .assistant, type: "agentMessage",
          payload: ["text": "Cached transcript remains readable."], sequence: 2, provenance: .cache))
      _ = try database.saveDraft(threadId: thread.id, text: "Keep this smoke-test draft.")
      await client.close()
      let ready: [String: String] = ["socket": paths.socketPath, "threadId": thread.id]
      try JSONEncoder().encode(ready).write(to: root.appendingPathComponent("ready.json"), options: .atomic)
      trace("Fixture ready")
      for await _ in stopped { break }
      trace("Closing coordinator")
      await coordinator.close()
    } catch {
      await coordinator.close()
      throw error
    }
  }

  static func trace(_ phase: String) {
    FileHandle.standardError.write(Data("\(Date().timeIntervalSince1970): \(phase)\n".utf8))
  }
}
