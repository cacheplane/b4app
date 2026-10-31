import Foundation
import Testing
import WorkspaceProtocol

@testable import B4Adapter

private func run(_ frames: [B4StreamEvent], reattaching: Bool = false) -> ([AdapterEvent], B4TurnTranslator) {
  var translator = B4TurnTranslator(connectionId: "c1", threadId: "thr_1", turnId: "turn-1", generation: 1)
  translator.reattaching = reattaching
  var events: [AdapterEvent] = []
  for frame in frames { events += translator.translate(frame) }
  return (events, translator)
}

private let completedOutput: JSONValue = ["messages": [["role": "assistant", "content": "Hello"]]]

@Suite struct B4TranslatorTests {
  @Test func streamsAMessageInOrder() {
    let (events, translator) = run([
      .chunk("Hel"), .chunk("lo"), .messageEnd(messageId: "m1"),
      .done(.completed, output: completedOutput, error: nil),
    ])
    #expect(
      events.map(\.kind) == [.messageStarted, .messageDelta, .messageDelta, .messageCompleted, .turnFinished])
    #expect(events[0].nativeIds == ["threadId": "thr_1", "turnId": "turn-1", "itemId": "turn-1:m1"])
    #expect(events[0].payload["type"]?.stringValue == "agentMessage")
    #expect(events[3].payload["item"]?["text"]?.stringValue == "Hello")
    #expect(events[4].payload["outcome"]?.stringValue == "completed")
    #expect(translator.phase == .finished(.completed))
    #expect(!translator.isActive)
  }

  @Test func pairsToolCallsWithResultsAndSplitsMessagesAroundThem() {
    let (events, _) = run([
      .chunk("Checking."), .toolCall(id: "call_1", name: "search", input: ["q": "b4"], messageId: nil),
      .toolResult(id: "call_1", name: "search", output: ["hits": 2]), .chunk("Found."),
      .done(.completed, output: completedOutput, error: nil),
    ])
    #expect(
      events.map(\.kind) == [
        .messageStarted, .messageDelta, .messageCompleted, .toolStarted, .toolCompleted, .messageStarted,
        .messageDelta, .messageCompleted, .turnFinished,
      ])
    #expect(events[3].nativeIds["itemId"] == "call_1")
    #expect(events[3].payload["type"]?.stringValue == "toolCall")
    #expect(events[3].payload["item"]?["status"]?.stringValue == "inProgress")
    #expect(events[4].payload["item"]?["name"]?.stringValue == "search")
    #expect(events[4].payload["item"]?["output"] == ["hits": 2])
    #expect(events[4].payload["item"]?["status"]?.stringValue == "completed")
    #expect(events[5].nativeIds["itemId"] == "turn-1:m2")
  }

  @Test func foldsStepsUsageAndToolMessagesIntoTheToolCard() {
    let toolMessage: JSONValue = [
      "lc": 1, "type": "constructor", "id": ["langchain_core", "messages", "ToolMessage"],
      "kwargs": [
        "tool_call_id": "call_1", "name": "runBash", "status": "error", "content": "{\"stdout\":\"\"}",
      ],
    ]
    let usage1: JSONValue = [
      "provider": "openai", "model": "gpt-5-mini",
      "usage_metadata": ["input_tokens": 10, "output_tokens": 2, "total_tokens": 12],
    ]
    let usage2: JSONValue = [
      "provider": "openai", "model": "gpt-5-mini",
      "usage_metadata": ["input_tokens": 20, "output_tokens": 3, "total_tokens": 23],
    ]
    let (events, _) = run([
      .toolCallArgs(id: "call_1", name: "runBash", delta: "{\"command\":"),
      .toolCallArgs(id: "call_1", name: "runBash", delta: "\"pwd\"}"),
      .unknown(event: "usage", data: usage1),
      .toolCall(id: "call_1", name: "runBash", input: ["command": "pwd"], messageId: "m"),
      .unknown(
        event: "step",
        data: ["v": 1, "kind": "server", "toolCallId": "call_1", "status": "running", "label": "Running pwd"]),
      .unknown(
        event: "step",
        data: ["v": 1, "kind": "server", "toolCallId": "call_1", "status": "completed", "label": "Ran pwd"]),
      .toolResult(id: "call_1", name: "runBash", output: toolMessage),
      .unknown(event: "usage", data: usage2),
      .chunk("done"), .done(.completed, output: completedOutput, error: nil),
    ])
    let kinds = events.map(\.kind)
    #expect(
      kinds == [
        .toolStarted, .toolStarted, .toolCompleted, .messageStarted, .messageDelta, .messageCompleted,
        .turnFinished,
      ])
    #expect(events[1].payload["item"]?["label"]?.stringValue == "Running pwd")
    #expect(events[1].payload["item"]?["command"]?.stringValue == "pwd")
    #expect(events[2].payload["item"]?["label"]?.stringValue == "Ran pwd")
    #expect(events[2].payload["item"]?["status"]?.stringValue == "failed")
    #expect(events[2].payload["item"]?["output"]?.stringValue == "{\"stdout\":\"\"}")
    let usage = events.last?.payload["usage"]
    #expect(usage?["usage_metadata"]?["total_tokens"]?.numberValue == 35)
    #expect(usage?["calls"]?.numberValue == 2)
    #expect(usage?["model"]?.stringValue == "gpt-5-mini")
  }

  @Test func aParkKeepsTheTurnOpenUntilTheResumeStreamFinishes() {
    var translator = B4TurnTranslator(connectionId: "c1", threadId: "thr_1", turnId: "turn-1", generation: 3)
    var events: [AdapterEvent] = []
    let raw: JSONValue = [
      "interruptId": "perm_1", "type": "permission-request", "kind": "command",
      "detail": ["command": "rm -rf tmp"], "toolCallId": "call_9", "grant": "g1",
    ]
    for frame: B4StreamEvent in [
      .chunk("Need approval"),
      .interrupt(
        interruptId: "perm_1", type: "permission-request", kind: "command", detail: ["command": "rm -rf tmp"],
        grant: "g1", raw: raw),
      .done(.snapshotOnly, output: .null, error: nil),
    ] {
      events += translator.translate(frame)
    }
    #expect(
      events.map(\.kind) == [
        .messageStarted, .messageDelta, .messageCompleted, .runtimeRequestOpened, .turnStateChanged,
      ])
    let opened = events[3]
    #expect(opened.nativeIds["requestId"] == "perm_1")
    #expect(opened.adapterGeneration == 3)
    #expect(opened.payload["kind"]?.stringValue == "command_approval")
    #expect(opened.payload["answerable"]?.boolValue == true)
    #expect(opened.payload["request"]?["command"]?.stringValue == "rm -rf tmp")
    #expect(opened.payload["request"]?["grant"]?.stringValue == "g1")
    #expect(opened.payload["request"]?["toolCallId"]?.stringValue == "call_9")
    #expect(opened.payload["request"]?["allowAlways"]?.boolValue == true)
    #expect(events[4].payload["status"]?.stringValue == "waiting_for_user")
    #expect(translator.phase == .parked)
    #expect(translator.isActive)

    translator.beginResume()
    events = []
    for frame: B4StreamEvent in [.chunk("Approved."), .done(.completed, output: completedOutput, error: nil)]
    {
      events += translator.translate(frame)
    }
    #expect(events.map(\.kind) == [.messageStarted, .messageDelta, .messageCompleted, .turnFinished])
    #expect(events[0].nativeIds["itemId"] == "turn-1:m2")
    #expect(translator.phase == .finished(.completed))
  }

  @Test func failedAndCancelledOutcomesAreTerminal() {
    let (failed, _) = run([.chunk("Trying"), .done(.failed, output: ["error": "boom"], error: "boom")])
    #expect(failed.last?.kind == .turnFinished)
    #expect(failed.last?.payload["outcome"]?.stringValue == "failed")
    #expect(failed.last?.payload["error"]?["message"]?.stringValue == "boom")
    let (cancelled, translator) = run([
      .chunk("Working"), .done(.cancelled, output: ["cancelled": true], error: nil),
    ])
    #expect(cancelled.last?.payload["outcome"]?.stringValue == "cancelled")
    #expect(translator.phase == .finished(.cancelled))
  }

  @Test func emitsTheFinalMessageWhenNothingStreamed() {
    let (plain, _) = run([.done(.completed, output: completedOutput, error: nil)])
    #expect(plain.map(\.kind) == [.messageCompleted, .turnFinished])
    #expect(plain[0].payload["item"]?["text"]?.stringValue == "Hello")
    let envelope: JSONValue = [
      "messages": [
        [
          "lc": 1, "type": "constructor", "id": ["langchain_core", "messages", "AIMessage"],
          "kwargs": ["content": [["type": "text", "text": "From "], ["type": "text", "text": "blocks"]]],
        ]
      ]
    ]
    let (lc, _) = run([.done(.completed, output: envelope, error: nil)])
    #expect(lc[0].payload["item"]?["text"]?.stringValue == "From blocks")
    let (streamed, _) = run([.chunk("x"), .done(.completed, output: completedOutput, error: nil)])
    #expect(streamed.filter { $0.kind == .messageCompleted }.count == 1)
  }

  @Test func capabilityEventsAndReasoningAreVisible() {
    let (events, _) = run([
      .reasoning("Think "), .reasoning("hard."), .unknown(event: "plan_update", data: ["todos": []]),
      .chunk("Done"), .messageEnd(messageId: nil), .done(.completed, output: completedOutput, error: nil),
    ])
    #expect(events[0].kind == .toolStarted)
    #expect(events[0].payload["type"]?.stringValue == "reasoning")
    #expect(events[1].kind == .toolCompleted)
    #expect(events[1].payload["type"]?.stringValue == "plan_update")
    #expect(events[1].payload["item"]?["data"] == ["todos": []])
    let reasoning = events.first {
      $0.kind == .toolCompleted && $0.payload["type"]?.stringValue == "reasoning"
    }
    #expect(reasoning?.payload["item"]?["text"]?.stringValue == "Think hard.")
  }

  @Test func aReattachThatFindsNothingLiveEndsWithoutAnOutcome() {
    let (events, translator) = run(
      [.state(status: "idle", live: false, raw: [:]), .done(.snapshotOnly, output: .null, error: nil)],
      reattaching: true)
    #expect(events.isEmpty)
    #expect(translator.phase == .ended)
    let (live, liveTranslator) = run(
      [
        .state(status: "busy", live: true, raw: [:]), .chunk("more"),
        .done(.completed, output: .null, error: nil),
      ],
      reattaching: true)
    #expect(live.map(\.kind) == [.messageStarted, .messageDelta, .messageCompleted, .turnFinished])
    #expect(liveTranslator.phase == .finished(.completed))
  }

  @Test func reopensADurablePromptAndReportsTransportLoss() {
    var translator = B4TurnTranslator(connectionId: "c1", threadId: "thr_1", turnId: "turn-2", generation: 2)
    let events = translator.reopen(
      interruptId: "perm_7",
      value: [
        "interruptId": "perm_7", "type": "permission-request", "kind": "tool",
        "detail": ["toolName": "shell"],
      ],
      grant: "g7")
    #expect(events.map(\.kind) == [.runtimeRequestOpened])
    #expect(events[0].payload["kind"]?.stringValue == "tool_permission")
    #expect(events[0].payload["request"]?["toolName"]?.stringValue == "shell")
    #expect(events[0].payload["request"]?["grant"]?.stringValue == "g7")
    #expect(translator.phase == .parked)
    let lost = translator.transportLost()
    #expect(lost.kind == .connectionChanged)
    #expect(lost.nativeIds == ["threadId": "thr_1"])
    #expect(lost.payload["transport"]?.stringValue == "disconnected")
  }
}

@Suite struct B4ProtocolTests {
  @Test func readsNestedAndFlatTurnLists() {
    let nested: JSONValue = [
      "threadId": "t", "status": "idle", "turns": ["threadId": "t", "turns": [["status": "done"]]],
    ]
    #expect(B4Protocol.turnList(nested)?.count == 1)
    #expect(B4Protocol.turnList(["turns": [["status": "done"], ["status": "failed"]]])?.count == 2)
    #expect(B4Protocol.turnList(["turns": "nope"]) == nil)
    #expect(B4Protocol.turnList(nil) == nil)
  }

  @Test func parsesRouteKeys() {
    let chat = B4RouteKey("/chat#agent")
    #expect(chat?.id == "/chat")
    #expect(chat?.isAgent == true)
    #expect(chat?.displayName == "chat")
    #expect(B4RouteKey(" /deep/path#agent ")?.key == "/deep/path#agent")
    #expect(B4RouteKey("/dispatch#workflow")?.isAgent == false)
    #expect(B4RouteKey("chat#agent") == nil)
    #expect(B4RouteKey("/a b#agent") == nil)
    #expect(B4RouteKey("/a#thing") == nil)
    #expect(B4RouteKey("/#agent") == nil)
  }

  @Test func mapsHttpFailuresToStableCodes() {
    func body(_ message: String, code: String? = nil) -> JSONValue {
      var error: [String: JSONValue] = ["kind": "request_error", "message": .string(message)]
      if let code { error["details"] = ["code": .string(code)] }
      return ["error": .object(error)]
    }
    #expect(
      B4Protocol.error(status: 401, body: body("Unauthorized"), operation: "turn start").code == .authRequired
    )
    #expect(
      B4Protocol.error(status: 404, body: body("Unknown route: /x#agent"), operation: "turn start").code
        == .incompatibleVersion)
    #expect(
      B4Protocol.error(status: 404, body: body("Thread not found", code: "thread_not_found"), operation: "x")
        .code == .nativeSessionMissing)
    let busy = B4Protocol.error(
      status: 409, body: body("busy", code: "run_in_flight"), operation: "turn start")
    #expect(busy.code == .protocolInvalid)
    #expect(busy.details?["reason"]?.stringValue == "turn_active")
    #expect(
      B4Protocol.error(status: 409, body: body("stale", code: "stale_interrupt"), operation: "resume").code
        == .staleRuntimeRequest)
    #expect(B4Protocol.error(status: 500, body: nil, operation: "resume").code == .internalError)
    #expect(B4Protocol.error(status: 400, body: body("bad"), operation: "resume").code == .protocolInvalid)
  }

  @Test func buildsExactResumeBodies() {
    #expect(
      B4Protocol.resumeBody(route: "/chat#agent", interruptId: "perm_1", decision: .once, grant: "g")
        == [
          "resume": [["interruptId": "perm_1", "status": "resolved", "payload": "once", "grant": "g"]],
          "route": "/chat#agent",
        ])
    #expect(
      B4Protocol.resumeBody(route: "/chat#agent", interruptId: "perm_1", decision: .cancelled, grant: nil)
        == ["resume": [["interruptId": "perm_1", "status": "cancelled"]], "route": "/chat#agent"])
    #expect(B4Protocol.resumeDecision(.allowAlways, allowAlways: true) == .always)
    #expect(B4Protocol.resumeDecision(.allowAlways, allowAlways: false) == .once)
    #expect(B4Protocol.resumeDecision(.deny, allowAlways: true) == .deny)
    #expect(
      B4Protocol.runBody(route: "/chat#agent", text: "hi")
        == ["route": "/chat#agent", "input": ["messages": [["role": "user", "content": "hi"]]]])
  }

  @Test func projectsLangChainStateIntoSnapshotItems() {
    func lc(_ cls: String, _ kwargs: JSONValue) -> JSONValue {
      ["lc": 1, "type": "constructor", "id": ["langchain_core", "messages", .string(cls)], "kwargs": kwargs]
    }
    let values: JSONValue = [
      "messages": [
        lc("HumanMessage", ["content": "find b4", "id": "h1"]),
        lc(
          "AIMessage",
          ["content": "Checking.", "tool_calls": [["id": "call_1", "name": "search", "args": ["q": "b4"]]]]),
        lc("ToolMessage", ["content": "{\"hits\":2}", "tool_call_id": "call_1", "name": "search"]),
        lc("AIMessage", ["content": [["type": "text", "text": "Found 2 hits."]]]),
        lc("SystemMessage", ["content": "ignored"]),
      ]
    ]
    let items = B4Protocol.snapshotItems(stateValues: values)
    #expect(items.map(\.type) == ["userMessage", "agentMessage", "toolCall", "agentMessage"])
    #expect(items[0].payload["text"]?.stringValue == "find b4")
    #expect(items[0].nativeItemId == "h1")
    #expect(items[2].nativeItemId == "call_1")
    #expect(items[2].payload["output"]?.stringValue == "{\"hits\":2}")
    #expect(items[2].payload["input"] == ["q": "b4"])
    #expect(items[3].payload["text"]?.stringValue == "Found 2 hits.")
  }
}
