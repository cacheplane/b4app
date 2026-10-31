import Foundation
import Synchronization
import WorkspaceProtocol

/// Agent Protocol HTTP client: JSON requests and SSE streams over URLSession. The endpoint secret is
/// resolved lazily, attached only to requests for the configured origin, and never follows a
/// redirect (D-022).
public struct B4HTTPClient: Sendable {
  public typealias AuthorizationProvider = @Sendable () async throws -> String?

  public let baseURL: URL
  public let origin: String
  private let authorization: AuthorizationProvider
  private let session: URLSession
  private let streamIdleTimeout: TimeInterval

  public init(
    baseURL: String, authorization: String? = nil, session: URLSession? = nil, timeout: TimeInterval = 15
  ) throws {
    try self.init(
      baseURL: baseURL, authorizationProvider: { authorization }, session: session, timeout: timeout)
  }

  public init(
    baseURL: String, authorizationProvider: @escaping AuthorizationProvider, session: URLSession? = nil,
    timeout: TimeInterval = 15, streamIdleTimeout: TimeInterval = 90
  ) throws {
    let url = try Self.assertAllowedOrigin(baseURL)
    self.baseURL = url
    self.origin = Self.origin(of: url)
    self.authorization = authorizationProvider
    self.streamIdleTimeout = streamIdleTimeout
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = timeout
      configuration.httpShouldSetCookies = false
      self.session = URLSession(configuration: configuration)
    }
  }

  static func origin(of url: URL) -> String {
    var origin = "\(url.scheme ?? "http")://\(url.host ?? "")"
    if let port = url.port { origin += ":\(port)" }
    return origin
  }

  /// Plain HTTP is allowed only for loopback; remote endpoints must use HTTPS (spec section 3.2).
  public static func assertAllowedOrigin(_ baseURL: String) throws -> URL {
    guard let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host else {
      throw WorkspaceError(.protocolInvalid, "Invalid B4 base URL: \(baseURL)")
    }
    if scheme == "https" || (scheme == "http" && isLoopback(host)) { return url }
    throw WorkspaceError(
      .protocolInvalid, "Remote B4 endpoints must use HTTPS; plain HTTP is allowed only for loopback.",
      details: ["baseUrl": .string(baseURL)])
  }

  public static func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
  }

  /// A stored secret becomes a bearer header unless it already names a scheme (`Bearer x`, `Basic y`).
  public static func authorizationHeader(secret: String) -> String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains(" ") ? trimmed : "Bearer \(trimmed)"
  }

  /// Resolve a path against the base, preserving any deployment base path.
  public func resolve(_ path: String) -> URL {
    var base = baseURL.absoluteString
    if !base.hasSuffix("/") { base += "/" }
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return URL(string: relative, relativeTo: URL(string: base))!.absoluteURL
  }

  private func request(
    _ method: String, _ path: String, body: JSONValue?, accept: String
  ) async throws
    -> URLRequest
  {
    var request = URLRequest(url: resolve(path))
    request.httpMethod = method
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONCoding.encoder.encode(body)
    }
    if Self.origin(of: request.url!) == origin, let header = try await authorization() {
      request.setValue(header, forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func unavailable(_ error: any Error) -> WorkspaceError {
    var details: [String: JSONValue] = ["origin": .string(origin)]
    if let urlError = error as? URLError {
      details["urlError"] = .number(Double(urlError.code.rawValue))
      if urlError.code == .timedOut { details["timeout"] = true }
    }
    return WorkspaceError(
      .endpointUnavailable, "Could not reach \(origin): \(error.localizedDescription)",
      details: .object(details))
  }

  // MARK: - JSON

  /// One JSON request. Transport failures are `endpoint_unavailable`; HTTP statuses are returned
  /// for the caller to map (`B4Protocol.error`). A non-JSON body decodes as nil.
  public func json(
    _ method: String, _ path: String, body: JSONValue? = nil
  ) async throws -> (
    status: Int, body: JSONValue?
  ) {
    let request = try await request(method, path, body: body, accept: "application/json")
    do {
      let (data, response) = try await session.data(for: request, delegate: RedirectRefusal.shared)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (status, try? JSONCoding.decoder.decode(JSONValue.self, from: data))
    } catch let error as WorkspaceError {
      throw error
    } catch {
      throw unavailable(error)
    }
  }

  public struct Health: Decodable, Sendable, Equatable {
    public var status: String
  }

  public struct Readiness: Decodable, Sendable, Equatable {
    public var status: String
    public var checks: [String: JSONValue]?
  }

  public func health() async throws -> Health {
    let (status, body) = try await json("GET", "/healthz")
    guard let body, let health = try? body.decode(Health.self) else {
      throw WorkspaceError(
        .incompatibleVersion, "healthz did not return the expected JSON (status \(status)).",
        details: ["status": .number(Double(status))])
    }
    return health
  }

  public func ready() async throws -> Readiness {
    let (status, body) = try await json("GET", "/readyz")
    guard let body, let readiness = try? body.decode(Readiness.self) else {
      throw WorkspaceError(
        .incompatibleVersion, "readyz did not return JSON (status \(status)).",
        details: ["status": .number(Double(status))])
    }
    return readiness
  }

  // MARK: - Streams

  /// An open response. `status` is known once the headers arrived; `bytes` delivers body chunks as
  /// they are received and finishes when the server closes the response or the transport fails.
  public struct StreamHandle: Sendable {
    public let status: Int
    public let contentType: String?
    public let bytes: AsyncThrowingStream<[UInt8], any Error>
    public let cancel: @Sendable () -> Void

    public var isEventStream: Bool { contentType?.lowercased().hasPrefix("text/event-stream") == true }

    /// Drain the body (for error responses) and decode it as JSON when possible.
    public func collectJSON() async -> JSONValue? {
      var data = Data()
      do {
        for try await chunk in bytes { data.append(contentsOf: chunk) }
      } catch {
        return nil
      }
      return try? JSONCoding.decoder.decode(JSONValue.self, from: data)
    }
  }

  /// Open a streaming request and return once the response headers arrive. Waiting is bounded by
  /// the session's request timeout; a timeout here means the server never answered.
  public func stream(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> StreamHandle {
    var request = try await request(method, path, body: body, accept: "text/event-stream")
    request.timeoutInterval = 30
    let (stream, continuation) = AsyncThrowingStream<[UInt8], any Error>.makeStream()
    let delegate = StreamingDelegate(body: continuation)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = streamIdleTimeout
    configuration.httpShouldSetCookies = false
    let owned = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    let task = owned.dataTask(with: request)
    continuation.onTermination = { _ in
      task.cancel()
      owned.finishTasksAndInvalidate()
    }
    task.resume()
    let headers: (Int, String?)
    do {
      headers = try await delegate.headers()
    } catch {
      owned.invalidateAndCancel()
      throw unavailable(error)
    }
    return StreamHandle(
      status: headers.0, contentType: headers.1, bytes: stream,
      cancel: {
        task.cancel()
        owned.finishTasksAndInvalidate()
      })
  }
}

/// Refuses every redirect so a credential is never replayed to another host or path.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
  static let shared = RedirectRefusal()

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Delivers response headers to one waiter and body chunks to an `AsyncThrowingStream`.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private struct State {
    var headers: (Int, String?)?
    var failure: (any Error)?
    var waiter: CheckedContinuation<(Int, String?), any Error>?
    var finished = false
  }

  private let state = Mutex(State())
  private let body: AsyncThrowingStream<[UInt8], any Error>.Continuation

  init(body: AsyncThrowingStream<[UInt8], any Error>.Continuation) {
    self.body = body
  }

  func headers() async throws -> (Int, String?) {
    try await withCheckedThrowingContinuation { continuation in
      let settled: Result<(Int, String?), any Error>? = state.withLock { state in
        if let headers = state.headers { return .success(headers) }
        if let failure = state.failure { return .failure(failure) }
        state.waiter = continuation
        return nil
      }
      if let settled { continuation.resume(with: settled) }
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let http = response as? HTTPURLResponse
    let headers = (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type"))
    let waiter: CheckedContinuation<(Int, String?), any Error>? = state.withLock { state in
      state.headers = headers
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(returning: headers)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    body.yield([UInt8](data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let failure = error ?? URLError(.badServerResponse)
    let waiter: CheckedContinuation<(Int, String?), any Error>? = state.withLock { state in
      guard !state.finished else { return nil }
      state.finished = true
      if state.headers == nil { state.failure = failure }
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume(throwing: failure)
    body.finish(throwing: error)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
