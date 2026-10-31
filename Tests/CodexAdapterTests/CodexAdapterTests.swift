import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

private let handshake = """
  {"id":0,"result":{"userAgent":"codex/0.166.0","codexHome":"/Users/me/.codex","platformFamily":"unix","platformOs":"macos"}}
  {"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}
  """

private let approval =
  #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_2","command":["ls","-la"],"cwd":"/tmp","reason":null}}"#

private let turnStream = """
  {"method":"turn/started","params":{"turn":{"id":"turn_1","status":"inProgress","items":[],"error":null}}}
  {"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"id":"item_1","type":"agentMessage","text":""},"startedAtMs":1}}
  {"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"Hel"}}
  {"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"lo"}}
  {"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"id":"item_1","type":"agentMessage","text":"Hello"}}}
  {"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"completed","items":[],"error":null}}}
  """

private func kinds(_ messages: [RpcMessage]) -> [String] {
  messages.map { message in
    switch message {
    case .response: return "response"
    case .error: return "error"
    case .request(_, let method, _): return "request:\(method)"
    case .notification(let method, _): return "notification:\(method)"
    }
  }
}

@Suite struct JSONRPCTests {
  @Test func classifiesResponsesNotificationsAndServerRequests() {
    var decoder = RpcDecoder()
    let messages = decoder.push(handshake + "\n" + approval + "\n")
    #expect(
      kinds(messages) == [
        "response", "notification:account/updated", "request:item/commandExecution/requestApproval",
      ])
    if case .request(let id, _, let params) = messages[2] {
      #expect(id == .number(7))
      #expect(params["itemId"]?.stringValue == "item_2")
    }
  }

  @Test func reassemblesMessagesSplitAcrossArbitraryChunkBoundaries() {
    let text = turnStream + "\n"
    var whole = RpcDecoder()
    let reference = whole.push(text)
    for size in [1, 3, 7, 64] {
      var chunked = RpcDecoder()
      var collected: [RpcMessage] = []
      var index = text.startIndex
      while index < text.endIndex {
        let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
        collected += chunked.push(String(text[index..<end]))
        index = end
      }
      #expect(collected == reference)
    }
    #expect(
      kinds(reference) == [
        "notification:turn/started", "notification:item/started", "notification:item/agentMessage/delta",
        "notification:item/agentMessage/delta", "notification:item/completed", "notification:turn/completed",
      ])
  }

  @Test func reportsInvalidLinesWithoutThrowing() {
    var decoder = RpcDecoder()
    let messages = decoder.push("garbage\n{\"id\":1,\"result\":{}}\n{\"nope\":true}\n")
    #expect(messages.count == 1)
    #expect(decoder.invalidLines == ["garbage", "{\"nope\":true}"])
  }

  @Test func encodesWithoutJsonrpcFieldOneMessagePerLine() throws {
    let request = try JSONRPC.encodeRequest(
      id: .number(0), method: "initialize", params: ["clientInfo": ["name": "x"]])
    #expect(
      String(decoding: request, as: UTF8.self)
        == "{\"id\":0,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"x\"}}}\n")
    let response = try JSONRPC.encodeResponse(id: .number(7), result: ["decision": "accept"])
    #expect(String(decoding: response, as: UTF8.self) == "{\"id\":7,\"result\":{\"decision\":\"accept\"}}\n")
    let error = JSONRPC.classify(["id": 1, "error": ["code": -32001, "message": "overloaded"]])
    #expect(error == .error(id: .number(1), error: RpcError(code: -32001, message: "overloaded", data: nil)))
  }
}

@Suite struct CodexInspectorTests {
  private func fakeExecutable(_ name: String, versionLine: String) throws -> String {
    let dir = NSTemporaryDirectory() + "b4app-codex-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = dir + "/" + name
    try "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"\(versionLine)\"; exit 0; fi\nexit 1\n".write(
      toFile: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
    return file
  }

  @Test func reportsMissingExecutableWithInstallGuidance() async throws {
    let result = await CodexInspector.inspect(
      explicitPath: NSTemporaryDirectory() + "missing-codex", environment: ["PATH": "/usr/bin"])
    #expect(result.status == .error)
    #expect(result.error?.code == .missingExecutable)
    #expect(result.message?.contains("npm install -g @openai/codex") == true)
  }

  @Test func acceptsCompatibleVersion() async throws {
    let result = await CodexInspector.inspect(
      explicitPath: try fakeExecutable("codex", versionLine: "codex-cli 0.166.0"))
    #expect(result.status == .ready)
    #expect(result.version == "0.166.0")
    #expect(result.authStatus == .unknown)
  }

  @Test func flagsOlderExecutableAsIncompatible() async throws {
    let result = await CodexInspector.inspect(
      explicitPath: try fakeExecutable("codex", versionLine: "codex-cli 0.120.3"))
    #expect(result.status == .incompatible)
    #expect(result.error?.code == .incompatibleVersion)
  }

  @Test func unimplementedMethodsThrowUnsupportedCapability() async {
    let adapter = CodexAdapter(executablePath: nil)
    do {
      _ = try await adapter.createSession(NewSessionInput())
      Issue.record("expected throw")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
      #expect(error.details?["milestone"]?.stringValue == "M1")
    } catch {
      Issue.record("unexpected \(error)")
    }
  }
}
