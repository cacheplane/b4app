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
  /// Text and thinking blocks the stream started and no `assistant` frame has completed yet, by
  /// message id, in stream order. Claude Code sends each block in its own `assistant` frame, so a
  /// frame's position is not the block's stream index; a completion takes the first of its type here.
  private var unfinished: [String: [(type: String, itemId: String)]] = [:]
  private var toolUses: [String: (name: String, input: JSONValue)] = [:]
  /// Tool uses whose permission the app refused (the user's "Deny", a decline, a stop). Claude Code
  /// reports each as an error result; it is the user's refusal, not the tool's failure (D-227).
  private var declinedToolUses: Set<String> = []
  /// Tool uses this turn closed as failed, as they were closed. Claude Code can say afterwards that it
  /// refused one itself (a `permission_denied` frame, the result's `permission_denials`); that one
  /// is closed again as declined (D-230).
  private var failedToolUses: [String: (use: (name: String, input: JSONValue)?, extra: [String: JSONValue])] =
    [:]
  private var lastErrorCode: ErrorCode?
  /// The session's task list (`TodoWrite` and the task tools): the turn's `taskList` item, not tool rows.
  private var tasks = ClaudeTaskFold()
  /// Task tools a sub-agent used, still waiting for their results. A sub-agent keeps its own list, and
  /// its lines are not in the session's transcript, so neither the list nor a row is made of them.
  private var subAgentTaskUses: Set<String> = []

  public init(connectionId: String, sessionId: String, generation: Int) {
    self.connectionId = connectionId
    self.sessionId = sessionId
    self.generation = generation
  }

  public mutating func beginTurn(uuid: String) {
    activeTurnUuid = uuid
    tasks.beginTurn()
    interruptRequested = false
    lastErrorCode = nil
  }

  public mutating func markInterruptRequested() { interruptRequested = true }

  /// The app refused this tool use's permission: its result is "declined", whatever Claude Code says.
  public mutating func markDeclined(toolUseId: String) { declinedToolUses.insert(toolUseId) }

  /// The refusal was never sent, so the tool use's result is its own.
  public mutating func unmarkDeclined(toolUseId: String) { declinedToolUses.remove(toolUseId) }

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
      case "permission_denied":
        // Claude Code refused the tool use without asking (a deny rule, the permission mode). The
        // frame can come before the tool use's error result or after it.
        guard let id = body["tool_use_id"]?.stringValue else { return [] }
        let closed = redecline(id)
        if closed.isEmpty { declinedToolUses.insert(id) }
        return closed
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
    case .rateLimit(let info):
      guard let reading = ClaudeUsage.reading(from: info, observedAt: Timestamp.now()),
        let event = try? AdapterEvent.usageChanged(
          connectionId: connectionId, reading: reading, adapterGeneration: generation)
      else { return [] }
      return [event]
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
        unfinished[messageId, default: []].append(("text", itemId))
        return [event(.messageStarted, item("agentMessage", role: .assistant, ["text": ""]), itemId: itemId)]
      case "tool_use":
        guard let id = block["id"]?.stringValue else { return [] }
        // A task tool is never a row: its `assistant` frame brings the input the list is made from.
        if let name = block["name"]?.stringValue, ClaudeTaskFold.toolNames.contains(name) { return [] }
        toolUses[id] = (block["name"]?.stringValue ?? "tool", .null)
        blocks[index] = ("tool_use", id)
        return [event(.toolStarted, toolItem(id: id, status: "inProgress"), itemId: id)]
      case "thinking":
        let itemId = "\(messageId)#\(index)"
        blocks[index] = ("thinking", itemId)
        unfinished[messageId, default: []].append(("thinking", itemId))
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
        let itemId = completedItemId(type: "text", messageId: messageId, index: index)
        events.append(
          event(
            .messageCompleted, item("agentMessage", role: .assistant, ["text": block["text"] ?? ""]),
            itemId: itemId))
      case "tool_use":
        guard let id = block["id"]?.stringValue else { continue }
        if let name = block["name"]?.stringValue, ClaudeTaskFold.toolNames.contains(name) {
          if value["parent_tool_use_id"]?.stringValue != nil {
            subAgentTaskUses.insert(id)
            continue
          }
          tasks.use(id: id, name: name, input: block["input"] ?? .null)
          continue
        }
        toolUses[id] = (block["name"]?.stringValue ?? "tool", block["input"] ?? .null)
        events.append(event(.toolStarted, toolItem(id: id, status: "inProgress"), itemId: id))
      case "thinking":
        let itemId = completedItemId(type: "thinking", messageId: messageId, index: index)
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

  /// The item a completed text or thinking block belongs to: the first block of that type the stream
  /// started for this message and nothing has completed yet; without one (nothing was streamed), the
  /// block's position in the frame.
  private mutating func completedItemId(type: String, messageId: String, index: Int) -> String {
    if let position = unfinished[messageId]?.firstIndex(where: { $0.type == type }) {
      return unfinished[messageId]!.remove(at: position).itemId
    }
    return "\(messageId)#\(index)"
  }

  private mutating func toolResults(_ value: JSONValue) -> [AdapterEvent] {
    if value["isReplay"]?.boolValue == true { return [] }
    var events: [AdapterEvent] = []
    for block in value["message"]?["content"]?.arrayValue ?? []
    where block["type"]?.stringValue == "tool_result" {
      guard let id = block["tool_use_id"]?.stringValue else { continue }
      let failed = block["is_error"]?.boolValue == true
      if subAgentTaskUses.remove(id) != nil {
        declinedToolUses.remove(id)
        continue
      }
      if tasks.owns(toolUseId: id) {
        // A refused task tool is the fold's failed result, not a declined row: nothing waits on the id.
        declinedToolUses.remove(id)
        let text = Self.text(of: block["content"]) ?? ""
        if let list = tasks.result(toolUseId: id, text: text, isError: failed) {
          events.append(taskListEvent(list))
        }
        continue
      }
      let declined = declinedToolUses.remove(id) != nil
      let extra: [String: JSONValue] = [
        "output": .string(Self.text(of: block["content"]) ?? ""), "isError": .bool(failed),
      ]
      events.append(
        event(
          .toolCompleted,
          toolItem(id: id, status: declined ? "declined" : failed ? "failed" : "completed", extra: extra),
          itemId: id))
      if failed, !declined { failedToolUses[id] = (toolUses[id], extra) }
      toolUses[id] = nil
    }
    return events
  }

  private func taskListEvent(_ list: SnapshotItem) -> AdapterEvent {
    event(
      .toolCompleted, ["item": list.payload, "role": .string(list.role), "type": .string(list.type)],
      itemId: list.nativeItemId)
  }

  /// Rebuild the session's task list from its transcript, for a session whose process was started
  /// again: the list lives for the session, and this tracker was made empty. Emits nothing.
  public mutating func seedTasks(transcriptLines: [String]) {
    seedTasks(Self.tasks(transcriptLines: transcriptLines))
  }

  /// The list a transcript holds, folded as the history import folds it.
  static func tasks(transcriptLines: [String]) -> ClaudeTaskFold {
    var fold = ClaudeTaskFold()
    _ = snapshotItems(transcriptLines: transcriptLines, tasks: &fold)
    fold.beginTurn()
    return fold
  }

  mutating func seedTasks(_ fold: ClaudeTaskFold) { tasks = fold }

  /// Close a tool use again as declined, if this turn closed it as failed: Claude Code refused it.
  private mutating func redecline(_ id: String) -> [AdapterEvent] {
    guard let closed = failedToolUses.removeValue(forKey: id) else { return [] }
    toolUses[id] = closed.use
    defer { toolUses[id] = nil }
    return [event(.toolCompleted, toolItem(id: id, status: "declined", extra: closed.extra), itemId: id)]
  }

  private mutating func finish(_ result: ClaudeStream.ResultFrame) -> [AdapterEvent] {
    // The turn's list item ends with the turn: a turn Claude Code starts itself is never begun by the
    // app, and history starts a new item at its user line.
    tasks.beginTurn()
    let reason = (result.terminalReason ?? "").lowercased()
    let outcome: TurnOutcome
    // A stop we asked for is a cancellation even though the real CLI reports it as an error result
    // (seen live with Claude Code 2.1.282); only an unrequested error is a failure.
    if interruptRequested || reason.contains("interrupt") || reason.contains("cancel")
      || reason.contains("abort")
    {
      outcome = .cancelled
    } else if result.isError {
      outcome = .failed
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
    // Claude Code's own record of what it refused this turn; `permission_denied` frames are advisory.
    let redeclined = result.permissionDenials.flatMap { redecline($0) }
    failedToolUses = [:]
    let finished = event(.turnFinished, .object(payload))
    activeTurnUuid = nil
    interruptRequested = false
    blocks = [:]
    unfinished = [:]
    return redeclined + [finished]
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
      let rules = sessionRules(request: request.request)
      if request.toolName != "AskUserQuestion", !rules.isEmpty {
        out[AllowScope.payloadKey] = .string(AllowScope.session.rawValue)
        out[AllowScope.rulePayloadKey] = .string(ruleText(rules))
      }
    } else if request.subtype == "elicitation" {
      out["message"] = request.request["message"] ?? ""
    }
    return .object(out)
  }

  /// The allow rules a `can_use_tool` request suggests, each re-addressed to the session, so the rule
  /// lives in the process and no settings file is written. A suggested mode change or directory is
  /// left out: "Allow for session" grants the rule the card shows and nothing more (D-250).
  static func sessionRules(request: JSONValue) -> [JSONValue] {
    (request["permission_suggestions"]?.arrayValue ?? []).compactMap { suggestion in
      guard suggestion["type"]?.stringValue == "addRules", suggestion["behavior"]?.stringValue == "allow",
        let rules = suggestion["rules"]?.arrayValue, !rules.isEmpty,
        rules.allSatisfy({ $0["toolName"]?.stringValue?.isEmpty == false }),
        case .object(var update) = suggestion
      else { return nil }
      update["destination"] = "session"
      return .object(update)
    }
  }

  /// The rules as Claude Code writes them, `Bash(touch one.txt)` or a bare tool name.
  static func ruleText(_ updates: [JSONValue]) -> String {
    updates.flatMap { $0["rules"]?.arrayValue ?? [] }.map { rule in
      let tool = rule["toolName"]?.stringValue ?? ""
      guard let content = rule["ruleContent"]?.stringValue, !content.isEmpty else { return tool }
      return "\(tool)(\(content))"
    }.joined(separator: ", ")
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
  ///
  /// An assistant block is named as the stream names it, `<message id>#<index>`, so a reconcile finds
  /// the row the live turn wrote (D-238). The transcript writes one line per block, each carrying the
  /// message's id, so the index is the block's position among all of that message's blocks, counted
  /// across lines. A line with no message id falls back to the line's `uuid`.
  ///
  /// The task tools are folded as the live tracker folds them: one `taskList` item for each turn that
  /// changed the list, under the same id, and no tool rows. A turn begins at a user line with text.
  public static func snapshotItems(transcriptLines: [String]) -> [SnapshotItem] {
    var tasks = ClaudeTaskFold()
    return snapshotItems(transcriptLines: transcriptLines, tasks: &tasks)
  }

  static func snapshotItems(transcriptLines: [String], tasks: inout ClaudeTaskFold) -> [SnapshotItem] {
    var items: [SnapshotItem] = []
    func place(_ list: SnapshotItem?, in items: inout [SnapshotItem]) {
      guard let list else { return }
      if let index = items.firstIndex(where: { $0.nativeItemId == list.nativeItemId }) {
        items[index] = list
      } else {
        items.append(list)
      }
    }
    var toolNames: [String: (name: String, input: JSONValue)] = [:]
    var blocksSeen: [String: Int] = [:]
    for line in transcriptLines {
      guard let value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line.utf8)),
        let type = value["type"]?.stringValue, type == "user" || type == "assistant",
        value["isMeta"]?.boolValue != true
      else { continue }
      let uuid = value["uuid"]?.stringValue ?? UUID().uuidString
      let content = value["message"]?["content"]
      // A compaction summary is a user line with text in the middle of a turn, not a turn.
      let beginsTurn = value["isCompactSummary"]?.boolValue != true
      if type == "user", let text = content?.stringValue {
        if beginsTurn { tasks.beginTurn() }
        items.append(
          SnapshotItem(
            nativeItemId: uuid, role: "user", type: "userMessage", payload: ["text": .string(text)]))
        continue
      }
      let messageId = type == "assistant" ? value["message"]?["id"]?.stringValue : nil
      for (index, block) in (content?.arrayValue ?? []).enumerated() {
        let id: String
        if let messageId {
          id = "\(messageId)#\(blocksSeen[messageId, default: 0])"
          blocksSeen[messageId, default: 0] += 1
        } else {
          id = "\(uuid)#\(index)"
        }
        switch block["type"]?.stringValue {
        case "thinking":
          guard type == "assistant" else { continue }
          items.append(
            SnapshotItem(
              nativeItemId: id, role: "assistant", type: "thinking",
              payload: ["text": block["thinking"] ?? ""]))
        case "text":
          if type == "user" {
            if beginsTurn { tasks.beginTurn() }
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
          if ClaudeTaskFold.toolNames.contains(name) {
            tasks.use(id: toolId, name: name, input: block["input"] ?? .null)
            continue
          }
          toolNames[toolId] = (name, block["input"] ?? .null)
          var body: [String: JSONValue] = [
            "id": .string(toolId), "name": .string(name), "input": block["input"] ?? .null,
            "status": "inProgress",
          ]
          if let command = block["input"]?["command"]?.stringValue { body["command"] = .string(command) }
          items.append(
            SnapshotItem(nativeItemId: toolId, role: "tool", type: "toolUse", payload: .object(body)))
        case "tool_result":
          guard let toolId = block["tool_use_id"]?.stringValue else { continue }
          if tasks.owns(toolUseId: toolId) {
            place(
              tasks.result(
                toolUseId: toolId, text: text(of: block["content"]) ?? "",
                isError: block["is_error"]?.boolValue == true), in: &items)
            continue
          }
          guard let index = items.lastIndex(where: { $0.nativeItemId == toolId }) else { continue }
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
