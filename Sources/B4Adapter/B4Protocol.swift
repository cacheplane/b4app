import Foundation
import WorkspaceProtocol

/// Exact route key `/<id>#<kind>` (spec section 9). Only `agent` routes carry the message input
/// shape the conversation uses; other kinds are reported as a compatibility result (D-023).
public struct B4RouteKey: Sendable, Equatable, Hashable {
  public static let kinds: Set<String> = ["agent", "workflow", "graph", "chain"]
  public let id: String
  public let kind: String

  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let hash = trimmed.lastIndex(of: "#") else { return nil }
    let id = String(trimmed[..<hash])
    let kind = String(trimmed[trimmed.index(after: hash)...])
    guard id.hasPrefix("/"), id.count > 1, !id.contains(where: { $0.isWhitespace || $0 == "#" }),
      Self.kinds.contains(kind)
    else { return nil }
    self.id = id
    self.kind = kind
  }

  public var key: String { "\(id)#\(kind)" }
  public var isAgent: Bool { kind == "agent" }
  /// `/research` → `research`; used as the default thread title.
  public var displayName: String { String(id.dropFirst()) }
}

/// Request bodies, error mapping, and history projection for the B4 Agent Protocol as served by
/// `@b4run/cli` 0.15.8 (`packages/cli/src/lib/dev/runtime-fetch-core.ts`, verified 2026-10-31).
public enum B4Protocol {
  public static func threadCreateBody(route: String, clientVersion: String) -> JSONValue {
    ["metadata": ["route": .string(route), "client": .string("b4app/\(clientVersion)")]]
  }

  /// `agent()` routes read `input.messages` and keep the `user` entries; `content` may be a string.
  public static func runBody(route: String, text: String) -> JSONValue {
    ["route": .string(route), "input": ["messages": [["role": "user", "content": .string(text)]]]]
  }

  /// B4's own permission decisions. `cancelled` is the resume status with no payload.
  public enum ResumeDecision: String, Sendable, Equatable {
    case once, always, deny, cancelled
  }

  /// Map the app's decision to B4's. `allow_always` becomes `once` when the prompt said
  /// `allowAlways: false` (D-021).
  public static func resumeDecision(_ decision: RuntimeDecision, allowAlways: Bool) -> ResumeDecision {
    switch decision {
    case .allowOnce: return .once
    case .allowAlways: return allowAlways ? .always : .once
    case .deny: return .deny
    }
  }

  /// Exactly `{ resume: [entry], route }`; any extra key is a 400 on the server.
  public static func resumeBody(
    route: String, interruptId: String, decision: ResumeDecision, grant: String?
  ) -> JSONValue {
    var entry: [String: JSONValue] = ["interruptId": .string(interruptId)]
    if decision == .cancelled {
      entry["status"] = "cancelled"
    } else {
      entry["status"] = "resolved"
      entry["payload"] = .string(decision.rawValue)
    }
    if let grant { entry["grant"] = .string(grant) }
    return ["resume": [.object(entry)], "route": .string(route)]
  }

  public static func errorCode(_ body: JSONValue?) -> String? {
    body?["error"]?["details"]?["code"]?.stringValue ?? body?["error"]?["code"]?.stringValue
  }

  public static func errorMessage(_ body: JSONValue?) -> String? {
    body?["error"]?["message"]?.stringValue
  }

  /// Map an HTTP failure to a stable app error code. Messages name the operation so a user can tell
  /// a rejected credential from a missing route from a server fault.
  public static func error(status: Int, body: JSONValue?, operation: String) -> WorkspaceError {
    let code = errorCode(body)
    let message = errorMessage(body) ?? "HTTP \(status)"
    var details: [String: JSONValue] = ["status": .number(Double(status)), "operation": .string(operation)]
    if let code { details["b4Code"] = .string(code) }
    switch (status, code) {
    case (401, _), (403, _):
      return WorkspaceError(
        .authRequired,
        "The B4 endpoint rejected \(operation) (\(status): \(message)). Check the endpoint credential.",
        details: .object(details))
    case (404, _) where message.hasPrefix("Unknown route"):
      return WorkspaceError(
        .incompatibleVersion, "\(message). The server does not serve the connection's route.",
        details: .object(details))
    case (404, _)
    where code == "thread_not_found" || message.localizedCaseInsensitiveContains("thread not found"):
      return WorkspaceError(
        .nativeSessionMissing,
        "The B4 server no longer has this thread. The cached transcript stays; start a new thread to continue.",
        details: .object(details))
    case (404, _):
      return WorkspaceError(
        .incompatibleVersion,
        "\(operation) is not served at this endpoint (404). It may not be a B4 Agent Protocol server.",
        details: .object(details))
    case (409, "run_in_flight"), (409, "resume_in_progress"):
      details["reason"] = "turn_active"
      return WorkspaceError(
        .protocolInvalid, "A run is already in flight on this thread.", details: .object(details))
    case (409, "stale_interrupt"), (409, "interrupt_set_mismatch"), (409, "resume_required"),
      (409, "malformed_checkpoint"):
      return WorkspaceError(
        .staleRuntimeRequest, "The B4 server did not accept the answer: \(message)", details: .object(details)
      )
    case (409, "no_run_in_flight"):
      details["reason"] = "no_run_in_flight"
      return WorkspaceError(
        .protocolInvalid, "No run is in flight on this thread.", details: .object(details))
    case (400..<500, _):
      return WorkspaceError(
        .protocolInvalid, "\(operation) was rejected (\(status)): \(message)", details: .object(details))
    default:
      return WorkspaceError(
        .internalError, "\(operation) failed on the server (\(status)): \(message)", details: .object(details)
      )
    }
  }

  /// B4 permission kinds onto the app's request kinds. `command` and `path` reuse the harness
  /// approval kinds so the same cards render; everything else is a tool permission.
  public static func requestKind(_ kind: String?) -> RuntimeRequestKind {
    switch kind {
    case "command": return .commandApproval
    case "path": return .fileChangeApproval
    default: return .toolPermission
    }
  }

  /// The turn list from `GET /threads/:id/turns`. The live server nests it (`turns: { threadId,
  /// turns: [...] }`, the `TurnsView` object); the flat form is accepted too.
  public static func turnList(_ body: JSONValue?) -> [JSONValue]? {
    body?["turns"]?["turns"]?.arrayValue ?? body?["turns"]?.arrayValue
  }

  /// `TurnView.status` from `GET /threads/:id/turns` onto a turn outcome; `working` and `awaiting`
  /// are not outcomes.
  public static func turnOutcome(turnStatus: String?) -> TurnOutcome? {
    switch turnStatus {
    case "done": return .completed
    case "failed": return .failed
    case "stopped": return .cancelled
    default: return nil
    }
  }

  // MARK: - Messages

  /// One normalized message from either a plain `{ role, content }` object or a LangChain
  /// serialization envelope (`{ lc: 1, id: [..., "HumanMessage"], kwargs: {...} }`).
  struct Message {
    var role: String
    var text: String
    var toolCalls: [JSONValue]
    var toolCallId: String?
    var id: String?
  }

  static func message(_ value: JSONValue) -> Message? {
    let body: JSONValue
    let role: String
    if value["lc"] != nil, let cls = value["id"]?.arrayValue?.last?.stringValue {
      body = value["kwargs"] ?? .null
      switch cls {
      case "HumanMessage", "HumanMessageChunk": role = "user"
      case "AIMessage", "AIMessageChunk": role = "assistant"
      case "ToolMessage", "ToolMessageChunk": role = "tool"
      default: return nil
      }
    } else if let plain = value["role"]?.stringValue {
      body = value
      role = plain
    } else {
      return nil
    }
    return Message(
      role: role, text: text(of: body["content"]), toolCalls: body["tool_calls"]?.arrayValue ?? [],
      toolCallId: body["tool_call_id"]?.stringValue, id: body["id"]?.stringValue)
  }

  static func text(of content: JSONValue?) -> String {
    if let string = content?.stringValue { return string }
    guard let parts = content?.arrayValue else { return "" }
    return parts.compactMap { part -> String? in
      if let string = part.stringValue { return string }
      if part["type"]?.stringValue == "text" { return part["text"]?.stringValue }
      return nil
    }.joined()
  }

  /// The last assistant text in a `done` output (`{ messages: [...] }` or `{ update: { messages } }`).
  public static func assistantText(fromDoneOutput output: JSONValue) -> String? {
    let messages = output["messages"]?.arrayValue ?? output["update"]?["messages"]?.arrayValue ?? []
    return messages.reversed().lazy.compactMap(message).first { $0.role == "assistant" && !$0.text.isEmpty }?
      .text
  }

  /// History from `GET /threads/:id/state` `values.messages`. Tool results are folded into their
  /// tool call items; unknown message classes are skipped rather than guessed.
  public static func snapshotItems(stateValues: JSONValue) -> [SnapshotItem] {
    let messages = (stateValues["messages"]?.arrayValue ?? []).compactMap(message)
    var results: [String: String] = [:]
    for entry in messages where entry.role == "tool" {
      if let id = entry.toolCallId { results[id] = entry.text }
    }
    var items: [SnapshotItem] = []
    for entry in messages {
      switch entry.role {
      case "user":
        items.append(
          SnapshotItem(
            nativeItemId: entry.id, role: "user", type: "userMessage", payload: ["text": .string(entry.text)])
        )
      case "assistant":
        if !entry.text.isEmpty {
          items.append(
            SnapshotItem(
              nativeItemId: entry.id, role: "assistant", type: "agentMessage",
              payload: ["text": .string(entry.text)]))
        }
        for call in entry.toolCalls {
          let id = call["id"]?.stringValue
          var payload: [String: JSONValue] = [
            "name": .string(call["name"]?.stringValue ?? "tool"), "input": call["args"] ?? .null,
            "status": "completed",
          ]
          if let id, let output = results[id] { payload["output"] = .string(output) }
          items.append(
            SnapshotItem(nativeItemId: id, role: "tool", type: "toolCall", payload: .object(payload)))
        }
      default:
        continue
      }
    }
    return items
  }
}
