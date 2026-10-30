import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import os

/// One `codex app-server` child: handshake, request/response matching, and a single inbound stream of
/// server requests, notifications, and exit markers. Restarting after an exit bumps `generation`.
public actor CodexAppServer {
  public struct Options: Sendable {
    public var executablePath: String
    public var environment: [String: String]
    public var clientVersion: String
    public var requestTimeout: Duration
    public var handshakeTimeout: Duration

    public init(
      executablePath: String, environment: [String: String], clientVersion: String,
      requestTimeout: Duration = .seconds(30), handshakeTimeout: Duration = .seconds(20)
    ) {
      self.executablePath = executablePath
      self.environment = environment
      self.clientVersion = clientVersion
      self.requestTimeout = requestTimeout
      self.handshakeTimeout = handshakeTimeout
    }
  }

  public enum Inbound: Sendable {
    case message(RpcMessage, generation: Int)
    case exited(generation: Int, status: ExitStatus, stderrTail: String)
  }

  public let inbound: AsyncStream<Inbound>
  private let inboundContinuation: AsyncStream<Inbound>.Continuation
  private let options: Options
  private var process: StreamingProcess?
  private var nextId = 0
  private var pending: [RpcId: CheckedContinuation<JSONValue, any Error>] = [:]
  public private(set) var generation = 0
  private var starting: Task<Void, any Error>?
  private var closed = false
  private let logger = CodexLog.logger("codex.app-server")

  public init(options: Options) {
    self.options = options
    (inbound, inboundContinuation) = AsyncStream<Inbound>.makeStream()
  }

  public var isRunning: Bool { process?.isRunning ?? false }

  /// Start the child and complete the handshake if it is not already running. Concurrent callers wait
  /// for the same start.
  public func ensureStarted() async throws {
    if closed { throw WorkspaceError(.endpointUnavailable, "Codex app server was disposed.") }
    if let process, process.isRunning { return }
    if let starting {
      try await starting.value
      return
    }
    let task = Task { try await self.launch() }
    starting = task
    defer { starting = nil }
    try await task.value
  }

  private func launch() async throws {
    let child = try StreamingProcess.start(
      executable: options.executablePath, arguments: ["app-server"], environment: options.environment)
    generation += 1
    process = child
    let generation = generation
    logger.info(
      "started pid \(child.processIdentifier, privacy: .public) generation \(generation, privacy: .public)")
    Task { await self.readLoop(child, generation: generation) }
    do {
      _ = try await request(
        "initialize", CodexProtocol.initializeParams(version: options.clientVersion),
        timeout: options.handshakeTimeout)
      try notify("initialized", [:])
    } catch {
      child.terminate()
      throw WorkspaceError(
        .incompatibleVersion, "Codex app-server handshake failed: \(WorkspaceError.from(error).message)",
        details: ["stderr": .string(child.recentStderr())])
    }
  }

  private func readLoop(_ child: StreamingProcess, generation: Int) async {
    var decoder = RpcDecoder()
    for await chunk in child.stdout {
      for message in decoder.push(chunk) { dispatch(message, generation: generation) }
    }
    let status = await child.waitForExit()
    handleExit(generation: generation, status: status, stderr: child.recentStderr())
  }

  private func dispatch(_ message: RpcMessage, generation: Int) {
    switch message {
    case .response(let id, let result):
      pending.removeValue(forKey: id)?.resume(returning: result)
    case .error(let id, let error):
      pending.removeValue(forKey: id)?.resume(
        throwing: WorkspaceError(
          .internalError, error.message,
          details: ["rpcCode": .number(Double(error.code)), "data": error.data ?? .null]))
    case .request, .notification:
      inboundContinuation.yield(.message(message, generation: generation))
    }
  }

  private func handleExit(generation: Int, status: ExitStatus, stderr: String) {
    logger.info(
      "exited generation \(generation, privacy: .public): \(String(describing: status), privacy: .public)")
    if self.generation == generation { process = nil }
    let failure = WorkspaceError(
      .endpointUnavailable, "codex app-server exited (\(status)).", details: ["reason": "exited"])
    for continuation in pending.values { continuation.resume(throwing: failure) }
    pending = [:]
    inboundContinuation.yield(.exited(generation: generation, status: status, stderrTail: stderr))
    if closed { inboundContinuation.finish() }
  }

  /// Send a request and await its result. A JSON-RPC error becomes `internal` with `rpcCode` in the
  /// details; a timeout becomes `endpoint_unavailable` with `reason: "timeout"`.
  public func request(
    _ method: String, _ params: JSONValue, timeout: Duration? = nil
  ) async throws -> JSONValue {
    guard let process, process.isRunning else {
      throw WorkspaceError(.endpointUnavailable, "codex app-server is not running.")
    }
    nextId += 1
    let id = RpcId.number(nextId)
    let line = try JSONRPC.encodeRequest(id: id, method: method, params: params)
    let timeout = timeout ?? options.requestTimeout
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try process.write(line)
      } catch {
        pending[id] = nil
        continuation.resume(throwing: error)
        return
      }
      Task {
        try? await Task.sleep(for: timeout)
        self.expire(id, method: method, after: timeout)
      }
    }
  }

  private func expire(_ id: RpcId, method: String, after timeout: Duration) {
    pending.removeValue(forKey: id)?.resume(
      throwing: WorkspaceError(
        .endpointUnavailable, "Codex did not answer \"\(method)\" within \(timeout).",
        details: ["reason": "timeout", "method": .string(method)]))
  }

  public func notify(_ method: String, _ params: JSONValue) throws {
    guard let process else { throw WorkspaceError(.endpointUnavailable, "codex app-server is not running.") }
    try process.write(try JSONRPC.encodeNotification(method: method, params: params))
  }

  /// Answer a server-initiated request by its exact id.
  public func respond(id: RpcId, result: JSONValue) throws {
    guard let process else { throw WorkspaceError(.endpointUnavailable, "codex app-server is not running.") }
    try process.write(try JSONRPC.encodeResponse(id: id, result: result))
  }

  public func respondError(id: RpcId, code: Int, message: String) throws {
    guard let process else { throw WorkspaceError(.endpointUnavailable, "codex app-server is not running.") }
    try process.write(
      try JSONRPC.encodeError(id: id, error: RpcError(code: code, message: message, data: nil)))
  }

  /// Close stdin, give the child two seconds to exit, then terminate it. Never a remote cancel: Codex
  /// keeps its own thread history.
  public func close() async {
    closed = true
    guard let process else {
      inboundContinuation.finish()
      return
    }
    process.closeInput()
    let exited = await withTaskGroup(of: Bool.self) { group in
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
    if !exited { process.terminate() }
  }
}

enum CodexLog {
  static func logger(_ category: String) -> os.Logger {
    os.Logger(subsystem: "com.cacheplane.b4app", category: category)
  }
}
