import Foundation
import WorkspaceProtocol

public enum DesyncReason: Sendable, Equatable {
  case gap, epochChanged
}

public struct RequestOptions: Sendable {
  public var operationId: String?
  public var timeout: Duration
  public init(operationId: String? = nil, timeout: Duration = .seconds(15)) {
    self.operationId = operationId
    self.timeout = timeout
  }
}

/// Typed client over any `WorkspaceTransport`. One actor owns the pending request table, the event
/// cursor, and fan-out streams for events and desync signals.
public actor WorkspaceClient {
  private let transport: any WorkspaceTransport
  private var pending: [String: CheckedContinuation<ResponseEnvelope, any Error>] = [:]
  private var cursor = EventCursor()
  private var counter = 0
  private var helloContinuations: [CheckedContinuation<HelloEnvelope, any Error>] = []
  private var hello: HelloEnvelope?
  private var closed = false
  private var closeError: WorkspaceError?
  private var eventContinuations: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
  private var desyncContinuations: [UUID: AsyncStream<DesyncReason>.Continuation] = [:]
  private var readerTask: Task<Void, Never>?

  public init(transport: any WorkspaceTransport) {
    self.transport = transport
    Task { await self.startReading() }
  }

  private func startReading() {
    guard readerTask == nil else { return }
    readerTask = Task { [transport] in
      for await line in transport.incoming {
        self.handle(line: line)
      }
      self.handleClosed(error: nil)
    }
  }

  /// Resolves once the coordinator's hello has been received.
  public func ready() async throws -> HelloEnvelope {
    if let hello { return hello }
    if let closeError { throw closeError }
    return try await withCheckedThrowingContinuation { continuation in
      helloContinuations.append(continuation)
    }
  }

  public var currentCursor: EventCursor { cursor }

  public func resetCursor(epoch: String, sequence: Int) {
    cursor.reset(epoch: epoch, sequence: sequence)
  }

  /// Send a typed command and decode its result. Coordinator errors surface as `WorkspaceError`.
  public func request<C: WorkspaceCommand>(
    _ command: C.Type, _ params: C.Params, options: RequestOptions = RequestOptions()
  ) async throws -> C.Result {
    if let closeError { throw closeError }
    counter += 1
    let requestId = "\(ProcessInfo.processInfo.processIdentifier)-\(counter)-\(UUID().uuidString.prefix(8))"
    let envelope = CommandEnvelope(
      requestId: requestId, method: C.method.rawValue, params: try JSONValue(encoding: params),
      operationId: options.operationId)
    let line = try NDJSON.encodeLine(envelope)
    let response: ResponseEnvelope = try await withCheckedThrowingContinuation { continuation in
      pending[requestId] = continuation
      Task {
        do {
          try await transport.send(line)
        } catch {
          self.fail(requestId: requestId, with: WorkspaceError.from(error))
        }
      }
      Task {
        try? await Task.sleep(for: options.timeout)
        self.fail(
          requestId: requestId,
          with: WorkspaceError(
            .endpointUnavailable, "Request \"\(C.method.rawValue)\" timed out after \(options.timeout)."))
      }
    }
    if response.ok {
      guard let result = response.result else {
        throw WorkspaceError(.protocolInvalid, "Response for \"\(C.method.rawValue)\" carried no result.")
      }
      do {
        return try result.decode(C.Result.self)
      } catch {
        throw WorkspaceError(
          .protocolInvalid, "Invalid result for \"\(C.method.rawValue)\".",
          details: ["reason": .string(String(describing: error))])
      }
    }
    throw response.error ?? WorkspaceError(.internalError, "Coordinator returned an error without details.")
  }

  /// Ordered events after the cursor. Duplicates are dropped; gaps and epoch changes go to `desync()`.
  public func events() -> AsyncStream<EventEnvelope> {
    let id = UUID()
    return AsyncStream { continuation in
      eventContinuations[id] = continuation
      continuation.onTermination = { _ in Task { await self.removeEventContinuation(id) } }
    }
  }

  /// Fired when the stream position can no longer be trusted; fetch `events.snapshot` and reset the cursor.
  public func desync() -> AsyncStream<DesyncReason> {
    let id = UUID()
    return AsyncStream { continuation in
      desyncContinuations[id] = continuation
      continuation.onTermination = { _ in Task { await self.removeDesyncContinuation(id) } }
    }
  }

  public func close() async {
    await transport.close()
    handleClosed(error: nil)
  }

  // MARK: - Internals

  private func removeEventContinuation(_ id: UUID) { eventContinuations[id] = nil }
  private func removeDesyncContinuation(_ id: UUID) { desyncContinuations[id] = nil }

  private func fail(requestId: String, with error: WorkspaceError) {
    if let continuation = pending.removeValue(forKey: requestId) {
      continuation.resume(throwing: error)
    }
  }

  private func handle(line: Data) {
    guard let message = ServerEnvelope.decode(line) else { return }
    switch message {
    case .hello(let hello):
      self.hello = hello
      cursor.reset(epoch: hello.epoch, sequence: hello.sequence)
      let waiting = helloContinuations
      helloContinuations = []
      for continuation in waiting { continuation.resume(returning: hello) }
    case .response(let response):
      if let continuation = pending.removeValue(forKey: response.requestId) {
        continuation.resume(returning: response)
      }
    case .event(let event):
      switch cursor.advance(epoch: event.epoch, sequence: event.sequence) {
      case .ok:
        for continuation in eventContinuations.values { continuation.yield(event) }
      case .duplicate:
        break
      case .gap:
        for continuation in desyncContinuations.values { continuation.yield(.gap) }
      case .epochChanged:
        for continuation in desyncContinuations.values { continuation.yield(.epochChanged) }
      }
    }
  }

  private func handleClosed(error: Error?) {
    guard !closed else { return }
    closed = true
    let failure = WorkspaceError(
      .endpointUnavailable,
      error.map { String(describing: $0) } ?? transport.unavailableReason ?? "Coordinator connection closed.")
    closeError = failure
    for continuation in pending.values { continuation.resume(throwing: failure) }
    pending = [:]
    for continuation in helloContinuations { continuation.resume(throwing: failure) }
    helloContinuations = []
    for continuation in eventContinuations.values { continuation.finish() }
    for continuation in desyncContinuations.values { continuation.finish() }
    eventContinuations = [:]
    desyncContinuations = [:]
  }
}
