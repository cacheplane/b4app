import Darwin
import Foundation
import Testing
import WorkspacePlatform

@testable import B4Adapter

@Suite struct AgentProtocolTransportTests {
  @Test func deploymentNormalizationPreservesCaseAndEncodedComponents() throws {
    let client = try AgentProtocolClient(
      baseURL: "https://EXAMPLE.com:443/Deploy/%61/", authentication: .none, decodingPolicy: .generic)
    #expect(client.baseURL.absoluteString == "https://example.com/Deploy/%61")
  }

  @Test func deploymentRejectsUserInfoQueryFragmentAndPathEscape() {
    for base in [
      "https://user:password@example.com/base", "https://example.com/base?token=private",
      "https://example.com/base#fragment", "https://example.com/base/../other",
      "https://example.com/base/%2e%2e/other", "http://example.com/base",
    ] {
      #expect(throws: AgentProtocolTransportError.invalidBaseURL) {
        _ = try AgentProtocolClient(baseURL: base, authentication: .none, decodingPolicy: .generic)
      }
    }
  }

  @Test func resourceIdentityIsOneComponentWithinDeployment() throws {
    let client = try AgentProtocolClient(
      baseURL: "https://example.com/one", authentication: .none, decodingPolicy: .generic)
    #expect(
      try client.url(for: .agent("route/child#agent")).absoluteString
        == "https://example.com/one/agents/route%2Fchild%23agent")
  }

  @Test func bearerDoesNotGuessAnotherSchemeFromWhitespace() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/one", authentication: .bearer(.make()), decodingPolicy: .generic,
        resolveSecret: { _ in "Basic synthetic-only" })
      _ = try await client.searchAgents()
      #expect(try await peer.records().first?["bearer"] == .bool(true))
    }
  }

  @Test func sseIDsPersistWithoutDispatchingControlOnlyFrames() {
    var parser = SSEParser()
    #expect(parser.push("id: cursor\n\n").isEmpty)
    let events = parser.push("data: one\n\ndata: two\n\nid:\n\ndata: three\n\n")
    #expect(events.map(\.data) == ["one", "two", "three"])
    #expect(events.map(\.id) == ["cursor", "cursor", ""])
  }

  @Test func sseRetryAcceptsOnlyASCIIDigits() {
    var parser = SSEParser()
    let events = parser.push("retry: +12\ndata: one\n\nretry: -1\ndata: two\n\nretry: 12\ndata: three\n\n")
    #expect(events.map(\.retry) == [nil, nil, 12])
  }

  @Test func sseEOFDiscardsUnterminatedEvent() {
    var parser = SSEParser()
    #expect(parser.push("data: incomplete").isEmpty)
    #expect(parser.flush() == nil)
  }

  @Test func sseIgnoresNulIDAndEventOnlyBlocks() {
    var parser = SSEParser()
    #expect(parser.push("event: ignored\nid: cursor\n\n").isEmpty)
    let events = parser.push("id: rejected\u{0}id\ndata: one\n\ndata:\n\n")
    #expect(
      events == [
        SSEEvent(event: nil, data: "one", id: "cursor"),
        SSEEvent(event: nil, data: "", id: "cursor"),
      ])
  }

  @Test func sseLoneCRDispatchesWithoutWaitingForAnotherChunk() {
    var parser = SSEParser()
    #expect(parser.push("data: complete\r\r") == [SSEEvent(event: nil, data: "complete")])
  }

  @Test func sseStripsOnlyOneLeadingBOM() {
    var parser = SSEParser()
    let bytes = Array("\u{feff}data: first\n\ndata: \u{feff}second\n\n".utf8)
    var events: [SSEEvent] = []
    for byte in bytes { events += parser.push([byte]) }
    #expect(events.map(\.data) == ["first", "\u{feff}second"])
  }

  @Test func splitUnicodeAndCRLFPreserveData() {
    let source = Array("\u{feff}: heartbeat\r\nid: cursor\r\nevent: message\r\ndata: 🦉 café\r\n\r\n".utf8)
    for size in [1, 2, 3, 7, 13] {
      var parser = SSEParser()
      var events: [SSEEvent] = []
      for start in stride(from: 0, to: source.count, by: size) {
        events += parser.push(Array(source[start..<min(source.count, start + size)]))
      }
      #expect(events == [SSEEvent(event: "message", data: "🦉 café", id: "cursor")])
    }
  }

  @Test func explicitAuthModesAreLazyAndScopedAcrossDiscovery() async throws {
    try await withProtocolPeer { peer in
      let reference = SecretRef.make()
      let resolutions = ResolutionCounter()
      let configurations: [(AgentProtocolClient.Authentication, String, String?)] = [
        (.none, "none", nil), (.bearer(reference), "bearer", "Basic synthetic-only"),
        (.header(name: "x-api-key", reference: reference), "apiKey", "synthetic-only"),
        (.header(name: "Authorization", reference: reference), "basic", "Basic synthetic-only"),
      ]
      for (authentication, prefix, value) in configurations {
        let client = try AgentProtocolClient(
          baseURL: peer.baseURL + "/" + prefix, authentication: authentication, decodingPolicy: .generic,
          resolveSecret: { ref in
            #expect(ref == reference)
            await resolutions.increment()
            return value
          })
        let before = await resolutions.count
        let agents = try await client.searchAgents()
        #expect(agents.count == 1)
        _ = try await client.agent(id: "route/child#agent")
        _ = try await client.schemas(agentID: "route/child#agent")
        #expect(await resolutions.count == before + (value == nil ? 0 : 3))
      }
      let records = try await peer.records()
      #expect(records.count == 12)
      for record in records {
        #expect(record["hasCookie"] == .bool(false))
        guard case .string(let path) = record["path"] else { Issue.record("missing path"); continue }
        #expect(path.contains("/agents/"))
        #expect(
          !path.contains("health") && !path.contains("ready") && !path.contains("agui")
            && !path.contains("memory") && !path.contains("threads"))
        if path.hasPrefix("/none/") { #expect(record["hasAuthorization"] == .bool(false)) }
        if path.hasPrefix("/bearer/") { #expect(record["bearer"] == .bool(true)) }
        if path.hasPrefix("/apiKey/") { #expect(record["apiKey"] == .bool(true)) }
        if path.hasPrefix("/basic/") { #expect(record["basic"] == .bool(true)) }
      }
    }
  }

  @Test func missingSecretAndInvalidHeaderNeverReachListener() async throws {
    try await withProtocolPeer { peer in
      let reference = SecretRef.make()
      for name in [
        "", "x key", "x\r\nkey", "Host", "Cookie", "Content-Length", "Transfer-Encoding", "Connection",
        "Upgrade", "Sec-WebSocket-Key", "Accept", "Content-Type", "Content-Encoding", "Proxy-Authorization",
        "Forwarded", "X-Forwarded-Host", "X-HTTP-Method-Override",
      ] {
        #expect(throws: AgentProtocolTransportError.invalidHeaderName) {
          _ = try AgentProtocolClient(
            baseURL: peer.baseURL, authentication: .header(name: name, reference: reference),
            decodingPolicy: .generic)
        }
      }
      let invalidValues: [String?] = [
        nil, "", "synthetic-only\r\nInjected: value", "synthetic-only\u{0}", "synthetic-only\t",
      ]
      for value in invalidValues {
        let client = try AgentProtocolClient(
          baseURL: peer.baseURL, authentication: .bearer(reference), decodingPolicy: .generic,
          resolveSecret: { _ in value })
        await #expect(throws: (any Error).self) { _ = try await client.searchAgents() }
      }
      #expect(try await peer.records().isEmpty)
    }
  }

  @Test func everyAuthModeUsesSameScopeForRESTSSEAndWebSocket() async throws {
    try await withProtocolPeer { peer in
      let reference = SecretRef.make()
      let cases: [(AgentProtocolClient.Authentication, String, String?)] = [
        (.none, "none", nil), (.bearer(reference), "bearer", "Basic synthetic-only"),
        (.header(name: "x-api-key", reference: reference), "apiKey", "synthetic-only"),
        (.header(name: "Authorization", reference: reference), "basic", "Basic synthetic-only"),
      ]
      for (authentication, prefix, value) in cases {
        let client = try AgentProtocolClient(
          baseURL: peer.baseURL + "/" + prefix, authentication: authentication, decodingPolicy: .generic,
          resolveSecret: { _ in
            guard let value else { throw SyntheticCredentialError() }
            return value
          })
        _ = try await client.request(.get, .thread("id"))
        let observation = try await client.observe(
          threadID: "id", body: .object(["channels": .array([.string("values")])]))
        for try await _ in observation.events {}
        observation.cancel()
        let socket = try await client.connect(threadID: "id")
        try await socket.send(makeCommand(id: 9))
        _ = try await socket.receive()
        socket.close()
      }
      let records = try await peer.records()
      let requests = records.filter { $0["path"] != nil }
      #expect(requests.count == 12)
      for record in requests {
        #expect(record["hasCookie"] == .bool(false))
        guard case .string(let path) = record["path"] else { Issue.record("missing path"); continue }
        if path.hasPrefix("/none/") { #expect(record["hasAuthorization"] == .bool(false)) }
        if path.hasPrefix("/bearer/") { #expect(record["bearer"] == .bool(true)) }
        if path.hasPrefix("/apiKey/") { #expect(record["apiKey"] == .bool(true)) }
        if path.hasPrefix("/basic/") { #expect(record["basic"] == .bool(true)) }
      }
    }
  }

  @Test func secretStoreIsReadLazilyAndChangesAreVisibleOnNextRequest() async throws {
    try await withProtocolPeer { peer in
      let store = MemorySecretStore()
      let reference = SecretRef.make()
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .bearer(reference), decodingPolicy: .generic,
        secretStore: store)
      await #expect(throws: AgentProtocolTransportError.credentialUnavailable) {
        _ = try await client.searchAgents()
      }
      try await store.put(reference, value: "Basic synthetic-only")
      _ = try await client.searchAgents()
      #expect(try await peer.records().count == 1)
    }
  }

  @Test func commandsCheckCorrelationAndSendOnlyOnce() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/one", authentication: .none, decodingPolicy: .generic)
      let normal = try await client.command(threadID: "id", command: makeCommand(id: 11))
      guard case .success(let success) = normal else { Issue.record("expected success"); return }
      #expect(success.id.rawValue == 11)
      var mismatch = try makeCommand(id: 12).raw
      mismatch["params"] = .object(["namespace": .array([.string("mismatch")])])
      let command = try JSONDecoder().decode(AgentProtocol.Command.self, from: JSONEncoder().encode(mismatch))
      await #expect(throws: AgentProtocolTransportError.correlationMismatch) {
        _ = try await client.command(threadID: "id", command: command)
      }
      #expect(try await peer.records().count == 2)
    }
  }

  @Test func normalizesOnlyOriginAndTrailingSlashAndRefusesUnsafePaths() throws {
    for base in ["https://EXAMPLE.com:443", "https://example.com/"] {
      #expect(
        try AgentProtocolClient(baseURL: base, authentication: .none, decodingPolicy: .generic).baseURL
          .absoluteString
          == "https://example.com")
    }
    for base in ["http://localhost:80/Base", "http://127.0.0.1/Base", "http://[::1]/Base"] {
      let client = try AgentProtocolClient(baseURL: base, authentication: .none, decodingPolicy: .generic)
      #expect(try client.url(for: .threadStream("id"), webSocket: true).scheme == "ws")
    }
    let remote = try AgentProtocolClient(
      baseURL: "https://example.com/Case/%61", authentication: .none, decodingPolicy: .generic)
    #expect(
      try remote.url(for: .threadStream("id"), webSocket: true).absoluteString
        == "wss://example.com/Case/%61/threads/id/stream")
    for bad in [
      "https://example.com/base/%2E./other", "https://example.com/base\\..\\other",
      "https://example.com/base/%2e%2e%2fother", "https://example.com:0", "https://example.com:99999",
      "https://example.com/base?", "https://example.com/base#",
    ] {
      #expect(throws: AgentProtocolTransportError.invalidBaseURL) {
        _ = try AgentProtocolClient(baseURL: bad, authentication: .none, decodingPolicy: .generic)
      }
    }
    for bad in ["", ".", "..", "id\u{0}"] {
      #expect(throws: AgentProtocolTransportError.invalidResourceID) { _ = try remote.url(for: .agent(bad)) }
    }
    #expect(
      try remote.url(for: .agent("/%2F #?é")).absoluteString
        == "https://example.com/Case/%61/agents/%2F%252F%20%23%3F%C3%A9")
    #expect(
      try remote.url(for: .agent("https://elsewhere.example/other")).absoluteString
        == "https://example.com/Case/%61/agents/https%3A%2F%2Felsewhere.example%2Fother")
    let repeated = try AgentProtocolClient(
      baseURL: "https://example.com/base//", authentication: .none, decodingPolicy: .generic)
    #expect(repeated.normalizedBaseURL == "https://example.com/base//")
    #expect(try repeated.url(for: .agentsSearch).absoluteString == "https://example.com/base//agents/search")
  }

  @Test func standardResourceInventoryStaysUnderSelectedPrefix() throws {
    let resources: [(AgentProtocolClient.Resource, String)] = [
      (.agentsSearch, "agents/search"), (.agent("id"), "agents/id"),
      (.agentSchemas("id"), "agents/id/schemas"),
      (.threads, "threads"), (.threadsSearch, "threads/search"), (.thread("id"), "threads/id"),
      (.threadHistory("id"), "threads/id/history"), (.threadCopy("id"), "threads/id/copy"),
      (.runs, "runs"), (.runsSearch, "runs/search"), (.run("id"), "runs/id"),
      (.runWait("id"), "runs/id/wait"),
      (.runStream("id"), "runs/id/stream"), (.runCancel("id"), "runs/id/cancel"), (.runsWait, "runs/wait"),
      (.runsStream, "runs/stream"),
      (.threadStream("id"), "threads/id/stream"), (.threadCommands("id"), "threads/id/commands"),
      (.storeItems, "store/items"), (.storeItemsSearch, "store/items/search"),
      (.storeNamespaces, "store/namespaces"),
    ]
    for prefix in ["/one", "/two/Case/%61"] {
      let client = try AgentProtocolClient(
        baseURL: "https://example.com" + prefix, authentication: .none, decodingPolicy: .generic)
      for (resource, suffix) in resources {
        #expect(try client.url(for: resource).absoluteString == "https://example.com" + prefix + "/" + suffix)
      }
    }
  }

  @Test func restMethodsAndQueryUseStandardPathsWithoutRetries() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/one", authentication: .none, decodingPolicy: .generic)
      let body: AgentProtocol.Value = .object(["metadata": .object(["label": .string("fixture")])])
      for method in [AgentProtocolClient.Method.get, .post, .patch, .delete, .put] {
        _ = try await client.request(
          method, .thread("id/#?"), body: method == .get ? nil : body,
          query: [URLQueryItem(name: "before", value: "a/#?&")])
      }
      let records = try await peer.records()
      #expect(records.count == 5)
      #expect(
        records.map { $0["method"] } == [
          .string("GET"), .string("POST"), .string("PATCH"), .string("DELETE"), .string("PUT"),
        ])
      for record in records {
        guard case .string(let path) = record["path"] else { Issue.record("missing path"); continue }
        #expect(path.hasPrefix("/one/threads/id%2F%23%3F?before="))
      }
    }
  }

  @Test func httpSSEAndWebSocketRefuseEveryRedirect() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/redirect", authentication: .bearer(.make()), decodingPolicy: .generic,
        resolveSecret: { _ in "Basic synthetic-only" })
      await #expect(throws: AgentProtocolTransportError.http(status: 307)) {
        _ = try await client.searchAgents()
      }
      await #expect(throws: AgentProtocolTransportError.http(status: 307)) {
        _ = try await client.observe(threadID: "id", body: .object(["channels": .array([.string("values")])]))
      }
      await #expect(throws: (any Error).self) { _ = try await client.connect(threadID: "id") }
      let records = try await peer.records()
      #expect(records.count == 3)
      #expect(
        records.allSatisfy { record in
          if case .string(let path) = record["path"] { return path.hasPrefix("/redirect/") }
          return false
        })
    }
  }

  @Test func observationKeepsSSECursorDistinctFromWireIdentity() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/one", authentication: .header(name: "x-api-key", reference: .make()),
        decodingPolicy: .generic,
        resolveSecret: { _ in "synthetic-only" })
      let observation = try await client.observe(
        threadID: "id/#", body: .object(["channels": .array([.string("values")])]))
      defer { observation.cancel() }
      var received: [AgentProtocolReceivedEvent] = []
      for try await event in observation.events { received.append(event) }
      #expect(received.count == 1)
      #expect(received.first?.lastEventID == "sse-cursor")
      guard case .event(let event) = received.first?.frame else { Issue.record("missing wire event"); return }
      #expect(event.eventID == "opaque-id")
      #expect(event.seq?.rawValue == 42)
      #expect(event.method == "future.extension")
      #expect(event.params["data"] == .string("🦉"))
      let records = try await peer.records()
      #expect(records.first?["path"] == .string("/one/threads/id%2F%23/stream"))
      #expect(records.first?["apiKey"] == .bool(true))
    }
  }

  @Test func realWebSocketUpgradeCommandsAndSharedDecode() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/two", authentication: .header(name: "Authorization", reference: .make()),
        decodingPolicy: .generic,
        resolveSecret: { _ in "Basic synthetic-only" })
      let socket = try await client.connect(threadID: "id/#")
      defer { socket.close() }
      let command = try makeCommand(id: 7)
      try await socket.send(command)
      guard case .success(let response) = try await socket.receive() else {
        Issue.record("expected success"); return
      }
      #expect(response.id.rawValue == 7)
      guard case .event(let event) = try await socket.receive() else {
        Issue.record("expected event"); return
      }
      #expect(event.eventID == "opaque-id" && event.seq?.rawValue == 42)
      let records = try await peer.records()
      #expect(records.first?["upgrade"] == .bool(true))
      #expect(records.first?["basic"] == .bool(true))
      #expect(records.first?["path"] == .string("/two/threads/id%2F%23/stream"))
      #expect(records.last?["webSocketCommand"] == .object(command.raw))
    }
  }

  @Test func httpAndCorrelatedASPErrorsHaveRedactedDiagnostics() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/http-error", authentication: .bearer(.make()), decodingPolicy: .generic,
        resolveSecret: { _ in "synthetic-only" })
      do {
        _ = try await client.searchAgents()
        Issue.record("expected HTTP failure")
      } catch {
        #expect(error as? AgentProtocolTransportError == .http(status: 401))
        expectRedacted(error)
      }
      let commands = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .none, decodingPolicy: .generic)
      let response = try await commands.command(threadID: "id", command: makeCommand(id: 8, reject: true))
      guard case .failure(let failure) = response else {
        Issue.record("expected correlated ASP failure"); return
      }
      #expect(failure.id?.rawValue == 8)
      #expect(failure.code == .permissionDenied)
      expectRedacted(failure)
    }
  }

  @Test func resolverFailuresNeverExposeRawCause() async throws {
    let client = try AgentProtocolClient(
      baseURL: "https://example.com", authentication: .bearer(.make()), decodingPolicy: .generic,
      resolveSecret: { _ in throw SyntheticCredentialError() })
    do { _ = try await client.searchAgents(); Issue.record("expected resolver failure") } catch {
      expectRedacted(error)
    }
  }

  @Test func sharedDecoderPreservesSnapshotsUnknownFramesAndValidatedReceipt() throws {
    let snapshot = try protocolFixture("hydration no invented sequence")
    guard
      case .snapshot(let decoded) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(snapshot), policy: .negotiatedB4V1)
    else {
      Issue.record("expected snapshot"); return
    }
    #expect(decoded.event.eventID == nil && decoded.event.seq == nil)
    #expect(decoded.delivery.throughSeq.rawValue == 5)
    let unknown: AgentProtocol.Value = .object([
      "type": .string("future"), "nested": .object(["v": .integer(9)]),
    ])
    guard
      case .opaque(let opaque) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(unknown), policy: .generic)
    else {
      Issue.record("expected opaque extension"); return
    }
    #expect(opaque == unknown)
    guard
      case .extensionEvent(let name, let data) = try AgentProtocolDecoder.decode(
        SSEEvent(event: "future", data: "opaque non-JSON", id: "cursor"), policy: .generic
      ).frame
    else { Issue.record("expected opaque SSE extension"); return }
    #expect(name == "future" && data == "opaque non-JSON")
    var failure = try protocolFixture("ASP error permission_denied")
    failure["message"] = .string("synthetic-only")
    failure["stacktrace"] = .string("Basic synthetic-only")
    failure["meta"] = .object([
      "b4": try protocolFixture("B4 receipt response"), "appliedThroughSeq": .integer(42),
      "unknown": .string("synthetic-only"),
    ])
    guard
      case .failure(let error) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(failure), policy: .negotiatedB4V1)
    else {
      Issue.record("expected ASP failure"); return
    }
    #expect(error.appliedThroughSeq?.rawValue == 42)
    #expect(error.receipt?.disposition == .accepted)
    expectRedacted(error)
    #expect(throws: AgentProtocolTransportError.invalidResponse) {
      _ = try AgentProtocolDecoder.decode(Data("synthetic-only".utf8), policy: .generic)
    }
  }

  @Test func commandFailureRetainsOnlySafeReceiptMachineFields() throws {
    for fixture in ["receipt", "native receipt"] {
      var receipt = try protocolFixture(fixture)
      receipt["echo"] = .string("synthetic-only")
      receipt["reason"] = .string("Basic synthetic-only")
      receipt["inputId"] = .string("0da04590-7139-4020-b6c0-de2c25b34f8c")
      if fixture == "native receipt" { receipt["submissionId"] = .string("synthetic-only") }
      let wireReceipt = try JSONDecoder().decode(
        AgentProtocol.Receipt.self, from: JSONEncoder().encode(receipt))
      #expect(wireReceipt.raw["echo"] == .string("synthetic-only"))
      #expect(wireReceipt.reason == "Basic synthetic-only")
      let error = try commandFailure(receipt: receipt)
      #expect(error.id?.rawValue == 1)
      #expect(error.receipt?.runID.rawValue.uuidString.lowercased() == "871e7ea2-7a46-4678-bcac-3a912de1b008")
      #expect(
        error.receipt?.turnID.rawValue.uuidString.lowercased() == "871e7ea2-7a46-4678-bcac-3a912de1b008")
      #expect(error.receipt?.replayed == false)
      #expect(error.receipt?.disposition == .accepted)
      #expect(
        error.receipt?.inputID?.rawValue.uuidString.lowercased() == "0da04590-7139-4020-b6c0-de2c25b34f8c")
      #expect(error.receipt?.acceptedAt.rawValue == "2026-11-05T12:00:00Z")
      #expect(error.receipt?.submissionKind == (fixture == "native receipt" ? .agui : .b4))
      if fixture == "native receipt" {
        #expect(error.receipt?.submissionID == nil)
      } else {
        #expect(
          error.receipt?.submissionID?.rawValue.uuidString.lowercased()
            == "871e7ea2-7a46-4678-bcac-3a912de1b008")
      }
      expectRedacted(error)
      #expect(!storedStrings(error).contains(where: { $0.contains("synthetic-only") }))
      let encoded = String(decoding: try JSONEncoder().encode(error.receipt), as: UTF8.self)
      #expect(!encoded.contains("synthetic-only"))
      let fullError = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
      #expect(!fullError.contains("synthetic-only"))
    }
  }

  @Test func commandFailurePreservesFixedB4DiagnosticDistinctions() throws {
    for diagnostic in AgentProtocolDiagnostic.allCases where diagnostic != .unrecognized {
      let code = diagnostic.rawValue
      let error = try commandFailure(diagnostic: code)
      #expect(error.code == .invalidArgument)
      #expect(error.diagnostic == diagnostic)
    }
    let unknown = try commandFailure(diagnostic: "synthetic-only")
    #expect(unknown.diagnostic == .unrecognized)
    expectRedacted(unknown)
    #expect(!storedStrings(unknown).contains(where: { $0.contains("synthetic-only") }))
  }

  @Test func httpCommandKeepsB4DiagnosticDistinctions() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .none, decodingPolicy: .negotiatedB4V1)
      for code in ["stale_generation", "receipt_expired", "resync_required", "synthetic-only"] {
        var command = try makeCommand(id: 17).raw
        command["params"] = .object(["namespace": .array([.string("diagnostic"), .string(code)])])
        let request = try JSONDecoder().decode(
          AgentProtocol.Command.self, from: JSONEncoder().encode(command))
        guard case .failure(let error) = try await client.command(threadID: "id", command: request) else {
          Issue.record("expected correlated diagnostic failure")
          continue
        }
        #expect(error.id?.rawValue == 17 && error.code == .invalidArgument)
        #expect(error.diagnostic?.rawValue == (code == "synthetic-only" ? "unrecognized" : code))
        #expect(!storedStrings(error).contains(where: { $0.contains("synthetic-only") }))
        expectRedacted(error)
      }
      #expect(try await peer.records().count == 4)
    }
  }

  @Test func genericEventPreservesUnnegotiatedB4WithoutAuthority() throws {
    for extra in genericB4Extras() {
      var wire = try protocolFixture("extensible event")
      wire["b4"] = extra
      do {
        guard
          case .event(let event) = try AgentProtocolDecoder.decode(
            JSONEncoder().encode(wire), policy: .generic)
        else {
          Issue.record("generic standard event was not delivered as an event")
          continue
        }
        #expect(event.raw == wireObject(wire))
        #expect(event.method == "lifecycle" && event.seq?.rawValue == 2)
        #expect(event.correlation == nil)
        #expect(event.standard.raw["b4"] == nil)
        #expect(try JSONDecoder().decode(AgentProtocol.Value.self, from: JSONEncoder().encode(event)) == wire)
      } catch { Issue.record("generic standard event rejected an unnegotiated optional extension") }
    }
  }

  @Test func genericSuccessPreservesUnnegotiatedResponseMetaWithoutReceipt() throws {
    for extra in genericB4Extras() + [try protocolFixture("B4 receipt response")] {
      var wire = try protocolFixture("response closed RunStartResponse")
      var meta = try protocolFixture("response meta extensible")
      meta["b4"] = extra
      wire["meta"] = meta
      do {
        guard
          case .success(let success) = try AgentProtocolDecoder.decode(
            JSONEncoder().encode(wire), policy: .generic)
        else {
          Issue.record("generic standard success was not delivered")
          continue
        }
        #expect(success.raw == wireObject(wire))
        #expect(success.meta?.appliedThroughSeq?.rawValue == 1)
        #expect(success.meta?.receipt == nil)
        #expect(success.standard.meta?.raw["b4"] == nil)
        #expect(
          try JSONDecoder().decode(AgentProtocol.Value.self, from: JSONEncoder().encode(success)) == wire)
      } catch { Issue.record("generic success rejected an unnegotiated optional ResponseMeta extension") }
    }
  }

  @Test func genericErrorDropsUnnegotiatedB4AtSafeErrorBoundary() throws {
    for extra in genericB4Extras() + [
      try protocolFixture("B4 receipt response"),
      .object(["v": .integer(1), "code": .string("stale_generation")]),
    ] {
      var wire = try protocolFixture("ASP error invalid_argument")
      wire["message"] = .string("synthetic-only")
      wire["meta"] = .object([
        "appliedThroughSeq": .integer(42), "b4": extra, "echo": .string("synthetic-only"),
      ])
      do {
        guard
          case .failure(let error) = try AgentProtocolDecoder.decode(
            JSONEncoder().encode(wire), policy: .generic)
        else {
          Issue.record("generic standard ASP error was not delivered")
          continue
        }
        #expect(error.id?.rawValue == 1 && error.code == .invalidArgument)
        #expect(error.appliedThroughSeq?.rawValue == 42)
        #expect(error.diagnostic == nil && error.receipt == nil)
        expectRedacted(error)
        #expect(!storedStrings(error).contains(where: { $0.contains("synthetic-only") }))
      } catch { Issue.record("generic ASP error rejected an unnegotiated optional ResponseMeta extension") }
    }
  }

  @Test func genericObservationPreservesUnnegotiatedB4() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/generic-extension", authentication: .none, decodingPolicy: .generic)
      let observation = try await client.observe(
        threadID: "id", body: .object(["channels": .array([.string("values")])]))
      defer { observation.cancel() }
      var count = 0
      for try await received in observation.events {
        guard case .event(let event) = received.frame else {
          Issue.record("expected generic event"); continue
        }
        #expect(
          event.raw["b4"]
            == .object(["v": .integer(2), "delivery": .string("snapshot"), "extra": .string("opaque")]))
        #expect(event.correlation == nil)
        #expect(event.method == "values" && event.seq?.rawValue == 42)
        #expect(received.lastEventID == "sse-cursor")
        count += 1
      }
      #expect(count == 1)
    }
  }

  @Test func genericWebSocketPreservesUnnegotiatedResponseAndEvent() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/generic-extension", authentication: .none, decodingPolicy: .generic)
      let socket = try await client.connect(threadID: "id")
      defer { socket.close() }
      try await socket.send(makeCommand(id: 19))
      guard case .success(let response) = try await socket.receive() else {
        Issue.record("expected generic success"); return
      }
      #expect(response.id.rawValue == 19 && response.meta?.appliedThroughSeq?.rawValue == 42)
      #expect(response.raw["meta"]?["b4"] == .string("opaque-unnegotiated"))
      #expect(response.meta?.receipt == nil)
      guard case .event(let event) = try await socket.receive() else {
        Issue.record("expected generic event"); return
      }
      #expect(event.method == "values" && event.correlation == nil)
      #expect(event.raw["b4"]?["v"] == .integer(2))
    }
  }

  @Test func genericHTTPCommandsPreserveSuccessExtrasAndSafeErrors() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/generic-extension", authentication: .none, decodingPolicy: .generic)
      guard
        case .success(let response) = try await client.command(threadID: "id", command: makeCommand(id: 20))
      else { Issue.record("expected generic success"); return }
      #expect(response.raw["meta"]?["b4"] == .string("opaque-unnegotiated"))
      #expect(response.meta?.appliedThroughSeq?.rawValue == 42 && response.meta?.receipt == nil)
      guard
        case .failure(let error) = try await client.command(
          threadID: "id", command: makeCommand(id: 21, reject: true))
      else { Issue.record("expected generic error"); return }
      #expect(error.id?.rawValue == 21 && error.code == .permissionDenied)
      #expect(error.diagnostic == nil && error.receipt == nil)
      expectRedacted(error)
      #expect(!storedStrings(error).contains(where: { $0.contains("synthetic-only") }))
      #expect(try await peer.records().count == 2)
    }
  }

  @Test func negotiatedPolicyKeepsFrozenB4ValidationAndGenericNeverInfersIt() throws {
    let validEvent = try protocolFixture("extensible event")
    guard
      case .event(let strict) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(validEvent), policy: .negotiatedB4V1),
      case .event(let generic) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(validEvent), policy: .generic)
    else { Issue.record("expected standard event views"); return }
    #expect(strict.correlation != nil && generic.correlation == nil)
    #expect(strict.raw == generic.raw)
    for extra in genericB4Extras() {
      var event = validEvent
      event["b4"] = extra
      #expect(throws: AgentProtocolTransportError.invalidResponse) {
        _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(event), policy: .negotiatedB4V1)
      }
      var success = try protocolFixture("response closed RunStartResponse")
      success["meta"] = .object(["b4": extra])
      #expect(throws: AgentProtocolTransportError.invalidResponse) {
        _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(success), policy: .negotiatedB4V1)
      }
      var error = try protocolFixture("ASP error invalid_argument")
      error["meta"] = .object(["b4": extra])
      #expect(throws: AgentProtocolTransportError.invalidResponse) {
        _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(error), policy: .negotiatedB4V1)
      }
    }
    let snapshot = try protocolFixture("hydration no invented sequence")
    guard
      case .snapshot(let validated) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(snapshot), policy: .negotiatedB4V1),
      case .event(let ordinary) = try AgentProtocolDecoder.decode(
        JSONEncoder().encode(snapshot), policy: .generic)
    else { Issue.record("snapshot classification must require negotiated B4"); return }
    #expect(validated.delivery.throughSeq.rawValue == 5)
    #expect(ordinary.correlation == nil && ordinary.raw == wireObject(snapshot))
    let invalidSnapshot = try protocolFixture("snapshot rejects invented journal sequence")
    #expect(throws: AgentProtocolTransportError.invalidResponse) {
      _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(invalidSnapshot), policy: .negotiatedB4V1)
    }
  }

  @Test func genericExtensionPolicyDoesNotRelaxStandardFields() throws {
    var event = try protocolFixture("extensible event")
    event["b4"] = .string("opaque")
    event["seq"] = .unsignedInteger(9_007_199_254_740_992)
    #expect(throws: AgentProtocolTransportError.invalidResponse) {
      _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(event), policy: .generic)
    }
    event["seq"] = .integer(1)
    event["method"] = .integer(1)
    #expect(throws: AgentProtocolTransportError.invalidResponse) {
      _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(event), policy: .generic)
    }
    var success = try protocolFixture("response closed RunStartResponse")
    success["meta"] = .object(["b4": .string("opaque"), "appliedThroughSeq": .integer(-1)])
    #expect(throws: AgentProtocolTransportError.invalidResponse) {
      _ = try AgentProtocolDecoder.decode(JSONEncoder().encode(success), policy: .generic)
    }
  }

  @Test func negotiatedTransportRejectsInvalidExtensionsWithoutPolicyFallback() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/generic-extension", authentication: .none, decodingPolicy: .negotiatedB4V1)
      #expect(client.decodingPolicy == .negotiatedB4V1)
      await #expect(throws: AgentProtocolTransportError.invalidResponse) {
        _ = try await client.command(threadID: "id", command: makeCommand(id: 22))
      }
      let observation = try await client.observe(
        threadID: "id", body: .object(["channels": .array([.string("values")])]))
      do {
        for try await _ in observation.events { Issue.record("invalid B4 event must not be delivered") }
        Issue.record("expected strict B4 stream failure")
      } catch { #expect(error as? AgentProtocolTransportError == .invalidResponse) }
      observation.cancel()
      let socket = try await client.connect(threadID: "id")
      defer { socket.close() }
      try await socket.send(makeCommand(id: 23))
      await #expect(throws: AgentProtocolTransportError.invalidResponse) { _ = try await socket.receive() }
      #expect(try await peer.records().count == 4)
    }
  }

  @Test func negotiatedTransportValidatesCorpusSnapshotsCorrelationAndReceipts() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL + "/b4-v1", authentication: .none, decodingPolicy: .negotiatedB4V1)
      guard
        case .success(let response) = try await client.command(threadID: "id", command: makeCommand(id: 24))
      else { Issue.record("expected B4 success"); return }
      #expect(response.meta?.receipt?.disposition == .accepted)
      let observation = try await client.observe(
        threadID: "snapshot", body: .object(["channels": .array([.string("values")])]))
      var snapshots = 0
      for try await received in observation.events {
        guard case .snapshot(let snapshot) = received.frame else {
          Issue.record("expected validated B4 snapshot"); continue
        }
        #expect(snapshot.delivery.throughSeq.rawValue == 5)
        #expect(snapshot.event.seq == nil && snapshot.event.eventID == nil)
        #expect(received.lastEventID == nil)
        snapshots += 1
      }
      observation.cancel()
      #expect(snapshots == 1)
      let socket = try await client.connect(threadID: "journal")
      defer { socket.close() }
      try await socket.send(makeCommand(id: 25))
      guard case .success(let socketResponse) = try await socket.receive(),
        case .event(let event) = try await socket.receive()
      else { Issue.record("expected B4 response and event"); return }
      #expect(socketResponse.meta?.receipt?.disposition == .accepted)
      #expect(
        event.correlation?.generation.rawValue.uuidString.lowercased()
          == "0da04590-7139-4020-b6c0-de2c25b34f8c")
      #expect(event.seq?.rawValue == 2)
    }
  }

  @Test func webSocketPendingReceiveCancellationSettlesWithoutExplicitClose() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .none, decodingPolicy: .generic)
      // Control: an idle open peer leaves a normal receive pending, and explicit close settles it.
      let control = try await client.connect(threadID: "close-control")
      let controlState = SocketOperationState()
      let controlGate = SocketOperationGate()
      let controlReader = socketReader(control, gate: controlGate, state: controlState)
      #expect(await waitForSocketOperation { await controlGate.waiting })
      await controlGate.open()
      #expect(await waitForSocketOperation { await controlState.started })
      #expect(!(await waitForSocketOperation(timeout: .milliseconds(100)) { await controlState.finished }))
      try await closeAndJoin(control, operation: controlReader, state: controlState)

      let socket = try await client.connect(threadID: "pending-cancel")
      let state = SocketOperationState()
      let gate = SocketOperationGate()
      let reader = socketReader(socket, gate: gate, state: state)
      #expect(await waitForSocketOperation { await gate.waiting })
      await gate.open()
      #expect(await waitForSocketOperation { await state.started })
      #expect(!(await waitForSocketOperation(timeout: .milliseconds(100)) { await state.finished }))
      reader.cancel()
      let settledBeforeClose = await waitForSocketOperation(timeout: .milliseconds(500)) {
        await state.finished
      }
      #expect(settledBeforeClose)
      try await closeAndJoin(socket, operation: reader, state: state)
      #expect(await state.failure != nil)
      #expect(try await peer.records().allSatisfy { $0["webSocketCommand"] == nil })
    }
  }

  @Test func webSocketPreCanceledReceiveDoesNotRegisterPendingRead() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .none, decodingPolicy: .generic)
      let socket = try await client.connect(threadID: "pre-cancelled-read")
      let state = SocketOperationState()
      let gate = SocketOperationGate()
      let reader = socketReader(socket, gate: gate, state: state)
      #expect(await waitForSocketOperation { await gate.waiting })
      reader.cancel()  // The gate guarantees cancellation precedes the call to receive().
      await gate.open()
      #expect(await waitForSocketOperation { await state.started })
      let settledBeforeClose = await waitForSocketOperation(timeout: .milliseconds(500)) {
        await state.finished
      }
      #expect(settledBeforeClose)
      try await closeAndJoin(socket, operation: reader, state: state)
      #expect(await state.failure != nil)
      #expect(try await peer.records().allSatisfy { $0["webSocketCommand"] == nil })
    }
  }

  @Test func webSocketPreCanceledSendDispatchesNoCommand() async throws {
    try await withProtocolPeer { peer in
      let client = try AgentProtocolClient(
        baseURL: peer.baseURL, authentication: .none, decodingPolicy: .generic)
      let control = try await client.connect(threadID: "send-control")
      try await control.send(makeCommand(id: 40))
      guard case .success(let acknowledgement) = try await control.receive() else {
        Issue.record("expected normal command acknowledgement"); control.close(); return
      }
      #expect(acknowledgement.id.rawValue == 40)
      control.close()

      let socket = try await client.connect(threadID: "pre-cancelled-send")
      let state = SocketOperationState()
      let gate = SocketOperationGate()
      let sender = Task {
        await gate.wait()
        await state.begin()
        do { try await socket.send(makeCommand(id: 41)); await state.returned() } catch {
          await state.failed(error)
        }
      }
      #expect(await waitForSocketOperation { await gate.waiting })
      sender.cancel()  // No send can begin until the already-canceled task leaves this gate.
      await gate.open()
      let settled = await waitForSocketOperation { await state.finished }
      #expect(settled)
      #expect(await state.failure != nil)
      // A bounded peer-record barrier catches dispatch even if the local write completes first.
      let dispatched = await waitForSocketOperation(timeout: .milliseconds(250)) {
        (try? await peer.records().contains { $0["webSocketCommand"]?["id"] == .integer(41) }) == true
      }
      #expect(!dispatched)
      try await closeAndJoin(socket, operation: sender, state: state)
      let commands = try await peer.records().compactMap { $0["webSocketCommand"] }
      #expect(commands.count == 1 && commands.first?["id"] == .integer(40))
      #expect(commands.allSatisfy { $0["method"] == .string("state.get") })
    }
  }
}

private actor SocketOperationGate {
  private(set) var waiting = false
  private var opened = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      waiting = true
    }
  }
  func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor SocketOperationState {
  private(set) var started = false
  private(set) var finished = false
  private(set) var failure: AgentProtocolTransportError?
  func begin() { started = true }
  func returned() { finished = true }
  func failed(_ error: any Error) {
    failure = error as? AgentProtocolTransportError
    expectRedacted(error)
    finished = true
  }
}

private func socketReader(
  _ socket: AgentProtocolClient.WebSocket, gate: SocketOperationGate, state: SocketOperationState
) -> Task<Void, Never> {
  Task {
    await gate.wait()
    await state.begin()
    do { _ = try await socket.receive(); await state.returned() } catch { await state.failed(error) }
  }
}

private func waitForSocketOperation(
  timeout: Duration = .seconds(2), _ predicate: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await predicate()
}

private func closeAndJoin(
  _ socket: AgentProtocolClient.WebSocket, operation: Task<Void, Never>, state: SocketOperationState
) async throws {
  socket.close()
  guard await waitForSocketOperation({ await state.finished }) else {
    operation.cancel()
    throw AgentProtocolTransportError.unavailable(code: nil)
  }
  await operation.value
}

private func genericB4Extras() -> [AgentProtocol.Value] {
  [
    .object(["v": .integer(2)]), .string("opaque-unnegotiated"),
    .object(["delivery": .string("snapshot"), "malformedForB4": .bool(true)]),
  ]
}

private func wireObject(_ value: AgentProtocol.Value) -> AgentProtocol.Object {
  guard case .object(let object) = value else { return [:] }
  return object
}

private func commandFailure(
  receipt: AgentProtocol.Value? = nil, diagnostic: String? = nil
) throws -> AgentProtocolCommandFailure {
  var raw = try protocolFixture("ASP error invalid_argument")
  var b4: AgentProtocol.Object = ["v": .integer(1)]
  if let receipt { b4["receipt"] = receipt }
  if let diagnostic { b4["code"] = .string(diagnostic) }
  raw["meta"] = .object(["b4": .object(b4)])
  guard
    case .failure(let error) = try AgentProtocolDecoder.decode(
      JSONEncoder().encode(raw), policy: .negotiatedB4V1)
  else {
    throw AgentProtocolTransportError.invalidResponse
  }
  return error
}

private func storedStrings(_ value: Any, depth: Int = 0) -> [String] {
  guard depth < 24 else { return [] }
  if let string = value as? String { return [string] }
  return Mirror(reflecting: value).children.flatMap { storedStrings($0.value, depth: depth + 1) }
}

private func protocolFixture(_ name: String) throws -> AgentProtocol.Value {
  struct Corpus: Decodable {
    let upstream: [AgentProtocol.Object]
    let b4: [AgentProtocol.Object]
  }
  let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
    "Fixtures/agent-protocol/agent-protocol.fixtures.json")
  let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
  let entries = corpus.upstream + corpus.b4
  return try #require(entries.first { $0["name"] == .string(name) }?["value"])
}

private actor ResolutionCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private struct SyntheticCredentialError: Error, LocalizedError {
  var errorDescription: String? { "synthetic-only" }
}

private func expectRedacted(_ error: any Error) {
  for diagnostic in [String(describing: error), String(reflecting: error), error.localizedDescription] {
    #expect(!diagnostic.contains("synthetic-only"))
    #expect(!diagnostic.contains("Basic synthetic"))
  }
  #expect(!storedStrings((error as NSError).userInfo).contains(where: { $0.contains("synthetic-only") }))
  if let encodable = error as? any Encodable {
    do {
      let encoded = String(decoding: try JSONEncoder().encode(encodable), as: UTF8.self)
      #expect(!encoded.contains("synthetic-only"))
    } catch { Issue.record("Could not encode a public machine error") }
  }
}

private func makeCommand(id: Int, reject: Bool = false) throws -> AgentProtocol.Command {
  let value: AgentProtocol.Value = .object([
    "id": .integer(Int64(id)), "method": .string("state.get"),
    "params": .object(["namespace": .array(reject ? [.string("reject")] : [])]),
  ])
  return try JSONDecoder().decode(AgentProtocol.Command.self, from: JSONEncoder().encode(value))
}

/// A real loopback listener owned by one test operation. No account/provider environment is inherited.
private final class ProtocolTestPeer: Sendable {
  let process: StreamingProcess
  let baseURL: String

  private init(process: StreamingProcess, baseURL: String) {
    self.process = process
    self.baseURL = baseURL
  }

  static func start() async throws -> ProtocolTestPeer {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/agent-protocol-transport.py").path
    var environment = [
      "PATH": "/usr/bin:/bin", "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp",
    ]
    if let directory = ProcessInfo.processInfo.environment["B4APP_A2_PEER_RECORD_DIR"] {
      environment["B4APP_A2_PEER_RECORD_DIR"] = directory
    }
    if let nonce = ProcessInfo.processInfo.environment["B4APP_A2_PEER_NONCE"] {
      environment["B4APP_A2_PEER_NONCE"] = nonce
    }
    let process = try StreamingProcess.start(
      executable: "/usr/bin/python3", arguments: [fixture],
      environment: environment)
    var buffer = ""
    for await chunk in process.stdout {
      buffer += String(decoding: chunk, as: UTF8.self)
      if let newline = buffer.firstIndex(of: "\n"), buffer.hasPrefix("listening on ") {
        let base = String(buffer[..<newline].dropFirst("listening on ".count))
        print(
          "A2 local peer started pid=\(process.processIdentifier) pgid=\(getpgid(process.processIdentifier)) url=\(base)"
        )
        return ProtocolTestPeer(process: process, baseURL: base)
      }
    }
    process.terminate()
    _ = await process.waitForExit()
    throw PeerFailure.didNotStart
  }

  func records() async throws -> [AgentProtocol.Object] {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, _) = try await session.data(from: URL(string: baseURL + "/records")!)
    return try JSONDecoder().decode([AgentProtocol.Object].self, from: data)
  }

  func stop() async {
    process.terminate()
    let exit = await process.waitForExit()
    if let directory = ProcessInfo.processInfo.environment["B4APP_A2_PEER_RECORD_DIR"] {
      let file = URL(fileURLWithPath: directory).appendingPathComponent("\(process.processIdentifier).json")
      if let data = try? Data(contentsOf: file),
        var record = try? JSONDecoder().decode(AgentProtocol.Object.self, from: data)
      {
        record["stopped"] = .bool(true)
        record["exit"] = .string(String(describing: exit))
        if let updated = try? JSONEncoder().encode(record) { try? updated.write(to: file, options: .atomic) }
      }
    }
    print("A2 local peer stopped pid=\(process.processIdentifier) exit=\(exit)")
  }

  private enum PeerFailure: Error { case didNotStart }
}

private func withProtocolPeer<T: Sendable>(
  _ operation: @Sendable (ProtocolTestPeer) async throws -> T
) async throws -> T {
  let peer = try await ProtocolTestPeer.start()
  do {
    let result = try await operation(peer)
    await peer.stop()
    return result
  } catch {
    await peer.stop()
    throw error
  }
}
