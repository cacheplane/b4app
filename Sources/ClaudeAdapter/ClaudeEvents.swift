import Foundation
import WorkspaceProtocol

/// Turns Claude Code stream-json frames into normalized adapter events for one native session.
/// Holds only what the protocol forces: the current assistant message id and block types from
/// `stream_event`, tool uses awaiting results, the active turn uuid, and the interrupt flag.
public struct ClaudeTurnTracker: Sendable {
  public let connectionId: String
  public let sessionId: String
  public var generation: Int
  public private(set) var activeTurnUuid: String?
  public private(set) var model: String?
  public private(set) var apiKeySource: String?
  private var interruptRequested = false
  private var currentMessageId: String?
  private var blocks: [Int: (type: String, itemId: String)] = [:]
  private var toolUses: [String: (name: String, input: JSONValue)] = [:]
  private var lastErrorCode: ErrorCode?

  public init(connectionId: String, sessionId: String, generation: Int) {
    self.connectionId = connectionId
    self.sessionId = sessionId
    self.generation = generation
  }

  public mutating func beginTurn(uuid: String) {
    activeTurnUuid = uuid
    interruptRequested = false
    lastErrorCode = nil
  }

  public mutating func markInterruptRequested() { interruptRequested = true }

  private func event(
    _ kind: EventKind, _ payload: JSONValue = [:], itemId: String? = nil, requestId: String? = nil
  ) -> AdapterEvent {
    var ids = ["threadId": sessionId]
    if let turn = activeTurnUuid { ids["turnId"] = turn }
    if let itemId { ids["itemId"] = itemId }
    if let requestId { ids["requestId"] = requestId }
    return AdapterEvent(
      kind: kind, connectionId: connectionId, nativeIds: ids, adapterGeneration: generation, payload: payload)
  }

  private func item(_ type: String, role: DisplayItemRole, _ body: [String: JSONValue]) -> JSONValue {
    var merged = body
    merged["type"] = .string(type)
    return ["item": .object(merged), "role": .string(role.rawValue), "type": .string(type)]
  }

  private func toolItem(id: String, status: String, extra: [String: JSONValue] = [:]) -> JSONValue {
    let use = toolUses[id]
    var body: [String: JSONValue] = [
      "id": .string(id), "name": .string(use?.name ?? "tool"), "input": use?.input ?? .null,
      "status": .string(status),
    ]
    if let command = use?.input["command"]?.stringValue { body["command"] = .string(command) }
    if let path = use?.input["file_path"]?.stringValue { body["path"] = .string(path) }
    body.merge(extra) { _, new in new }
    return item("toolUse", role: .tool, body)
  }

  // MARK: - Frames

  public mutating func translate(_ frame: ClaudeStream.Frame) -> [AdapterEvent] {
    switch frame {
    case .systemInit(let info):
      model = info.model
      apiKeySource = info.apiKeySource
      var events = [
        event(
          .turnStateChanged,
          [
            "status": .string(TurnStatus.running.rawValue), "nativeStatus": "init",
            "model": info.model.map(JSONValue.string) ?? .null,
            "claudeCodeVersion": info.claudeCodeVersion.map(JSONValue.string) ?? .null,
          ])
      ]
      if let source = info.apiKeySource, source != "none" {
        events.append(
          event(
            .adapterError,
            [
              "message": .string(
                "Claude Code is using API credentials (\(source)), not the Claude plan login. Unset them to keep plan billing."
              ),
              "errorCode": .string(ErrorCode.authModeConflict.rawValue), "willRetry": false,
            ]))
      }
      return events
    case .system(let subtype, let body):
      switch subtype {
      case "session_state_changed":
        let state = body["state"]?.stringValue ?? ""
        let mapped: String
        switch state {
        case "requires_action": mapped = TurnStatus.waitingForUser.rawValue
        case "running": mapped = TurnStatus.running.rawValue
        default: mapped = "idle"
        }
        return [event(.turnStateChanged, ["status": .string(mapped), "nativeStatus": .string(state)])]
      case "api_retry":
        return [
          event(
            .adapterError,
            [
              "message": body["error"] ?? "Claude is retrying an API request.", "willRetry": true,
              "errorCode": .string(ErrorCode.endpointUnavailable.rawValue),
            ])
        ]
      default:
        return []
      }
    case .streamEvent(let value):
      return streamEvent(value["event"] ?? [:])
    case .assistant(let value):
      return assistant(value)
    case .user(let value):
      return toolResults(value)
    case .result(let result):
      return finish(result)
    case .controlRequest(let request):
      return [requestOpened(request)]
    case .controlCancel(let requestId):
      return [event(.runtimeRequestResolved, ["source": "server"], requestId: requestId)]
    case .controlResponse, .keepAlive, .unknown:
      return []
    }
  }

  private mutating func streamEvent(_ raw: JSONValue) -> [AdapterEvent] {
    switch raw["type"]?.stringValue {
    case "message_start":
      currentMessageId = raw["message"]?["id"]?.stringValue
      blocks = [:]
      return []
    case "content_block_start":
      guard let index = raw["index"]?.numberValue.map(Int.init), let block = raw["content_block"],
        let type = block["type"]?.stringValue
      else { return [] }
      let messageId = currentMessageId ?? "message"
      switch type {
      case "text":
        let itemId = "\(messageId)#\(index)"
        blocks[index] = ("text", itemId)
        return [event(.messageStarted, item("agentMessage", role: .assistant, ["text": ""]), itemId: itemId)]
      case "tool_use":
        guard let id = block["id"]?.stringValue else { return [] }
        toolUses[id] = (block["name"]?.stringValue ?? "tool", .null)
        blocks[index] = ("tool_use", id)
        return [event(.toolStarted, toolItem(id: id, status: "inProgress"), itemId: id)]
      case "thinking":
        let itemId = "\(messageId)#\(index)"
        blocks[index] = ("thinking", itemId)
        return [event(.toolStarted, item("thinking", role: .assistant, ["text": ""]), itemId: itemId)]
      default:
        return []
      }
    case "content_block_delta":
      guard let index = raw["index"]?.numberValue.map(Int.init), let block = blocks[index],
        block.type == "text",
        let delta = raw["delta"]?["text"]?.stringValue
      else { return [] }
      return [event(.messageDelta, ["delta": .string(delta)], itemId: block.itemId)]
    default:
      return []
    }
  }

  private mutating func assistant(_ value: JSONValue) -> [AdapterEvent] {
    var events: [AdapterEvent] = []
    let message = value["message"] ?? [:]
    let messageId = message["id"]?.stringValue ?? currentMessageId ?? "message"
    if let errorName = value["error"]?.stringValue {
      let code = Self.errorCode(forAssistantError: errorName)
      lastErrorCode = code
      events.append(
        event(
          .adapterError,
          [
            "message": .string(Self.text(of: message["content"]) ?? errorName),
            "errorCode": .string(code.rawValue),
            "willRetry": false, "nativeError": .string(errorName),
          ]))
    }
    for (index, block) in (message["content"]?.arrayValue ?? []).enumerated() {
      switch block["type"]?.stringValue {
      case "text":
        let itemId = "\(messageId)#\(index)"
        events.append(
          event(
            .messageCompleted, item("agentMessage", role: .assistant, ["text": block["text"] ?? ""]),
            itemId: itemId))
      case "tool_use":
        guard let id = block["id"]?.stringValue else { continue }
        toolUses[id] = (block["name"]?.stringValue ?? "tool", block["input"] ?? .null)
        events.append(event(.toolStarted, toolItem(id: id, status: "inProgress"), itemId: id))
      case "thinking":
        let itemId = "\(messageId)#\(index)"
        events.append(
          event(
            .toolCompleted, item("thinking", role: .assistant, ["text": block["thinking"] ?? ""]),
            itemId: itemId))
      default:
        continue
      }
    }
    return events
  }

  private mutating func toolResults(_ value: JSONValue) -> [AdapterEvent] {
    if value["isReplay"]?.boolValue == true { return [] }
    var events: [AdapterEvent] = []
    for block in value["message"]?["content"]?.arrayValue ?? []
    where block["type"]?.stringValue == "tool_result" {
      guard let id = block["tool_use_id"]?.stringValue else { continue }
      let failed = block["is_error"]?.boolValue == true
      events.append(
        event(
          .toolCompleted,
          toolItem(
            id: id, status: failed ? "failed" : "completed",
            extra: ["output": .string(Self.text(of: block["content"]) ?? ""), "isError": .bool(failed)]),
          itemId: id))
      toolUses[id] = nil
    }
    return events
  }

  private mutating func finish(_ result: ClaudeStream.ResultFrame) -> [AdapterEvent] {
    let reason = result.terminalReason ?? ""
    let outcome: TurnOutcome
    if result.isError {
      outcome = .failed
    } else if interruptRequested || reason.contains("interrupt") || reason.contains("cancel") {
      outcome = .cancelled
    } else {
      outcome = .completed
    }
    var payload: [String: JSONValue] = [
      "outcome": .string(outcome.rawValue), "status": .string(result.subtype),
      "terminalReason": result.terminalReason.map(JSONValue.string) ?? .null,
      "numTurns": result.numTurns.map { .number(Double($0)) } ?? .null,
      "costUsd": result.totalCostUsd.map(JSONValue.number) ?? .null,
    ]
    if outcome == .failed {
      let message = result.result ?? result.errors.first ?? "Claude Code reported an error."
      payload["error"] = [
        "message": .string(message), "details": .array(result.errors.map(JSONValue.string)),
      ]
      payload["errorCode"] = .string(
        (lastErrorCode ?? Self.errorCode(forResultSubtype: result.subtype)).rawValue)
    }
    let finished = event(.turnFinished, .object(payload))
    activeTurnUuid = nil
    interruptRequested = false
    blocks = [:]
    return [finished]
  }

  private func requestOpened(_ request: ClaudeStream.ControlRequestFrame) -> AdapterEvent {
    let (kind, answerable) = Self.requestKind(subtype: request.subtype, toolName: request.toolName)
    return event(
      .runtimeRequestOpened,
      [
        "kind": .string(kind.rawValue), "method": .string(request.subtype), "answerable": .bool(answerable),
        "request": Self.safePayload(request),
      ],
      requestId: request.requestId)
  }

  /// Process exit with a turn in flight: the CLI process is the execution, so the turn is over.
  public mutating func processExited(status: String) -> [AdapterEvent] {
    var events: [AdapterEvent] = []
    if activeTurnUuid != nil {
      events.append(
        event(
          .turnFinished,
          [
            "outcome": .string(TurnOutcome.failed.rawValue), "status": "exited",
            "errorCode": .string((lastErrorCode ?? .internalError).rawValue),
            "error": ["message": .string("claude exited (\(status)) before the turn finished.")],
          ]))
      activeTurnUuid = nil
    }
    events.append(
      AdapterEvent(
        kind: .connectionChanged, connectionId: connectionId, nativeIds: ["threadId": sessionId],
        adapterGeneration: generation,
        payload: [
          "status": .string(ConnectionStatus.ready.rawValue),
          "authStatus": .string(AuthStatus.unknown.rawValue),
          "transport": .string(TransportStatus.disconnected.rawValue),
          "message": .string("claude exited (\(status)) for thread \(sessionId)."),
        ]))
    return events
  }

  // MARK: - Classification helpers

  public static func requestKind(subtype: String, toolName: String?) -> (RuntimeRequestKind, answerable: Bool)
  {
    switch subtype {
    case "can_use_tool":
      return toolName == "AskUserQuestion" ? (.userQuestion, true) : (.toolPermission, true)
    case "elicitation": return (.elicitation, false)
    default: return (.unknown, false)
    }
  }

  /// What the UI may see. Questions get synthetic ids `q0`, `q1`, … because the native shape has none.
  public static func safePayload(_ request: ClaudeStream.ControlRequestFrame) -> JSONValue {
    var out: [String: JSONValue] = [:]
    if let toolName = request.toolName { out["toolName"] = .string(toolName) }
    if let toolUseId = request.toolUseId { out["toolUseId"] = .string(toolUseId) }
    if request.subtype == "can_use_tool" {
      if request.toolName == "AskUserQuestion" {
        let questions = (request.input["questions"]?.arrayValue ?? []).enumerated().map { index, question in
          JSONValue.object([
            "id": .string("q\(index)"), "header": question["header"] ?? "",
            "question": question["question"] ?? "",
            "options": question["options"] ?? [], "multiSelect": question["multiSelect"] ?? false,
          ])
        }
        out["questions"] = .array(questions)
      } else {
        out["input"] = request.input
        if let command = request.input["command"]?.stringValue { out["command"] = .string(command) }
        if let path = request.input["file_path"]?.stringValue { out["path"] = .string(path) }
        if let description = request.input["description"]?.stringValue {
          out["reason"] = .string(description)
        }
      }
      if let reason = request.request["decision_reason"]?.stringValue {
        out["decisionReason"] = .string(reason)
      }
    } else if request.subtype == "elicitation" {
      out["message"] = request.request["message"] ?? ""
    }
    return .object(out)
  }

  static func errorCode(forAssistantError name: String) -> ErrorCode {
    switch name {
    case "authentication_failed", "unauthorized": return .authRequired
    case "rate_limit", "usage_limit", "billing_error": return .allowanceExceeded
    case "server_error", "overloaded", "connection_error": return .endpointUnavailable
    default: return .internalError
    }
  }

  static func errorCode(forResultSubtype subtype: String) -> ErrorCode {
    switch subtype {
    case "error_max_budget_usd": return .allowanceExceeded
    default: return .internalError
    }
  }

  /// Flatten Messages API content into text.
  static func text(of content: JSONValue?) -> String? {
    guard let content else { return nil }
    if let text = content.stringValue { return text }
    let parts = (content.arrayValue ?? []).compactMap { block -> String? in
      if block["type"]?.stringValue == "text" { return block["text"]?.stringValue }
      return nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  // MARK: - Transcript snapshots

  /// Items from the native transcript JSONL Claude Code writes (`user` and `assistant` lines).
  public static func snapshotItems(transcriptLines: [String]) -> [SnapshotItem] {
    var items: [SnapshotItem] = []
    var toolNames: [String: (name: String, input: JSONValue)] = [:]
    for line in transcriptLines {
      guard let value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line.utf8)),
        let type = value["type"]?.stringValue, type == "user" || type == "assistant",
        value["isMeta"]?.boolValue != true
      else { continue }
      let uuid = value["uuid"]?.stringValue ?? UUID().uuidString
      let content = value["message"]?["content"]
      if type == "user", let text = content?.stringValue {
        items.append(
          SnapshotItem(
            nativeItemId: uuid, role: "user", type: "userMessage", payload: ["text": .string(text)]))
        continue
      }
      for (index, block) in (content?.arrayValue ?? []).enumerated() {
        let id = "\(uuid)#\(index)"
        switch block["type"]?.stringValue {
        case "text":
          if type == "user" {
            items.append(
              SnapshotItem(
                nativeItemId: id, role: "user", type: "userMessage", payload: ["text": block["text"] ?? ""]))
          } else {
            items.append(
              SnapshotItem(
                nativeItemId: id, role: "assistant", type: "agentMessage",
                payload: ["text": block["text"] ?? ""]))
          }
        case "tool_use":
          guard let toolId = block["id"]?.stringValue else { continue }
          let name = block["name"]?.stringValue ?? "tool"
          toolNames[toolId] = (name, block["input"] ?? .null)
          var body: [String: JSONValue] = [
            "id": .string(toolId), "name": .string(name), "input": block["input"] ?? .null,
            "status": "inProgress",
          ]
          if let command = block["input"]?["command"]?.stringValue { body["command"] = .string(command) }
          items.append(
            SnapshotItem(nativeItemId: toolId, role: "tool", type: "toolUse", payload: .object(body)))
        case "tool_result":
          guard let toolId = block["tool_use_id"]?.stringValue,
            let index = items.lastIndex(where: { $0.nativeItemId == toolId })
          else { continue }
          var body = items[index].payload.objectValue ?? [:]
          body["status"] = block["is_error"]?.boolValue == true ? "failed" : "completed"
          body["output"] = .string(text(of: block["content"]) ?? "")
          items[index].payload = .object(body)
        default:
          continue
        }
      }
    }
    return items
  }
}
