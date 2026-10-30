import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

private func messages(_ text: String) -> [RpcMessage] {
  var decoder = RpcDecoder()
  return decoder.push(text + "\n")
}

private func events(_ text: String) -> [AdapterEvent] {
  messages(text).flatMap { CodexEventTranslator.translate($0, connectionId: "c1", generation: 3) }
}

private let turnStream = """
  {"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"inProgress","items":[],"error":null}}}
  {"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"id":"item_1","type":"agentMessage","text":""},"startedAtMs":1}}
  {"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"Hel"}}
  {"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_1","delta":"lo"}}
  {"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"id":"item_1","type":"agentMessage","text":"Hello"},"completedAtMs":2}}
  {"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","status":"completed","items":[],"error":null}}}
  """

@Suite struct CodexEventTranslatorTests {
  @Test func translatesAStreamedTurnInOrder() {
    let translated = events(turnStream)
    #expect(
      translated.map(\.kind) == [
        .turnAcknowledged, .messageStarted, .messageDelta, .messageDelta, .messageCompleted, .turnFinished,
      ])
    #expect(
      translated.allSatisfy { $0.nativeIds["threadId"] == "thr_1" && $0.nativeIds["turnId"] == "turn_1" })
    #expect(translated.allSatisfy { $0.adapterGeneration == 3 && $0.connectionId == "c1" })
    #expect(translated[2].nativeIds["itemId"] == "item_1")
    #expect(translated[2].payload["delta"]?.stringValue == "Hel")
    #expect(translated[4].payload["item"]?["text"]?.stringValue == "Hello")
    #expect(translated[4].payload["role"]?.stringValue == "assistant")
    #expect(translated[5].payload["outcome"]?.stringValue == "completed")
  }

  @Test func mapsInterruptedAndFailedTurns() {
    let interrupted = events(
      #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"interrupted","items":[],"error":null}}}"#
    )
    #expect(interrupted[0].payload["outcome"]?.stringValue == "cancelled")
    let failed = events(
      #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"failed","items":[],"error":{"message":"limit","codexErrorInfo":"usageLimitExceeded"}}}}"#
    )
    #expect(failed[0].payload["outcome"]?.stringValue == "failed")
    #expect(failed[0].payload["errorCode"]?.stringValue == "allowance_exceeded")
    #expect(failed[0].payload["error"]?["message"]?.stringValue == "limit")
    let unauthorized = CodexProtocol.errorCode(codexErrorInfo: "unauthorized")
    #expect(unauthorized == .authRequired)
    #expect(
      CodexProtocol.errorCode(codexErrorInfo: ["httpConnectionFailed": ["httpStatusCode": 502]])
        == .endpointUnavailable)
  }

  @Test func toolItemsBecomeToolEvents() {
    let translated = events(
      #"{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"id":"i9","type":"commandExecution","command":"ls","cwd":"/tmp","status":"completed","exitCode":0},"completedAtMs":5}}"#
    )
    #expect(translated[0].kind == .toolCompleted)
    #expect(translated[0].payload["role"]?.stringValue == "tool")
    #expect(translated[0].nativeIds["itemId"] == "i9")
  }

  @Test func commandApprovalRequestOpensARuntimeRequestWithSafePayload() {
    let translated = events(
      #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"item_2","command":"ls -la","cwd":"/tmp","reason":null,"environmentId":"env_secret","startedAtMs":1}}"#
    )
    #expect(translated.count == 1)
    #expect(translated[0].kind == .runtimeRequestOpened)
    #expect(translated[0].nativeIds["requestId"] == "7")
    #expect(translated[0].nativeIds["itemId"] == "item_2")
    #expect(translated[0].payload["kind"]?.stringValue == "command_approval")
    #expect(translated[0].payload["answerable"]?.boolValue == true)
    #expect(translated[0].payload["request"]?["command"]?.stringValue == "ls -la")
    #expect(translated[0].payload["request"]?["cwd"]?.stringValue == "/tmp")
    #expect(translated[0].payload["request"]?["environmentId"] == nil)
    #expect(translated[0].payload["request"]?["reason"] == nil)
  }

  @Test func classifiesEveryServerRequestMethod() {
    #expect(CodexProtocol.requestKind(method: "item/tool/requestUserInput") == .userQuestion)
    #expect(CodexProtocol.requestKind(method: "item/permissions/requestApproval") == .toolPermission)
    #expect(CodexProtocol.requestKind(method: "mcpServer/elicitation/request") == .elicitation)
    #expect(CodexProtocol.requestKind(method: "item/tool/call") == .unknown)
    #expect(CodexProtocol.requestKind(method: "execCommandApproval") == .commandApproval)
    #expect(CodexProtocol.requestKind(method: "something/new") == .unknown)
    for method in CodexProtocol.ServerRequestMethod.allCases where !method.answerable {
      let decline = CodexProtocol.declineResponse(method: method)
      if method == .authTokensRefresh || method == .attestation {
        #expect(decline == nil)
      } else {
        #expect(decline != nil, "\(method) needs an explicit decline body")
      }
    }
    #expect(CodexProtocol.declineResponse(method: .commandApproval) == ["decision": "decline"])
  }

  @Test func buildsDecisionAndAnswerBodies() {
    #expect(CodexProtocol.approvalResponse(.allowOnce, legacy: false) == ["decision": "accept"])
    #expect(CodexProtocol.approvalResponse(.allowAlways, legacy: false) == ["decision": "acceptForSession"])
    #expect(CodexProtocol.approvalResponse(.deny, legacy: false) == ["decision": "decline"])
    #expect(CodexProtocol.approvalResponse(.allowOnce, legacy: true) == ["decision": "approved"])
    #expect(CodexProtocol.approvalResponse(.deny, legacy: true)["decision"]?["denied"] != nil)
    let answers = CodexProtocol.userInputResponse(["q1": ["yes"], "q2": ["a", "b"]])
    #expect(answers["answers"]?["q1"]?["answers"] == ["yes"])
    #expect(answers["answers"]?["q2"]?["answers"]?.arrayValue?.count == 2)
  }

  @Test func accountStatusAndNotificationsMapToConnectionChanges() {
    let signedIn = events(#"{"method":"account/updated","params":{"authMode":"chatgpt","planType":"plus"}}"#)
    #expect(signedIn[0].kind == .connectionChanged)
    #expect(signedIn[0].payload["authStatus"]?.stringValue == "authenticated")
    let signedOut = events(#"{"method":"account/updated","params":{"authMode":null,"planType":null}}"#)
    #expect(signedOut[0].payload["authStatus"]?.stringValue == "required")
    let account = CodexAccount(
      accountReadResult: [
        "account": ["type": "chatgpt", "email": "me@example.com", "planType": "plus"],
        "requiresOpenaiAuth": true,
      ])
    #expect(account?.nativeScope == "me@example.com")
    #expect(CodexAccount(accountReadResult: ["account": .null, "requiresOpenaiAuth": true]) == nil)
    #expect(CodexAccount(accountReadResult: ["account": ["type": "apiKey"]])?.nativeScope == "apiKey")
  }

  @Test func threadStatusAndResolvedRequestsTranslate() {
    let waiting = events(
      #"{"method":"thread/status/changed","params":{"threadId":"t","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#
    )
    #expect(waiting[0].kind == .turnStateChanged)
    #expect(waiting[0].payload["status"]?.stringValue == "waiting_for_user")
    let resolved = events(#"{"method":"serverRequest/resolved","params":{"threadId":"t","requestId":7}}"#)
    #expect(resolved[0].kind == .runtimeRequestResolved)
    #expect(resolved[0].nativeIds["requestId"] == "7")
    #expect(events(#"{"method":"configWarning","params":{"summary":"x"}}"#).isEmpty)
  }

  @Test func snapshotItemsFlattenTurnsInOrder() {
    let page: JSONValue = [
      "data": [
        [
          "id": "turn_1", "status": "completed",
          "items": [
            ["id": "u1", "type": "userMessage", "content": [["type": "text", "text": "hi"]]],
            ["id": "a1", "type": "agentMessage", "text": "hello"],
          ],
        ],
        [
          "id": "turn_2", "status": "completed",
          "items": [["id": "c1", "type": "commandExecution", "command": "ls"]],
        ],
      ],
      "nextCursor": .null,
    ]
    let items = CodexEventTranslator.snapshotItems(turnsListResult: page)
    #expect(items.map(\.nativeItemId) == ["u1", "a1", "c1"])
    #expect(items.map(\.role) == ["user", "assistant", "tool"])
  }

  @Test func requestBuildersMatchTheWireShapes() throws {
    let start = CodexProtocol.threadStartParams(cwd: "/work")
    #expect(start == ["cwd": "/work", "serviceName": "agent_workspace"])
    let turn = CodexProtocol.turnStartParams(threadId: "thr_1", text: "Run tests", cwd: "/work")
    #expect(turn["input"] == [["type": "text", "text": "Run tests"]])
    #expect(turn["threadId"]?.stringValue == "thr_1")
    let initialize = CodexProtocol.initializeParams(version: "0.0.0")
    #expect(initialize["clientInfo"]?["name"]?.stringValue == "agent_workspace")
    #expect(initialize["capabilities"]?["experimentalApi"]?.boolValue == false)
    #expect(CodexProtocol.turnsListParams(threadId: "t")["itemsView"]?.stringValue == "full")
  }
}
