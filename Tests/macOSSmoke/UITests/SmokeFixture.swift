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
  let realRuntime: B4RuntimeOwner?
  private let lifetime: FileHandle

  private init(
    root: URL, process: Process, socket: String, client: WorkspaceClient, threadId: String,
    realRuntime: B4RuntimeOwner?, lifetime: FileHandle
  ) {
    self.root = root
    self.process = process
    self.socket = socket
    self.client = client
    self.threadId = threadId
    self.realRuntime = realRuntime
    self.lifetime = lifetime
  }

  static func start(in test: XCTestCase, realB4: Bool = false) async throws -> SmokeFixture {
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
    process.arguments = [root.path, realB4 ? "--b4" : fake.path]
    process.standardOutput = output
    process.standardError = output
    process.standardInput = ownerPipe
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
      "B4APP_POSTGRES_BIN": try XCTUnwrap(ProcessInfo.processInfo.environment["B4APP_POSTGRES_BIN"]),
    ]
    var runtime: B4RuntimeOwner?
    do {
      if realB4 {
        runtime = try B4RuntimeOwner(root: root)
        try await runtime?.start()
      }
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
        realRuntime: runtime,
        lifetime: ownerPipe.fileHandleForWriting)
    } catch {
      try? output.close()
      try? ownerPipe.fileHandleForWriting.close()
      try? ownerPipe.fileHandleForReading.close()
      let hostStopped = await stopProcess(process)
      let runtimeStopped = await runtime?.stop(in: test) ?? true
      attachLogs(root: root, to: test)
      if hostStopped, runtimeStopped { try? FileManager.default.removeItem(at: root) }
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
    if realRuntime != nil {
      // Capture even when the journey failed before its final assertions. Evidence collection must
      // not prevent independent client, coordinator and runtime cleanup.
      var state: [String: JSONValue] = [:]
      do {
        state["thread"] = try JSONValue(
          encoding: await client.request(
            ThreadRead.self, .init(threadId: threadId), options: .init(timeout: .seconds(5))))
      } catch { state["threadReadError"] = .string(String(describing: error)) }
      do {
        state["draft"] = try JSONValue(
          encoding: await client.request(
            DraftRead.self, .init(threadId: threadId), options: .init(timeout: .seconds(5))))
      } catch { state["draftReadError"] = .string(String(describing: error)) }
      if let data = try? JSONEncoder().encode(state) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "b4-coordinator-teardown-state"
        attachment.lifetime = .keepAlways
        test.add(attachment)
      }
    }
    await client.close()
    try? lifetime.close()
    let stopped = await Self.stopProcess(process)
    let runtimeStopped = await realRuntime?.stop(in: test) ?? true
    Self.attachLogs(root: root, to: test)
    XCTAssertTrue(stopped, "Fixture host failed to stop: \(root.path)")
    if stopped {
      XCTAssertEqual(process.terminationReason, .exit, "Fixture host crashed during shutdown")
      XCTAssertEqual(process.terminationStatus, 0)
    }
    if stopped, runtimeStopped { try FileManager.default.removeItem(at: root) }
  }

  private static func attachLogs(root: URL, to test: XCTestCase) {
    for name in ["host.log", "runtime-requests.jsonl"] {
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
