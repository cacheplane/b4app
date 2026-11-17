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
  let threadId: String
  let currentThreadId: String?
  let historicalB4: Bool
  private let lifetime: FileHandle

  private init(
    root: URL, process: Process, socket: String, client: WorkspaceClient, threadId: String,
    currentThreadId: String?, historicalB4: Bool, lifetime: FileHandle
  ) {
    self.root = root
    self.process = process
    self.socket = socket
    self.client = client
    self.threadId = threadId
    self.currentThreadId = currentThreadId
    self.historicalB4 = historicalB4
    self.lifetime = lifetime
  }

  /// `reading` asks the host for a second thread that ends in a reply with a fenced block: forty short
  /// replies before it, or `tall`, one reply several windows tall, or `long`, two hundred replies.
  enum Reading: String { case short = "", tall, long }

  static func start(
    in test: XCTestCase, historicalB4: Bool = false, reading: Reading? = nil
  ) async throws
    -> SmokeFixture
  {
    let root = URL(fileURLWithPath: "/tmp/b4smk-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if let reading {
      _ = FileManager.default.createFile(
        atPath: root.appendingPathComponent("reading").path, contents: Data(reading.rawValue.utf8))
    }
    if historicalB4 {
      _ = FileManager.default.createFile(
        atPath: root.appendingPathComponent("historical-b4").path, contents: Data())
    }
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
    do {
      try process.run()
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
      let threadId = try XCTUnwrap(manifest["threadId"])
      let transport = try await UnixSocketTransport.connect(path: socket)
      let client = WorkspaceClient(transport: transport)
      return SmokeFixture(
        root: root, process: process, socket: socket, client: client, threadId: threadId,
        currentThreadId: manifest["currentThreadId"], historicalB4: historicalB4,
        lifetime: ownerPipe.fileHandleForWriting)
    } catch {
      try? output.close()
      try? ownerPipe.fileHandleForWriting.close()
      try? ownerPipe.fileHandleForReading.close()
      let hostStopped = await stopProcess(process)
      attachLogs(root: root, to: test)
      if hostStopped { try? FileManager.default.removeItem(at: root) }
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
    var historicalState: [String: JSONValue] = [:]
    if historicalB4 {
      // Capture even on an assertion failure, without preventing independent owned teardown.
      for id in [threadId, currentThreadId].compactMap({ $0 }) {
        var state: [String: JSONValue] = [:]
        do {
          state["read"] = try JSONValue(
            encoding: await client.request(
              ThreadRead.self, .init(threadId: id), options: .init(timeout: .seconds(5))))
        } catch { state["readError"] = .string(String(describing: error)) }
        do {
          state["draft"] = try JSONValue(
            encoding: await client.request(
              DraftRead.self, .init(threadId: id), options: .init(timeout: .seconds(5))))
        } catch { state["draftError"] = .string(String(describing: error)) }
        if id == threadId { historicalState = state }
        if let data = try? JSONEncoder().encode(state) {
          let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
          attachment.name = "coordinator-teardown-\(id)"
          attachment.lifetime = .keepAlways
          test.add(attachment)
        }
      }
    }
    await client.close()
    try? lifetime.close()
    let stopped = await Self.stopProcess(process)
    Self.attachLogs(root: root, to: test)
    XCTAssertTrue(stopped, "Fixture host failed to stop: \(root.path)")
    if stopped {
      XCTAssertEqual(process.terminationReason, .exit, "Fixture host crashed during shutdown")
      XCTAssertEqual(process.terminationStatus, 0)
      if historicalB4 {
        // Read the host's actual database snapshots only after its existing bounded join.
        // Defer removal so a decoding/assertion error cannot leave a stopped fixture behind.
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try databaseSnapshot("historical-database-seed.json")
        let final = try databaseSnapshot("historical-database-final.json")
        XCTAssertEqual(final["connection"], seed["connection"])
        for key in ["turns", "items", "requests"] {
          XCTAssertEqual(final["read"]?[key], seed["read"]?[key], "Historical DB \(key) changed")
          if let observed = historicalState["read"] {
            XCTAssertEqual(final["read"]?[key], observed[key])
          }
        }
        for key in ["id", "connectionId", "nativeThreadId", "nativeScope", "context", "continuity"] {
          XCTAssertEqual(final["read"]?["thread"]?[key], seed["read"]?["thread"]?[key])
        }
        if let draft = historicalState["draft"] { XCTAssertEqual(final["draft"], draft) }
      } else {
        try FileManager.default.removeItem(at: root)
      }
    }
  }

  func databaseSnapshot(_ name: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent(name)))
  }

  private static func attachLogs(root: URL, to test: XCTestCase) {
    for name in [
      "host.log", "runtime-requests.jsonl", "historical-database-seed.json", "historical-database-final.json",
    ] {
      if let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
      }
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
