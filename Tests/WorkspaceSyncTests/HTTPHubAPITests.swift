import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

/// Answers requests for one host from a registered handler, so tests running in parallel never see
/// each other's traffic. Registered only on a dedicated ephemeral session, never on `.shared`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Reply {
    var status: Int
    var body: Data
    var error: URLError?
    var responseURL: URL?
    var redirectURL: URL?

    static func json(_ status: Int, _ json: String) -> Reply { Reply(status: status, body: Data(json.utf8)) }
  }

  struct Captured: Sendable {
    var request: URLRequest
    var body: Data
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: @Sendable (Captured) -> Reply] = [:]

  static func register(host: String, handler: @escaping @Sendable (Captured) -> Reply) {
    lock.withLock { handlers[host] = handler }
  }

  static func unregister(host: String) {
    _ = lock.withLock { handlers.removeValue(forKey: host) }
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
      }
      stream.close()
    } else if let data = request.httpBody {
      body = data
    }
    let host = request.url?.host ?? ""
    guard let handler = Self.lock.withLock({ Self.handlers[host] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
      return
    }
    let reply = handler(Captured(request: request, body: body))
    if let error = reply.error {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    var headers = ["Content-Type": "application/json"]
    if let url = reply.redirectURL { headers["Location"] = url.absoluteString }
    let response = HTTPURLResponse(
      url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
      headerFields: headers)!
    if let url = reply.redirectURL {
      var redirected = request
      redirected.url = url
      client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Collects what a stub handler saw, for assertions after the call.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [StubProtocol.Captured] = []
  func add(_ captured: StubProtocol.Captured) { lock.withLock { items.append(captured) } }
  var all: [StubProtocol.Captured] { lock.withLock { items } }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

final class TokenSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: [String?]
  init(_ values: [String?]) { remaining = values }
  func next() -> String? { lock.withLock { remaining.removeFirst() } }
}

@Suite struct HTTPHubAPITests {
  private func make(
    host: String, token: @escaping @Sendable () async throws -> String? = { "t0k" },
    handler: @escaping @Sendable (StubProtocol.Captured) -> StubProtocol.Reply
  ) -> HTTPHubAPI {
    StubProtocol.register(host: host, handler: handler)
    return HTTPHubAPI(
      baseURL: URL(string: "https://\(host)")!, token: token, session: StubProtocol.session())
  }

  private func queryItems(_ request: URLRequest) -> [String: String] {
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }

  @Test func readinessReportsSupportSeparatelyFromActiveMinimumAndUsesTheDeploymentBase() async throws {
    let host = "readiness-base.test"
    let recorder = Recorder()
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { captured in
      recorder.add(captured)
      return .json(
        200,
        #"{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":1,"supportedClientProtocol":2}"#
      )
    }
    let api = HTTPHubAPI(
      baseURL: URL(string: "https://\(host)/deployment")!, token: { "private-token" }, session: session)
    let facts = try await api.readiness()
    #expect(facts.minClientProtocol == 1 && facts.supportedClientProtocol == 2)
    #expect(!facts.reportsActiveProtocolTwo)
    let sent = try #require(recorder.all.first)
    #expect(sent.request.url?.absoluteString == "https://\(host)/deployment/readyz")
    #expect(sent.request.value(forHTTPHeaderField: "B4-Protocol") == "2")
    #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(sent.body.isEmpty)
  }

  @Test func activeReadinessIsOnlyATypedServerFact() async throws {
    let host = "readiness-active.test"
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { _ in
      .json(
        200,
        #"{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":2,"supportedClientProtocol":2,"maintenance":"read_only"}"#
      )
    }
    let api = HTTPHubAPI(baseURL: URL(string: "https://\(host)")!, token: { nil }, session: session)
    let facts = try await api.readiness()
    #expect(facts.reportsActiveProtocolTwo)
    #expect(facts.maintenance == "read_only")
    // No account binding, persistence or write admission is constructed by this HTTP fact.
  }

  @Test(arguments: ["0", "-1", "3", "2.5", "\"2\"", "null"])
  func readinessRefusesInvalidOrUnsupportedMinimum(_ minimum: String) async throws {
    let host = "readiness-invalid-\(UUID().uuidString.lowercased()).test"
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { _ in
      .json(
        200,
        "{\"ok\":true,\"migrations\":\"current\",\"relay\":\"ok\",\"instances\":\"ok\",\"minClientProtocol\":\(minimum),\"supportedClientProtocol\":2}"
      )
    }
    let api = HTTPHubAPI(baseURL: URL(string: "https://\(host)")!, token: { nil }, session: session)
    await #expect(throws: HubError.self) { try await api.readiness() }
  }

  @Test func readinessDoesNotConvertHTTPFailureIntoAnActiveFact() async throws {
    let host = "readiness-unavailable.test"
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { _ in
      .json(
        503,
        #"{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":2,"supportedClientProtocol":2}"#
      )
    }
    let api = HTTPHubAPI(baseURL: URL(string: "https://\(host)")!, token: { nil }, session: session)
    do { _ = try await api.readiness(); Issue.record("HTTP failure is not readiness evidence") } catch let
      error as HubError
    { #expect(error.status == 503) }
  }

  @Test func readinessWithoutSupportedVersionCannotReportActiveTwo() throws {
    let data = Data(
      #"{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":2}"#.utf8)
    let facts = try JSONCoding.decoder.decode(HubReadiness.self, from: data)
    #expect(!facts.reportsActiveProtocolTwo)
  }

  @Test(arguments: ["readyz", "v1/me"], [false, true])
  func identityResponsesFromAnotherBaseAreRefused(_ path: String, otherOrigin: Bool) async throws {
    let host = "identity-base-\(UUID().uuidString.lowercased()).test"
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { _ in
      var reply = StubProtocol.Reply.json(200, "{}")
      reply.responseURL = URL(
        string: otherOrigin
          ? "https://another-identity.test/deployment/\(path)" : "https://\(host)/another/\(path)")!
      return reply
    }
    let api = HTTPHubAPI(
      baseURL: URL(string: "https://\(host)/deployment")!, token: { "private-token" }, session: session)
    do {
      if path == "readyz" { _ = try await api.readiness() } else { _ = try await api.me() }
      Issue.record("A different response base must not supply identity evidence")
    } catch let error as HubError { #expect(error.code == "wrong_endpoint") }
  }

  @Test(arguments: ["readyz", "v1/me"])
  func identityRedirectsAreNotFollowed(_ path: String) async throws {
    let peer = try await IdentityRedirectPeer.start(path: path)
    let session = URLSession(configuration: .ephemeral)
    let api = HTTPHubAPI(
      baseURL: peer.baseURL, token: { "private-token" }, session: session)
    var hubError: HubError?
    var primaryError: (any Error)?
    do {
      if path == "readyz" { _ = try await api.readiness() } else { _ = try await api.me() }
    } catch let error as HubError {
      hubError = error
    } catch {
      primaryError = error
    }
    session.invalidateAndCancel()
    let facts = await peer.stop()
    if !facts.cleanupSucceeded { Issue.record("Identity redirect peer cleanup failed") }
    if let error = hubError {
      // A transport timeout/status0 is a fixture failure, not evidence of redirect refusal.
      if error.status != 302 || error.code != "http_302" {
        let route = path == "readyz" ? "readyz" : "me"
        let code: String
        switch error.code {
        case "http_302": code = "http_302"
        case "transport": code = "transport"
        case "wrong_endpoint": code = "wrong_endpoint"
        case "unexpected_status": code = "unexpected_status"
        default: code = "other"
        }
        print(
          "identity_redirect_diagnostic route=\(route) status=\(error.status) code=\(code) destinationVisits=\(facts.destinationVisits)"
        )
      }
      #expect(error.status == 302 && error.code == "http_302")
    } else if primaryError == nil {
      Issue.record("The actual redirect response must be refused")
    }
    #expect(facts.destinationVisits == 0)
    #expect(facts.sourceVisits == 1)
    #expect(facts.sourceGETAndPathMatch)
    #expect(facts.sourceRedirectFlushes == 1)
    #expect(facts.closedChildren == facts.registeredChildren)
    if let primaryError { throw primaryError }
  }

  @Test(arguments: ["readyz", "v1/me"])
  func identityEvidenceRequiresTheActualOKStatus(_ path: String) async throws {
    let host = "identity-status-\(UUID().uuidString.lowercased()).test"
    let session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { _ in .json(201, "{}") }
    let api = HTTPHubAPI(
      baseURL: URL(string: "https://\(host)")!, token: { "private-token" }, session: session)
    do {
      if path == "readyz" { _ = try await api.readiness() } else { _ = try await api.me() }
      Issue.record("A non-200 response must not supply identity evidence")
    } catch let error as HubError { #expect(error.code == "unexpected_status") }
  }

  @Test(arguments: ["ok", "migrations", "relay", "instances", "maintenance"])
  func unhealthyReadinessDoesNotReportActiveTwo(_ field: String) throws {
    var object: [String: JSONValue] = [
      "ok": true, "migrations": "current", "relay": "ok", "instances": "ok", "minClientProtocol": 2,
      "supportedClientProtocol": 2,
    ]
    object[field] = field == "ok" ? false : "unexpected"
    let facts = try JSONCoding.decoder.decode(HubReadiness.self, from: JSONCoding.encoder.encode(object))
    #expect(!facts.reportsActiveProtocolTwo)
  }

  @Test func readinessMustBeExplicitlyScriptedByFakesAndProtocolDefaults() async throws {
    let fake = FakeHubAPI()
    await #expect(throws: HubError.self) { try await fake.readiness() }
    let legacy = LegacyOnlyHubAPI()
    await #expect(throws: HubError.self) { try await legacy.readiness() }
    let staged = HubReadiness(
      ok: true, migrations: "current", minClientProtocol: 1, supportedClientProtocol: 2, relay: "ok",
      instances: "ok")
    await fake.setReadiness(staged)
    #expect(try await fake.readiness() == staged)
    #expect(!(try await fake.readiness()).reportsActiveProtocolTwo)
    #expect(try await fake.me().orgId == nil)
    await fake.setOrgId("fixture-org")
    #expect(try await fake.me().orgId == "fixture-org")
  }

  @Test func authenticatedSyncRequestsCarryClientProtocolTwo() async throws {
    let host = "client-protocol-two.test"
    let recorder = Recorder()
    let session = StubProtocol.session()
    defer {
      session.invalidateAndCancel()
      StubProtocol.unregister(host: host)
    }
    StubProtocol.register(host: host) { captured in
      recorder.add(captured)
      switch (captured.request.httpMethod, captured.request.url?.path) {
      case ("POST", "/v1/changes"):
        return .json(200, #"{"acceptedThrough":0}"#)
      case ("GET", "/v1/changes"):
        return .json(200, #"{"changes":[],"next":0,"more":false}"#)
      case ("GET", "/v1/snapshot"):
        return .json(200, #"{"changes":[],"clocks":[],"next":0}"#)
      default:
        return .json(
          404,
          #"{"error":{"kind":"request_error","message":"Unknown test path.","details":{"code":"not_found"}}}"#
        )
      }
    }
    let api = HTTPHubAPI(
      baseURL: URL(string: "https://\(host)")!, token: { "fixture-protocol-token" }, session: session)
    #expect(try await api.push([]).acceptedThrough == 0)
    #expect(try await api.pull(after: 0, limit: 1, wait: 0).changes.isEmpty)
    #expect(try await api.snapshot().changes.isEmpty)
    let requests = recorder.all.map(\.request)
    try #require(requests.count == 3)
    #expect(requests.map { $0.url?.path } == ["/v1/changes", "/v1/changes", "/v1/snapshot"])
    #expect(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-protocol-token" }
    )
    for request in requests {
      #expect(request.value(forHTTPHeaderField: "B4-Protocol") == "2")
    }
  }

  @Test func mapsHubErrorsAndSendsTheBearer() async throws {
    let recorder = Recorder()
    let api = make(host: "map-errors.test") { captured in
      recorder.add(captured)
      return .json(
        401,
        #"{"error":{"kind":"request_error","message":"Unauthorized.","details":{"code":"unauthorized"}}}"#)
    }

    do {
      _ = try await api.me()
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.kind == "request_error")
      #expect(error.code == "unauthorized")
      #expect(error.status == 401)
      #expect(error.message == "Unauthorized.")
    }
    let request = try #require(recorder.all.first).request
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/v1/me")
    #expect(request.timeoutInterval == 30)
  }

  @Test func anErrorWithoutTheEnvelopeStillMapsToAHubError() async {
    let api = make(host: "no-envelope.test") { _ in .json(502, "<html>bad gateway</html>") }
    do {
      _ = try await api.me()
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.status == 502)
      #expect(error.code == "http_502")
      #expect(error.kind == "execution_error")
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test func aTwoHundredBodyThatDoesNotDecodeIsATransportFailureWithTheStatus() async {
    let api = make(host: "bad-body.test") { _ in .json(200, #"{"unexpected":true}"#) }
    do {
      _ = try await api.me()
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.code == "transport")
      #expect(error.status == 200)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test func aNetworkFailureIsATransportError() async {
    let api = make(host: "offline.test") { _ in
      StubProtocol.Reply(status: 0, body: Data(), error: URLError(.notConnectedToInternet))
    }
    do {
      _ = try await api.me()
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.code == "transport")
      #expect(error.status == 0)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test func pullCarriesAfterLimitAndWait() async throws {
    let recorder = Recorder()
    let api = make(host: "pull.test") { captured in
      recorder.add(captured)
      return .json(200, #"{"changes":[],"next":42,"more":false}"#)
    }

    let page = try await api.pull(after: 42, limit: 1000, wait: 25)

    #expect(page.next == 42 && page.changes.isEmpty)
    let request = try #require(recorder.all.first).request
    #expect(queryItems(request) == ["after": "42", "limit": "1000", "wait": "25"])
    #expect(request.url?.path == "/v1/changes")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
  }

  @Test func pullTimeoutIsWaitPlusFive() async throws {
    let recorder = Recorder()
    let api = make(host: "pull-timeout.test") { captured in
      recorder.add(captured)
      return .json(200, #"{"changes":[],"next":0,"more":false}"#)
    }
    _ = try await api.pull(after: 0, limit: 10, wait: 25)
    _ = try await api.pull(after: 0, limit: 10, wait: 0)
    let timeouts = recorder.all.map(\.request.timeoutInterval)
    #expect(timeouts == [30, 5])
  }

  @Test func pushPostsTheChangesAsJSON() async throws {
    let recorder = Recorder()
    let api = make(host: "push.test") { captured in
      recorder.add(captured)
      return .json(200, #"{"acceptedThrough":7}"#)
    }
    let change = SyncChange(
      deviceSeq: 7, wall: 1, table: "threads", rowId: "t", op: "update", column: "title", value: .null)

    let response = try await api.push([change])

    #expect(response.acceptedThrough == 7)
    let captured = try #require(recorder.all.first)
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/v1/changes")
    #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    #expect(captured.request.timeoutInterval == 30)
    let body = try JSONCoding.decoder.decode(JSONValue.self, from: captured.body)
    let sent = try #require(body["changes"]?.arrayValue?.first)
    #expect(sent["deviceSeq"] == 7 && sent["value"] == .some(.null))
  }

  @Test func enrollSendsNoBearerAndTheRequestBody() async throws {
    let recorder = Recorder()
    let tokenCalls = Counter()
    let api = make(
      host: "enroll.test",
      token: {
        tokenCalls.increment()
        return "t0k"
      }
    ) { captured in
      recorder.add(captured)
      return .json(
        200,
        #"{"deviceId":"d","token":"new","org":{"slug":"o","name":"O"},"user":{"username":"u","displayName":"U"}}"#
      )
    }

    let response = try await api.enroll(EnrollRequest(code: "ABCD2345", deviceName: "Mac", platform: "macos"))

    #expect(response.token == "new")
    let captured = try #require(recorder.all.first)
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/v1/enroll")
    #expect(captured.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONCoding.decoder.decode(JSONValue.self, from: captured.body)
    #expect(body["code"] == "ABCD2345" && body["deviceName"] == "Mac" && body["platform"] == "macos")
    #expect(tokenCalls.value == 0)
  }

  @Test func httpHubAPIDecodesSnapshotAndDevices() async throws {
    let recorder = Recorder()
    let api = make(host: "snapshot-devices.test") { captured in
      recorder.add(captured)
      if captured.request.url?.path == "/v1/snapshot" {
        return .json(
          200,
          #"""
          {"changes":[{"hubSeq":0,"deviceId":"d","deviceSeq":0,"wall":0,"table":"threads","rowId":"t","op":"insert","column":null,"value":{"id":"t","title":null},"hlc":"000000000000-0000-d"}],
           "clocks":[{"table":"threads","rowId":"t","column":"title","hlc":"019a396c76e8-0000-d"}],"next":12}
          """#)
      }
      return .json(
        200,
        #"""
        {"devices":[
          {"id":"d","name":"Mac","platform":"macos","lastSeenAt":"2026-10-31T12:00:00.000000Z","revokedAt":null},
          {"id":"p","name":"iPhone","platform":"ios","lastSeenAt":null,"revokedAt":"2026-10-31T13:00:00.000000Z"}]}
        """#)
    }

    let snapshot = try await api.snapshot()
    #expect(snapshot.next == 12)
    #expect(snapshot.changes.count == 1 && snapshot.changes[0].hlc == "000000000000-0000-d")
    #expect(snapshot.changes[0].column == nil && snapshot.changes[0].value?["title"] == .some(.null))
    #expect(
      snapshot.clocks == [
        ColumnClock(table: "threads", rowId: "t", column: "title", hlc: "019a396c76e8-0000-d")
      ])

    let devices = try await api.devices()
    #expect(devices.map(\.id) == ["d", "p"])
    #expect(devices[0].lastSeenAt == "2026-10-31T12:00:00.000000Z" && devices[0].revokedAt == nil)
    #expect(devices[1].lastSeenAt == nil && devices[1].revokedAt == "2026-10-31T13:00:00.000000Z")

    let requests = recorder.all.map(\.request)
    #expect(requests.map { $0.url?.path } == ["/v1/snapshot", "/v1/devices"])
    #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0k" })
  }

  @Test func httpMintPairingCodeDecodes() async throws {
    let recorder = Recorder()
    let api = make(host: "mint.test") { captured in
      recorder.add(captured)
      return .json(
        200,
        #"{"code":"ABCD2345","expiresAt":"2026-11-01T12:05:00.000000Z","hubURL":"https://hub.example.com/"}"#
      )
    }
    let minted = try await api.mintPairingCode()
    #expect(minted.code == "ABCD2345")
    #expect(minted.expiresAt == "2026-11-01T12:05:00.000000Z")
    #expect(minted.hubURL == "https://hub.example.com/")
    let request = try #require(recorder.all.first).request
    #expect(request.httpMethod == "POST" && request.url?.path == "/v1/pairing-codes")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    // The description of a minted code never prints the code.
    #expect(!"\(minted)".contains("ABCD2345") && !String(reflecting: minted).contains("ABCD2345"))

    // `hubURL` is absent when the hub has no public URL.
    let bare = make(host: "mint-bare.test") { _ in
      .json(200, #"{"code":"ABCD2345","expiresAt":"2026-11-01T12:05:00.000000Z"}"#)
    }
    #expect(try await bare.mintPairingCode().hubURL == nil)
  }

  @Test func httpMintPairingCodeReadsARateLimit() async throws {
    let api = make(host: "mint-limited.test") { _ in
      .json(
        429,
        #"{"error":{"kind":"request_error","message":"too many requests; try again shortly","details":{"code":"rate_limited","retryAfterMs":1234}}}"#
      )
    }
    do {
      _ = try await api.mintPairingCode()
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.status == 429 && error.code == "rate_limited" && error.retryAfterMs == 1234)
    }
  }

  @Test func aPushResponseWithRejectionsDecodesOverHTTP() async throws {
    let api = make(host: "rejected.test") { _ in
      .json(200, #"{"acceptedThrough":3,"rejected":[{"deviceSeq":2,"code":"payload_too_large"}]}"#)
    }
    let response = try await api.push([])
    #expect(response.acceptedThrough == 3)
    #expect(response.rejected == [RejectedChange(deviceSeq: 2, code: "payload_too_large")])
  }

  @Test func revokeSelfDeletesAndAcceptsNoContent() async throws {
    let recorder = Recorder()
    let api = make(host: "revoke.test") { captured in
      recorder.add(captured)
      return StubProtocol.Reply(status: 204, body: Data())
    }
    try await api.revokeSelf()
    let request = try #require(recorder.all.first).request
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.path == "/v1/devices/self")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
  }

  @Test func registerPushTokenPostsBody() async throws {
    let recorder = Recorder()
    let api = make(host: "push-token.test") { captured in
      recorder.add(captured)
      return StubProtocol.Reply(status: 204, body: Data())
    }
    try await api.registerPushToken("ab12cd", environment: "sandbox", bundleId: "com.cacheplane.b4app.dev")
    let captured = try #require(recorder.all.first)
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/v1/devices/self/push-token")
    #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONCoding.decoder.decode(JSONValue.self, from: captured.body)
    #expect(body["token"] == .string("ab12cd"))
    #expect(body["environment"] == .string("sandbox"))
    #expect(body["bundleId"] == .string("com.cacheplane.b4app.dev"))
    #expect(body.objectValue?.count == 3)
  }

  @Test func registerPushTokenSurfacesAForbiddenAsAHubError() async {
    let api = make(host: "push-token-403.test") { _ in
      .json(
        403,
        #"{"error":{"kind":"request_error","message":"Only an iOS device can register a push token.","details":{"code":"forbidden"}}}"#
      )
    }
    do {
      try await api.registerPushToken("ab12", environment: "production", bundleId: "com.cacheplane.b4app")
      Issue.record("expected a HubError")
    } catch let error as HubError {
      #expect(error.code == "forbidden")
      #expect(error.status == 403)
    } catch {
      Issue.record("expected a HubError, got \(error)")
    }
  }

  @Test func theTokenClosureRunsPerRequestAndNilSendsNoAuthorization() async throws {
    let recorder = Recorder()
    let tokens = TokenSequence(["first", nil, "third"])
    let api = make(host: "per-request.test", token: { tokens.next() }) { captured in
      recorder.add(captured)
      return .json(200, #"{"changes":[],"next":0,"more":false}"#)
    }
    for _ in 0..<3 { _ = try await api.pull(after: 0, limit: 1, wait: 0) }
    let headers = recorder.all.map { $0.request.value(forHTTPHeaderField: "Authorization") }
    #expect(headers == ["Bearer first", nil, "Bearer third"])
  }

  @Test func aBaseURLWithAPathPrefixIsKept() async throws {
    let recorder = Recorder()
    StubProtocol.register(host: "prefixed.test") { captured in
      recorder.add(captured)
      return .json(200, #"{"changes":[],"next":0,"more":false}"#)
    }
    let api = HTTPHubAPI(
      baseURL: URL(string: "https://prefixed.test/hub/")!, token: { nil }, session: StubProtocol.session())
    _ = try await api.pull(after: 0, limit: 1, wait: 0)
    #expect(recorder.all.first?.request.url?.path == "/hub/v1/changes")
  }

  // MARK: - Sign-in and the account

  private static let session = #"""
    {"deviceId":"d1","token":"issued","org":{"slug":"o","name":"O"},
     "user":{"username":"u","displayName":""},"needsOnboarding":true}
    """#
  private static let meJSON = #"""
    {"deviceId":"d1","deviceName":"Mac","platform":"macos","org":{"slug":"o","name":"O"},
     "user":{"username":"u","displayName":"Brian Love","fullName":"Brian Love"},
     "createdAt":"2026-11-01T09:00:00.000000Z","onboarded":true,
     "identities":[{"id":"i1","kind":"passkey","name":"Agent Workspace account",
                    "createdAt":"2026-11-01T09:00:00.000000Z","lastUsedAt":null}]}
    """#
  private static let identityJSON = #"""
    {"id":"i2","kind":"passkey","name":"Agent Workspace account",
     "createdAt":"2026-11-01T12:00:00.000000Z","lastUsedAt":null}
    """#

  /// Answers each account route with a body of the right shape, keyed by method and path.
  private static func accountReply(_ captured: StubProtocol.Captured) -> StubProtocol.Reply {
    let key = "\(captured.request.httpMethod ?? "") \(captured.request.url?.path ?? "")"
    switch key {
    case "GET /v1/auth/config":
      return .json(
        200, #"{"passkeys":{"rpId":"b4.run"},"apple":{"native":true,"web":true},"signup":"closed"}"#)
    case "POST /v1/auth/passkey/begin":
      return .json(200, #"{"ceremonyId":"c1","authentication":{"publicKey":{"challenge":"x"}}}"#)
    case "POST /v1/auth/passkey/finish", "POST /v1/auth/apple/native", "POST /v1/auth/handoff":
      return .json(200, session)
    case "POST /v1/auth/apple/begin": return .json(200, #"{"ceremonyId":"c2","nonce":"n"}"#)
    case "POST /v1/enroll":
      return .json(
        200,
        #"{"deviceId":"d1","token":"issued","org":{"slug":"o","name":"O"},"user":{"username":"u","displayName":"U"}}"#
      )
    case "GET /v1/me", "PUT /v1/me/profile": return .json(200, meJSON)
    case "POST /v1/me/passkeys/begin":
      return .json(200, #"{"ceremonyId":"c3","registration":{"publicKey":{"challenge":"y"}}}"#)
    case "POST /v1/me/passkeys/finish", "POST /v1/me/apple/native", "POST /v1/me/apple/handoff":
      return .json(200, identityJSON)
    case "POST /v1/me/apple", "POST /v1/me/step-up/apple":
      return .json(200, #"{"ceremonyId":"c4","nonce":"n4"}"#)
    case "POST /v1/me/step-up/passkey/begin":
      return .json(200, #"{"ceremonyId":"c5","authentication":{"publicKey":{"challenge":"z"}}}"#)
    case "POST /v1/me/step-up/passkey/finish", "POST /v1/me/step-up/apple/native",
      "POST /v1/me/step-up/apple/handoff", "POST /v1/me/step-up/code":
      return .json(200, #"{"stepUp":"g1","expiresAt":"2026-11-02T12:02:00.000000Z"}"#)
    case "DELETE /v1/me/identities/i2", "DELETE /v1/sessions/self", "DELETE /v1/me":
      return StubProtocol.Reply(status: 204, body: Data())
    default:
      return .json(
        404, #"{"error":{"kind":"request_error","message":"not found","details":{"code":"not_found"}}}"#)
    }
  }

  private let device = DeviceSpec(deviceName: "Mac", platform: "macos")

  @Test func unauthenticatedCallsSendNoBearer() async throws {
    let recorder = Recorder()
    let tokenReads = Counter()
    let api = make(
      host: "no-bearer.test",
      token: {
        tokenReads.increment()
        return "t0k"
      }
    ) { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }

    _ = try await api.authConfig()
    _ = try await api.passkeyBegin()
    _ = try await api.passkeyFinish(
      PasskeyFinishRequest(ceremonyId: "c1", assertion: ["id": "a"], attestation: nil, device: device))
    _ = try await api.appleBegin()
    _ = try await api.appleNative(
      AppleNativeRequest(
        ceremonyId: "c2", identityToken: "jwt", authorizationCode: "code", fullName: nil, device: device))
    _ = try await api.handoff(HandoffRequest(handoff: "h", verifier: "v", device: device))
    _ = try await api.enroll(EnrollRequest(code: "ABCD2345", deviceName: "Mac", platform: "macos"))

    let seen = recorder.all.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
    #expect(
      seen == [
        "GET /v1/auth/config", "POST /v1/auth/passkey/begin", "POST /v1/auth/passkey/finish",
        "POST /v1/auth/apple/begin", "POST /v1/auth/apple/native", "POST /v1/auth/handoff",
        "POST /v1/enroll",
      ])
    for captured in recorder.all {
      #expect(captured.request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    #expect(tokenReads.value == 0, "an unauthenticated call never asks for the stored token")
  }

  @Test func signInCallsSendTheirBodiesAndDecodeTheirAnswers() async throws {
    let recorder = Recorder()
    let api = make(host: "sign-in.test") { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }

    let config = try await api.authConfig()
    #expect(config.passkeys.rpId == "b4.run" && config.apple.native && config.signup == .closed)
    let begun = try await api.passkeyBegin()
    #expect(begun.ceremonyId == "c1" && begun.registration == nil)
    let session = try await api.passkeyFinish(
      PasskeyFinishRequest(
        ceremonyId: "c1", assertion: ["id": "a"], attestation: nil,
        device: DeviceSpec(deviceName: "Mac", platform: "macos", deviceId: "d1")))
    #expect(session.token == "issued" && session.needsOnboarding)
    let finish = try #require(recorder.all.last)

    _ = try await api.appleBegin(
      AppleBeginRequest(verifierHash: String(repeating: "a", count: 64), scheme: "b4app"))
    _ = try await api.appleBegin()
    let begins = recorder.all.suffix(2).map { try? JSONCoding.decoder.decode(JSONValue.self, from: $0.body) }
    #expect(
      begins == [["verifierHash": .string(String(repeating: "a", count: 64)), "scheme": "b4app"], [:]])

    #expect(finish.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONCoding.decoder.decode(JSONValue.self, from: finish.body)
    #expect(
      body == [
        "ceremonyId": "c1", "assertion": ["id": "a"],
        "device": ["deviceName": "Mac", "platform": "macos", "deviceId": "d1"],
      ])
  }

  @Test func accountCallsSendTheBearer() async throws {
    let recorder = Recorder()
    let api = make(host: "account.test") { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }

    let profile = try await api.setProfile(ProfileRequest(fullName: "Brian Love"))
    #expect(profile.fullName == "Brian Love" && profile.onboarded)
    let identities = try await api.identities()
    #expect(identities.map(\.id) == ["i1"])
    let begun = try await api.addPasskeyBegin(stepUp: "g-add")
    #expect(begun.ceremonyId == "c3")
    let added = try await api.addPasskeyFinish(
      AddPasskeyFinishRequest(ceremonyId: "c3", attestation: ["id": "a"]))
    #expect(added.id == "i2")
    try await api.removeIdentity("i2", stepUp: "g-remove")
    try await api.endSession()
    try await api.deleteAccount(stepUp: "g-delete")

    let seen = recorder.all.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
    #expect(
      seen == [
        "PUT /v1/me/profile", "GET /v1/me", "POST /v1/me/passkeys/begin", "POST /v1/me/passkeys/finish",
        "DELETE /v1/me/identities/i2", "DELETE /v1/sessions/self", "DELETE /v1/me",
      ])
    for captured in recorder.all {
      #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }
    // A change that needs a step-up carries its grant in `B4-Step-Up`; no other call has one.
    #expect(
      recorder.all.map { $0.request.value(forHTTPHeaderField: "B4-Step-Up") } == [
        nil, nil, "g-add", nil, "g-remove", nil, "g-delete",
      ])
    let profileBody = try JSONCoding.decoder.decode(
      JSONValue.self, from: try #require(recorder.all.first).body)
    #expect(profileBody == ["fullName": "Brian Love"])
  }

  /// Task 14: the three link routes carry the device's bearer and their bodies.
  @Test func appleLinkCallsSendTheBearerAndTheirBodies() async throws {
    let recorder = Recorder()
    let api = make(host: "link.test") { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }

    let native = try await api.appleLinkBegin(AppleBeginRequest(), stepUp: "g1")
    #expect(native == AppleBeginResponse(ceremonyId: "c4", nonce: "n4"))
    _ = try await api.appleLinkBegin(
      AppleBeginRequest(verifierHash: String(repeating: "b", count: 64), scheme: "b4app-beta"), stepUp: "g2")
    let linked = try await api.appleLinkNative(
      AppleLinkNativeRequest(ceremonyId: "c4", identityToken: "jwt", authorizationCode: "code"))
    #expect(linked.id == "i2")
    let handed = try await api.appleLinkHandoff(AppleLinkHandoffRequest(handoff: "h", verifier: "v"))
    #expect(handed.id == "i2")

    let seen = recorder.all.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
    #expect(
      seen == [
        "POST /v1/me/apple", "POST /v1/me/apple", "POST /v1/me/apple/native", "POST /v1/me/apple/handoff",
      ])
    for captured in recorder.all {
      #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }
    #expect(
      recorder.all.map { $0.request.value(forHTTPHeaderField: "B4-Step-Up") } == ["g1", "g2", nil, nil])
    let bodies = recorder.all.map { try? JSONCoding.decoder.decode(JSONValue.self, from: $0.body) }
    #expect(
      bodies == [
        [:], ["verifierHash": .string(String(repeating: "b", count: 64)), "scheme": "b4app-beta"],
        ["ceremonyId": "c4", "identityToken": "jwt", "authorizationCode": "code"],
        ["handoff": "h", "verifier": "v"],
      ])
  }

  /// D-150: the step-up routes carry the bearer and their bodies, and answer the grant.
  @Test func stepUpCallsSendTheBearerAndTheirBodies() async throws {
    let recorder = Recorder()
    let api = make(host: "step-up.test") { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }
    let begun = try await api.stepUpPasskeyBegin()
    #expect(begun.ceremonyId == "c5")
    let passkey = try await api.stepUpPasskeyFinish(
      StepUpFinishRequest(ceremonyId: "c5", assertion: ["id": "a"]))
    #expect(passkey == StepUpResponse(stepUp: "g1", expiresAt: "2026-11-02T12:02:00.000000Z"))
    _ = try await api.stepUpAppleBegin(AppleBeginRequest())
    _ = try await api.stepUpAppleNative(StepUpAppleNativeRequest(ceremonyId: "c4", identityToken: "jwt"))
    _ = try await api.stepUpAppleHandoff(AppleLinkHandoffRequest(handoff: "h", verifier: "v"))
    _ = try await api.stepUpCode(StepUpCodeRequest(code: "K7QX2M9P"))

    let seen = recorder.all.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
    #expect(
      seen == [
        "POST /v1/me/step-up/passkey/begin", "POST /v1/me/step-up/passkey/finish",
        "POST /v1/me/step-up/apple",
        "POST /v1/me/step-up/apple/native", "POST /v1/me/step-up/apple/handoff",
        "POST /v1/me/step-up/code",
      ])
    for captured in recorder.all {
      #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    }
    let bodies = recorder.all.dropFirst().map {
      try? JSONCoding.decoder.decode(JSONValue.self, from: $0.body)
    }
    #expect(
      bodies == [
        ["ceremonyId": "c5", "assertion": ["id": "a"]], [:], ["ceremonyId": "c4", "identityToken": "jwt"],
        ["handoff": "h", "verifier": "v"], ["code": "K7QX2M9P"],
      ])
    #expect(!passkey.description.contains("g1"))
  }

  @Test func aStepUpRefusalCarriesTheMethods() async throws {
    let api = make(host: "refused.test") { _ in
      .json(
        403,
        #"{"error":{"kind":"request_error","message":"confirm","details":{"code":"step_up_required","methods":["passkey","apple"]}}}"#
      )
    }
    let refused = await #expect(throws: HubError.self) { try await api.deleteAccount(stepUp: nil) }
    #expect(refused?.code == "step_up_required" && refused?.status == 403)
    #expect(refused?.methods == ["passkey", "apple"])
  }

  @Test func theFakeLinksOneAppleIDAndRecordsTheCalls() async throws {
    let fake = FakeHubAPI()
    _ = try await fake.appleLinkBegin(AppleBeginRequest(), stepUp: nil)
    let first = try await fake.appleLinkNative(
      AppleLinkNativeRequest(ceremonyId: "fake-apple-ceremony", identityToken: "t", authorizationCode: "c"))
    #expect(first.kind == "apple")
    #expect(try await fake.identities().map(\.kind) == ["apple"])
    // One Apple ID per account: the begin is refused once there is one.
    let refused = await #expect(throws: HubError.self) {
      _ = try await fake.appleLinkBegin(AppleBeginRequest(), stepUp: nil)
    }
    #expect(refused?.code == "apple_linked" && refused?.status == 409)
    _ = try await fake.appleLinkHandoff(AppleLinkHandoffRequest(handoff: "h", verifier: "v"))
    #expect(await fake.appleLinkBegins.count == 2)
    #expect(await fake.appleLinkNatives.count == 1)
    #expect(await fake.appleLinkHandoffs.count == 1)
  }

  @Test func enrollSendsABearerOnlyWhenGivenAToken() async throws {
    let recorder = Recorder()
    let tokenReads = Counter()
    let api = make(
      host: "enroll-merge.test",
      token: {
        tokenReads.increment()
        return "stored"
      }
    ) { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }
    let request = EnrollRequest(code: "ABCD2345", deviceName: "Phone", platform: "ios")

    _ = try await api.enroll(request, replacingToken: "phone-token")
    _ = try await api.enroll(request, replacingToken: nil)
    _ = try await api.enroll(request)

    let headers = recorder.all.map { $0.request.value(forHTTPHeaderField: "Authorization") }
    #expect(headers == ["Bearer phone-token", nil, nil])
    #expect(tokenReads.value == 0, "pairing never sends the device's own stored token by itself")
    #expect(recorder.all.allSatisfy { $0.request.url?.path == "/v1/enroll" })
  }

  @Test func aMergeRefusalCarriesItsReason() async throws {
    for reason in ["same_account", "has_mac", "shared_org"] {
      let api = make(host: "merge-\(reason).test") { _ in
        .json(
          409,
          #"{"error":{"kind":"request_error","message":"this account cannot be merged into another","details":{"code":"merge_refused","reason":"\#(reason)"}}}"#
        )
      }
      do {
        _ = try await api.enroll(
          EnrollRequest(code: "ABCD2345", deviceName: "Phone", platform: "ios"), replacingToken: "phone-token"
        )
        Issue.record("expected merge_refused")
      } catch let error as HubError {
        #expect(error.status == 409 && error.code == "merge_refused" && error.reason == reason)
      }
    }
    // An older hub sends none.
    let old = make(host: "merge-old.test") { _ in
      .json(409, #"{"error":{"kind":"request_error","message":"no","details":{"code":"merge_refused"}}}"#)
    }
    let error = await #expect(throws: HubError.self) {
      _ = try await old.enroll(
        EnrollRequest(code: "ABCD2345", deviceName: "Phone", platform: "ios"), replacingToken: "phone-token")
    }
    #expect(error?.reason == nil)
  }

  @Test func signInRefusalsKeepTheirHubCodes() async {
    let codes: [(status: Int, code: String)] = [
      (403, "signup_closed"), (400, "ceremony_expired"), (401, "credential_rejected"),
      (409, "last_identity"), (409, "merge_refused"), (409, "shared_org"), (429, "rate_limited"),
    ]
    for (index, expected) in codes.enumerated() {
      let api = make(host: "refusal-\(index).test") { _ in
        .json(
          expected.status,
          #"{"error":{"kind":"request_error","message":"no","details":{"code":"\#(expected.code)"}}}"#)
      }
      do {
        _ = try await api.passkeyBegin()
        Issue.record("expected \(expected.code)")
      } catch let error as HubError {
        #expect(error.code == expected.code && error.status == expected.status)
        #expect(ErrorCode(rawValue: error.code) != nil, "\(error.code) is an ErrorCode")
      } catch {
        Issue.record("unexpected \(error)")
      }
    }
  }

  @Test func removeIdentityRefusesAnIdThatIsNotAPathSegment() async {
    let recorder = Recorder()
    let api = make(host: "bad-id.test") { captured in
      recorder.add(captured)
      return Self.accountReply(captured)
    }
    for id in ["", "a/b", "../me", "a b", "i1?x=1"] {
      do {
        try await api.removeIdentity(id, stepUp: nil)
        Issue.record("\"\(id)\" should be refused")
      } catch let error as HubError {
        #expect(error.code == "invalid_request" && error.status == 0)
      } catch {
        Issue.record("unexpected \(error)")
      }
    }
    #expect(recorder.all.isEmpty, "nothing was sent")
  }
}

@Suite struct FakeHubAPITests {
  private func enrolled() -> EnrollResponse {
    EnrollResponse(
      deviceId: "dev-1", token: "tok", org: OrgInfo(slug: "o", name: "O"),
      user: UserInfo(username: "u", displayName: "U"))
  }

  private func change(_ seq: Int) -> SyncChange {
    SyncChange(deviceSeq: seq, wall: seq, table: "threads", rowId: "t\(seq)", op: "delete")
  }

  @Test func enrollRedeemsACodeOnce() async throws {
    let fake = FakeHubAPI(enrollmentCodes: ["ABCD2345": enrolled()])
    let request = EnrollRequest(code: "ABCD2345", deviceName: "Mac", platform: "macos")

    let response = try await fake.enroll(request)
    #expect(response.deviceId == "dev-1")
    #expect(await fake.enrollCalls == 1)

    do {
      _ = try await fake.enroll(request)
      Issue.record("a code is single-use")
    } catch let error as HubError {
      #expect(error.code == "invalid_code" && error.status == 401)
    }
    #expect(await fake.enrollCalls == 2)
  }

  @Test func pushRecordsBatchesAndFeedsPullInOrder() async throws {
    let fake = FakeHubAPI(enrollmentCodes: ["ABCD2345": enrolled()])
    _ = try await fake.enroll(EnrollRequest(code: "ABCD2345", deviceName: "Mac", platform: "macos"))

    let pushed = try await fake.push([change(1), change(2)])
    #expect(pushed.acceptedThrough == 2)
    #expect(try await fake.push([change(2), change(3)]).acceptedThrough == 3)
    #expect(await fake.pushed.count == 2)

    let page = try await fake.pull(after: 0, limit: 2, wait: 0)
    #expect(page.changes.map(\.hubSeq) == [1, 2] && page.next == 2 && page.more)
    let rest = try await fake.pull(after: page.next, limit: 10, wait: 0)
    #expect(rest.changes.map(\.deviceSeq) == [3] && !rest.more)
    let empty = try await fake.pull(after: rest.next, limit: 10, wait: 0)
    #expect(empty.changes.isEmpty && empty.next == rest.next)
  }

  @Test func failNextFailsExactlyOneCall() async throws {
    let fake = FakeHubAPI()
    let failure = HubError(kind: "execution_error", code: "internal_error", message: "boom", status: 500)
    await fake.setFailNext(failure)
    do {
      _ = try await fake.push([change(1)])
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == failure)
    }
    #expect(await fake.failNext == nil)
    #expect(try await fake.push([change(1)]).acceptedThrough == 1)
  }

  @Test func revokeSelfMarksRevokedAndLaterCallsAreUnauthorized() async throws {
    let fake = FakeHubAPI()
    try await fake.revokeSelf()
    #expect(await fake.revoked)
    do {
      _ = try await fake.me()
      Issue.record("a revoked device is unauthorized")
    } catch let error as HubError {
      #expect(error.code == "unauthorized" && error.status == 401)
    }
  }

  @Test(.timeLimit(.minutes(1))) func appendFeedsAReaderAndALongPollWakesForIt() async throws {
    let fake = FakeHubAPI()
    async let page = fake.pull(after: 0, limit: 10, wait: 30)
    // The append comes once the pull is parked in its long poll, so it is the append that wakes it.
    await fake.untilPulling()
    await fake.append([
      StoredChange(
        hubSeq: 1, deviceId: "other", deviceSeq: 1, wall: 1, table: "threads", rowId: "t", op: "delete")
    ])
    let result = try await page
    #expect(result.changes.count == 1 && result.next == 1)
  }

  // MARK: - Sign-in and the account

  private func signedIn() -> AuthSession {
    AuthSession(
      deviceId: "dev-9", token: "tok-9", org: OrgInfo(slug: "o-9", name: "My Org"),
      user: UserInfo(username: "u-9", displayName: ""), needsOnboarding: true)
  }

  private let mac = DeviceSpec(deviceName: "Brian's Mac", platform: "macos")

  @Test func scriptedSignInAnswersAndRecordsWhatItWasSent() async throws {
    let fake = FakeHubAPI()
    await fake.setAuthConfig(
      AuthConfig(passkeys: .init(rpId: "b4.run"), apple: .init(native: true, web: false), signup: .closed))
    await fake.setSession(signedIn())
    #expect(try await fake.authConfig().signup == .closed)
    #expect(try await fake.passkeyBegin().ceremonyId.isEmpty == false)

    let request = PasskeyFinishRequest(
      ceremonyId: "c", assertion: ["id": "a"], attestation: nil, device: mac)
    let session = try await fake.passkeyFinish(request)
    #expect(session == signedIn())
    #expect(await fake.passkeyFinishes == [request])

    // Signed in, the fake answers `me` as the session's account and the finish's device.
    let me = try await fake.me()
    #expect(me.deviceId == "dev-9" && me.deviceName == "Brian's Mac" && me.platform == "macos")
    #expect(me.user.username == "u-9" && !me.onboarded)

    let native = AppleNativeRequest(
      ceremonyId: "c2", identityToken: "jwt", authorizationCode: "code", fullName: nil, device: mac)
    _ = try await fake.appleNative(native)
    let handoff = HandoffRequest(handoff: "h", verifier: "v", device: mac)
    _ = try await fake.handoff(handoff)
    #expect(try await fake.appleBegin().nonce.isEmpty == false)
    #expect(await fake.appleNatives == [native])
    #expect(await fake.handoffs == [handoff])
  }

  @Test func profileOnboardsAndIdentitiesFollowTheLastIdentityRule() async throws {
    let fake = FakeHubAPI()
    await fake.setSession(signedIn())
    _ = try await fake.passkeyFinish(
      PasskeyFinishRequest(ceremonyId: "c", assertion: ["id": "a"], attestation: nil, device: mac))

    let me = try await fake.setProfile(ProfileRequest(fullName: "Brian Love"))
    #expect(me.fullName == "Brian Love" && me.onboarded && me.user.displayName == "Brian Love")
    #expect(await fake.profiles == [ProfileRequest(fullName: "Brian Love")])

    let first = Identity(id: "i1", kind: "passkey", name: "Agent Workspace account", createdAt: "t")
    await fake.setIdentities([first])
    // Like the hub, a change of an account with a sign-in method needs a live grant, used once.
    do {
      _ = try await fake.addPasskeyBegin(stepUp: nil)
      Issue.record("an add needs a step-up")
    } catch let error as HubError {
      #expect(error.code == "step_up_required" && error.status == 403 && error.methods == ["passkey"])
    }
    let grant = try await fake.stepUpPasskeyFinish(
      StepUpFinishRequest(ceremonyId: "c", assertion: ["id": "a"]))
    _ = try await fake.addPasskeyBegin(stepUp: grant.stepUp)
    await #expect(throws: HubError.self) { _ = try await fake.addPasskeyBegin(stepUp: grant.stepUp) }
    let added = try await fake.addPasskeyFinish(
      AddPasskeyFinishRequest(ceremonyId: "c", attestation: ["id": "b"]))
    #expect(added.kind == "passkey")
    #expect(try await fake.identities().count == 2)

    let again = try await fake.stepUpPasskeyFinish(
      StepUpFinishRequest(ceremonyId: "c", assertion: ["id": "a"]))
    try await fake.removeIdentity(added.id, stepUp: again.stepUp)
    do {
      try await fake.removeIdentity("i1", stepUp: nil)
      Issue.record("the last identity cannot be removed")
    } catch let error as HubError {
      #expect(error.code == "last_identity" && error.status == 409)
    }
    do {
      try await fake.removeIdentity("nope", stepUp: nil)
      Issue.record("an unknown identity is not found")
    } catch let error as HubError {
      #expect(error.code == "not_found" && error.status == 404)
    }
    #expect(await fake.removedIdentities == [added.id, "i1", "nope"])
  }

  @Test func endingASessionSignsOutUntilTheNextSignIn() async throws {
    let fake = FakeHubAPI()
    await fake.setSession(signedIn())
    _ = try await fake.passkeyFinish(
      PasskeyFinishRequest(ceremonyId: "c", assertion: ["id": "a"], attestation: nil, device: mac))
    try await fake.endSession()
    #expect(await fake.endSessionCalls == 1)
    do {
      _ = try await fake.me()
      Issue.record("a signed-out session is unauthorized")
    } catch let error as HubError {
      #expect(error.code == "unauthorized" && error.status == 401)
    }
    _ = try await fake.passkeyFinish(
      PasskeyFinishRequest(ceremonyId: "c", assertion: ["id": "a"], attestation: nil, device: mac))
    #expect(try await fake.me().deviceId == "dev-9")

    try await fake.deleteAccount(stepUp: nil)
    #expect(await fake.deleteAccountCalls == 1)
    do {
      _ = try await fake.identities()
      Issue.record("a deleted account is unauthorized")
    } catch let error as HubError {
      #expect(error.status == 401)
    }
  }

  @Test func enrollRecordsTheTokenItReplaces() async throws {
    let fake = FakeHubAPI(enrollmentCodes: ["ABCD2345": enrolled()])
    let request = EnrollRequest(code: "ABCD2345", deviceName: "Phone", platform: "ios")
    _ = try await fake.enroll(request, replacingToken: "phone-token")
    #expect(await fake.enrollTokens == ["phone-token"])
    await fake.addEnrollmentCode("ABCD2345", enrolled())
    _ = try await fake.enroll(request)
    #expect(await fake.enrollTokens == ["phone-token", nil])
  }

  @Test func failNextAppliesToTheAccountCalls() async throws {
    let fake = FakeHubAPI()
    let failure = HubError(kind: "request_error", code: "rate_limited", message: "slow down", status: 429)
    await fake.setFailNext(failure)
    do {
      _ = try await fake.passkeyBegin()
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == failure)
    }
    #expect(try await fake.passkeyBegin().ceremonyId.isEmpty == false)
  }
}

/// A pre-readiness conformer keeps working through the fail-closed protocol extension.
private struct LegacyOnlyHubAPI: HubAPI {
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    throw HubError.unsupported("enroll")
  }
  func me() async throws -> MeResponse { throw HubError.unsupported("me") }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { throw HubError.unsupported("push") }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    throw HubError.unsupported("pull")
  }
  func snapshot() async throws -> SnapshotResponse { throw HubError.unsupported("snapshot") }
  func devices() async throws -> [DeviceInfo] { throw HubError.unsupported("devices") }
  func mintPairingCode() async throws -> PairingCodeResponse { throw HubError.unsupported("mintPairingCode") }
  func revokeSelf() async throws { throw HubError.unsupported("revokeSelf") }
}

/// Owns only the finite HTTP peer resources used by the identity redirect test.
private final class IdentityRedirectPeer {
  private enum SetupError: Error { case missingPort, samePort }

  struct Facts {
    let sourceVisits: Int
    let destinationVisits: Int
    let sourceGETAndPathMatch: Bool
    let sourceRedirectFlushes: Int
    let registeredChildren: Int
    let closedChildren: Int
    let cleanupSucceeded: Bool
  }

  private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let state = State()
  private var listeners: [Channel] = []
  private var sourcePort = 0
  var baseURL: URL { URL(string: "http://127.0.0.1:\(sourcePort)")! }

  static func start(path: String) async throws -> IdentityRedirectPeer {
    let peer = IdentityRedirectPeer()
    do {
      let destination = try await peer.bind(path: path, location: nil)
      peer.listeners.append(destination)
      guard let destinationPort = destination.localAddress?.port else { throw SetupError.missingPort }
      let source = try await peer.bind(
        path: path, location: "http://127.0.0.1:\(destinationPort)/\(path)")
      peer.listeners.append(source)
      guard let sourcePort = source.localAddress?.port else { throw SetupError.missingPort }
      guard sourcePort != destinationPort else { throw SetupError.samePort }
      peer.sourcePort = sourcePort
      return peer
    } catch {
      let facts = await peer.stop()
      if !facts.cleanupSucceeded { Issue.record("Identity redirect peer setup cleanup failed") }
      throw error
    }
  }

  private func bind(path: String, location: String?) async throws -> Channel {
    let state = self.state
    return try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        let (entry, closing) = state.register(channel)
        if closing {
          state.requestClose(entry)
          return channel.eventLoop.makeSucceededFuture(())
        }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.configureHTTPServerPipeline()
          try channel.pipeline.syncOperations.addHandler(
            ResponseHandler(state: state, entry: entry, expectedPath: "/" + path, location: location))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
  }

  func stop() async -> Facts {
    state.beginClosing()
    var cleanupSucceeded = true
    for listener in listeners {
      var requestAllowed = true
      do { try await listener.close().get() } catch {
        requestAllowed = Self.isAlreadyClosed(error)
      }
      var exactCloseSucceeded = false
      do { try await listener.closeFuture.get(); exactCloseSucceeded = true } catch {}
      if !requestAllowed || !exactCloseSucceeded { cleanupSucceeded = false }
    }
    let children = state.children
    for entry in children { state.requestClose(entry) }
    for entry in children {
      do { try await entry.closeFuture.get() } catch { cleanupSucceeded = false }
    }
    do { try await group.shutdownGracefully() } catch { cleanupSucceeded = false }
    // No future APIs after shutdown: include every late registration using its cached exact witness.
    return state.finalFacts(cleanupSucceeded: cleanupSucceeded)
  }

  private static func isAlreadyClosed(_ error: any Error) -> Bool {
    guard let channelError = error as? ChannelError else { return false }
    if case .alreadyClosed = channelError { return true }
    return false
  }

  /// Entries never leave the registry; all mutable entry fields are protected by State.lock.
  private final class Child: @unchecked Sendable {
    let channel: Channel
    let closeFuture: EventLoopFuture<Void>
    var closeSucceeded: Bool?
    var pendingCloseRequests = 0
    var invalidCloseRequest = false

    init(_ channel: Channel) {
      self.channel = channel
      self.closeFuture = channel.closeFuture
    }
  }

  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Child] = []
    private var closing = false
    private var sourceVisits = 0
    private var destinationVisits = 0
    private var sourceGETAndPathMatch = true
    private var sourceRedirectFlushes = 0
    private var responseFailed = false

    func register(_ channel: Channel) -> (Child, Bool) {
      let entry = Child(channel)
      let closing = lock.withLock {
        entries.append(entry)
        return self.closing
      }
      // whenComplete may run inline; attach it outside the registry lock while the loop is alive.
      entry.closeFuture.whenComplete { result in
        self.lock.withLock {
          switch result {
          case .success: entry.closeSucceeded = true
          case .failure: entry.closeSucceeded = false
          }
        }
      }
      return (entry, closing)
    }

    func beginClosing() { lock.withLock { closing = true } }
    var children: [Child] { lock.withLock { entries } }

    func requestClose(_ entry: Child) {
      lock.withLock { entry.pendingCloseRequests += 1 }
      entry.channel.close().whenComplete { result in
        let requestAllowed: Bool
        switch result {
        case .success: requestAllowed = true
        case .failure(let error): requestAllowed = IdentityRedirectPeer.isAlreadyClosed(error)
        }
        self.lock.withLock {
          entry.pendingCloseRequests -= 1
          if !requestAllowed { entry.invalidCloseRequest = true }
        }
      }
    }

    func recordHead(isSource: Bool, matches: Bool) {
      lock.withLock {
        if isSource {
          sourceVisits += 1
          sourceGETAndPathMatch = sourceGETAndPathMatch && matches
        } else {
          destinationVisits += 1
        }
      }
    }

    func recordFlush(isSource: Bool, succeeded: Bool) {
      lock.withLock {
        if isSource && succeeded { sourceRedirectFlushes += 1 }
        if !succeeded { responseFailed = true }
      }
    }

    func recordResponseFailure() { lock.withLock { responseFailed = true } }

    func finalFacts(cleanupSucceeded: Bool) -> Facts {
      lock.withLock {
        let closed = entries.filter { $0.closeSucceeded == true }.count
        let exactClosesSucceeded = entries.allSatisfy { $0.closeSucceeded == true }
        let requestsCompleted = entries.allSatisfy {
          $0.pendingCloseRequests == 0 && !$0.invalidCloseRequest
        }
        return Facts(
          sourceVisits: sourceVisits, destinationVisits: destinationVisits,
          sourceGETAndPathMatch: sourceGETAndPathMatch, sourceRedirectFlushes: sourceRedirectFlushes,
          registeredChildren: entries.count, closedChildren: closed,
          cleanupSucceeded: cleanupSucceeded && exactClosesSucceeded && requestsCompleted && !responseFailed)
      }
    }
  }

  private final class ResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let state: State
    private let entry: Child
    private let expectedPath: String
    private let location: String?
    private var responded = false

    init(state: State, entry: Child, expectedPath: String, location: String?) {
      self.state = state
      self.entry = entry
      self.expectedPath = expectedPath
      self.location = location
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      switch unwrapInboundIn(data) {
      case .head(let head):
        state.recordHead(isSource: location != nil, matches: head.method == .GET && head.uri == expectedPath)
      case .body: break
      case .end:
        guard !responded else { return }
        responded = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "2")
        headers.add(name: "Connection", value: "close")
        if let location { headers.add(name: "Location", value: location) }
        let head = HTTPResponseHead(
          version: .http1_1, status: location == nil ? .ok : .found, headers: headers)
        var body = context.channel.allocator.buffer(capacity: 2)
        body.writeString("{}")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        let state = self.state
        let entry = self.entry
        let isSource = location != nil
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { result in
          switch result {
          case .success: state.recordFlush(isSource: isSource, succeeded: true)
          case .failure: state.recordFlush(isSource: isSource, succeeded: false)
          }
          state.requestClose(entry)
        }
      }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
      state.recordResponseFailure()
      state.requestClose(entry)
    }
  }
}
