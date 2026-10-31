import Foundation
import WorkspaceProtocol

/// Pure translation from app-server messages to normalized adapter events. Native ids travel in
/// `nativeIds` (`threadId`, `turnId`, `itemId`, `requestId`); app ids are resolved by the coordinator.
public enum CodexEventTranslator {
  public static func translate(_ message: RpcMessage, connectionId: String, generation: Int) -> [AdapterEvent]
  {
    switch message {
    case .response, .error:
      return []
    case .request(let id, let method, let params):
      return [
        requestOpened(
          id: id, method: method, params: params, connectionId: connectionId, generation: generation)
      ]
    case .notification(let method, let params):
      return notification(method: method, params: params, connectionId: connectionId, generation: generation)
    }
  }

  static func requestIdString(_ id: RpcId) -> String {
    switch id {
    case .number(let n): return String(n)
    case .string(let s): return s
    }
  }

  private static func requestOpened(
    id: RpcId, method: String, params: JSONValue, connectionId: String, generation: Int
  ) -> AdapterEvent {
    let known = CodexProtocol.ServerRequestMethod(rawValue: method)
    var nativeIds = ["requestId": requestIdString(id)]
    if let threadId = params["threadId"]?.stringValue ?? params["conversationId"]?.stringValue {
      nativeIds["threadId"] = threadId
    }
    if let turnId = params["turnId"]?.stringValue { nativeIds["turnId"] = turnId }
    if let itemId = params["itemId"]?.stringValue { nativeIds["itemId"] = itemId }
    let payload: JSONValue = known.map { CodexProtocol.safeRequestPayload(method: $0, params: params) } ?? [:]
    return AdapterEvent(
      kind: .runtimeRequestOpened, connectionId: connectionId, nativeIds: nativeIds,
      adapterGeneration: generation,
      payload: [
        "kind": .string((known?.kind ?? .unknown).rawValue), "method": .string(method),
        "answerable": .bool(known?.answerable ?? false), "request": payload,
      ])
  }

  private static func notification(
    method: String, params: JSONValue, connectionId: String, generation: Int
  ) -> [AdapterEvent] {
    var ids: [String: String] = [:]
    if let threadId = params["threadId"]?.stringValue { ids["threadId"] = threadId }
    if let turnId = params["turnId"]?.stringValue ?? params["turn"]?["id"]?.stringValue {
      ids["turnId"] = turnId
    }
    func event(_ kind: EventKind, _ payload: JSONValue = [:], extra: [String: String] = [:]) -> AdapterEvent {
      AdapterEvent(
        kind: kind, connectionId: connectionId, nativeIds: ids.merging(extra) { _, new in new },
        adapterGeneration: generation, payload: payload)
    }
    switch method {
    case "turn/started":
      return [event(.turnAcknowledged, ["status": params["turn"]?["status"] ?? .null])]
    case "item/started", "item/completed":
      guard let item = params["item"], let itemId = item["id"]?.stringValue,
        let type = item["type"]?.stringValue
      else { return [] }
      let started = method == "item/started"
      let kind: EventKind
      if type == "agentMessage" || type == "userMessage" {
        kind = started ? .messageStarted : .messageCompleted
      } else {
        kind = started ? .toolStarted : .toolCompleted
      }
      return [
        event(
          kind, ["item": item, "role": .string(role(forItemType: type).rawValue), "type": .string(type)],
          extra: ["itemId": itemId])
      ]
    case "item/agentMessage/delta":
      guard let itemId = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else {
        return []
      }
      return [event(.messageDelta, ["delta": .string(delta)], extra: ["itemId": itemId])]
    case "turn/completed":
      guard let turn = params["turn"], let status = turn["status"]?.stringValue else { return [] }
      var payload: [String: JSONValue] = ["status": .string(status)]
      switch status {
      case "completed": payload["outcome"] = .string(TurnOutcome.completed.rawValue)
      case "interrupted": payload["outcome"] = .string(TurnOutcome.cancelled.rawValue)
      case "failed": payload["outcome"] = .string(TurnOutcome.failed.rawValue)
      default: return [event(.turnStateChanged, ["status": .string(status)])]
      }
      if let error = turn["error"], !error.isNull {
        payload["error"] = [
          "message": error["message"] ?? "", "details": error["additionalDetails"] ?? .null,
        ]
        payload["errorCode"] = .string(
          CodexProtocol.errorCode(codexErrorInfo: error["codexErrorInfo"]).rawValue)
        payload["codexErrorInfo"] = error["codexErrorInfo"] ?? .null
      }
      return [event(.turnFinished, .object(payload))]
    case "error":
      let error = params["error"] ?? [:]
      return [
        event(
          .adapterError,
          [
            "message": error["message"] ?? "Codex reported an error.",
            "willRetry": params["willRetry"] ?? false,
            "errorCode": .string(CodexProtocol.errorCode(codexErrorInfo: error["codexErrorInfo"]).rawValue),
            "codexErrorInfo": error["codexErrorInfo"] ?? .null,
          ])
      ]
    case "thread/status/changed":
      guard let status = params["status"]?["type"]?.stringValue else { return [] }
      let flags = params["status"]?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let mapped: String
      switch status {
      case "active": mapped = flags.isEmpty ? TurnStatus.running.rawValue : TurnStatus.waitingForUser.rawValue
      case "systemError": mapped = "error"
      default: mapped = "idle"
      }
      return [event(.turnStateChanged, ["status": .string(mapped), "nativeStatus": .string(status)])]
    case "serverRequest/resolved":
      guard let requestId = params["requestId"] else { return [] }
      let text = requestId.stringValue ?? requestId.numberValue.map { String(Int($0)) } ?? ""
      return [event(.runtimeRequestResolved, ["source": "server"], extra: ["requestId": text])]
    case "account/updated":
      let authenticated = !(params["authMode"]?.isNull ?? true)
      return [
        AdapterEvent.connectionChanged(
          connectionId: connectionId, status: .ready, authStatus: authenticated ? .authenticated : .required,
          transport: .connected,
          message: authenticated
            ? "Signed in (\(params["authMode"]?.stringValue ?? "?"), \(params["planType"]?.stringValue ?? "plan unknown"))."
            : "Codex is signed out.",
          adapterGeneration: generation)
      ]
    case "account/login/completed":
      let success = params["success"]?.boolValue ?? false
      return [
        AdapterEvent.connectionChanged(
          connectionId: connectionId, status: .ready, authStatus: success ? .authenticated : .required,
          transport: .connected,
          message: success
            ? "Sign-in completed." : "Sign-in failed: \(params["error"]?.stringValue ?? "unknown")",
          adapterGeneration: generation)
      ]
    default:
      return []
    }
  }

  public static func role(forItemType type: String) -> DisplayItemRole {
    switch type {
    case "userMessage": return .user
    case "agentMessage", "reasoning", "plan": return .assistant
    case "contextCompaction", "hookPrompt": return .system
    default: return .tool
    }
  }

  /// Items from a `thread/turns/list` page (oldest first), for history snapshots.
  public static func snapshotItems(turnsListResult: JSONValue) -> [SnapshotItem] {
    var items: [SnapshotItem] = []
    for turn in turnsListResult["data"]?.arrayValue ?? [] {
      for item in turn["items"]?.arrayValue ?? [] {
        guard let type = item["type"]?.stringValue else { continue }
        items.append(
          SnapshotItem(
            nativeItemId: item["id"]?.stringValue, role: role(forItemType: type).rawValue, type: type,
            payload: item))
      }
    }
    return items
  }
}
