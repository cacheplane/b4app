import Foundation
import WorkspaceProtocol

/// Wire types for the Claude Code CLI stream-json protocol as the TypeScript Agent SDK speaks it
/// (verified against SDK 0.3.314 and CLI 2.1.282 on 2026-10-30; undocumented, version-coupled).
public enum ClaudeStream {
  /// Launch arguments in the order the SDK uses. `cwd` is the spawn working directory, not a flag.
  public struct LaunchOptions: Sendable, Equatable {
    public var permissionMode: String = "default"
    public var settingSources: [String] = ["user", "project", "local"]
    public var includePartialMessages = true
    public var answerPermissions = true
    public var resumeSessionId: String?
    public var forkSession = false
    public var sessionId: String?
    public var model: String?
    public var maxTurns: Int?
    public var addDirectories: [String] = []
    public var replayUserMessages = true

    public init() {}

    public var arguments: [String] {
      var args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"]
      if let model { args += ["--model", model] }
      if let maxTurns { args += ["--max-turns", String(maxTurns)] }
      if answerPermissions { args.append("--permission-prompt-tool=stdio") }
      if let resumeSessionId { args += ["--resume", resumeSessionId] }
      if !settingSources.isEmpty { args += ["--setting-sources", settingSources.joined(separator: ",")] }
      args += ["--permission-mode", permissionMode]
      if includePartialMessages { args.append("--include-partial-messages") }
      if replayUserMessages { args.append("--replay-user-messages") }
      for dir in addDirectories { args += ["--add-dir", dir] }
      if forkSession { args.append("--fork-session") }
      if let sessionId { args += ["--session-id", sessionId] }
      return args
    }
  }

  /// Variables that would silently switch the session to API billing. Removed for plan auth.
  public static let inheritedCredentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

  /// Build the child environment: inherit, drop API credentials and NODE_OPTIONS, mark the entrypoint.
  public static func childEnvironment(from base: [String: String], clientVersion: String) -> [String: String]
  {
    var env = base
    for key in inheritedCredentialVariables { env[key] = nil }
    env["NODE_OPTIONS"] = nil
    env["CLAUDE_CODE_ENTRYPOINT"] = env["CLAUDE_CODE_ENTRYPOINT"] ?? "sdk-swift"
    env["CLAUDE_CODE_SDK_READS_SESSION_STATE"] = "1"
    env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "b4app/\(clientVersion)"
    return env
  }

  // MARK: - Outbound frames

  public static func initializeRequest(requestId: String) throws -> Data {
    try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_request", "request_id": .string(requestId),
        "request": ["subtype": "initialize", "hooks": [:]],
      ]))
  }

  public static func interruptRequest(requestId: String, cancelQueued: Bool) throws -> Data {
    var request: [String: JSONValue] = ["subtype": "interrupt"]
    if cancelQueued { request["cancel_queued"] = true }
    return try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_request", "request_id": .string(requestId), "request": .object(request),
      ]))
  }

  public static func setPermissionModeRequest(requestId: String, mode: String) throws -> Data {
    try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_request", "request_id": .string(requestId),
        "request": ["subtype": "set_permission_mode", "mode": .string(mode)],
      ]))
  }

  public static func userMessage(text: String, uuid: String) throws -> Data {
    try NDJSON.encodeLine(
      JSONValue.object([
        "type": "user", "session_id": "", "uuid": .string(uuid), "parent_tool_use_id": .null,
        "message": ["role": "user", "content": [["type": "text", "text": .string(text)]]],
      ]))
  }

  public enum PermissionDecision: Sendable, Equatable {
    case allow(updatedInput: JSONValue)
    case deny(message: String, interrupt: Bool)
  }

  public static func permissionResponse(
    requestId: String, toolUseId: String, decision: PermissionDecision
  ) throws -> Data {
    var response: [String: JSONValue] = ["toolUseID": .string(toolUseId)]
    switch decision {
    case .allow(let updatedInput):
      response["behavior"] = "allow"
      response["updatedInput"] = updatedInput
    case .deny(let message, let interrupt):
      response["behavior"] = "deny"
      response["message"] = .string(message)
      response["interrupt"] = .bool(interrupt)
    }
    return try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_response",
        "response": ["subtype": "success", "request_id": .string(requestId), "response": .object(response)],
      ]))
  }

  /// Answer AskUserQuestion: the original questions must be passed through alongside answers.
  public static func askUserQuestionAnswer(
    questions: JSONValue, answers: [String: JSONValue]
  ) -> PermissionDecision {
    .allow(updatedInput: ["questions": questions, "answers": .object(answers)])
  }

  public static func controlErrorResponse(requestId: String, message: String) throws -> Data {
    try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_response",
        "response": ["subtype": "error", "request_id": .string(requestId), "error": .string(message)],
      ]))
  }

  public static func elicitationDecline(requestId: String) throws -> Data {
    try NDJSON.encodeLine(
      JSONValue.object([
        "type": "control_response",
        "response": [
          "subtype": "success", "request_id": .string(requestId), "response": ["action": "decline"],
        ],
      ]))
  }

  // MARK: - Inbound frames

  public struct SystemInit: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String?
    public var model: String?
    public var tools: [String]
    public var permissionMode: String?
    public var apiKeySource: String?
    public var capabilities: [String]
    public var claudeCodeVersion: String?
  }

  public struct ResultFrame: Sendable, Equatable {
    public var subtype: String
    public var sessionId: String?
    public var isError: Bool
    public var numTurns: Int?
    public var durationMs: Int?
    public var totalCostUsd: Double?
    public var stopReason: String?
    public var terminalReason: String?
    public var result: String?
    public var errors: [String]
    public var userMessageUuid: String?
    public var isSuccess: Bool { subtype == "success" && !isError }
  }

  public struct ControlRequestFrame: Sendable, Equatable {
    public var requestId: String
    public var subtype: String
    public var request: JSONValue
    public var toolName: String? { request["tool_name"]?.stringValue }
    public var toolUseId: String? { request["tool_use_id"]?.stringValue }
    public var input: JSONValue { request["input"] ?? .null }
  }

  public struct ControlResponseFrame: Sendable, Equatable {
    public var requestId: String
    public var subtype: String
    public var response: JSONValue?
    public var error: String?
  }

  public enum Frame: Sendable, Equatable {
    case systemInit(SystemInit)
    case system(subtype: String, body: JSONValue)
    case assistant(JSONValue)
    case user(JSONValue)
    case streamEvent(JSONValue)
    case result(ResultFrame)
    case controlRequest(ControlRequestFrame)
    case controlResponse(ControlResponseFrame)
    case controlCancel(requestId: String)
    case keepAlive
    case unknown(type: String?, body: JSONValue)
  }

  /// Decode one stdout line. Never throws: unknown frames are returned as `.unknown`.
  public static func decodeFrame(_ line: String) -> Frame {
    guard let value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line.utf8)),
      case .object = value
    else {
      return .unknown(type: nil, body: .string(line))
    }
    let type = value["type"]?.stringValue
    switch type {
    case "system":
      let subtype = value["subtype"]?.stringValue ?? ""
      if subtype == "init" {
        return .systemInit(
          SystemInit(
            sessionId: value["session_id"]?.stringValue ?? "", cwd: value["cwd"]?.stringValue,
            model: value["model"]?.stringValue,
            tools: value["tools"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            permissionMode: value["permissionMode"]?.stringValue,
            apiKeySource: value["apiKeySource"]?.stringValue,
            capabilities: value["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            claudeCodeVersion: value["claude_code_version"]?.stringValue))
      }
      return .system(subtype: subtype, body: value)
    case "assistant": return .assistant(value)
    case "user": return .user(value)
    case "stream_event": return .streamEvent(value)
    case "result":
      return .result(
        ResultFrame(
          subtype: value["subtype"]?.stringValue ?? "", sessionId: value["session_id"]?.stringValue,
          isError: value["is_error"]?.boolValue ?? false,
          numTurns: value["num_turns"]?.numberValue.map(Int.init),
          durationMs: value["duration_ms"]?.numberValue.map(Int.init),
          totalCostUsd: value["total_cost_usd"]?.numberValue,
          stopReason: value["stop_reason"]?.stringValue,
          terminalReason: value["terminal_reason"]?.stringValue,
          result: value["result"]?.stringValue,
          errors: value["errors"]?.arrayValue?.compactMap(\.stringValue) ?? [],
          userMessageUuid: value["user_message_uuid"]?.stringValue))
    case "control_request":
      guard let requestId = value["request_id"]?.stringValue, let request = value["request"] else {
        return .unknown(type: type, body: value)
      }
      return .controlRequest(
        ControlRequestFrame(
          requestId: requestId, subtype: request["subtype"]?.stringValue ?? "", request: request))
    case "control_response":
      guard let response = value["response"], let requestId = response["request_id"]?.stringValue else {
        return .unknown(type: type, body: value)
      }
      return .controlResponse(
        ControlResponseFrame(
          requestId: requestId, subtype: response["subtype"]?.stringValue ?? "",
          response: response["response"],
          error: response["error"]?.stringValue))
    case "control_cancel_request":
      return .controlCancel(requestId: value["request_id"]?.stringValue ?? "")
    case "keep_alive": return .keepAlive
    default: return .unknown(type: type, body: value)
    }
  }
}
