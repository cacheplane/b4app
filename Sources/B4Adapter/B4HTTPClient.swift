import Foundation
import WorkspaceProtocol

/// Minimal Agent Protocol HTTP client: health and readiness now, thread operations in M3.
public struct B4HTTPClient: Sendable {
  public let baseURL: URL
  public let origin: String
  /// Full Authorization header value, held in memory only and sent only to the configured origin.
  private let authorization: String?
  private let session: URLSession

  public init(
    baseURL: String, authorization: String? = nil, session: URLSession? = nil, timeout: TimeInterval = 10
  ) throws {
    let url = try Self.assertAllowedOrigin(baseURL)
    self.baseURL = url
    self.origin = Self.origin(of: url)
    self.authorization = authorization
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = timeout
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
    let loopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    if scheme == "https" || (scheme == "http" && loopback) { return url }
    throw WorkspaceError(
      .protocolInvalid, "Remote B4 endpoints must use HTTPS; plain HTTP is allowed only for loopback.",
      details: ["baseUrl": .string(baseURL)])
  }

  /// Resolve a path against the base, preserving any deployment base path.
  public func resolve(_ path: String) -> URL {
    var base = baseURL.absoluteString
    if !base.hasSuffix("/") { base += "/" }
    let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
    return URL(string: relative, relativeTo: URL(string: base))!.absoluteURL
  }

  private func request(_ method: String, _ path: String) -> URLRequest {
    var request = URLRequest(url: resolve(path))
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let authorization, Self.origin(of: request.url!) == origin {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func fetch(_ method: String, _ path: String) async throws -> (Int, Data) {
    do {
      let (data, response) = try await session.data(for: request(method, path))
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      return (status, data)
    } catch {
      throw WorkspaceError(.endpointUnavailable, "Could not reach \(origin): \(error.localizedDescription)")
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
    let (status, data) = try await fetch("GET", "/healthz")
    guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
      throw WorkspaceError(
        .incompatibleVersion, "healthz did not return the expected JSON (status \(status)).",
        details: ["status": .number(Double(status))])
    }
    return health
  }

  public func ready() async throws -> Readiness {
    let (status, data) = try await fetch("GET", "/readyz")
    guard let readiness = try? JSONDecoder().decode(Readiness.self, from: data) else {
      throw WorkspaceError(
        .incompatibleVersion, "readyz did not return JSON (status \(status)).",
        details: ["status": .number(Double(status))])
    }
    return readiness
  }
}
