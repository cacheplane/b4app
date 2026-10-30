import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

private let loggedIn = """
  {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/Users/me/.claude/projects","configDirectory":"/Users/me/.claude","email":"me@example.com","orgId":"org_1","orgName":"Personal","subscriptionType":"pro"}
  """
private let loggedOut = """
  {"loggedIn":false,"authMethod":"none","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/Users/me/.claude/projects","configDirectory":"/Users/me/.claude"}
  """
private let apiKey = """
  {"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","analyticsDisabled":false,"projectsDirectory":"/Users/me/.claude/projects","configDirectory":"/Users/me/.claude"}
  """
private let clean = ["PATH": "/usr/bin"]

@Suite struct ClaudeAuthTests {
  @Test func acceptsPlanLoginWithoutInheritedCredentials() throws {
    let status = try #require(ClaudeAuthStatus.parse(loggedIn))
    let result = ClaudeAuth.assess(status, environment: clean)
    #expect(result.authStatus == .authenticated)
    #expect(result.nativeScope == "me@example.com")
    #expect(result.error == nil)
  }

  @Test func reportsAuthModeConflictWhenApiKeyIsInherited() throws {
    let status = try #require(ClaudeAuthStatus.parse(loggedIn))
    let result = ClaudeAuth.assess(status, environment: ["ANTHROPIC_API_KEY": "sk-x"])
    #expect(result.authStatus == .error)
    #expect(result.error?.code == .authModeConflict)
    #expect(!result.message.contains("sk-x"))
  }

  @Test func requiresSignInWhenLoggedOut() throws {
    let status = try #require(ClaudeAuthStatus.parse(loggedOut))
    let result = ClaudeAuth.assess(status, environment: clean)
    #expect(result.authStatus == .required)
    #expect(result.error?.code == .authRequired)
  }

  @Test func treatsApiKeyAuthAsModeConflict() throws {
    let status = try #require(ClaudeAuthStatus.parse(apiKey))
    #expect(ClaudeAuth.assess(status, environment: clean).error?.code == .authModeConflict)
  }

  @Test func returnsNilForMalformedOutput() {
    #expect(ClaudeAuthStatus.parse("not json") == nil)
    #expect(ClaudeAuthStatus.parse(#"{"loggedIn":"yes"}"#) == nil)
  }
}

@Suite struct ClaudeStreamTests {
  @Test func buildsLaunchArgumentsInSdkOrder() {
    var options = ClaudeStream.LaunchOptions()
    options.resumeSessionId = "sess_1"
    let args = options.arguments
    #expect(
      Array(args.prefix(5)) == [
        "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
      ])
    #expect(args.contains("--permission-prompt-tool=stdio"))
    #expect(args.contains("--include-partial-messages"))
    #expect(args.firstIndex(of: "--resume").map { args[$0 + 1] } == "sess_1")
    #expect(!args.contains("--bare"))
    #expect(!args.contains("-p"))
  }

  @Test func childEnvironmentDropsApiCredentials() {
    let env = ClaudeStream.childEnvironment(
      from: ["ANTHROPIC_API_KEY": "k", "NODE_OPTIONS": "x", "PATH": "/usr/bin"], clientVersion: "0.0.0")
    #expect(env["ANTHROPIC_API_KEY"] == nil)
    #expect(env["NODE_OPTIONS"] == nil)
    #expect(env["PATH"] == "/usr/bin")
    #expect(env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] == "1")
  }

  @Test func encodesInitializeAndUserFrames() throws {
    let initializeLine = String(decoding: try ClaudeStream.initializeRequest(requestId: "r1"), as: UTF8.self)
    #expect(
      initializeLine
        == "{\"request\":{\"hooks\":{},\"subtype\":\"initialize\"},\"request_id\":\"r1\",\"type\":\"control_request\"}\n"
    )
    let user = try JSONCoding.decoder.decode(
      JSONValue.self, from: try ClaudeStream.userMessage(text: "hi", uuid: "u1"))
    #expect(user["type"]?.stringValue == "user")
    #expect(user["message"]?["content"]?.arrayValue?.first?["text"]?.stringValue == "hi")
    #expect(user["parent_tool_use_id"]?.isNull == true)
  }

  @Test func decodesCanUseToolAndEncodesDecisions() throws {
    let line =
      #"{"type":"control_request","request_id":"abc","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"tool_use_id":"toolu_1"}}"#
    guard case .controlRequest(let request) = ClaudeStream.decodeFrame(line) else {
      Issue.record("expected control request")
      return
    }
    #expect(request.subtype == "can_use_tool")
    #expect(request.toolName == "Bash")
    #expect(request.input["command"]?.stringValue == "ls")
    let allow = try JSONCoding.decoder.decode(
      JSONValue.self,
      from: try ClaudeStream.permissionResponse(
        requestId: "abc", toolUseId: "toolu_1", decision: .allow(updatedInput: request.input)))
    #expect(allow["response"]?["request_id"]?.stringValue == "abc")
    #expect(allow["response"]?["response"]?["behavior"]?.stringValue == "allow")
    #expect(allow["response"]?["response"]?["updatedInput"]?["command"]?.stringValue == "ls")
    let deny = try JSONCoding.decoder.decode(
      JSONValue.self,
      from: try ClaudeStream.permissionResponse(
        requestId: "abc", toolUseId: "toolu_1", decision: .deny(message: "User declined", interrupt: false)))
    #expect(deny["response"]?["response"]?["behavior"]?.stringValue == "deny")
    #expect(deny["response"]?["response"]?["toolUseID"]?.stringValue == "toolu_1")
  }

  @Test func answersAskUserQuestionWithQuestionsPassedThrough() throws {
    let questions: JSONValue = [
      [
        "question": "Which?", "header": "Pick", "options": [["label": "A", "description": ""]],
        "multiSelect": false,
      ]
    ]
    let decision = ClaudeStream.askUserQuestionAnswer(questions: questions, answers: ["Which?": "A"])
    guard case .allow(let updated) = decision else {
      Issue.record("expected allow")
      return
    }
    #expect(updated["questions"] == questions)
    #expect(updated["answers"]?["Which?"]?.stringValue == "A")
  }

  @Test func decodesSystemInitAndResultFrames() {
    let initLine =
      #"{"type":"system","subtype":"init","session_id":"s1","cwd":"/tmp","model":"claude","tools":["Bash"],"permissionMode":"default","apiKeySource":"none","capabilities":["interrupt_receipt_v1"]}"#
    guard case .systemInit(let info) = ClaudeStream.decodeFrame(initLine) else {
      Issue.record("expected system init")
      return
    }
    #expect(info.sessionId == "s1")
    #expect(info.capabilities == ["interrupt_receipt_v1"])
    #expect(info.claudeCodeVersion == nil)
    let resultLine =
      #"{"type":"result","subtype":"success","session_id":"s1","is_error":false,"num_turns":1,"duration_ms":10,"total_cost_usd":0.01,"result":"done","stop_reason":"end_turn"}"#
    guard case .result(let result) = ClaudeStream.decodeFrame(resultLine) else {
      Issue.record("expected result")
      return
    }
    #expect(result.isSuccess)
    #expect(result.totalCostUsd == 0.01)
    #expect(ClaudeStream.decodeFrame(#"{"type":"keep_alive"}"#) == .keepAlive)
    if case .unknown(let type, _) = ClaudeStream.decodeFrame(#"{"type":"transcript_mirror"}"#) {
      #expect(type == "transcript_mirror")
    } else {
      Issue.record("expected unknown")
    }
  }
}

@Suite struct ClaudeInspectorTests {
  private func fake(version: String, authJson: String) throws -> String {
    let dir = NSTemporaryDirectory() + "b4app-claude-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = dir + "/claude"
    let json = authJson.replacingOccurrences(of: "'", with: "'\\''")
    let script =
      "#!/bin/sh\ncase \"$1\" in\n  --version) echo \"\(version) (Claude Code)\";;\n  auth) echo '\(json)';;\n  *) exit 1;;\nesac\n"
    try script.write(toFile: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
    return file
  }

  @Test func combinesVersionAndAuthThroughTheSameExecutable() async throws {
    let result = await ClaudeInspector.inspect(
      explicitPath: try fake(version: "2.1.282", authJson: loggedIn), environment: clean)
    #expect(result.status == .ready)
    #expect(result.version == "2.1.282")
    #expect(result.authStatus == .authenticated)
    #expect(result.nativeScope == "me@example.com")
  }

  @Test func reportsMissingExecutable() async {
    let result = await ClaudeInspector.inspect(
      explicitPath: NSTemporaryDirectory() + "missing-claude", environment: clean)
    #expect(result.error?.code == .missingExecutable)
  }

  @Test func flagsOldVersionBeforeCheckingAuth() async throws {
    let result = await ClaudeInspector.inspect(
      explicitPath: try fake(version: "1.0.99", authJson: loggedIn), environment: clean)
    #expect(result.status == .incompatible)
  }

  @Test func surfacesConflictFromEnvironmentDuringInspection() async throws {
    let result = await ClaudeInspector.inspect(
      explicitPath: try fake(version: "2.1.282", authJson: loggedIn),
      environment: ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk"])
    #expect(result.status == .ready)
    #expect(result.authStatus == .error)
    #expect(result.error?.code == .authModeConflict)
  }
}
