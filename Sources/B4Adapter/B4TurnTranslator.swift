import Foundation
import WorkspaceProtocol

/// Turns one thread's SSE events into normalized adapter events. A value type: the adapter owns one
/// per thread and keeps it across a park (`interrupt` + `done`) so the resume stream continues the
/// same turn with continuing item numbers.
public struct B4TurnTranslator: Sendable {
  public enum Phase: Sendable, Equatable {
    case streaming
    /// `interrupt` was seen and the stream ended without a failure: waiting for `POST /resume`.
    case parked
    case finished(TurnOutcome)
    /// A reattach stream reported `live: false`: nothing is running; the outcome needs `reconcile`.
    case ended
  }

  public let connectionId: String
  public let threadId: String
  public let turnId: String
  public var generation: Int
  public private(set) var phase: Phase = .streaming
  /// True while consuming a `GET /runs/stream` reattach, where `done { output: null }` is not an outcome.
  public var reattaching = false

  private var messageIndex = 0
  private var currentMessage: (id: String, text: String)?
  private var currentReasoning: (id: String, text: String)?
  private var toolCalls: [String: (name: String, input: JSONValue, args: String)] = [:]
  private var toolOrder: [String] = []
  private var sawInterrupt = false
  private var streamedText = false
  private var capabilityIndex = 0

  public init(connectionId: String, threadId: String, turnId: String, generation: Int) {
    self.connectionId = connectionId
    self.threadId = threadId
    self.turnId = turnId
    self.generation = generation
  }

  public var isActive: Bool {
    if case .finished = phase { return false }
    return phase != .ended
  }

  /// A resume stream continues the turn: the park is over until the next `interrupt`.
  public mutating func beginResume() {
    sawInterrupt = false
    phase = .streaming
    reattaching = false
  }

  private func event(
    _ kind: EventKind, _ payload: JSONValue = [:], itemId: String? = nil, requestId: String? = nil
  ) -> AdapterEvent {
    var ids = ["threadId": threadId, "turnId": turnId]
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

  private mutating func closeMessage() -> [AdapterEvent] {
    var events: [AdapterEvent] = []
    if let reasoning = currentReasoning {
      events.append(
        event(
          .toolCompleted, item("reasoning", role: .assistant, ["text": .string(reasoning.text)]),
          itemId: reasoning.id))
      currentReasoning = nil
    }
    if let message = currentMessage {
      events.append(
        event(
          .messageCompleted, item("agentMessage", role: .assistant, ["text": .string(message.text)]),
          itemId: message.id))
      currentMessage = nil
    }
    return events
  }

  private func toolPayload(id: String, status: String, output: JSONValue? = nil) -> JSONValue {
    let call = toolCalls[id]
    var body: [String: JSONValue] = ["name": .string(call?.name ?? "tool"), "status": .string(status)]
    if let call {
      body["input"] = call.input.isNull && !call.args.isEmpty ? .string(call.args) : call.input
    }
    if let output {
      body["output"] = output.stringValue.map(JSONValue.string) ?? output
    }
    return item("toolCall", role: .tool, body)
  }

  public mutating func translate(_ incoming: B4StreamEvent) -> [AdapterEvent] {
    guard isActive || reattaching else { return [] }
    switch incoming {
    case .chunk(let text):
      var events: [AdapterEvent] = []
      if currentMessage == nil {
        messageIndex += 1
        let id = "\(turnId):m\(messageIndex)"
        currentMessage = (id, "")
        events.append(
          event(.messageStarted, item("agentMessage", role: .assistant, ["text": ""]), itemId: id))
      }
      currentMessage?.text += text
      streamedText = true
      events.append(event(.messageDelta, ["delta": .string(text)], itemId: currentMessage!.id))
      return events
    case .reasoning(let text):
      var events: [AdapterEvent] = []
      if currentReasoning == nil {
        messageIndex += 1
        let id = "\(turnId):r\(messageIndex)"
        currentReasoning = (id, "")
        events.append(event(.toolStarted, item("reasoning", role: .assistant, ["text": ""]), itemId: id))
      }
      currentReasoning?.text += text
      return events
    case .messageEnd:
      return closeMessage()
    case .toolCall(let id, let name, let input, _):
      var events = closeMessage()
      let callId = id ?? "\(turnId):t\(toolOrder.count + 1)"
      toolCalls[callId] = (name, input, "")
      toolOrder.append(callId)
      events.append(event(.toolStarted, toolPayload(id: callId, status: "inProgress"), itemId: callId))
      return events
    case .toolCallArgs(let id, let name, let delta):
      if toolCalls[id] == nil {
        toolCalls[id] = (name, .null, "")
        toolOrder.append(id)
      }
      toolCalls[id]?.args += delta
      return []
    case .toolResult(let id, let name, let output):
      let callId =
        id ?? toolOrder.last(where: { toolCalls[$0]?.name == name }) ?? "\(turnId):t\(toolOrder.count + 1)"
      if toolCalls[callId] == nil {
        toolCalls[callId] = (name, .null, "")
        toolOrder.append(callId)
      }
      let failed = output["error"] != nil
      return [
        event(
          .toolCompleted, toolPayload(id: callId, status: failed ? "failed" : "completed", output: output),
          itemId: callId)
      ]
    case .interrupt(let interruptId, let type, let kind, let detail, let grant, let raw):
      var events = closeMessage()
      sawInterrupt = true
      var request: [String: JSONValue] = [
        "interruptId": .string(interruptId), "type": .string(type), "kind": .string(kind ?? "tool"),
        "detail": detail, "allowAlways": .bool(raw["allowAlways"]?.boolValue ?? true),
      ]
      if let grant { request["grant"] = .string(grant) }
      if let toolCallId = raw["toolCallId"]?.stringValue { request["toolCallId"] = .string(toolCallId) }
      if let command = detail["command"]?.stringValue { request["command"] = .string(command) }
      if let path = detail["path"]?.stringValue { request["path"] = .string(path) }
      if let toolName = detail["toolName"]?.stringValue { request["toolName"] = .string(toolName) }
      events.append(
        event(
          .runtimeRequestOpened,
          [
            "kind": .string(B4Protocol.requestKind(kind).rawValue), "answerable": true, "method": "interrupt",
            "request": .object(request),
          ], requestId: interruptId))
      return events
    case .state(_, let live, _):
      if reattaching, !live { phase = .ended }
      return []
    case .detached:
      return []
    case .done(let outcome, let output, let error):
      var events = closeMessage()
      switch outcome {
      case .failed:
        phase = .finished(.failed)
        events.append(
          event(
            .turnFinished,
            [
              "outcome": "failed", "status": "failed",
              "error": ["message": .string(error ?? "The B4 run failed.")],
            ]))
      case .cancelled:
        phase = .finished(.cancelled)
        events.append(event(.turnFinished, ["outcome": "cancelled", "status": "cancelled"]))
      case .completed, .snapshotOnly:
        if sawInterrupt {
          phase = .parked
          events.append(
            event(.turnStateChanged, ["status": "waiting_for_user", "nativeStatus": "interrupted"]))
        } else if outcome == .snapshotOnly, reattaching {
          phase = .ended
        } else {
          if !streamedText, let text = B4Protocol.assistantText(fromDoneOutput: output) {
            messageIndex += 1
            let id = "\(turnId):m\(messageIndex)"
            events.append(
              event(
                .messageCompleted, item("agentMessage", role: .assistant, ["text": .string(text)]), itemId: id
              )
            )
          }
          phase = .finished(.completed)
          events.append(event(.turnFinished, ["outcome": "completed", "status": "idle"]))
        }
      }
      return events
    case .unknown(let name, let data):
      guard let name, !name.isEmpty else { return [] }
      capabilityIndex += 1
      let id = "\(turnId):c\(capabilityIndex)"
      return [
        event(
          .toolCompleted,
          item(name, role: .tool, ["event": .string(name), "data": data, "status": "completed"]),
          itemId: id)
      ]
    }
  }

  /// The run is known to be over with the given outcome (from `reconcile`).
  public mutating func finish(_ outcome: TurnOutcome, source: String) -> [AdapterEvent] {
    var events = closeMessage()
    phase = .finished(outcome)
    events.append(event(.turnFinished, ["outcome": .string(outcome.rawValue), "source": .string(source)]))
    return events
  }

  /// A durable prompt re-opened from `GET /threads/:id/pending_interrupts` after a restart.
  public mutating func reopen(interruptId: String, value: JSONValue, grant: String?) -> [AdapterEvent] {
    var raw = value.objectValue ?? [:]
    if let grant { raw["grant"] = .string(grant) }
    let translated = translate(
      .interrupt(
        interruptId: interruptId, type: value["type"]?.stringValue ?? "permission-request",
        kind: value["kind"]?.stringValue, detail: value["detail"] ?? .null, grant: grant, raw: .object(raw)))
    phase = .parked
    return translated
  }

  /// The transport dropped and could not be reattached: the turn's outcome is unknown until reconciled.
  public func transportLost() -> AdapterEvent {
    AdapterEvent(
      kind: .connectionChanged, connectionId: connectionId, nativeIds: ["threadId": threadId],
      adapterGeneration: generation,
      payload: [
        "status": .string(ConnectionStatus.offline.rawValue),
        "authStatus": .string(AuthStatus.unknown.rawValue),
        "transport": .string(TransportStatus.disconnected.rawValue),
        "message": "The B4 stream was lost and could not be reattached; reopen the thread to reconcile.",
      ])
  }
}
