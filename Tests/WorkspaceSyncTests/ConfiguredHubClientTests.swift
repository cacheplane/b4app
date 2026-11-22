import Foundation
import Testing

@testable import WorkspaceSync

@Suite struct ConfiguredHubClientTests {
  private var unavailable: HubError {
    HubError(
      kind: "execution_error", code: "proof_unavailable",
      message: "The configured hub proof source is unavailable.", status: 0,
      retryAfterMs: nil, reason: nil, methods: nil)
  }

  @Test func lazyLiveConfiguration() throws {
    let host = "configured-lazy-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return "synthetic-lazy"
    }
    #expect(reads.value == 0 && recorder.all.isEmpty)
    let bundle = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    #expect(reads.value == 0 && recorder.all.isEmpty)
    let api = try #require(bundle.api as? HTTPHubAPI)
    let source = try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    try bundle.requireBinding(baseURL: base, credentials: credentials)
    #expect(try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect((bundle.api as? HTTPHubAPI) === api)
    #expect(reads.value == 0 && recorder.all.isEmpty)
  }

  @Test func independentLiveProductsStayDistinct() throws {
    let host = "configured-distinct-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return "synthetic-distinct"
    }
    let first = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let second = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let firstAPI = try #require(first.api as? HTTPHubAPI)
    let secondAPI = try #require(second.api as? HTTPHubAPI)
    let firstSource = try first.requireHTTPProofSource(baseURL: base, credentials: credentials)
    let secondSource = try second.requireHTTPProofSource(baseURL: base, credentials: credentials)
    #expect(firstAPI !== secondAPI && firstSource !== secondSource)
    #expect((first.api as? HTTPHubAPI) === firstAPI)
    #expect((second.api as? HTTPHubAPI) === secondAPI)
    #expect(try first.requireHTTPProofSource(baseURL: base, credentials: credentials) === firstSource)
    #expect(try second.requireHTTPProofSource(baseURL: base, credentials: credentials) === secondSource)
    #expect(reads.value == 0 && recorder.all.isEmpty)
  }

  @Test func fixtureHasNoProofSource() async throws {
    let host = "configured-fixture-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return "synthetic-fixture"
    }
    let fake = FakeHubAPI()
    let bundle = ConfiguredHubClient.fixtureAPI(fake, baseURL: base, credentials: credentials)
    #expect((bundle.api as? FakeHubAPI) === fake)
    try bundle.requireBinding(baseURL: base, credentials: credentials)
    #expect(throws: unavailable) {
      try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    }
    let me = try await bundle.api.me()
    #expect(me.deviceId == "fake-device")
    #expect(await fake.meCalls == 1)
    #expect(reads.value == 0 && recorder.all.isEmpty)
  }

  @Test func wrappingHTTPAsFixtureCannotUpgrade() async throws {
    let host = "configured-wrapped-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(
        200,
        #"{"ok":true,"migrations":"current","relay":"ok","instances":"ok","minClientProtocol":2,"supportedClientProtocol":2}"#
      )
    }
    let credentials = HubCredentialSource {
      reads.increment(); return "synthetic-wrapped"
    }
    let original = HTTPHubAPI(baseURL: base, token: { try await credentials.value() }, session: session)
    let bundle = ConfiguredHubClient.fixtureAPI(original, baseURL: base, credentials: credentials)
    #expect((bundle.api as? HTTPHubAPI) === original)
    try bundle.requireBinding(baseURL: base, credentials: credentials)
    #expect(throws: unavailable) {
      try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    }
    #expect(reads.value == 0 && recorder.all.isEmpty)
    let readiness = try await bundle.api.readiness()
    #expect(readiness.minClientProtocol == 2)
    #expect(recorder.all.count == 1)
    let sent = try #require(recorder.all.first)
    #expect(sent.request.url?.absoluteString == "\(base.absoluteString)/readyz")
    #expect(sent.request.httpMethod == "GET")
    #expect(sent.request.value(forHTTPHeaderField: "B4-Protocol") == "2")
    #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(reads.value == 0)
  }

  @Test func equalCredentialTextDoesNotReplaceIdentity() throws {
    let host = "configured-identity-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let originalReads = Counter(), replacementReads = Counter()
    let recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let original = HubCredentialSource {
      originalReads.increment(); return "same-synthetic-text"
    }
    let replacement = HubCredentialSource {
      replacementReads.increment(); return "same-synthetic-text"
    }
    #expect(original !== replacement)
    let live = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: original, session: session)
    let fixture = ConfiguredHubClient.fixtureAPI(FakeHubAPI(), baseURL: base, credentials: original)
    try live.requireBinding(baseURL: base, credentials: original)
    let source = try live.requireHTTPProofSource(baseURL: base, credentials: original)
    try fixture.requireBinding(baseURL: base, credentials: original)
    #expect(throws: unavailable) { try live.requireBinding(baseURL: base, credentials: replacement) }
    #expect(throws: unavailable) {
      try live.requireHTTPProofSource(baseURL: base, credentials: replacement)
    }
    #expect(throws: unavailable) { try fixture.requireBinding(baseURL: base, credentials: replacement) }
    #expect(try live.requireHTTPProofSource(baseURL: base, credentials: original) === source)
    #expect(originalReads.value == 0 && replacementReads.value == 0 && recorder.all.isEmpty)
  }

  @Test(arguments: ["other-host", "other-path", "trailing-slash", "query", "fragment", "scheme", "port"])
  func baseBindingIsExact(_ variant: String) throws {
    let host = "configured-base-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let alternatives = [
      "other-host": "https://other-\(host)/deployment",
      "other-path": "https://\(host)/another-deployment",
      "trailing-slash": "https://\(host)/deployment/",
      "query": "https://\(host)/deployment?mode=other",
      "fragment": "https://\(host)/deployment#other",
      "scheme": "http://\(host)/deployment",
      "port": "https://\(host):443/deployment",
    ]
    let alternateText = try #require(alternatives[variant])
    let alternate = try #require(URL(string: alternateText))
    #expect(alternate.absoluteString != base.absoluteString)
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return "synthetic-base"
    }
    let live = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let fixture = ConfiguredHubClient.fixtureAPI(FakeHubAPI(), baseURL: base, credentials: credentials)
    try live.requireBinding(baseURL: base, credentials: credentials)
    try fixture.requireBinding(baseURL: base, credentials: credentials)
    let source = try live.requireHTTPProofSource(baseURL: base, credentials: credentials)
    #expect(throws: unavailable) { try live.requireBinding(baseURL: alternate, credentials: credentials) }
    #expect(throws: unavailable) { try fixture.requireBinding(baseURL: alternate, credentials: credentials) }
    #expect(throws: unavailable) {
      try live.requireHTTPProofSource(baseURL: alternate, credentials: credentials)
    }
    #expect(try live.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect(reads.value == 0 && recorder.all.isEmpty)
  }

  @Test func ordinaryRequestsUseOriginalSessionAndReader() async throws {
    let host = "configured-ordinary-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let tokens = TokenSequence(["synthetic-A", "synthetic-B"])
    let credentials = HubCredentialSource {
      reads.increment(); return tokens.next()
    }
    let bundle = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let source = try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    #expect(reads.value == 0 && recorder.all.isEmpty)
    _ = try await bundle.api.push([])
    #expect(reads.value == 1 && recorder.all.count == 1)
    #expect(try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect(reads.value == 1 && recorder.all.count == 1)
    _ = try await bundle.api.push([])
    #expect(reads.value == 2 && recorder.all.count == 2)
    #expect(try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect(reads.value == 2 && recorder.all.count == 2)
    let requests = recorder.all.map(\.request)
    #expect(
      requests.map { $0.url?.absoluteString }
        == Array(repeating: "\(base.absoluteString)/v1/changes", count: 2))
    #expect(requests.map(\.httpMethod) == ["POST", "POST"])
    #expect(requests.map { $0.value(forHTTPHeaderField: "B4-Protocol") } == ["2", "2"])
    #expect(
      requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
        "Bearer synthetic-A", "Bearer synthetic-B",
      ])
    // These requests are simulated transport observations, not live authentication or receipt evidence.
  }

  @Test func nilCredentialPreservesOrdinaryBehavior() async throws {
    let host = "configured-nil-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return nil
    }
    let bundle = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let source = try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    #expect(reads.value == 0 && recorder.all.isEmpty)
    _ = try await bundle.api.push([])
    #expect(reads.value == 1 && recorder.all.count == 1)
    let sent = try #require(recorder.all.first)
    #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect(reads.value == 1 && recorder.all.count == 1)
    // Retrieving this marker does not establish a valid credential or session.
  }

  private enum ReaderFailure: Error, Equatable { case synthetic }

  @Test func readerFailureRemainsFailure() async throws {
    let host = "configured-reader-error-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/deployment")!
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); throw ReaderFailure.synthetic
    }
    let bundle = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let source = try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    #expect(reads.value == 0 && recorder.all.isEmpty)
    await #expect(throws: ReaderFailure.synthetic) { try await bundle.api.push([]) }
    #expect(reads.value == 1 && recorder.all.isEmpty)
    #expect(try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials) === source)
    #expect(reads.value == 1 && recorder.all.isEmpty)
  }

  @Test func descriptionsAndReflectionAreRedacted() throws {
    let host = "configured-redaction-\(UUID().uuidString.lowercased()).test"
    let base = URL(string: "https://\(host)/synthetic-private-deployment")!
    let secret = "synthetic-private-credential"
    let reads = Counter(), recorder = Recorder(), session = StubProtocol.session()
    defer { session.invalidateAndCancel(); StubProtocol.unregister(host: host) }
    StubProtocol.register(host: host) { request in
      recorder.add(request)
      return .json(200, #"{"acceptedThrough":0,"rejected":[]}"#)
    }
    let credentials = HubCredentialSource {
      reads.increment(); return secret
    }
    let bundle = ConfiguredHubClient.liveHTTP(baseURL: base, credentials: credentials, session: session)
    let source = try bundle.requireHTTPProofSource(baseURL: base, credentials: credentials)
    expectRedacted(credentials, as: "HubCredentialSource(redacted)", secret: secret, base: base)
    expectRedacted(bundle, as: "ConfiguredHubClient(redacted)", secret: secret, base: base)
    expectRedacted(source, as: "HTTPProofSource(redacted)", secret: secret, base: base)
    let fixture = ConfiguredHubClient.fixtureAPI(FakeHubAPI(), baseURL: base, credentials: credentials)
    #expect(throws: unavailable) {
      try fixture.requireHTTPProofSource(baseURL: base, credentials: credentials)
    }
    #expect(throws: unavailable) {
      try bundle.requireBinding(baseURL: base, credentials: HubCredentialSource { secret })
    }
    #expect(reads.value == 0 && recorder.all.isEmpty)
    // Only the new representations and refusals are covered; ordinary API values and reader errors are unchanged.
  }

  private func expectRedacted<T: CustomStringConvertible & CustomDebugStringConvertible & CustomReflectable>(
    _ value: T, as expected: String, secret: String, base: URL
  ) {
    let representations = [
      value.description, value.debugDescription, String(describing: value), String(reflecting: value),
    ]
    for representation in representations {
      #expect(representation == expected)
      #expect(!representation.contains(secret) && !representation.contains(base.absoluteString))
    }
    #expect(Mirror(reflecting: value).children.isEmpty)
  }
}
