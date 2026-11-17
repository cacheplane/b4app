import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

/// Extra fixtures are explicit at their call sites; shared Phone/ScriptedTransport behavior is unchanged.
@MainActor enum HistoricalActionFixture {
  nonisolated static let unavailableIds = [
    "historical-attached", "historical-managed", "historical-remote", "staged-protocol",
  ]
  static let cutover = WorkspaceError(
    .unsupportedCapability, "Historical connection is read-only.",
    details: ["reason": "agent_protocol_cutover"])

  static func staged(owner: String? = "mac-1") -> Connection {
    Connection(
      id: "staged-protocol", kind: .agentProtocol, label: "Staged protocol",
      target: "https://example.invalid",
      nativeScope: #"["agent-protocol-v1","agentProtocol","https://example.invalid"]"#,
      peerProfile: .agentProtocol, agentId: "fixture-agent",
      authMode: ConnectionAuthMode.none, ownerDeviceId: owner,
      capabilities: Dictionary(uniqueKeysWithValues: CapabilityKey.allCases.map { ($0, .supported) }),
      status: .ready, authStatus: .notRequired)
  }

  /// Fixture validity is checked independently of the unavailable-action oracle.
  static func checkCanonicalStaged(_ connection: Connection) throws {
    let components = try JSONDecoder().decode(
      [String].self, from: Data((connection.nativeScope ?? "").utf8))
    let canonicalScope =
      components == [
        "agent-protocol-v1", "agentProtocol", "https://example.invalid",
      ] && connection.peerProfile == .agentProtocol && connection.target == "https://example.invalid"
    let configured = connection.agentId?.isEmpty == false && connection.authMode == ConnectionAuthMode.none
    #expect(canonicalScope)
    #expect(configured)
  }

  /// All externally visible draft choices and state, including exact unsent whitespace.
  static func draft(_ value: NewThreadDraft) -> [String: JSONValue] {
    [
      "environmentId": value.environmentId.map(JSONValue.string) ?? .null,
      "folder": value.folder.map(JSONValue.string) ?? .null,
      "chosenFolder": value.chosenFolder.map(JSONValue.string) ?? .null,
      "connectionId": value.connectionId.map(JSONValue.string) ?? .null,
      "model": value.model.map(JSONValue.string) ?? .null,
      "permission": value.permission.map(JSONValue.string) ?? .null,
      "text": .string(value.text), "isNoFolder": .bool(value.isNoFolder),
      "isRemoteB4": .bool(value.isRemoteB4), "submitting": .bool(value.submitting),
      "startedThreadId": value.startedThreadId.map(JSONValue.string) ?? .null,
      "refusal": value.refusal.map(JSONValue.string) ?? .null,
      "status": value.status.map(JSONValue.string) ?? .null,
      "finished": .bool(value.finished), "canSend": .bool(value.canSend),
    ]
  }

  static func connections(phone: Bool, disabledCurrent: Bool = false) -> [Connection] {
    let owner: String? = phone ? "mac-1" : nil
    let historical: [(String, B4Mode)] = [
      ("historical-attached", .attachedLocal), ("historical-managed", .managedLocal),
      ("historical-remote", .remote),
    ]
    return historical.map { id, mode in
      Connection(
        id: id, kind: .b4, label: id,
        target: mode == .remote ? "https://example.invalid" : "http://127.0.0.1:9", routeKey: "/cached#agent",
        b4Mode: mode, localServerId: mode == .managedLocal ? "fixture-server" : nil,
        nativeScope: "old-scope", environmentId: mode == .remote ? nil : "fixture-work", ownerDeviceId: owner,
        capabilities: Dictionary(uniqueKeysWithValues: CapabilityKey.allCases.map { ($0, .supported) }),
        status: .ready, authStatus: .notRequired)
    } + [staged(owner: owner)]
      + [ConnectionKind.codex, .claude].map { kind in
        Connection(
          id: kind.rawValue, kind: kind, label: kind.rawValue, enabled: !disabledCurrent, target: "",
          ownerDeviceId: owner, status: .ready)
      }
  }

  static let exactDraft = "  Keep this draft exactly\n"

  static func read(
    _ connection: Connection, active: Bool = true, status: TurnStatus? = nil
  ) -> ThreadRead.Result {
    let threadId = "thread-\(connection.id)"
    let status: TurnStatus = active ? status ?? .reconciling : .terminal
    let turn = Turn(
      id: "turn-\(connection.id)", threadId: threadId, operationId: "operation-\(connection.id)",
      nativeTurnId: "opaque/native/turn#\(connection.id)", status: status,
      submission: status == .reconciling ? .unknown : .acknowledged, outcome: active ? nil : .completed,
      createdAt: PhoneFixture.at(-30), updatedAt: PhoneFixture.at(-20))
    let thread = ConversationThread(
      id: threadId, connectionId: connection.id, nativeThreadId: "opaque/native/thread#\(connection.id)",
      nativeScope: connection.nativeScope ?? "current-scope", title: "Cached", context: connection.routeKey,
      createdAt: PhoneFixture.at(-60), updatedAt: PhoneFixture.at(-20),
      environmentId: connection.environmentId,
      activity: ThreadActivity(
        latestTurnId: turn.id, latestTurnStatus: turn.status, latestTurnOutcome: turn.outcome,
        pendingRequests: active ? 2 : 0, lastActivityAt: PhoneFixture.at(-20)),
      ownerDeviceId: connection.ownerDeviceId)
    let item = DisplayItem(
      id: "item-\(connection.id)", threadId: thread.id, turnId: turn.id,
      nativeItemId: "opaque/native/item#\(connection.id)", role: .assistant, type: "unknown_cached_type",
      payload: ["opaque": ["retained": true, "namespace": ["one", "two"]]], sequence: 7, provenance: .cache,
      createdAt: PhoneFixture.at(-25))
    let approval: RuntimeRequestKind = connection.kind == .claude ? .toolPermission : .commandApproval
    let kinds: [RuntimeRequestKind] = active ? [approval, .userQuestion] : []
    let requests = kinds.map { kind in
      let payload: JSONValue
      if kind == .userQuestion {
        payload = [
          "answerable": true,
          "request": [
            "questions": [
              [
                "id": "question", "header": "Choice", "question": "Which option?",
                "options": [["label": "retained answer", "description": "Fixture choice"]],
                "isOther": false, "isSecret": false,
              ]
            ]
          ], "opaque": ["keep": true],
        ]
      } else if kind == .toolPermission {
        payload = [
          "answerable": true,
          "request": ["toolName": "Bash", "input": ["command": "pwd"], "cwd": "/fixture/work"],
          "opaque": ["keep": true],
        ]
      } else {
        payload = [
          "answerable": true, "request": ["command": "pwd", "cwd": "/fixture/work"],
          "opaque": ["keep": true],
        ]
      }
      return RuntimeRequest(
        id: "request-\(connection.id)-\(kind.rawValue)",
        nativeRequestId: "opaque/native/request#\(kind.rawValue)", threadId: thread.id, turnId: turn.id,
        adapterGeneration: 17, kind: kind, payload: payload,
        createdAt: PhoneFixture.at(-25), updatedAt: PhoneFixture.at(-25))
    }
    return ThreadRead.Result(thread: thread, turns: [turn], items: [item], requests: requests)
  }

  static func withModel(
    phone: Bool, selected: String, disabledCurrent: Bool = false, currentSend: Bool = false,
    currentStatus: TurnStatus? = nil,
    _ body: (WorkspaceModel, ScriptedTransport, [ThreadRead.Result]) async throws -> Void
  ) async throws {
    let transport = ScriptedTransport()
    let profiles = connections(phone: phone, disabledCurrent: disabledCurrent)
    let reads = profiles.map {
      read($0, active: !(currentSend && $0.id == selected), status: $0.id == selected ? currentStatus : nil)
    }
    let environment = WorkEnvironment(
      id: "fixture-work", name: "Cached environment",
      folders: [
        EnvironmentFolder(id: "fixture-folder", environmentId: "fixture-work", path: "/fixture/work")
      ],
      ownerDeviceId: phone ? "mac-1" : nil)
    transport.set(connections: profiles, threads: reads.map(\.thread), environments: [environment])
    for read in reads {
      transport.setRead(read)
      transport.setDraft(Draft(threadId: read.thread.id, text: exactDraft, updatedAt: PhoneFixture.at(-10)))
    }
    let model = WorkspaceModel(transportProvider: { transport })
    let clock = TestClock()
    model.clock = clock
    model.now = { clock.date }
    if phone { model.accountSource = .host }
    model.connect()
    var failure: (any Error)?
    do {
      try #require(await model.settledLink() == .ready)
      for profile in profiles where profile.kind == .agentProtocol { try checkCanonicalStaged(profile) }
      for read in reads {
        let coherentPending =
          read.thread.activity?.pendingRequests == read.requests.count
          && (read.turns.first?.status != .terminal || read.requests.isEmpty)
        #expect(coherentPending)
      }
      if phone {
        model.apply(PhoneFixture.presence(online: true))
        #expect(model.hostPhase(deviceId: "mac-1") == .connected)
      }
      await model.openThread(id: "thread-\(selected)")
      try #require(model.detail?.thread.id == "thread-\(selected)")
      #expect(model.composerText == exactDraft)
      try await body(model, transport, reads)
    } catch { failure = error }
    await model.disconnect()
    if let failure { throw failure }
  }
}

nonisolated enum HistoricalAction: String, CaseIterable, Sendable {
  case send, stop, respond, answer, abandon

  var method: WorkspaceProtocol.Method {
    switch self {
    case .send: .turnSend
    case .stop: .turnInterrupt
    case .respond, .answer: .requestRespond
    case .abandon: .turnAbandon
    }
  }

  @MainActor func perform(_ model: WorkspaceModel, read: ThreadRead.Result) async throws {
    switch self {
    case .send: await model.send()
    case .stop: await model.stop()
    case .respond:
      let request = try #require(
        read.requests.first { $0.kind == .commandApproval || $0.kind == .toolPermission })
      await model.respond(requestId: request.id, decision: .allowOnce)
    case .answer:
      let request = try #require(read.requests.first { $0.kind == .userQuestion })
      await model.answer(requestId: request.id, answers: ["question": ["retained answer"]])
    case .abandon: await model.abandonTurn(threadId: read.thread.id)
    }
  }
}

nonisolated struct HistoricalActionCase: Sendable {
  let phone: Bool
  let id: String
  let action: HistoricalAction

  static let unavailable = [false, true].flatMap { phone in
    HistoricalActionFixture.unavailableIds.flatMap { id in
      HistoricalAction.allCases.filter { $0 != .abandon || id != "staged-protocol" }.map {
        Self(phone: phone, id: id, action: $0)
      }
    }
  }
  static let current = [false, true].flatMap { phone in
    ["codex", "claude"].flatMap { id in
      HistoricalAction.allCases.map { Self(phone: phone, id: id, action: $0) }
    }
  }
  static let historicalRequests = [false, true].flatMap { phone in
    HistoricalActionFixture.unavailableIds.flatMap { id in
      [HistoricalAction.respond, .answer].map { Self(phone: phone, id: id, action: $0) }
    }
  }
  static let currentRequests = current.filter { $0.action == .respond || $0.action == .answer }
}

/// Model-only regressions. Immediate scripted errors bound baseline execution; no provider, store,
/// filesystem, network, holds, retries or production guard changes. The first managed run must show
/// assertion RED for the unavailable predicates/action commands before their implementation changes.
@MainActor @Suite struct AgentProtocolHistoricalActionTests {
  @Test(arguments: [false, true], HistoricalActionFixture.unavailableIds)
  func historicalAndStagedControlsAreUnavailableWithoutAHostFailure(phone: Bool, id: String) async throws {
    try await HistoricalActionFixture.withModel(phone: phone, selected: id) { model, _, _ in
      let detail = try #require(model.detail)
      #expect(model.sendBlockedReason(for: detail.thread) != nil)
      #expect(!model.canStop(detail.thread))
      for request in detail.requests { #expect(!model.canAnswer(request)) }
      // Historical unavailability must never masquerade as an offline Mac.
      #expect(model.controlsDisabledReason(for: detail.thread) == nil)
      #expect(model.threadNotice(for: detail.thread) == nil)
      #expect(model.activeTurnLabel(for: detail.thread) == nil)
      #expect(detail.activeTurn?.status == .reconciling)
      #expect(detail.activeTurn?.submission == .unknown)
      #expect(detail.activeTurn?.outcome == nil)
    }
  }

  @Test(arguments: HistoricalActionCase.unavailable)
  func directUnavailableActionsNeverLeaveTheModel(fixture: HistoricalActionCase) async throws {
    let (phone, id, action) = (fixture.phone, fixture.id, fixture.action)
    try await HistoricalActionFixture.withModel(phone: phone, selected: id) { model, transport, reads in
      let before = try #require(model.detail)
      let read = try #require(reads.first { $0.thread.id == before.thread.id })
      let turns = model.activeTurns
      let profiles = model.connections
      let threads = model.threads
      let pending = model.pendingSends
      let stops = model.stopStates
      let answers = model.answerStates
      // If the baseline dispatches, fail promptly with an assertion about the recorded command.
      transport.script(action.method, [.failure(HistoricalActionFixture.cutover)])
      try await action.perform(model, read: read)
      for method: WorkspaceProtocol.Method in [.turnSend, .turnInterrupt, .requestRespond, .turnAbandon] {
        #expect(transport.recorded(method).isEmpty)
      }
      let exactDraftRetained = model.composerText == HistoricalActionFixture.exactDraft
      let exactCacheRetained =
        model.detail == before && model.activeTurns == turns
        && model.connections == profiles && model.threads == threads
      #expect(exactDraftRetained)
      #expect(exactCacheRetained)
      let sendStateRetained = model.pendingSends == pending
      let controlStateRetained = model.stopStates == stops && model.answerStates == answers
      #expect(sendStateRetained)
      #expect(controlStateRetained)
      #expect(model.detail?.activeTurn?.submission == .unknown)
      #expect(model.detail?.activeTurn?.outcome == nil)
      #expect(model.detail?.requests.allSatisfy { $0.state == .pending } == true)
    }
  }

  @Test(arguments: HistoricalActionCase.current)
  func currentHarnessActionsStillDispatch(fixture: HistoricalActionCase) async throws {
    let (phone, id, action) = (fixture.phone, fixture.id, fixture.action)
    let status: TurnStatus =
      switch action {
      case .send: .terminal
      case .stop: .waitingForUser
      case .respond, .answer: .waitingForUser
      case .abandon: .reconciling
      }
    try await HistoricalActionFixture.withModel(
      phone: phone, selected: id, currentSend: action == .send, currentStatus: status
    ) { model, transport, reads in
      let detail = try #require(model.detail)
      let read = try #require(reads.first { $0.thread.id == detail.thread.id })
      #expect(model.sendBlockedReason(for: detail.thread) == nil)
      #expect(model.canStop(detail.thread))
      if action == .send {
        #expect(detail.activeTurn == nil)
        #expect(detail.requests.isEmpty)
        #expect(detail.thread.activity?.pendingRequests == 0)
      } else {
        #expect(detail.requests.count == 2)
        for request in detail.requests { #expect(model.canAnswer(request)) }
      }
      if action == .stop || action == .respond || action == .answer {
        #expect(detail.activeTurn?.status == .waitingForUser)
      }
      if action == .respond || action == .answer {
        var request = try #require(
          read.requests.first {
            action == .respond
              ? ($0.kind == .commandApproval || $0.kind == .toolPermission) : $0.kind == .userQuestion
          })
        request.state = .resolved
        transport.script(
          .requestRespond, [.result(try JSONValue(encoding: RequestRespond.Result(request: request)))])
      } else {
        var turn = try #require(read.turns.first)
        if action == .send { turn.status = .running; turn.outcome = nil }
        if action == .stop || action == .abandon {
          turn.status = .terminal
          turn.outcome = .failed
        }
        transport.script(action.method, [PhoneFixture.sent(turn)])
      }
      try await action.perform(model, read: read)
      #expect(transport.recorded(action.method).count == 1)
      let call = try #require(transport.recorded(action.method).first)
      #expect(call.operationId?.isEmpty == false)
      if action == .respond || action == .answer {
        let request = try #require(
          read.requests.first {
            action == .respond
              ? ($0.kind == .commandApproval || $0.kind == .toolPermission) : $0.kind == .userQuestion
          })
        #expect(call.params["requestId"] == .string(request.id))
        if action == .respond { #expect(call.params["decision"] == "allow_once") }
        if action == .answer { #expect(call.params["answers"] == ["question": ["retained answer"]]) }
      } else {
        #expect(call.params["threadId"] == .string(detail.thread.id))
        if action == .send { #expect(call.params["text"] == "Keep this draft exactly") }
      }
      #expect(model.lastError == nil)
    }
  }

  @Test(arguments: [false, true])
  func dormantProtocolKeepsDeliberateLocalAbandonment(phone: Bool) async throws {
    try await HistoricalActionFixture.withModel(phone: phone, selected: "staged-protocol") {
      model, transport, reads in
      let read = try #require(reads.first { $0.thread.id == model.detail?.thread.id })
      var turn = try #require(read.turns.first)
      turn.status = .terminal
      turn.outcome = .failed
      transport.script(.turnAbandon, [PhoneFixture.sent(turn)])
      await model.abandonTurn(threadId: read.thread.id)
      #expect(transport.recorded(.turnAbandon).count == 1)
      #expect(transport.recorded(.turnAbandon).first?.params["threadId"] == .string(read.thread.id))
      #expect(model.lastError == nil)
    }
  }

  @Test(arguments: [false, true], ["codex", "claude"])
  func disabledCurrentConnectionsCanStillStopExistingWork(phone: Bool, id: String) async throws {
    try await HistoricalActionFixture.withModel(
      phone: phone, selected: id, disabledCurrent: true, currentStatus: .waitingForUser
    ) {
      model, transport, reads in
      let detail = try #require(model.detail)
      #expect(model.connection(id: id)?.enabled == false)
      #expect(model.canStop(detail.thread))
      for request in detail.requests { #expect(model.canAnswer(request)) }
      transport.script(.turnInterrupt, [PhoneFixture.sent(try #require(detail.turns.first))])
      try await HistoricalAction.stop.perform(
        model, read: try #require(reads.first { $0.thread.id == detail.thread.id }))
      #expect(transport.recorded(.turnInterrupt).count == 1)
    }
  }

  @Test(arguments: [false, true], HistoricalActionFixture.unavailableIds)
  func requestPredicatesUseTheRequestsActualThreadAcrossSelection(phone: Bool, id: String) async throws {
    try await HistoricalActionFixture.withModel(phone: phone, selected: id) { model, _, reads in
      let historical = try #require(model.detail)
      await model.openThread(id: "thread-codex")
      #expect(model.selectedThreadId == "thread-codex")
      for request in historical.requests { #expect(!model.canAnswer(request)) }
      let current = try #require(model.detail)
      await model.openThread(id: historical.thread.id)
      #expect(model.selectedThreadId == historical.thread.id)
      for request in current.requests { #expect(model.canAnswer(request)) }
      let pendingRetained = model.detail?.requests == historical.requests
      #expect(pendingRetained)
      #expect(reads.contains { $0.thread.id == current.thread.id })
    }
  }

  @Test(arguments: HistoricalActionCase.historicalRequests)
  func savedHistoricalRequestIdsRemainBlockedAfterOpeningACurrentThread(
    fixture: HistoricalActionCase
  ) async throws {
    let (phone, id, action) = (fixture.phone, fixture.id, fixture.action)
    try await HistoricalActionFixture.withModel(phone: phone, selected: id) { model, transport, reads in
      let historical = try #require(reads.first { $0.thread.id == model.detail?.thread.id })
      // Capture from an authoritative read, then actually open another thread: a real selection race.
      await model.openThread(id: "thread-codex")
      let before = model.detail
      let draft = model.composerText
      transport.script(.requestRespond, [.failure(HistoricalActionFixture.cutover)])
      try await action.perform(model, read: historical)
      #expect(transport.recorded(.requestRespond).isEmpty)
      let selectedStateRetained = model.detail == before && model.composerText == draft
      #expect(selectedStateRetained)
      #expect(model.answerStates.isEmpty)
      await model.openThread(id: historical.thread.id)
      let historicalCacheRetained =
        model.detail?.turns == historical.turns
        && model.detail?.items == historical.items && model.detail?.requests == historical.requests
        && model.detail?.thread == historical.thread
      #expect(historicalCacheRetained)
      #expect(model.composerText == HistoricalActionFixture.exactDraft)
    }
  }

  @Test(arguments: HistoricalActionCase.currentRequests)
  func savedCurrentRequestIdsStillDispatchWhileHistoricalIsSelected(
    fixture: HistoricalActionCase
  ) async throws {
    let (phone, id, action) = (fixture.phone, fixture.id, fixture.action)
    try await HistoricalActionFixture.withModel(phone: phone, selected: id, currentStatus: .waitingForUser) {
      model, transport, reads in
      let current = try #require(reads.first { $0.thread.id == model.detail?.thread.id })
      await model.openThread(id: "thread-historical-managed")
      let before = model.detail
      let draft = model.composerText
      var request = try #require(
        current.requests.first {
          action == .respond
            ? ($0.kind == .commandApproval || $0.kind == .toolPermission) : $0.kind == .userQuestion
        })
      request.state = .resolved
      transport.script(
        .requestRespond, [.result(try JSONValue(encoding: RequestRespond.Result(request: request)))])
      try await action.perform(model, read: current)
      #expect(transport.recorded(.requestRespond).count == 1)
      #expect(transport.recorded(.requestRespond).first?.params["requestId"] == .string(request.id))
      let selectedStateRetained = model.detail == before && model.composerText == draft
      #expect(selectedStateRetained)
      #expect(model.lastError == nil)
    }
  }

  @Test(arguments: HistoricalActionFixture.unavailableIds + ["codex", "claude"])
  func unavailableProfilesDoNotChangeHostPresenceCopyOrUnknownTurns(id: String) async throws {
    try await HistoricalActionFixture.withModel(phone: true, selected: id) { model, _, _ in
      let detail = try #require(model.detail)
      let historical = HistoricalActionFixture.unavailableIds.contains(id)
      #expect(model.controlsDisabledReason(for: detail.thread) == nil)
      #expect(model.activeTurnLabel(for: detail.thread) == nil)
      model.apply(PhoneFixture.presence(online: false, lastSeen: -30))
      #expect(model.threadNotice(for: detail.thread)?.kind == .reconnecting)
      #expect(model.threadNotice(for: detail.thread)?.text == RelayCopy.reconnecting)
      #expect(model.controlsDisabledReason(for: detail.thread) == nil)
      #expect(model.activeTurnLabel(for: detail.thread) == nil)
      #expect((model.sendBlockedReason(for: detail.thread) != nil) == historical)
      #expect(model.canStop(detail.thread) == !historical)
      model.apply(PhoneFixture.presence(online: false, lastSeen: -120))
      #expect(model.threadNotice(for: detail.thread)?.kind == .offline)
      #expect(
        model.controlsDisabledReason(for: detail.thread) == model.threadNotice(for: detail.thread)?.text)
      #expect(model.activeTurnLabel(for: detail.thread) == RelayCopy.offlineTurn)
      #expect(!model.canStop(detail.thread))
      for request in detail.requests { #expect(!model.canAnswer(request)) }
      model.hostDisconnected = true
      #expect(model.controlsDisabledReason(for: detail.thread) == RelayCopy.leftHub)
      model.hostDisconnected = false
      model.apply(PhoneFixture.link(.connecting))
      #expect(model.hubLinkNotice == RelayCopy.connecting)
      #expect(model.controlsDisabledReason(for: detail.thread) == nil)
      #expect(model.activeTurnLabel(for: detail.thread) == nil)
      model.apply(PhoneFixture.presence(online: true))
      #expect(model.threadNotice(for: detail.thread) == nil)
      #expect(model.activeTurnLabel(for: detail.thread) == nil)
      let detailRetained = model.detail == detail
      #expect(detailRetained)
      #expect(model.detail?.activeTurn?.status == .reconciling)
      #expect(model.detail?.activeTurn?.submission == .unknown)
      #expect(model.detail?.activeTurn?.outcome == nil)
    }
  }
}
