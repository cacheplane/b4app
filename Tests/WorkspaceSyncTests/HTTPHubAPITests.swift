import Foundation
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
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
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

  @Test func appendFeedsAReaderAndALongPollWakesForIt() async throws {
    let fake = FakeHubAPI()
    async let page = fake.pull(after: 0, limit: 10, wait: 5)
    // Timed on purpose: lets the pull park in its long poll first; the fake reports no "parked" event.
    try await Task.sleep(for: .milliseconds(50))
    await fake.append([
      StoredChange(
        hubSeq: 1, deviceId: "other", deviceSeq: 1, wall: 1, table: "threads", rowId: "t", op: "delete")
    ])
    let result = try await page
    #expect(result.changes.count == 1 && result.next == 1)
  }
}
