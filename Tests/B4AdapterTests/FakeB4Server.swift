import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import B4Adapter

func fakeB4Path() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-b4.py")
    .path
}

/// The Python fixture server as a child process. `port: 0` picks a free port; pass the same port
/// and `FAKE_B4_STATE` again to simulate a server restart with its stores preserved.
final class FakeB4Server: Sendable {
  let process: StreamingProcess
  let port: Int
  var baseURL: String { "http://127.0.0.1:\(port)" }

  private init(process: StreamingProcess, port: Int) {
    self.process = process
    self.port = port
  }

  static func start(port: Int = 0, environment extra: [String: String] = [:]) async throws -> FakeB4Server {
    var env = ProcessInfo.processInfo.environment
    for (key, value) in extra { env[key] = value }
    let process = try StreamingProcess.start(
      executable: fakeB4Path(), arguments: ["--port", String(port)], environment: env)
    var buffer = ""
    for await chunk in process.stdout {
      buffer += String(decoding: chunk, as: UTF8.self)
      if let range = buffer.range(of: "listening on http://127.0.0.1:"),
        let newline = buffer[range.upperBound...].firstIndex(of: "\n")
      {
        guard let bound = Int(buffer[range.upperBound..<newline]) else { break }
        return FakeB4Server(process: process, port: bound)
      }
    }
    throw WorkspaceError(.internalError, "fake-b4 did not start: \(process.recentStderr())")
  }

  func stop() async {
    process.terminate()
    _ = await process.waitForExit()
  }

  /// Raw read for assertions about server-side state (turn counts, thread status).
  func get(_ path: String, token: String? = nil) async throws -> JSONValue? {
    var request = URLRequest(url: URL(string: baseURL + path)!)
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, _) = try await URLSession.shared.data(for: request)
    return try? JSONCoding.decoder.decode(JSONValue.self, from: data)
  }
}

actor EventCollector {
  private(set) var events: [AdapterEvent] = []
  init(_ stream: AsyncStream<AdapterEvent>) {
    Task { for await event in stream { await self.append(event) } }
  }
  /// Suspended `waitFor` calls, resumed by the next event (or a deadline).
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private func append(_ event: AdapterEvent) {
    events.append(event)
    wake()
  }

  private func wake() {
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  /// The first event matching `predicate`, checked now and again as each event arrives. The timeout
  /// only ends a test that would otherwise hang.
  @discardableResult
  func waitFor(
    timeout: Duration = .seconds(60), _ predicate: @Sendable (AdapterEvent) -> Bool
  ) async throws -> AdapterEvent {
    let deadline = ContinuousClock.now + timeout
    let alarm = Task { [weak self] in
      guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
      await self?.wake()
    }
    defer { alarm.cancel() }
    while true {
      if let match = events.first(where: predicate) { return match }
      guard ContinuousClock.now < deadline else {
        throw WorkspaceError(
          .internalError, "timed out waiting for event; saw \(events.map(\.kind.rawValue))")
      }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  func deltas(turnId: String) -> String {
    events.filter { $0.kind == .messageDelta && $0.nativeIds["turnId"] == turnId }
      .compactMap { $0.payload["delta"]?.stringValue }.joined()
  }
}
