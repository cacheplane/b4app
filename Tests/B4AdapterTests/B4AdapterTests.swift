import Foundation
import Testing
import WorkspaceProtocol

@testable import B4Adapter

private let successfulRun = [
  "event: chunk\ndata: \"Hello\"\n\n",
  "event: chunk\ndata: \", world\"\n\n",
  ": ping\n\n",
  "event: tool_call\ndata: {\"id\":\"call_1\",\"name\":\"search\",\"input\":{\"q\":\"b4\"}}\n\n",
  "event: tool_result\ndata: {\"id\":\"call_1\",\"name\":\"search\",\"output\":{\"hits\":2}}\n\n",
  "event: message_end\ndata: {\"messageId\":\"m1\"}\n\n",
  "event: done\ndata: {\"output\":{\"messages\":[{\"role\":\"assistant\",\"content\":\"Hello, world\"}]}}\n\n",
].joined()

private let parkedRun = [
  "event: chunk\ndata: \"Need approval\"\n\n",
  "event: interrupt\ndata: {\"interruptId\":\"int_1\",\"type\":\"permission-request\",\"kind\":\"tool\",\"detail\":{\"name\":\"shell\"}}\n\n",
  "event: done\ndata: {\"output\":null}\n\n",
].joined()

private let reattach = [
  "event: state\ndata: {\"status\":\"busy\",\"live\":true,\"anchor\":3,\"values\":{},\"input\":null,\"turn\":null,\"interrupts\":[]}\n\n",
  "retry: 2000\n",
  "event: chunk\ndata: \"more\"\n\n",
  "event: detached\ndata: {\"reason\":\"capacity\"}\n\n",
].joined()

private func parseAll(_ text: String, chunkSize: Int = Int.max) -> [B4StreamEvent] {
  var parser = SSEParser()
  var out: [B4StreamEvent] = []
  let bytes = Array(text.utf8)
  var index = 0
  while index < bytes.count {
    let end = min(index + chunkSize, bytes.count)
    out += parser.push(Array(bytes[index..<end])).map(B4StreamEvent.init)
    index = end
  }
  if let rest = parser.flush() { out.append(B4StreamEvent(rest)) }
  return out
}

@Suite struct SSEParserTests {
  @Test func parsesFullRunAndIgnoresHeartbeats() {
    let events = parseAll(successfulRun)
    #expect(events.count == 6)
    #expect(events[0] == .chunk("Hello"))
    #expect(events[2] == .toolCall(id: "call_1", name: "search", input: ["q": "b4"], messageId: nil))
    if case .done(let outcome, _, _) = events[5] {
      #expect(outcome == .completed)
    } else {
      Issue.record("expected done")
    }
  }

  @Test func yieldsIdenticalEventsForEveryChunkSize() {
    let reference = parseAll(successfulRun)
    for size in [1, 2, 3, 5, 7, 11, 64] {
      #expect(parseAll(successfulRun, chunkSize: size) == reference)
    }
  }

  @Test func joinsMultiLineDataWithNewlines() {
    var parser = SSEParser()
    let events = parser.push("event: note\ndata: line one\ndata: line two\n\n")
    #expect(events == [SSEEvent(event: "note", data: "line one\nline two")])
  }

  @Test func handlesCrlfSplitAcrossChunks() {
    let crlf = "event: chunk\r\ndata: \"a\"\r\n\r\nevent: chunk\r\ndata: \"b\"\r\n\r\n"
    let bytes = Array(crlf.utf8)
    var parser = SSEParser()
    var events: [SSEEvent] = []
    events += parser.push(Array(bytes[0..<13]))
    events += parser.push(Array(bytes[13..<14]))
    events += parser.push(Array(bytes[14...]))
    #expect(events.map(\.data) == ["\"a\"", "\"b\""])
  }

  @Test func distinguishesParkedFailedCancelledAndSnapshotOnly() {
    let parked = parseAll(parkedRun)
    #expect(
      parked[1]
        == .interrupt(
          interruptId: "int_1", type: "permission-request", kind: "tool", detail: ["name": "shell"],
          grant: nil,
          raw: [
            "interruptId": "int_1", "type": "permission-request", "kind": "tool", "detail": ["name": "shell"],
          ]))
    #expect(parked[2] == .done(.snapshotOnly, output: .null, error: nil))
    #expect(
      parseAll("event: done\ndata: {\"output\":{\"error\":\"boom\"}}\n\n")[0]
        == .done(.failed, output: ["error": "boom"], error: "boom"))
    #expect(
      parseAll("event: done\ndata: {\"output\":{\"cancelled\":true}}\n\n")[0]
        == .done(.cancelled, output: ["cancelled": true], error: nil))
  }

  @Test func parsesReattachStreamsWithStateRetryAndDetached() {
    let events = parseAll(reattach)
    #expect(events.count == 3)
    if case .state(let status, let live, _) = events[0] {
      #expect(status == "busy")
      #expect(live)
    } else {
      Issue.record("expected state")
    }
    #expect(events[2] == .detached(reason: "capacity"))
  }

  @Test func flushesTrailingEventWithoutBlankLine() {
    var parser = SSEParser()
    #expect(parser.push("event: chunk\ndata: \"tail\"").isEmpty)
    #expect(parser.flush() == SSEEvent(event: "chunk", data: "\"tail\""))
  }

  @Test func reportsUnknownEventsInsteadOfDroppingThem() {
    #expect(
      parseAll("event: plan_update\ndata: {\"steps\":[]}\n\n")[0]
        == .unknown(event: "plan_update", data: ["steps": []]))
  }
}

/// URLProtocol stub so inspection runs against canned responses without a real server.
final class StubProtocol: URLProtocol {
  nonisolated(unsafe) static var routes: [String: (Int, String, String)] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? ""
    nonisolated(unsafe) var recorded = StubProtocol.seenAuthorization
    recorded = request.value(forHTTPHeaderField: "Authorization")
    StubProtocol.seenAuthorization = recorded
    guard let (status, contentType, body) = StubProtocol.routes[path] else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  nonisolated(unsafe) static var seenAuthorization: String?

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }
}

@Suite(.serialized) struct B4InspectorTests {
  @Test func reportsReachableServerWithoutClaimingModelCredentials() async throws {
    StubProtocol.routes = [
      "/healthz": (200, "application/json", "{\"status\":\"ready\"}"),
      "/readyz": (
        503, "application/json", "{\"status\":\"not_ready\",\"checks\":{\"threads\":{\"status\":\"failed\"}}}"
      ),
    ]
    let result = await B4Inspector.inspect(
      baseURL: "https://agent.example.com", authorization: "Bearer test-token",
      session: StubProtocol.session())
    #expect(result.status == .ready)
    #expect(result.nativeScope == "https://agent.example.com")
    #expect(result.message?.contains("not verified") == true)
    #expect(result.message?.contains("not_ready") == true)
    #expect(StubProtocol.seenAuthorization == "Bearer test-token")
  }

  @Test func mapsConnectionFailureToOffline() async {
    let result = await B4Inspector.inspect(baseURL: "http://127.0.0.1:1")
    #expect(result.status == .offline)
    #expect(result.error?.code == .endpointUnavailable)
  }

  @Test func treatsNonJsonHealthzAsIncompatible() async {
    StubProtocol.routes = ["/base/healthz": (200, "text/html", "<html>")]
    let result = await B4Inspector.inspect(
      baseURL: "https://host.example/base", session: StubProtocol.session())
    #expect(result.status == .incompatible)
    #expect(result.error?.code == .incompatibleVersion)
  }

  @Test func rejectsPlainHttpForNonLoopbackHosts() async {
    let result = await B4Inspector.inspect(baseURL: "http://agent.example.com")
    #expect(result.status == .error)
    #expect(result.error?.code == .protocolInvalid)
    #expect(throws: Never.self) { try B4HTTPClient.assertAllowedOrigin("https://agent.example.com") }
    #expect(throws: Never.self) { try B4HTTPClient.assertAllowedOrigin("http://localhost:8000") }
  }

  @Test func preservesDeploymentBasePath() throws {
    let client = try B4HTTPClient(baseURL: "https://host/b4")
    #expect(client.resolve("/threads").absoluteString == "https://host/b4/threads")
    let slash = try B4HTTPClient(baseURL: "https://host/b4/")
    #expect(slash.resolve("threads/x/state").absoluteString == "https://host/b4/threads/x/state")
    #expect(client.origin == "https://host")
  }
}
