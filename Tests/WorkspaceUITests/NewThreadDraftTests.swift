import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - Fixture

/// Two Macs. `mac-1` owns project `p1` (two folders) and `p2` (one folder) with their connections;
/// `mac-2` owns `p3` (one folder).
private enum Phone {
  static func folder(_ id: String, _ projectId: String, _ path: String) -> ProjectFolder {
    ProjectFolder(id: id, projectId: projectId, path: path, createdAt: PhoneFixture.at(-1000))
  }

  static let p1 = Project(
    id: "p1", name: "Atlas", createdAt: PhoneFixture.at(-1000), updatedAt: PhoneFixture.at(-1000),
    folders: [folder("f1", "p1", "/work/atlas"), folder("f2", "p1", "/work/atlas-docs")],
    ownerDeviceId: "mac-1")
  static let p2 = Project(
    id: "p2", name: "Borealis", createdAt: PhoneFixture.at(-900), updatedAt: PhoneFixture.at(-900),
    folders: [folder("f3", "p2", "/work/borealis")], ownerDeviceId: "mac-1")
  static let p3 = Project(
    id: "p3", name: "Cirrus", createdAt: PhoneFixture.at(-800), updatedAt: PhoneFixture.at(-800),
    folders: [folder("f4", "p3", "/work/cirrus")], ownerDeviceId: "mac-2")

  static func connection(
    _ id: String, _ kind: ConnectionKind, owner: String? = "mac-1", label: String? = nil,
    enabled: Bool = true, status: ConnectionStatus = .ready, projectId: String? = nil,
    route: String? = nil, mode: B4Mode? = nil
  ) -> Connection {
    Connection(
      id: id, kind: kind, label: label ?? id, enabled: enabled, target: "", routeKey: route, b4Mode: mode,
      projectId: projectId, ownerDeviceId: owner, status: status)
  }

  static let connections = [
    connection("codex-1", .codex, label: "Codex"),
    connection("claude-1", .claude, label: "Claude Code"),
    connection(
      "b4-p1", .b4, label: "research @ atlas", projectId: "p1", route: "/research#agent",
      mode: .managedLocal),
    connection(
      "b4-p2", .b4, label: "support @ borealis", projectId: "p2", route: "/support#agent",
      mode: .managedLocal),
    connection(
      "b4-remote", .b4, label: "remote @ host", projectId: nil, route: "/remote#agent", mode: .remote),
    // Not offered: another Mac's, switched off, not ready.
    connection("codex-2", .codex, owner: "mac-2", label: "Codex (other Mac)"),
    connection("claude-off", .claude, enabled: false),
    connection("codex-down", .codex, status: .offline),
  ]

  /// A phone on the test clock with both Macs online, projects and connections loaded.
  @MainActor
  static func model(
    _ transport: ScriptedTransport, clock: TestClock, threads: [ConversationThread] = []
  ) async throws -> WorkspaceModel {
    transport.set(connections: connections, threads: threads, projects: [p1, p2, p3])
    let model = try await PhoneFixture.model(transport, clock: clock, online: nil, open: nil)
    model.preferences = InMemoryPreferences()
    transport.emit(PhoneFixture.presence("mac-1", online: true))
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: true))
    try await waitUntil("presence") {
      model.hostPresence["mac-1"] != nil && model.hostPresence["mac-2"] != nil
    }
    try await waitUntil("projects") { model.projects.count == 3 }
    return model
  }

  /// The Mac's own view of the same projects and connections: no owners, and two Claude connections.
  static let macProjects = [p1, p2, p3].map { project in
    var project = project
    project.ownerDeviceId = nil
    return project
  }

  static let macConnections = [
    connection("codex-1", .codex, owner: nil, label: "Codex"),
    Connection(
      id: "claude-1", kind: .claude, label: "Claude Code", target: "",
      models: RuntimeOptions.claudeModels, status: .ready),
    Connection(
      id: "claude-2", kind: .claude, label: "Claude Code (work)", target: "",
      models: RuntimeOptions.claudeModels, status: .ready),
    connection(
      "b4-p1", .b4, owner: nil, label: "research @ atlas", projectId: "p1", route: "/research#agent",
      mode: .managedLocal),
    connection(
      "b4-remote", .b4, owner: nil, label: "remote @ host", projectId: nil, route: "/remote#agent",
      mode: .remote),
  ]

  /// The Mac's model over its own coordinator, projects and connections loaded, on `preferences`.
  @MainActor
  static func macModel(
    _ transport: ScriptedTransport, preferences: InMemoryPreferences = InMemoryPreferences(),
    threads: [ConversationThread] = [], connections: [Connection] = macConnections
  ) async throws -> WorkspaceModel {
    transport.set(connections: connections, threads: threads, projects: macProjects)
    let model = WorkspaceModel(transportProvider: { transport })
    model.preferences = preferences
    model.connect()
    try #require(await model.settledLink() == .ready)
    try await waitUntil("projects") { model.projects.count == 3 }
    return model
  }

  /// Sends `draft` and answers the start with its thread in `projectId`, started in `folder`; returns
  /// the command the coordinator received.
  @MainActor
  static func land(
    _ draft: NewThreadDraft, _ model: WorkspaceModel, _ transport: ScriptedTransport,
    projectId: String?, folder: String?
  ) async throws -> ScriptedTransport.Call {
    transport.script(.threadStart, [.hold])
    let task = Task { await draft.send() }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    let call = try #require(transport.recorded(.threadStart).last)
    let pending = try #require(model.pendingSends.values.first { $0.state == .sending })
    var thread = PhoneFixture.thread(pending.threadId, owner: nil)
    thread.projectId = projectId
    thread.context = folder
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: started(thread, pending.id))
    await task.value
    return call
  }

  static func started(_ thread: ConversationThread, _ id: String) -> ScriptedTransport.Reply {
    .result(
      try! JSONValue(
        encoding: ThreadStart.Result(
          thread: thread, turn: PhoneFixture.turn("turn-1", in: thread.id, operationId: id))))
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct NewThreadDraftTests {
  @Test func offersCodexClaudeAndThisProjectsLocalB4Only() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let ids = { (project: Project) in model.startConnections(for: project).map(\.id) }
    // Codex and Claude of the owner, and this project's own local B4; no remote B4, no other Mac's
    // connection, nothing switched off or not ready, and no other project's B4.
    #expect(ids(Phone.p1) == ["codex-1", "claude-1", "b4-p1"])
    #expect(ids(Phone.p2) == ["codex-1", "claude-1", "b4-p2"])
    // The other Mac's project gets the other Mac's connections only.
    #expect(ids(Phone.p3) == ["codex-2"])
    // A B4 connection reads as its route's name, as the Mac titles a B4 thread.
    let b4 = try #require(model.connection(id: "b4-p1"))
    #expect(model.startLabel(for: b4) == "research")
    #expect(model.startLabel(for: try #require(model.connection(id: "codex-1"))) == "Codex")
    // A project with no owner offers nothing: there is no Mac to send to.
    #expect(model.startConnections(for: Project(id: "px", name: "No owner")).isEmpty)
    await model.disconnect()
  }

  @Test func folderStepOnlyWhenSeveral() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let codex = try #require(model.connection(id: "codex-1"))
    #expect(
      model.startFolders(for: Phone.p1, connection: codex).map(\.path) == ["/work/atlas", "/work/atlas-docs"])
    #expect(model.needsFolderChoice(for: Phone.p1, connection: codex))
    #expect(!model.needsFolderChoice(for: Phone.p2, connection: codex))

    // One folder: no step, and the Mac still gets that folder.
    transport.script(.threadStart, [.hold])
    let single = Task {
      await model.startThread(projectId: "p2", connectionId: "codex-1", folder: nil, text: "One folder")
    }
    try await waitUntil("held") { transport.heldCount(.threadStart) == 1 }
    #expect(transport.recorded(.threadStart).first?.params["folder"] == "/work/borealis")
    let pending = try #require(model.pendingSends.values.first)
    transport.setRead(
      ThreadRead.Result(
        thread: PhoneFixture.thread(pending.threadId), turns: [], items: [], requests: []))
    transport.release(
      .threadStart, with: Phone.started(PhoneFixture.thread(pending.threadId), pending.id))
    _ = await single.value

    // Several folders and none chosen: nothing is sent.
    #expect(
      await model.startThread(projectId: "p1", connectionId: "codex-1", folder: nil, text: "Which?") == nil)
    #expect(transport.recorded(.threadStart).count == 1)
    await model.disconnect()
  }

  @Test func b4HasNoFolderStep() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let b4 = try #require(model.connection(id: "b4-p1"))
    // p1 has two folders, yet a B4 thread is bound to the route, not a folder.
    #expect(model.startFolders(for: Phone.p1, connection: b4).isEmpty)
    #expect(!model.needsFolderChoice(for: Phone.p1, connection: b4))

    transport.script(.threadStart, [.hold])
    let task = Task {
      // A folder passed with a B4 connection is dropped.
      await model.startThread(projectId: "p1", connectionId: "b4-p1", folder: "/work/atlas", text: "Hi B4")
    }
    try await waitUntil("held") { transport.heldCount(.threadStart) == 1 }
    let call = try #require(transport.recorded(.threadStart).first)
    #expect(call.params["connectionId"] == "b4-p1")
    #expect(call.params["folder"] == nil || call.params["folder"] == .null)
    let pending = try #require(model.pendingSends.values.first)
    transport.setRead(
      ThreadRead.Result(
        thread: PhoneFixture.thread(pending.threadId), turns: [], items: [], requests: []))
    transport.release(
      .threadStart, with: Phone.started(PhoneFixture.thread(pending.threadId), pending.id))
    _ = await task.value
    await model.disconnect()
  }

  @Test func remoteB4IsNeverStarted() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    #expect(
      await model.startThread(projectId: "p1", connectionId: "b4-remote", folder: nil, text: "No") == nil)
    // Nor another Mac's connection, nor another project's B4.
    #expect(
      await model.startThread(projectId: "p1", connectionId: "codex-2", folder: "/work/atlas", text: "No")
        == nil)
    #expect(await model.startThread(projectId: "p1", connectionId: "b4-p2", folder: nil, text: "No") == nil)
    #expect(transport.recorded(.threadStart).isEmpty)
    await model.disconnect()
  }

  @Test func startOpensTheThreadOnAccept() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let draft = model.newThreadDraft
    #expect(draft.projectId == "p1")
    #expect(draft.connectionId == "codex-1")
    #expect(draft.folder == "/work/atlas")
    draft.text = "  Start here  "
    transport.script(.threadStart, [.hold])
    let task = Task { await draft.send() }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    #expect(draft.status == "Starting…")
    #expect(!draft.canSend)
    let call = try #require(transport.recorded(.threadStart).first)
    #expect(call.params["projectId"] == "p1")
    #expect(call.params["connectionId"] == "codex-1")
    #expect(call.params["folder"] == "/work/atlas")
    #expect(call.params["text"] == "Start here")
    let pending = try #require(model.pendingSends.values.first)
    #expect(call.operationId == pending.id)
    #expect(call.params["threadId"] == .string(pending.threadId))

    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    await task.value
    #expect(draft.finished)
    // The accepted text is cleared, so Start cannot send it again while the sheet closes.
    #expect(draft.text.isEmpty)
    #expect(!draft.canSend)
    #expect(draft.status == nil)
    #expect(model.selectedThreadId == pending.threadId)
    #expect(model.detail?.thread.id == pending.threadId)
    await model.disconnect()
  }

  @Test func startRefusedKeepsTheSheetAndText() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let draft = NewThreadDraft(model: model, projectId: nil)
    draft.text = "Keep this"
    transport.script(
      .threadStart,
      [.failure(WorkspaceError(.protocolInvalid, "That folder is not in this project."))])
    await draft.send()
    #expect(!draft.finished)
    #expect(draft.text == "Keep this")
    #expect(draft.status == "That folder is not in this project.")
    #expect(draft.canSend)
    #expect(model.selectedThreadId == nil)

    // Sending again mints a new thread; the refused one is gone.
    let refused = try #require(model.pendingSends.values.first)
    transport.script(.threadStart, [.hold])
    let again = Task { await draft.send() }
    try await waitUntil("second") { transport.heldCount(.threadStart) == 1 }
    #expect(transport.recorded(.threadStart).count == 2)
    #expect(model.pendingSends[refused.threadId] == nil)
    #expect(Set(transport.recorded(.threadStart).map { $0.operationId ?? "" }).count == 2)
    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    await again.value
    #expect(draft.finished)
    await model.disconnect()
  }

  @Test func notConfirmedKeepsTheSheetUntilItSettles() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: clock)
    let draft = NewThreadDraft(model: model, projectId: nil)
    draft.text = "Maybe"
    transport.script(
      .threadStart,
      [
        .failure(
          WorkspaceError(
            .relayTimeout, "Not confirmed: your Mac may not have received this.",
            details: ["reason": "timeout"]))
      ])
    await draft.send()
    #expect(!draft.finished)
    #expect(draft.text == "Maybe")
    #expect(draft.status == "Not confirmed: your Mac may not have received this.")
    // The Mac may have it, so a second start is not offered.
    #expect(!draft.canSend)
    await draft.send()
    #expect(transport.recorded(.threadStart).count == 1)

    // The Mac's lookup says it never ran: the text is there to send again.
    transport.script(.turnLookup, [.result(try JSONValue(encoding: TurnLookup.Result(state: .none)))])
    clock.advance(by: .seconds(31))
    try await waitUntil("didn't reach") { draft.status == "Didn't reach your Mac" }
    #expect(draft.canSend)
    #expect(draft.text == "Maybe")
    await model.disconnect()
  }

  @Test func aRetryThatLandsClosesTheSheetAndOpensTheThread() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let draft = model.newThreadDraft
    draft.text = "Retry me"
    transport.script(
      .threadStart,
      [
        .failure(
          WorkspaceError(
            .relayTimeout, "Not confirmed: your Mac may not have received this.",
            details: ["reason": "link_dropped", "local": true]))
      ])
    await draft.send()
    #expect(draft.status == "Not confirmed: your Mac may not have received this.")
    #expect(!draft.finished)

    // The link comes back within 30 s: the same start is sent again and lands.
    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.script(.threadStart, [Phone.started(thread, pending.id)])
    transport.emit(PhoneFixture.link(.connecting))
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("finished") { draft.finished }
    // Accepted later, by the retry: the text is cleared all the same.
    #expect(draft.text.isEmpty)
    #expect(!draft.canSend)
    await draft.openStartedThread()
    #expect(model.detail?.thread.id == pending.threadId)
    #expect(transport.recorded(.threadStart).map(\.operationId) == [pending.id, pending.id])
    // The thread belongs to the project's Mac, so its controls follow that Mac.
    #expect(model.threads.first { $0.id == pending.threadId }?.ownerDeviceId == "mac-1")
    await model.disconnect()
  }

  private static let unconfirmed = ScriptedTransport.Reply.failure(
    WorkspaceError(
      .relayTimeout, "Not confirmed: your Mac may not have received this.",
      details: ["reason": "timeout"]))

  @Test func anUnsettledStartBlocksAnotherFromAFreshSheet() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: clock)
    let first = NewThreadDraft(model: model, projectId: nil)
    first.text = "Once only"
    transport.script(.threadStart, [Self.unconfirmed])
    await first.send()
    #expect(first.status == RelayCopy.notConfirmed)

    // Cancel, reopen: a fresh draft cannot start the same thing again while the first may land.
    let second = NewThreadDraft(model: model, projectId: nil)
    second.text = "Once only"
    #expect(second.blockedReason == "Waiting to hear whether your last new thread started.")
    #expect(!second.canSend)
    await second.send()
    #expect(second.status == "Waiting to hear whether your last new thread started.")
    #expect(
      await model.startThread(projectId: "p1", connectionId: "codex-1", folder: "/work/atlas", text: "Again")
        == nil)
    #expect(transport.recorded(.threadStart).count == 1)
    #expect(model.pendingSends.count == 1)

    // The Mac says it never ran it: settled, and a new start goes out as a new thread.
    transport.script(.turnLookup, [.result(try JSONValue(encoding: TurnLookup.Result(state: .none)))])
    clock.advance(by: .seconds(31))
    try await waitUntil("settled") { first.status == RelayCopy.didNotReach }
    #expect(second.blockedReason == nil)
    #expect(second.canSend)
    transport.script(.threadStart, [.hold])
    let task = Task { await second.send() }
    try await waitUntil("second start") { transport.heldCount(.threadStart) == 1 }
    #expect(Set(transport.recorded(.threadStart).map { $0.params["threadId"]?.stringValue ?? "" }).count == 2)
    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    await task.value
    #expect(second.finished)
    await model.disconnect()
  }

  @Test func anUnsettledStartIsFoundByLookupWhenTheMacIsBack() async throws {
    let clock = TestClock()
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: clock)
    let draft = NewThreadDraft(model: model, projectId: nil)
    draft.text = "Landed"
    transport.script(.threadStart, [Self.unconfirmed])
    await draft.send()
    let pending = try #require(model.pendingSends.values.first)
    // The owner goes quiet: no lookup is made, and the start stays open (the honest state).
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -5))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    clock.advance(by: .seconds(40))
    #expect(transport.recorded(.turnLookup).isEmpty)
    #expect(model.unsettledStartReason != nil)
    // Back online: the lookup finds the turn and settles it.
    transport.script(
      .turnLookup,
      [
        .result(
          try JSONValue(
            encoding: TurnLookup.Result(
              state: .found, turn: PhoneFixture.turn("turn-1", in: pending.threadId, operationId: pending.id))
          ))
      ])
    transport.emit(PhoneFixture.presence("mac-1", online: true))
    try await waitUntil("found") { draft.finished }
    #expect(model.unsettledStartReason == nil)
    await model.disconnect()
  }

  @Test func presenceRulesForStartingAreTheControllersRuling() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    // Reconnecting (offline 30 s): the quiet line, Start stays enabled.
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -30))
    try await waitUntil("reconnecting") { model.hostPresence["mac-1"]?.online == false }
    #expect(model.startNotice(for: Phone.p1)?.kind == .reconnecting)
    #expect(model.startBlockedReason(for: Phone.p1) == nil)
    let draft = NewThreadDraft(model: model, projectId: nil)
    draft.text = "Soon"
    #expect(draft.canSend)

    // Unknown presence (a Mac the hub has not reported): Start stays enabled.
    let stranger = Project(
      id: "px", name: "Stranger", folders: [Phone.folder("fx", "px", "/x")], ownerDeviceId: "mac-9")
    #expect(model.hostPhase(deviceId: "mac-9") == .unknown)
    #expect(model.startBlockedReason(for: stranger) == nil)

    // The Mac left the hub: blocked, with the notice.
    model.hostDisconnected = true
    #expect(model.startBlockedReason(for: Phone.p1) == RelayCopy.leftHub)
    #expect(model.startBlockedReason(for: Phone.p3) == RelayCopy.leftHub)
    model.hostDisconnected = false
    #expect(model.startBlockedReason(for: Phone.p1) == nil)

    // The phone's own link is down: blocked, and presence is forgotten.
    transport.emit(PhoneFixture.link(.connecting))
    try await waitUntil("link down") { model.hubLinkPhase == .connecting }
    #expect(model.startBlockedReason(for: Phone.p1) == RelayCopy.connecting)
    #expect(model.startBlockedReason(for: Phone.p3) == RelayCopy.connecting)
    await model.disconnect()
  }

  @Test func sendSaysWhyWhenNothingWasSent() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let draft = NewThreadDraft(model: model, projectId: nil)
    draft.text = "Hello"
    // Another start is out, from elsewhere: the tap says so instead of doing nothing.
    transport.script(.threadStart, [.hold])
    let other = Task {
      await model.startThread(projectId: "p2", connectionId: "codex-1", folder: nil, text: "Other")
    }
    try await waitUntil("other out") { transport.heldCount(.threadStart) == 1 }
    await draft.send()
    #expect(draft.status == RelayCopy.startPending)
    #expect(draft.statusIsFailure)
    #expect(transport.recorded(.threadStart).count == 1)
    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    _ = await other.value
    await model.disconnect()
  }

  @Test func disabledWhenTheMacIsOffline() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    #expect(model.startBlockedReason(for: Phone.p1) == nil)

    // Gone for two minutes: disabled, with the notice as the reason, and nothing is sent.
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    let reason = try #require(model.startBlockedReason(for: Phone.p1))
    #expect(reason.hasPrefix("\(PhoneFixture.macName) is offline · last seen "))
    let draft = NewThreadDraft(model: model, projectId: nil)
    // The sheet opens on a project whose Mac can take it; the owner of p1 is chosen by hand.
    #expect(draft.projectId == "p3")
    draft.selectProject("p1")
    draft.text = "Hello?"
    #expect(draft.blockedReason == reason)
    #expect(!draft.canSend)
    #expect(
      await model.startThread(projectId: "p1", connectionId: "codex-1", folder: "/work/atlas", text: "Hello?")
        == nil)
    #expect(transport.recorded(.threadStart).isEmpty)
    // Another Mac's project is unaffected.
    #expect(model.startBlockedReason(for: Phone.p3) == nil)
    await model.disconnect()
  }

  @Test func theProjectsOwnMacDecidesNotThePrimaryMac() async throws {
    let transport = ScriptedTransport()
    // mac-2 owns the newest thread, so it is the primary Mac the list speaks for.
    let recent = PhoneFixture.thread("recent", owner: "mac-2", at: -10)
    let model = try await Phone.model(transport, clock: TestClock(), threads: [recent])
    #expect(model.primaryHostId == "mac-2")

    // The primary Mac goes offline; mac-1, owner of p1, is online, so p1 can still start.
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: false, lastSeen: -120))
    try await waitUntil("mac-2 offline") { model.hostPresence["mac-2"]?.online == false }
    #expect(model.newThreadDisabledReason != nil)
    #expect(model.startBlockedReason(for: Phone.p1) == nil)
    transport.script(.threadStart, [.hold])
    let task = Task {
      await model.startThread(projectId: "p1", connectionId: "codex-1", folder: "/work/atlas", text: "Go")
    }
    try await waitUntil("held") { transport.heldCount(.threadStart) == 1 }
    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    _ = await task.value

    // The project owner offline blocks its own project, even though the primary Mac is back.
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: true))
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("mac-1 offline") {
      model.hostPresence["mac-1"]?.online == false && model.hostPresence["mac-2"]?.online == true
    }
    #expect(model.newThreadDisabledReason == nil)
    #expect(model.startBlockedReason(for: Phone.p1) != nil)
    #expect(
      await model.startThread(projectId: "p1", connectionId: "codex-1", folder: "/work/atlas", text: "No")
        == nil)
    #expect(transport.recorded(.threadStart).count == 1)
    await model.disconnect()
  }

  @Test func theEntryFollowsWhetherAnyProjectCanStart() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    #expect(model.newThreadEntryReason == nil)
    // Only mac-1 goes: p3 (mac-2) can still start.
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("mac-1 offline") { model.hostPresence["mac-1"]?.online == false }
    #expect(model.newThreadEntryReason == nil)
    // Both gone: the entry says why.
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: false, lastSeen: -120))
    try await waitUntil("mac-2 offline") { model.hostPresence["mac-2"]?.online == false }
    #expect(model.newThreadEntryReason?.contains("is offline") == true)
    await model.disconnect()
  }

  @Test func aSecondTapDoesNotMintASecondThread() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    transport.script(.threadStart, [.hold])
    let first = Task {
      await model.startThread(projectId: "p2", connectionId: "codex-1", folder: nil, text: "Once")
    }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    #expect(model.isStartingThread)
    // The same message, a different one: neither starts anything while the first is out.
    #expect(
      await model.startThread(projectId: "p2", connectionId: "codex-1", folder: nil, text: "Once") == nil)
    #expect(
      await model.startThread(projectId: "p2", connectionId: "codex-1", folder: nil, text: "Twice") == nil)
    #expect(transport.recorded(.threadStart).count == 1)
    #expect(model.pendingSends.count == 1)

    let pending = try #require(model.pendingSends.values.first)
    let thread = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    #expect(await first.value?.state == .accepted(turnId: "turn-1"))
    #expect(!model.isStartingThread)
    await model.disconnect()
  }

  // MARK: Defaults and memory

  @Test func defaultsComeFromTheLastChoiceInThatProject() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.macModel(transport)
    // No history: the newest project, its first folder, the first ready connection, its defaults.
    let first = NewThreadDraft(model: model, projectId: nil)
    #expect(first.projectId == "p1")
    #expect(first.folder == "/work/atlas")
    #expect(first.connectionId == "codex-1")
    #expect(first.model == nil)
    #expect(first.permission == nil)

    // A thread in p1's second folder on Claude, Opus, Plan mode.
    first.selectFolder("/work/atlas-docs", in: "p1")
    first.selectRuntime(connectionId: "claude-1", model: "opus")
    first.selectPermission("plan")
    first.text = "First"
    let call = try await Phone.land(first, model, transport, projectId: "p1", folder: "/work/atlas-docs")
    #expect(call.params["projectId"] == "p1")
    #expect(call.params["folder"] == "/work/atlas-docs")
    #expect(call.params["connectionId"] == "claude-1")
    #expect(call.params["model"] == "opus")
    #expect(call.params["permission"] == "plan")

    // Then one in p2 on Codex. A new project with no history of its own takes the last runtime used
    // anywhere.
    let second = NewThreadDraft(model: model, projectId: "p2")
    #expect(second.folder == "/work/borealis")
    #expect(second.connectionId == "claude-1")
    #expect(second.model == "opus")
    #expect(second.permission == "plan")
    second.selectRuntime(connectionId: "codex-1", model: nil)
    #expect(second.permission == nil)
    second.text = "Second"
    _ = try await Phone.land(second, model, transport, projectId: "p2", folder: "/work/borealis")

    // The next draft opens where the last thread started, with that project's runtime.
    let third = NewThreadDraft(model: model, projectId: nil)
    #expect(third.projectId == "p2")
    #expect(third.connectionId == "codex-1")
    #expect(third.model == nil)
    #expect(third.permission == nil)
    // Back in p1: its own last folder and runtime.
    let fourth = NewThreadDraft(model: model, projectId: "p1")
    #expect(fourth.folder == "/work/atlas-docs")
    #expect(fourth.connectionId == "claude-1")
    #expect(fourth.model == "opus")
    #expect(fourth.permission == "plan")
    await model.disconnect()
  }

  @Test func aProjectIdOverridesOnlyTheProject() async throws {
    let preferences = InMemoryPreferences()
    NewThreadMemory(
      projectId: "p2", folderByProject: ["p1": "/work/atlas-docs"],
      runtimeByProject: [
        "p1": RuntimeChoice(connectionId: "claude-2", model: "haiku", permission: "acceptEdits")
      ],
      lastRuntime: RuntimeChoice(connectionId: "codex-1", model: nil, permission: "read-only"), text: ""
    ).save(to: preferences)
    let model = try await Phone.macModel(ScriptedTransport(), preferences: preferences)

    // Without one, the remembered project.
    let remembered = NewThreadDraft(model: model, projectId: nil)
    #expect(remembered.projectId == "p2")
    #expect(remembered.connectionId == "codex-1")
    #expect(remembered.permission == "read-only")

    // With one, that project; its folder and runtime still come from memory.
    let p1 = NewThreadDraft(model: model, projectId: "p1")
    #expect(p1.projectId == "p1")
    #expect(p1.folder == "/work/atlas-docs")
    #expect(p1.connectionId == "claude-2")
    #expect(p1.model == "haiku")
    #expect(p1.permission == "acceptEdits")
    let p3 = NewThreadDraft(model: model, projectId: "p3")
    #expect(p3.projectId == "p3")
    #expect(p3.folder == "/work/cirrus")
    #expect(p3.connectionId == "codex-1")
    #expect(p3.permission == "read-only")

    // An id that names no project is ignored.
    #expect(NewThreadDraft(model: model, projectId: "gone").projectId == "p2")
    await model.disconnect()
  }

  @Test func switchingRuntimeResetsPermissionToAsConfigured() async throws {
    let model = try await Phone.macModel(ScriptedTransport())
    let draft = NewThreadDraft(model: model, projectId: "p1")
    draft.selectRuntime(connectionId: "claude-1", model: "opus")
    draft.selectPermission("plan")
    #expect(draft.permission == "plan")
    // Another connection of the same runtime keeps the permission; the model is the one chosen.
    draft.selectRuntime(connectionId: "claude-2", model: "sonnet")
    #expect(draft.model == "sonnet")
    #expect(draft.permission == "plan")
    // Another runtime: back to "As configured".
    draft.selectRuntime(connectionId: "codex-1", model: nil)
    #expect(draft.permission == nil)
    #expect(RuntimeOptions.permissionLabel(draft.permission, kind: .codex) == "As configured")
    draft.selectPermission("auto")
    #expect(draft.permission == "auto")
    // Claude's permission is not one of Codex's: nothing changes.
    draft.selectPermission("plan")
    #expect(draft.permission == "auto")
    // A B4 agent has neither model nor permission.
    draft.selectRuntime(connectionId: "b4-p1", model: "opus")
    #expect(draft.model == nil)
    #expect(draft.permission == nil)
    #expect(draft.projectId == "p1")
    await model.disconnect()
  }

  @Test func staleMemoryFallsBackToAValidChoice() async throws {
    let preferences = InMemoryPreferences()
    NewThreadMemory(
      projectId: "gone", folderByProject: ["p2": "/work/removed"],
      runtimeByProject: ["p2": RuntimeChoice(connectionId: "claude-gone", model: "opus", permission: "plan")],
      lastRuntime: RuntimeChoice(connectionId: "codex-gone", model: nil, permission: nil), text: ""
    ).save(to: preferences)
    // p2 has the newest thread, so it is the newest project.
    var recent = PhoneFixture.thread("recent", owner: nil, at: -10)
    recent.projectId = "p2"
    let model = try await Phone.macModel(ScriptedTransport(), preferences: preferences, threads: [recent])
    #expect(model.startProjects.first?.id == "p2")
    let draft = NewThreadDraft(model: model, projectId: nil)
    #expect(draft.projectId == "p2")
    #expect(draft.folder == "/work/borealis")
    #expect(draft.connectionId == "codex-1")
    #expect(draft.model == nil)
    #expect(draft.permission == nil)

    // A remembered model the connection no longer lists, or a permission of another runtime, is
    // dropped; the connection stays.
    NewThreadMemory(
      projectId: "p2", folderByProject: [:],
      runtimeByProject: ["p2": RuntimeChoice(connectionId: "claude-1", model: "retired", permission: "auto")],
      lastRuntime: nil, text: ""
    ).save(to: preferences)
    let pruned = NewThreadDraft(model: model, projectId: nil)
    #expect(pruned.connectionId == "claude-1")
    #expect(pruned.model == nil)
    #expect(pruned.permission == nil)
    await model.disconnect()
  }

  @Test func theMacOpensOnTheLastProjectWithNothingReady() async throws {
    let preferences = InMemoryPreferences()
    NewThreadMemory(projectId: "p3", text: "").save(to: preferences)
    // No connection is ready, so no project has one to offer: the Mac still opens on the last project.
    let offline = Phone.macConnections.map { connection in
      var connection = connection
      connection.status = .offline
      return connection
    }
    let model = try await Phone.macModel(ScriptedTransport(), preferences: preferences, connections: offline)
    let draft = NewThreadDraft(model: model, projectId: nil)
    #expect(draft.projectId == "p3")
    #expect(draft.folder == "/work/cirrus")
    #expect(draft.connectionId == nil)
    #expect(draft.blockedReason == "No ready connection can start a thread in this project.")
    await model.disconnect()
  }

  @Test func onlyARealSignOutClearsTheDraftText() async throws {
    let preferences = InMemoryPreferences()
    NewThreadMemory(text: "Keep me").save(to: preferences)
    let account = AccountStatus.Account(
      id: "0123456789abcdef", displayName: "Brian", orgName: "B4", hubURL: "")
    // A launch that reads "signed out" before anyone was signed in keeps the text.
    let launching = WorkspaceModel(transportProvider: { throw CancellationError() })
    launching.preferences = preferences
    #expect(launching.accountState != .signedIn)
    launching.applyAccountStatus(AccountStatus.Result(state: .signedOut), loadStore: false)
    #expect(NewThreadMemory.load(from: preferences).text == "Keep me")
    #expect(launching.newThreadDraft.text == "Keep me")

    let model = try await Phone.macModel(ScriptedTransport(), preferences: preferences)
    #expect(model.accountState == .signedIn)
    #expect(model.newThreadDraft.text == "Keep me")
    // Signing out of an account clears it.
    model.newThreadDraft.text = "Theirs"
    model.applyAccountStatus(AccountStatus.Result(state: .signedOut), loadStore: false)
    #expect(NewThreadMemory.load(from: preferences).text.isEmpty)
    #expect(model.newThreadDraft.text.isEmpty)

    // So does switching to another account.
    model.applyAccountStatus(AccountStatus.Result(state: .signedIn, account: account), loadStore: false)
    model.newThreadDraft.text = "Also theirs"
    var other = account
    other.id = "fedcba9876543210"
    model.applyAccountStatus(AccountStatus.Result(state: .signedIn, account: other), loadStore: false)
    #expect(NewThreadMemory.load(from: preferences).text.isEmpty)
    #expect(model.newThreadDraft.text.isEmpty)
    await model.disconnect()
  }

  @Test func theDraftTextSurvivesARelaunch() async throws {
    let preferences = InMemoryPreferences()
    let first = try await Phone.macModel(ScriptedTransport(), preferences: preferences)
    first.newThreadDraft.text = "Half a thought"
    #expect(first.newThreadDraft === first.newThreadDraft)
    await first.disconnect()

    let relaunched = try await Phone.macModel(ScriptedTransport(), preferences: preferences)
    #expect(relaunched.newThreadDraft.text == "Half a thought")
    await relaunched.disconnect()
  }

  @Test func aDraftMadeBeforeTheSnapshotFillsInOnRefresh() async throws {
    let transport = ScriptedTransport()
    transport.set(connections: Phone.macConnections, threads: [], projects: Phone.macProjects)
    let model = WorkspaceModel(transportProvider: { transport })
    model.preferences = InMemoryPreferences()
    let draft = model.newThreadDraft
    #expect(draft.projectId == nil)
    #expect(draft.connectionId == nil)
    #expect(draft.blockedReason == "Choose a folder to start in.")
    model.connect()
    try #require(await model.settledLink() == .ready)
    try await waitUntil("projects") { model.projects.count == 3 }
    draft.refreshChoices()
    #expect(draft.projectId == "p1")
    #expect(draft.folder == "/work/atlas")
    #expect(draft.connectionId == "codex-1")
    // Choices that are still offered are kept.
    draft.selectFolder("/work/borealis", in: "p2")
    draft.selectRuntime(connectionId: "claude-2", model: "sonnet")
    draft.refreshChoices()
    #expect(draft.projectId == "p2")
    #expect(draft.connectionId == "claude-2")
    #expect(draft.model == "sonnet")
    await model.disconnect()
  }

  // MARK: The Mac

  @Test func macOffersRemoteB4WithNoProject() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.macModel(transport)
    // Every project, each with the ready Codex and Claude connections and its own local B4; remote
    // B4 on its own.
    #expect(model.startProjects.map(\.id) == ["p1", "p2", "p3"])
    #expect(
      model.startConnections(for: Phone.macProjects[0]).map(\.id) == [
        "codex-1", "claude-1", "claude-2", "b4-p1",
      ])
    #expect(
      model.startConnections(for: Phone.macProjects[1]).map(\.id) == ["codex-1", "claude-1", "claude-2"])
    #expect(model.remoteB4Connections.map(\.id) == ["b4-remote"])

    let draft = NewThreadDraft(model: model, projectId: "p1")
    #expect(draft.connections.map(\.id) == ["codex-1", "claude-1", "claude-2", "b4-p1", "b4-remote"])
    draft.selectRuntime(connectionId: "claude-1", model: "opus")
    draft.selectPermission("plan")
    draft.selectRuntime(connectionId: "b4-remote", model: nil)
    #expect(draft.projectId == nil)
    #expect(draft.folder == nil)
    #expect(draft.model == nil)
    #expect(draft.permission == nil)
    draft.text = "Ask the remote agent"
    #expect(draft.blockedReason == nil)
    #expect(draft.canSend)
    let call = try await Phone.land(draft, model, transport, projectId: nil, folder: nil)
    #expect(call.params["connectionId"] == "b4-remote")
    for key in ["projectId", "folder", "model", "permission"] {
      #expect(call.params[key] == nil || call.params[key] == .null)
    }
    #expect(draft.finished)

    // Back to a runtime that needs a project: the project comes back.
    draft.selectRuntime(connectionId: "codex-1", model: nil)
    #expect(draft.projectId == "p1")
    #expect(draft.folder == "/work/atlas")
    await model.disconnect()

    // The phone has no route to a remote B4.
    let phone = try await Phone.model(ScriptedTransport(), clock: TestClock())
    #expect(phone.remoteB4Connections.isEmpty)
    #expect(phone.startConnectionsWithoutProject.isEmpty)
    #expect(!NewThreadDraft(model: phone, projectId: nil).connections.contains { $0.id == "b4-remote" })
    await phone.disconnect()
  }

  @Test func macStartsOverTheSocketAndOpensTheThread() async throws {
    let preferences = InMemoryPreferences()
    let transport = ScriptedTransport()
    let model = try await Phone.macModel(transport, preferences: preferences)
    let draft = model.newThreadDraft
    // A folder that is one of a project's folders starts in that project.
    draft.chooseFolder("/work/atlas-docs")
    #expect(draft.projectId == "p1")
    #expect(draft.folder == "/work/atlas-docs")
    #expect(draft.chosenFolder == nil)
    // Any other folder starts with no project; the coordinator finds or makes one on Send.
    draft.selectRuntime(connectionId: "b4-p1", model: nil)
    draft.chooseFolder("/elsewhere/tool")
    #expect(draft.projectId == nil)
    #expect(draft.chosenFolder == "/elsewhere/tool")
    #expect(draft.connectionId == "codex-1")
    draft.text = "  Look around  "

    // Refused: the text and the choices stay, the reason shows, and it can be sent again.
    transport.script(
      .threadStart,
      [.failure(WorkspaceError(.endpointUnavailable, "The coordinator is not running."))])
    await draft.send()
    #expect(draft.status == "The coordinator is not running.")
    #expect(draft.statusIsFailure)
    #expect(!draft.finished)
    #expect(draft.canSend)
    #expect(model.unsettledStartReason == nil)
    #expect(draft.text == "  Look around  ")

    transport.script(.threadStart, [.hold])
    let task = Task { await draft.send() }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    #expect(model.isStartingThread)
    #expect(!draft.canSend)
    #expect(draft.status == RelayCopy.starting)
    // A second start while the first is out is not made.
    #expect(
      await model.startThread(
        projectId: "p1", connectionId: "codex-1", folder: "/work/atlas", model: nil, permission: nil,
        text: "Again") == nil)
    let call = try #require(transport.recorded(.threadStart).last)
    #expect(call.params["projectId"] == nil || call.params["projectId"] == .null)
    #expect(call.params["folder"] == "/elsewhere/tool")
    #expect(call.params["text"] == "Look around")
    let pending = try #require(model.pendingSends.values.first { $0.state == .sending })
    #expect(call.operationId == pending.id)
    var thread = PhoneFixture.thread(pending.threadId, owner: nil)
    thread.projectId = "p-new"
    thread.context = "/elsewhere/tool"
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    await task.value
    #expect(transport.recorded(.threadStart).count == 2)

    // Accepted: the thread is listed and open, and the draft is cleared here and in memory.
    #expect(draft.finished)
    #expect(draft.status == nil)
    #expect(!model.isStartingThread)
    #expect(model.threads.contains { $0.id == pending.threadId })
    #expect(model.selectedThreadId == pending.threadId)
    #expect(model.detail?.thread.id == pending.threadId)
    #expect(draft.text.isEmpty)
    let memory = NewThreadMemory.load(from: preferences)
    #expect(memory.text.isEmpty)
    #expect(memory.projectId == "p-new")
    #expect(memory.folderByProject["p-new"] == "/elsewhere/tool")
    #expect(memory.lastRuntime == RuntimeChoice(connectionId: "codex-1", model: nil, permission: nil))
    await model.disconnect()
  }

  // MARK: The composer

  @Test func startRefusedKeepsTheText() async throws {
    let transport = ScriptedTransport()
    let existing = PhoneFixture.thread("t-old", owner: nil)
    let model = try await Phone.macModel(transport, threads: [existing])
    try await waitUntil("threads") { model.threads.count == 1 }
    let draft = model.newThreadDraft
    draft.selectFolder("/work/atlas", in: "p1")
    draft.text = "Find the flaky test"
    transport.script(
      .threadStart, [.failure(WorkspaceError(.protocolInvalid, "That folder is not in this project."))])
    await draft.send()
    #expect(draft.text == "Find the flaky test")
    #expect(draft.status == "That folder is not in this project.")
    #expect(draft.statusIsFailure)
    #expect(model.threads.map(\.id) == ["t-old"])
    #expect(model.selectedThreadId == nil)
    await model.disconnect()
  }

  @Test func secondSendWhileStartingIsIgnored() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.macModel(transport)
    let draft = model.newThreadDraft
    draft.selectFolder("/work/atlas", in: "p1")
    draft.text = "Once"
    transport.script(.threadStart, [.hold])
    let first = Task { await draft.send() }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    // A second Send (a double click, Return pressed twice) while the first is out does nothing at
    // all: no second start, and no refusal left behind to show once the first one settles.
    await draft.send()
    #expect(transport.recorded(.threadStart).count == 1)
    #expect(draft.refusal == nil)
    #expect(draft.status == RelayCopy.starting)

    let pending = try #require(model.pendingSends.values.first)
    var thread = PhoneFixture.thread(pending.threadId, owner: nil)
    thread.projectId = "p1"
    thread.context = "/work/atlas"
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.release(.threadStart, with: Phone.started(thread, pending.id))
    await first.value
    #expect(draft.finished)
    #expect(draft.refusal == nil)
    #expect(transport.recorded(.threadStart).count == 1)
    await model.disconnect()
  }

  @Test func aThreadsRuntimeChangeIsSent() async throws {
    let transport = ScriptedTransport()
    var thread = PhoneFixture.thread("t1", owner: nil)
    thread.connectionId = "claude-1"
    let model = try await Phone.macModel(transport, threads: [thread])
    try await waitUntil("threads") { model.threads.count == 1 }
    var changed = thread
    changed.permission = "plan"
    transport.script(.threadUpdate, [.result(try JSONValue(encoding: ThreadUpdate.Result(thread: changed)))])
    await model.setThreadRuntime(threadId: "t1", model: nil, permission: "plan")
    let calls = transport.recorded(.threadUpdate)
    #expect(calls.count == 1)
    #expect(calls.first?.params["threadId"] == "t1")
    #expect(calls.first?.params["permission"] == "plan")
    #expect(calls.first?.params["model"] == nil || calls.first?.params["model"] == .null)
    // The reply is the thread as stored: the row and the picker show the choice at once.
    #expect(model.threads.first?.permission == "plan")
    #expect(model.lastError == nil)

    // Nothing to change sends nothing.
    await model.setThreadRuntime(threadId: "t1", model: nil, permission: nil)
    #expect(transport.recorded(.threadUpdate).count == 1)
    await model.disconnect()
  }
}
