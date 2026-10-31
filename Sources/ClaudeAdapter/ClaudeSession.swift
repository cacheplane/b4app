import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import os

/// One `claude` stream-json process for one native session: launch, `initialize` handshake, control
/// request matching, and a single inbound stream of frames with an exit marker at the end.
actor ClaudeSession {
  struct Options: Sendable {
    var executablePath: String
    var environment: [String: String]
    var workingDirectory: String
    var sessionId: String
    var resume: Bool
    var clientVersion: String
    var handshakeTimeout: Duration = .seconds(30)
  }

  enum Inbound: Sendable {
    case frame(ClaudeStream.Frame)
    case exited(ExitStatus, stderrTail: String)
  }

  let sessionId: String
  let inbound: AsyncStream<Inbound>
  private let continuation: AsyncStream<Inbound>.Continuation
  private let options: Options
  private var process: StreamingProcess?
  private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
  private var counter = 0
  private var exited: (ExitStatus, String)?
  private let logger = Logger(subsystem: "com.cacheplane.b4app", category: "claude.session")

  init(options: Options) {
    self.options = options
    self.sessionId = options.sessionId
    (inbound, continuation) = AsyncStream<Inbound>.makeStream()
  }

  var isRunning: Bool { process?.isRunning ?? false }
  var processIdentifier: Int32? { process?.processIdentifier }

  /// Spawn and complete the `initialize` handshake. A process that exits before answering (for
  /// example `--resume` of an unknown id) surfaces as `endpoint_unavailable` with its stderr tail.
  func start() async throws {
    var launch = ClaudeStream.LaunchOptions()
    if options.resume {
      launch.resumeSessionId = options.sessionId
    } else {
      launch.sessionId = options.sessionId
    }
    let child = try StreamingProcess.start(
      executable: options.executablePath, arguments: launch.arguments,
      environment: ClaudeStream.childEnvironment(
        from: options.environment, clientVersion: options.clientVersion),
      workingDirectory: options.workingDirectory)
    process = child
    logger.info(
      "started pid \(child.processIdentifier, privacy: .public) session \(self.sessionId, privacy: .public)")
    Task { await self.readLoop(child) }
    do {
      _ = try await control("initialize", ["hooks": [:]], timeout: options.handshakeTimeout)
    } catch {
      child.terminate()
      let failure = WorkspaceError.from(error)
      throw WorkspaceError(
        failure.code == .endpointUnavailable ? .endpointUnavailable : .incompatibleVersion,
        "Claude Code handshake failed: \(failure.message)",
        details: ["stderr": .string(child.recentStderr()), "cause": failure.details ?? .null])
    }
  }

  private func readLoop(_ child: StreamingProcess) async {
    var lines = LineDecoder()
    for await chunk in child.stdout {
      for line in lines.push(chunk) { dispatch(ClaudeStream.decodeFrame(line)) }
    }
    let status = await child.waitForExit()
    let tail = child.recentStderr()
    exited = (status, tail)
    if self.process === child { process = nil }
    let failure = WorkspaceError(
      .endpointUnavailable, "claude exited (\(status)).\(tail.isEmpty ? "" : " \(tail.suffix(400))")",
      details: ["reason": "exited", "stderr": .string(tail)])
    for continuation in pending.values { continuation.resume(throwing: failure) }
    pending = [:]
    continuation.yield(.exited(status, stderrTail: tail))
    continuation.finish()
  }

  private func dispatch(_ frame: ClaudeStream.Frame) {
    if case .controlResponse(let response) = frame,
      let waiter = pending.removeValue(forKey: response.requestId)
    {
      if response.subtype == "error" {
        waiter.resume(
          throwing: WorkspaceError(.internalError, response.error ?? "Claude Code rejected the request."))
      } else {
        waiter.resume(returning: response.response ?? [:])
      }
      return
    }
    continuation.yield(.frame(frame))
  }

  /// Send a `control_request` and await its `control_response`.
  func control(
    _ subtype: String, _ body: [String: JSONValue], timeout: Duration = .seconds(15)
  ) async throws
    -> JSONValue
  {
    guard let process, process.isRunning else {
      throw WorkspaceError(.endpointUnavailable, "claude is not running for session \(sessionId).")
    }
    counter += 1
    let requestId = "b4-\(counter)"
    var request = body
    request["subtype"] = .string(subtype)
    let line = try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_request", "request_id": .string(requestId), "request": .object(request),
      ]))
    return try await withCheckedThrowingContinuation { continuation in
      pending[requestId] = continuation
      do {
        try process.write(line)
      } catch {
        pending[requestId] = nil
        continuation.resume(throwing: error)
        return
      }
      Task {
        try? await Task.sleep(for: timeout)
        self.expire(requestId, subtype: subtype, after: timeout)
      }
    }
  }

  private func expire(_ requestId: String, subtype: String, after timeout: Duration) {
    pending.removeValue(forKey: requestId)?.resume(
      throwing: WorkspaceError(
        .endpointUnavailable, "Claude Code did not answer \"\(subtype)\" within \(timeout).",
        details: ["reason": "timeout", "subtype": .string(subtype)]))
  }

  /// Write a pre-encoded line (a `user` message or a `control_response`).
  func send(_ line: Data) throws {
    guard let process else {
      throw WorkspaceError(.endpointUnavailable, "claude is not running for session \(sessionId).")
    }
    try process.write(line)
  }

  /// Close stdin (the protocol's end-of-session), wait two seconds, then terminate.
  func close() async {
    guard let process else { return }
    process.closeInput()
    let exitedInTime = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = await process.waitForExit()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !exitedInTime { process.terminate() }
  }
}
