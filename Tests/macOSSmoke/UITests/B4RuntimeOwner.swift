import Foundation
import WorkspaceProtocol
import XCTest

/// The test runner owns this pipe; EOF makes Node close its real B4 and aimock children.
@MainActor final class B4RuntimeOwner {
  private let root: URL
  private let process = Process()
  private let input = Pipe()
  private let output: FileHandle
  private var launched = false
  private var closing: Task<Bool, Never>?

  init(root: URL) throws {
    self.root = root
    let environment = ProcessInfo.processInfo.environment
    let node = try XCTUnwrap(environment["SMOKE_NODE_PATH"])
    let package = try XCTUnwrap(environment["SMOKE_RUNTIME_PACKAGE"])
    guard FileManager.default.isExecutableFile(atPath: node),
      FileManager.default.fileExists(atPath: package + "/owner.mjs")
    else { throw Self.failure("Missing pinned real-runtime fixture or Node executable") }
    let log = root.appendingPathComponent("b4-owner.log")
    _ = FileManager.default.createFile(atPath: log.path, contents: nil)
    output = try FileHandle(forWritingTo: log)
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [package + "/owner.mjs", root.path]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    process.environment = [
      "PATH": URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": NSTemporaryDirectory(),
    ]
  }

  func start() async throws {
    try process.run()
    launched = true
    try output.close()
    try input.fileHandleForReading.close()
    let manifest = try await waitFor(id: "startup", timeout: .seconds(120))
    guard manifest["state"]?.stringValue == "ready", let raw = manifest["url"]?.stringValue,
      let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1", url.port != nil
    else { throw Self.failure("Real-runtime owner did not provide a ready loopback endpoint") }
  }

  @discardableResult func command(_ command: String) async throws -> JSONValue {
    guard closing == nil, process.isRunning else { throw Self.failure("Real-runtime owner is stopped") }
    let id = UUID().uuidString
    let data = try JSONEncoder().encode(["id": id, "command": command])
    try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    let manifest = try await waitFor(id: id, timeout: .seconds(45))
    if command == "start" || command == "stop" {
      let expected = command == "start" ? "ready" : "stopped"
      guard manifest["state"]?.stringValue == expected else {
        throw Self.failure("Real-runtime owner did not reach \(expected)")
      }
    }
    return manifest
  }

  private func waitFor(id: String, timeout: Duration) async throws -> JSONValue {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let data = try? Data(contentsOf: root.appendingPathComponent("b4-runtime.json")),
        let manifest = try? JSONDecoder().decode(JSONValue.self, from: data)
      {
        if manifest["state"]?.stringValue == "failed" {
          throw Self.failure(manifest["error"]?.stringValue ?? "Real-runtime owner failed")
        }
        if manifest["id"]?.stringValue == id { return manifest }
      }
      guard process.isRunning else { throw Self.failure("Real-runtime owner exited: \(diagnostics())") }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw Self.failure("Timed out waiting for real-runtime owner operation \(id): \(diagnostics())")
  }

  func stop(in test: XCTestCase? = nil) async -> Bool {
    if closing == nil {
      closing = Task { @MainActor in
        try? self.input.fileHandleForWriting.close()
        try? self.input.fileHandleForReading.close()
        try? self.output.close()
        guard self.launched else { return true }
        var deadline = ContinuousClock.now + .seconds(45)
        while self.process.isRunning, ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(100))
        }
        if self.process.isRunning {
          self.process.terminate()
          deadline = ContinuousClock.now + .seconds(15)
          while self.process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        return !self.process.isRunning
      }
    }
    let stopped = await closing!.value
    if let test {
      XCTAssertTrue(stopped, "Real-runtime owner did not stop: \(diagnostics())")
      if stopped, launched {
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics())
      }
      let urls =
        [root.appendingPathComponent("b4-owner.log")]
        + ((try? FileManager.default.contentsOfDirectory(
          at: root.appendingPathComponent("b4-artifacts"), includingPropertiesForKeys: nil)) ?? [])
      for url in urls {
        if let data = try? Data(contentsOf: url) {
          let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
          attachment.name = "b4-" + url.lastPathComponent
          attachment.lifetime = .keepAlways
          test.add(attachment)
        }
      }
    }
    return stopped
  }

  private func diagnostics() -> String {
    (try? String(contentsOf: root.appendingPathComponent("b4-owner.log"), encoding: .utf8)) ?? "No owner log"
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "B4RuntimeOwner", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
