import Foundation
import WorkspaceProtocol

/// `HubAPI` over `URLSession`. The token closure runs for every request, so the secret stays in the
/// caller's `SecretStore` and is never held here; a `nil` token sends no `Authorization` header, and
/// the hub answers 401, which is the right outcome for a device that is not enrolled. `enroll` and the
/// sign-in calls authenticate with a code or a credential and never ask for the token; `enroll` sends a
/// bearer only when handed one to merge. Nothing here logs a request or an answer, so no token or
/// WebAuthn payload can reach a log.
public final class HTTPHubAPI: HubAPI {
  private let baseURL: URL
  private let token: @Sendable () async throws -> String?
  private let session: URLSession

  public init(
    baseURL: URL, token: @escaping @Sendable () async throws -> String?, session: URLSession = .shared
  ) {
    self.baseURL = baseURL
    self.token = token
    self.session = session
  }

  public func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try await enroll(request, replacingToken: nil)
  }

  public func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse {
    try await send(.post, "v1/enroll", body: request, authenticated: false, bearer: token)
  }

  public func me() async throws -> MeResponse {
    try await send(.get, "v1/me")
  }

  public func push(_ changes: [SyncChange]) async throws -> PushResponse {
    try await send(.post, "v1/changes", body: PushBody(changes: changes))
  }

  public func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await send(
      .get, "v1/changes",
      query: [
        URLQueryItem(name: "after", value: String(after)),
        URLQueryItem(name: "limit", value: String(limit)),
        URLQueryItem(name: "wait", value: String(wait)),
      ],
      timeout: TimeInterval(max(wait, 0) + 5))
  }

  public func snapshot() async throws -> SnapshotResponse {
    // One document holding the whole mirror, so it gets a longer timeout than a page.
    try await send(.get, "v1/snapshot", timeout: 120)
  }

  public func devices() async throws -> [DeviceInfo] {
    let response: DevicesResponse = try await send(.get, "v1/devices")
    return response.devices
  }

  public func mintPairingCode() async throws -> PairingCodeResponse {
    try await send(.post, "v1/pairing-codes", body: EmptyBody())
  }

  public func revokeSelf() async throws {
    _ = try await perform(.delete, "v1/devices/self")
  }

  /// Registers this phone's APNs token (hex) with the hub (D-122). `environment` is `sandbox` or
  /// `production`; `bundleId` is the app's own, so the hub needs no per-flavour setting. Only the iOS app
  /// calls this, so it is not on `HubAPI`. The hub answers 403 `forbidden` for a device that is not an
  /// iPhone. The token is a credential for pushes: callers must not log it.
  public func registerPushToken(_ token: String, environment: String, bundleId: String) async throws {
    let body = PushTokenBody(token: token, environment: environment, bundleId: bundleId)
    let encoded: Data
    do {
      encoded = try JSONCoding.encoder.encode(body)
    } catch {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The request could not be encoded.", status: 0)
    }
    _ = try await perform(.post, "v1/devices/self/push-token", body: encoded)
  }

  // MARK: - Signing in

  public func authConfig() async throws -> AuthConfig {
    try await send(.get, "v1/auth/config", authenticated: false)
  }

  public func passkeyBegin() async throws -> PasskeyBeginResponse {
    try await send(.post, "v1/auth/passkey/begin", authenticated: false)
  }

  public func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try await send(.post, "v1/auth/passkey/finish", body: request, authenticated: false)
  }

  public func appleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try await send(.post, "v1/auth/apple/begin", body: request, authenticated: false)
  }

  public func appleNative(_ request: AppleNativeRequest) async throws -> AuthSession {
    try await send(.post, "v1/auth/apple/native", body: request, authenticated: false)
  }

  public func handoff(_ request: HandoffRequest) async throws -> AuthSession {
    try await send(.post, "v1/auth/handoff", body: request, authenticated: false)
  }

  // MARK: - The signed-in account

  public func setProfile(_ request: ProfileRequest) async throws -> MeResponse {
    try await send(.put, "v1/me/profile", body: request)
  }

  public func identities() async throws -> [Identity] {
    try await me().identities
  }

  public func addPasskeyBegin(stepUp: String?) async throws -> AddPasskeyBeginResponse {
    try await send(.post, "v1/me/passkeys/begin", stepUp: stepUp)
  }

  public func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity {
    try await send(.post, "v1/me/passkeys/finish", body: request)
  }

  public func removeIdentity(_ id: String, stepUp: String?) async throws {
    // An identity id is a UUID; anything that could change which route is called is refused here.
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
      throw HubError(
        kind: "request_error", code: "invalid_request", message: "That is not an identity id.", status: 0)
    }
    _ = try await perform(.delete, "v1/me/identities/\(id)", stepUp: stepUp)
  }

  public func appleLinkBegin(_ request: AppleBeginRequest, stepUp: String?) async throws -> AppleBeginResponse
  {
    try await send(.post, "v1/me/apple", body: request, stepUp: stepUp)
  }

  public func appleLinkNative(_ request: AppleLinkNativeRequest) async throws -> Identity {
    try await send(.post, "v1/me/apple/native", body: request)
  }

  public func appleLinkHandoff(_ request: AppleLinkHandoffRequest) async throws -> Identity {
    try await send(.post, "v1/me/apple/handoff", body: request)
  }

  public func endSession() async throws {
    _ = try await perform(.delete, "v1/sessions/self")
  }

  public func deleteAccount(stepUp: String?) async throws {
    _ = try await perform(.delete, "v1/me", stepUp: stepUp)
  }

  // MARK: - Step-up

  public func stepUpPasskeyBegin() async throws -> StepUpBeginResponse {
    try await send(.post, "v1/me/step-up/passkey/begin")
  }

  public func stepUpPasskeyFinish(_ request: StepUpFinishRequest) async throws -> StepUpResponse {
    try await send(.post, "v1/me/step-up/passkey/finish", body: request)
  }

  public func stepUpAppleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try await send(.post, "v1/me/step-up/apple", body: request)
  }

  public func stepUpAppleNative(_ request: StepUpAppleNativeRequest) async throws -> StepUpResponse {
    try await send(.post, "v1/me/step-up/apple/native", body: request)
  }

  public func stepUpAppleHandoff(_ request: AppleLinkHandoffRequest) async throws -> StepUpResponse {
    try await send(.post, "v1/me/step-up/apple/handoff", body: request)
  }

  public func stepUpCode(_ request: StepUpCodeRequest) async throws -> StepUpResponse {
    try await send(.post, "v1/me/step-up/code", body: request)
  }

  // MARK: - Plumbing

  private struct PushTokenBody: Encodable {
    var token: String
    var environment: String
    var bundleId: String
  }

  private struct PushBody: Encodable {
    var changes: [SyncChange]
  }

  private struct EmptyBody: Encodable {}

  private enum Method: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
  }

  private func send<Response: Decodable>(
    _ method: Method, _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30,
    authenticated: Bool = true, bearer: String? = nil, stepUp: String? = nil
  ) async throws -> Response {
    let (data, status) = try await perform(
      method, path, query: query, timeout: timeout, authenticated: authenticated, bearer: bearer,
      stepUp: stepUp)
    return try decode(data, status: status)
  }

  private func send<Response: Decodable, Body: Encodable>(
    _ method: Method, _ path: String, body: Body, authenticated: Bool = true, bearer: String? = nil,
    stepUp: String? = nil
  ) async throws -> Response {
    let encoded: Data
    do {
      encoded = try JSONCoding.encoder.encode(body)
    } catch {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The request could not be encoded.", status: 0)
    }
    let (data, status) = try await perform(
      method, path, body: encoded, authenticated: authenticated, bearer: bearer, stepUp: stepUp)
    return try decode(data, status: status)
  }

  private func decode<Response: Decodable>(_ data: Data, status: Int) throws -> Response {
    do {
      return try JSONCoding.decoder.decode(Response.self, from: data)
    } catch {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The hub's response could not be read.",
        status: status)
    }
  }

  private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The hub URL is invalid.", status: 0)
    }
    var prefix = components.path
    while prefix.hasSuffix("/") { prefix.removeLast() }
    components.path = prefix + "/" + path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The hub URL is invalid.", status: 0)
    }
    return url
  }

  /// The header a change that needs a step-up carries its grant in (`Hub/API.md`, *Step-up*).
  static let stepUpHeader = "B4-Step-Up"

  /// Sends one request and returns the body and status of a 2xx answer; any other answer throws.
  /// `stepUp` is a step-up grant, sent in `B4-Step-Up` when given.
  private func perform(
    _ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
    timeout: TimeInterval = 30, authenticated: Bool = true, bearer: String? = nil, stepUp: String? = nil
  ) async throws -> (Data, Int) {
    var request = URLRequest(url: try url(path, query: query), timeoutInterval: timeout)
    request.httpMethod = method.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    // `bearer` is a token the caller holds and wants sent (a merge on enroll); otherwise an
    // authenticated call reads the stored one. An unauthenticated call with no `bearer` sends none.
    if let bearer {
      request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    } else if authenticated, let token = try await token() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let stepUp { request.setValue(stepUp, forHTTPHeaderField: Self.stepUpHeader) }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw HubError(
        kind: "execution_error", code: "transport",
        message: (error as? URLError)?.localizedDescription
          ?? "The hub could not be reached.", status: 0)
    }
    guard let http = response as? HTTPURLResponse else {
      throw HubError(
        kind: "execution_error", code: "transport", message: "The hub's answer was not HTTP.", status: 0)
    }
    guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
    return (data, http.statusCode)
  }

  private static func error(from data: Data, status: Int) -> HubError {
    if let envelope = try? JSONCoding.decoder.decode(HubErrorBody.self, from: data) {
      return HubError(
        kind: envelope.error.kind, code: envelope.error.details?.code ?? "http_\(status)",
        message: envelope.error.message, status: status, retryAfterMs: envelope.error.details?.retryAfterMs,
        reason: envelope.error.details?.reason, methods: envelope.error.details?.methods)
    }
    return HubError(
      kind: status >= 500 ? "execution_error" : "request_error", code: "http_\(status)",
      message: "The hub answered HTTP \(status).", status: status)
  }
}
