import Foundation
import NIOTransport
import WorkspaceClient
import WorkspaceProtocol
import XCTest

@MainActor final class SmokeFixture {
  static let draft = "Keep this smoke-test draft."
  let root: URL
  let process: Process
  let socket: String
  let client: WorkspaceClient
  private let lifetime: FileHandle

  private init(root: URL, process: Process, socket: String, client: WorkspaceClient, lifetime: FileHandle) {
    self.root = root
    self.process = process
    self.socket = socket
    self.client = client
    self.lifetime = lifetime
  }

  static func start() async throws -> SmokeFixture {
    let root = URL(fileURLWithPath: "/tmp/b4smk-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let bundle = Bundle(for: RecoverySmokeTests.self)
    var products = bundle.bundleURL
    while products.path != "/",
      !FileManager.default.isExecutableFile(
        atPath: products.appendingPathComponent("WorkspaceSmokeHost").path)
    { products.deleteLastPathComponent() }
    let host = products.appendingPathComponent("WorkspaceSmokeHost")
    let fake = try XCTUnwrap(bundle.url(forResource: "fake-codex", withExtension: "py"))
    let log = root.appendingPathComponent("host.log")
    _ = FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    let process = Process()
    let ownerPipe = Pipe()
    process.executableURL = host
    process.arguments = [root.path, fake.path]
    process.standardOutput = output
    process.standardError = output
    process.standardInput = ownerPipe
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
      "B4APP_POSTGRES_BIN": try XCTUnwrap(ProcessInfo.processInfo.environment["B4APP_POSTGRES_BIN"]),
    ]
    try process.run()
    do {
      try output.close()
      try ownerPipe.fileHandleForReading.close()
      let ready = root.appendingPathComponent("ready.json")
      let deadline = ContinuousClock.now + .seconds(120)
      while !FileManager.default.fileExists(atPath: ready.path) {
        guard process.isRunning, ContinuousClock.now < deadline else {
          throw NSError(
            domain: "SmokeFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: try String(contentsOf: log, encoding: .utf8)])
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: ready))
      let socket = try XCTUnwrap(manifest["socket"])
      let transport = try await UnixSocketTransport.connect(path: socket)
      let client = WorkspaceClient(transport: transport)
      return SmokeFixture(
        root: root, process: process, socket: socket, client: client,
        lifetime: ownerPipe.fileHandleForWriting)
    } catch {
      try? ownerPipe.fileHandleForWriting.close()
      if await stopProcess(process) { try? FileManager.default.removeItem(at: root) }
      throw error
    }
  }

  func releaseOwnership() throws { try lifetime.close() }

  func resumeCount() throws -> Int {
    let log = root.appendingPathComponent("runtime-requests.jsonl")
    guard let data = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
    let methods = try data.split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))["method"]?.stringValue
    }
    XCTAssertFalse(methods.contains("turn/start"), "The archived refusal must never start native inference")
    return methods.filter { $0 == "thread/resume" }.count
  }

  func waitForResume(after previous: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try resumeCount() <= previous {
      guard ContinuousClock.now < deadline else {
        throw NSError(
          domain: "SmokeFixture", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "The UI action did not reach the runtime"])
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func assertFailedAttempt(in test: XCTestCase) async throws {
    let read = try await client.request(ThreadRead.self, .init(threadId: "smoke-archived"))
    let draft = try await client.request(DraftRead.self, .init(threadId: "smoke-archived"))
    XCTAssertEqual(read.turns.count, 1)
    XCTAssertEqual(read.turns.first?.status, .terminal)
    XCTAssertEqual(read.turns.first?.outcome, .failed)
    XCTAssertNil(read.turns.first?.nativeTurnId)
    XCTAssertEqual(draft.draft?.text, Self.draft)
    XCTAssertTrue(read.items.contains { $0.id == "smoke-cached" })
    let state = XCTAttachment(data: try JSONEncoder().encode(read), uniformTypeIdentifier: "public.json")
    state.name = "persisted-thread"
    state.lifetime = .keepAlways
    test.add(state)
  }

  func stop(in test: XCTestCase) async throws {
    await client.close()
    try? lifetime.close()
    let stopped = await Self.stopProcess(process)
    for name in ["host.log", "runtime-requests.jsonl"] {
      if let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
      }
    }
    XCTAssertTrue(stopped, "Fixture host failed to stop: \(root.path)")
    if stopped {
      XCTAssertEqual(process.terminationReason, .exit, "Fixture host crashed during shutdown")
      XCTAssertEqual(process.terminationStatus, 0)
      try FileManager.default.removeItem(at: root)
    }
  }

  private static func stopProcess(_ process: Process) async -> Bool {
    if process.isRunning { process.terminate() }
    let deadline = ContinuousClock.now + .seconds(15)
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    return !process.isRunning
  }
}
