import Foundation
import Synchronization
import WorkspacePlatform

/// One immutable deployment binding for standard Agent Protocol REST, SSE and WebSocket.
/// All endpoints are selected from the standard inventory; callers cannot resolve arbitrary URLs.
public struct AgentProtocolClient: Sendable {
  public enum Authentication: Sendable, Equatable {
    case none
    case bearer(SecretRef)
    case header(name: String, reference: SecretRef)
  }

  public enum Method: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE", put = "PUT"
  }

  public enum Resource: Sendable {
    case agentsSearch, agent(String), agentSchemas(String)
    case threads, threadsSearch, thread(String), threadHistory(String), threadCopy(String)
    case runs, runsSearch, run(String), runWait(String), runStream(String), runCancel(String), runsWait,
      runsStream
    case threadStream(String), threadCommands(String)
    case storeItems, storeItemsSearch, storeNamespaces

    fileprivate var components: [String] {
      switch self {
      case .agentsSearch: ["agents", "search"]
      case .agent(let id): ["agents", id]
      case .agentSchemas(let id): ["agents", id, "schemas"]
      case .threads: ["threads"]
      case .threadsSearch: ["threads", "search"]
      case .thread(let id): ["threads", id]
      case .threadHistory(let id): ["threads", id, "history"]
      case .threadCopy(let id): ["threads", id, "copy"]
      case .runs: ["runs"]
      case .runsSearch: ["runs", "search"]
      case .run(let id): ["runs", id]
      case .runWait(let id): ["runs", id, "wait"]
      case .runStream(let id): ["runs", id, "stream"]
      case .runCancel(let id): ["runs", id, "cancel"]
      case .runsWait: ["runs", "wait"]
      case .runsStream: ["runs", "stream"]
      case .threadStream(let id): ["threads", id, "stream"]
      case .threadCommands(let id): ["threads", id, "commands"]
      case .storeItems: ["store", "items"]
      case .storeItemsSearch: ["store", "items", "search"]
      case .storeNamespaces: ["store", "namespaces"]
      }
    }
  }

  public typealias SecretResolver = @Sendable (SecretRef) async throws -> String?
  public let baseURL: URL
  public let decodingPolicy: AgentProtocolDecodingPolicy
  public var normalizedBaseURL: String { baseURL.absoluteString }
  private let authentication: Authentication
  private let resolveSecret: SecretResolver
  private let timeout: TimeInterval

  public init(
    baseURL: String, authentication: Authentication, decodingPolicy: AgentProtocolDecodingPolicy,
    resolveSecret: @escaping SecretResolver = { _ in nil }, timeout: TimeInterval = 15
  ) throws {
    self.baseURL = try Self.normalize(baseURL)
    self.decodingPolicy = decodingPolicy
    if case .header(let name, _) = authentication { try Self.validateHeaderName(name) }
    self.authentication = authentication
    self.resolveSecret = resolveSecret
    self.timeout = timeout
  }

  public init(
    baseURL: String, authentication: Authentication, decodingPolicy: AgentProtocolDecodingPolicy,
    secretStore: any SecretStore, timeout: TimeInterval = 15
  ) throws {
    try self.init(
      baseURL: baseURL, authentication: authentication, decodingPolicy: decodingPolicy,
      resolveSecret: { try await secretStore.read($0) },
      timeout: timeout)
  }

  private static func normalize(_ raw: String) throws -> URL {
    guard !raw.contains("\\"),
      !raw.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
      }),
      var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
      ["https", "http"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true,
      scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    else { throw AgentProtocolTransportError.invalidBaseURL }
    let path = parts.percentEncodedPath
    guard let decoded = path.removingPercentEncoding, !decoded.contains("\\"),
      !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0 == "." || $0 == ".."
      })
    else { throw AgentProtocolTransportError.invalidBaseURL }
    parts.scheme = scheme
    parts.host = host
    if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
    // A single optional delimiter is equivalent. Preserve repeated slashes and encoded components.
    if path.hasSuffix("/") && !path.hasSuffix("//") { parts.percentEncodedPath = String(path.dropLast()) }
    guard let result = parts.url else { throw AgentProtocolTransportError.invalidBaseURL }
    return result
  }

  public func url(for resource: Resource, query: [URLQueryItem] = [], webSocket: Bool = false) throws -> URL {
    let safe = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let components = try resource.components.map { component in
      guard !component.isEmpty, component != ".", component != "..",
        !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        let encoded = component.addingPercentEncoding(withAllowedCharacters: safe)
      else { throw AgentProtocolTransportError.invalidResourceID }
      return encoded
    }
    guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw AgentProtocolTransportError.invalidBaseURL
    }
    parts.percentEncodedPath +=
      (parts.percentEncodedPath.hasSuffix("/") ? "" : "/") + components.joined(separator: "/")
    if !query.isEmpty { parts.queryItems = query }
    if webSocket { parts.scheme = parts.scheme == "https" ? "wss" : "ws" }
    guard let result = parts.url else { throw AgentProtocolTransportError.invalidResourceID }
    return result
  }

  private static func validateHeaderName(_ name: String) throws {
    let token = CharacterSet(
      charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    let forbidden: Set<String> = [
      "host", "cookie", "cookie2", "content-length", "transfer-encoding", "connection", "upgrade", "te",
      "trailer", "expect", "accept", "accept-encoding", "content-type", "proxy-authorization",
      "proxy-authenticate", "keep-alive", "origin", "referer", "user-agent", "last-event-id", "forwarded",
      "x-http-method-override", "x-method-override",
    ]
    let lower = name.lowercased()
    guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains), !forbidden.contains(lower),
      !lower.hasPrefix("sec-"), !lower.hasPrefix("proxy-"), !lower.hasPrefix("content-"),
      !lower.hasPrefix("accept-"), !lower.hasPrefix("x-forwarded-")
    else { throw AgentProtocolTransportError.invalidHeaderName }
  }

  private func request(
    _ method: Method, _ resource: Resource, body: AgentProtocol.Value?, query: [URLQueryItem], accept: String,
    webSocket: Bool = false
  ) async throws -> URLRequest {
    var request = URLRequest(url: try url(for: resource, query: query, webSocket: webSocket))
    request.httpMethod = method.rawValue
    request.timeoutInterval = timeout
    request.httpShouldHandleCookies = false
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let body {
      do { request.httpBody = try JSONEncoder().encode(body) } catch {
        throw AgentProtocolTransportError.invalidResponse
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let name: String
    let reference: SecretRef
    switch authentication {
    case .none: return request
    case .bearer(let ref): name = "Authorization"; reference = ref
    case .header(let header, let ref): name = header; reference = ref
    }
    let secret: String
    do {
      guard let resolved = try await resolveSecret(reference), !resolved.isEmpty else {
        throw AgentProtocolTransportError.credentialUnavailable
      }
      secret = resolved
    } catch { throw AgentProtocolTransportError.credentialUnavailable }
    guard !secret.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw AgentProtocolTransportError.invalidHeaderValue
    }
    let value: String
    if case .bearer = authentication { value = "Bearer " + secret } else { value = secret }
    request.setValue(value, forHTTPHeaderField: name)
    return request
  }

  private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    return configuration
  }

  public func request(
    _ method: Method, _ resource: Resource, body: AgentProtocol.Value? = nil, query: [URLQueryItem] = []
  ) async throws -> AgentProtocol.Value {
    let request = try await request(method, resource, body: body, query: query, accept: "application/json")
    let session = URLSession(configuration: configuration())
    defer { session.invalidateAndCancel() }
    do {
      let (data, response) = try await session.data(for: request, delegate: RedirectRefusal.shared)
      guard let response = response as? HTTPURLResponse else {
        throw AgentProtocolTransportError.invalidResponse
      }
      guard (200..<300).contains(response.statusCode) else {
        throw AgentProtocolTransportError.http(status: response.statusCode)
      }
      if data.isEmpty { return .null }
      do { return try JSONDecoder().decode(AgentProtocol.Value.self, from: data) } catch {
        throw AgentProtocolTransportError.invalidResponse
      }
    } catch { throw AgentProtocolTransportError.sanitized(error) }
  }

  public func searchAgents(body: AgentProtocol.Value = .object([:])) async throws -> [AgentProtocol.Agent] {
    try decode([AgentProtocol.Agent].self, value: await request(.post, .agentsSearch, body: body))
  }

  public func agent(id: String) async throws -> AgentProtocol.Agent {
    try decode(AgentProtocol.Agent.self, value: await request(.get, .agent(id)))
  }

  public func schemas(agentID: String) async throws -> AgentProtocol.Value {
    try await request(.get, .agentSchemas(agentID))
  }

  private func decode<T: Decodable>(_ type: T.Type, value: AgentProtocol.Value) throws -> T {
    do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) } catch {
      throw AgentProtocolTransportError.invalidResponse
    }
  }

  public func command(threadID: String, command: AgentProtocol.Command) async throws -> AgentProtocolFrame {
    let value = try await request(.post, .threadCommands(threadID), body: .object(command.raw))
    let frame = try AgentProtocolDecoder.decode(JSONEncoder().encode(value), policy: decodingPolicy)
    switch frame {
    case .success(let success):
      guard success.id == command.id else { throw AgentProtocolTransportError.correlationMismatch }
    case .failure(let failure):
      guard failure.id == command.id else { throw AgentProtocolTransportError.correlationMismatch }
    default: throw AgentProtocolTransportError.invalidResponse
    }
    return frame
  }

  public struct Observation: Sendable {
    public let events: AsyncThrowingStream<AgentProtocolReceivedEvent, any Error>
    public let cancel: @Sendable () -> Void
  }

  public func observe(threadID: String, body: AgentProtocol.Value) async throws -> Observation {
    let request = try await request(
      .post, .threadStream(threadID), body: body, query: [], accept: "text/event-stream")
    let session = URLSession(configuration: configuration())
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusal.shared)
      guard let response = response as? HTTPURLResponse else {
        throw AgentProtocolTransportError.invalidResponse
      }
      guard (200..<300).contains(response.statusCode) else {
        throw AgentProtocolTransportError.http(status: response.statusCode)
      }
      guard
        response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(
          in: .whitespaces
        ).lowercased() == "text/event-stream"
      else { throw AgentProtocolTransportError.invalidResponse }
      let (events, continuation) = AsyncThrowingStream<AgentProtocolReceivedEvent, any Error>.makeStream()
      let reader = Task {
        defer { session.invalidateAndCancel() }
        do {
          var parser = SSEParser()
          for try await byte in bytes {
            try Task.checkCancellation()
            for event in parser.push([byte]) {
              continuation.yield(try AgentProtocolDecoder.decode(event, policy: decodingPolicy))
            }
          }
          _ = parser.flush()
          continuation.finish()
        } catch { continuation.finish(throwing: AgentProtocolTransportError.sanitized(error)) }
      }
      continuation.onTermination = { _ in
        reader.cancel(); session.invalidateAndCancel()
      }
      return Observation(
        events: events,
        cancel: {
          reader.cancel(); session.invalidateAndCancel()
        })
    } catch {
      session.invalidateAndCancel()
      throw AgentProtocolTransportError.sanitized(error)
    }
  }

  /// Canceling send or receive closes this local socket. If a command was dispatched, reconcile
  /// its server outcome separately; cancellation sends no protocol Stop.
  public final class WebSocket: Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let decodingPolicy: AgentProtocolDecodingPolicy
    fileprivate init(
      task: URLSessionWebSocketTask, session: URLSession, decodingPolicy: AgentProtocolDecodingPolicy
    ) {
      self.task = task; self.session = session
      self.decodingPolicy = decodingPolicy
    }

    public func send(_ command: AgentProtocol.Command) async throws {
      do {
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          let data = try JSONEncoder().encode(command)
          try Task.checkCancellation()
          try await task.send(.string(String(decoding: data, as: UTF8.self)))
          try Task.checkCancellation()
        } onCancel: {
          // Local socket cleanup only: a command may already have been dispatched. This neither
          // sends a protocol Stop nor establishes a server Run outcome.
          self.close()
        }
      } catch { throw AgentProtocolTransportError.sanitized(error) }
    }

    public func receive() async throws -> AgentProtocolFrame {
      do {
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          let message = try await task.receive()
          try Task.checkCancellation()
          let frame: AgentProtocolFrame
          switch message {
          case .data(let data): frame = try AgentProtocolDecoder.decode(data, policy: decodingPolicy)
          case .string(let text):
            frame = try AgentProtocolDecoder.decode(Data(text.utf8), policy: decodingPolicy)
          @unknown default: throw AgentProtocolTransportError.invalidResponse
          }
          try Task.checkCancellation()
          return frame
        } onCancel: {
          self.close()
        }
      } catch { throw AgentProtocolTransportError.sanitized(error) }
    }

    public func close() { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
    deinit { task.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
  }

  public func connect(threadID: String) async throws -> WebSocket {
    let request = try await request(
      .get, .threadStream(threadID), body: nil, query: [], accept: "application/json", webSocket: true)
    let delegate = AgentProtocolWebSocketDelegate()
    let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
    let task = session.webSocketTask(with: request)
    task.resume()
    do {
      try await withTaskCancellationHandler {
        try await delegate.opened()
      } onCancel: {
        task.cancel(); session.invalidateAndCancel()
      }
      return WebSocket(task: task, session: session, decodingPolicy: decodingPolicy)
    } catch {
      session.invalidateAndCancel()
      throw AgentProtocolTransportError.sanitized(error)
    }
  }
}

/// Await the actual RFC 6455 upgrade, and refuse redirects even when the target shares an origin.
private final class AgentProtocolWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
  private struct State {
    var result: Result<Void, AgentProtocolTransportError>?
    var waiter: CheckedContinuation<Void, any Error>?
  }
  private let state = Mutex(State())

  func opened() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let result: Result<Void, AgentProtocolTransportError>? = state.withLock { state in
        if let result = state.result { return result }
        state.waiter = continuation
        return nil
      }
      if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
    }
  }

  private func settle(_ result: Result<Void, AgentProtocolTransportError>) {
    let waiter = state.withLock { state in
      guard state.result == nil else { return nil as CheckedContinuation<Void, any Error>? }
      state.result = result
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(with: result.mapError { $0 as any Error })
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
  ) { settle(.success(())) }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
      settle(.failure(.http(status: response.statusCode)))
    } else {
      settle(.failure(.unavailable(code: (error as? URLError)?.code.rawValue)))
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
    settle(.failure(.http(status: response.statusCode)))
  }
}
