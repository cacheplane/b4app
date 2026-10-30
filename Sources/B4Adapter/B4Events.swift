import Foundation
import WorkspaceProtocol

/// B4 stream events as emitted by `runs/stream` and the read-only reattach stream.
public enum B4StreamEvent: Sendable, Equatable {
  case chunk(String)
  case reasoning(String)
  case toolCall(id: String?, name: String, input: JSONValue, messageId: String?)
  case toolCallArgs(id: String, name: String, delta: String)
  case toolResult(id: String?, name: String, output: JSONValue)
  case messageEnd(messageId: String?)
  case interrupt(interruptId: String, type: String, kind: String?, detail: JSONValue, grant: String?)
  case state(status: String, live: Bool, raw: JSONValue)
  case detached(reason: String)
  case done(DoneOutcome, output: JSONValue, error: String?)
  case unknown(event: String?, data: JSONValue)

  public enum DoneOutcome: String, Sendable, Equatable {
    case completed, failed, cancelled
    case snapshotOnly = "snapshot_only"
  }

  private static func parse(_ data: String) -> JSONValue {
    (try? JSONCoding.decoder.decode(JSONValue.self, from: Data(data.utf8))) ?? .string(data)
  }

  /// Classify a `done` payload. A `done` event accompanies several outcomes, so the content decides:
  /// `{output:{error}}` failed, `{output:{cancelled:true}}` cancelled, `{output:null}` snapshot-only
  /// reattach, anything else completed.
  public static func classifyDone(output: JSONValue?) -> B4StreamEvent {
    guard let output, !output.isNull else { return .done(.snapshotOnly, output: .null, error: nil) }
    if let error = output["error"]?.stringValue { return .done(.failed, output: output, error: error) }
    if output["cancelled"]?.boolValue == true { return .done(.cancelled, output: output, error: nil) }
    return .done(.completed, output: output, error: nil)
  }

  public init(_ sse: SSEEvent) {
    let data = Self.parse(sse.data)
    switch sse.event {
    case "chunk":
      self = .chunk(data.stringValue ?? sse.data)
      return
    case "reasoning":
      self = .reasoning(data.stringValue ?? sse.data)
      return
    case "tool_call":
      if let name = data["name"]?.stringValue {
        self = .toolCall(
          id: data["id"]?.stringValue, name: name, input: data["input"] ?? .null,
          messageId: data["messageId"]?.stringValue)
        return
      }
    case "tool_call_args":
      if let id = data["id"]?.stringValue, let name = data["name"]?.stringValue,
        let delta = data["delta"]?.stringValue
      {
        self = .toolCallArgs(id: id, name: name, delta: delta)
        return
      }
    case "tool_result":
      if let name = data["name"]?.stringValue {
        self = .toolResult(id: data["id"]?.stringValue, name: name, output: data["output"] ?? .null)
        return
      }
    case "message_end":
      self = .messageEnd(messageId: data["messageId"]?.stringValue)
      return
    case "interrupt":
      if let interruptId = data["interruptId"]?.stringValue, let type = data["type"]?.stringValue {
        self = .interrupt(
          interruptId: interruptId, type: type, kind: data["kind"]?.stringValue,
          detail: data["detail"] ?? .null,
          grant: data["grant"]?.stringValue)
        return
      }
    case "state":
      if let status = data["status"]?.stringValue, let live = data["live"]?.boolValue {
        self = .state(status: status, live: live, raw: data)
        return
      }
    case "detached":
      if let reason = data["reason"]?.stringValue {
        self = .detached(reason: reason)
        return
      }
    case "done":
      self = Self.classifyDone(output: data["output"])
      return
    default:
      break
    }
    self = .unknown(event: sse.event, data: data)
  }
}
