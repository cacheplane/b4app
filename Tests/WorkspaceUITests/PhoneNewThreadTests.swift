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
    transport.emit(PhoneFixture.presence("mac-1", online: true))
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: true))
    try await waitUntil("presence") {
      model.hostPresence["mac-1"] != nil && model.hostPresence["mac-2"] != nil
    }
    try await waitUntil("projects") { model.projects.count == 3 }
    return model
  }

  static func started(_ thread: ConversationThread, _ id: String) -> ScriptedTransport.Reply {
    .result(
      try! JSONValue(
        encoding: ThreadStart.Result(
          thread: thread, turn: PhoneFixture.turn("turn-1", in: thread.id, operationId: id))))
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct PhoneNewThreadTests {
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
    let draft = PhoneNewThreadDraft(model: model)
    #expect(draft.projectId == "p1")
    #expect(draft.connectionId == "codex-1")
    #expect(draft.folder == "/work/atlas")
    draft.text = "  Start here  "
    transport.script(.threadStart, [.hold])
    let task = Task { await draft.submit() }
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
    #expect(draft.status == nil)
    #expect(model.selectedThreadId == pending.threadId)
    #expect(model.detail?.thread.id == pending.threadId)
    await model.disconnect()
  }

  @Test func startRefusedKeepsTheSheetAndText() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.model(transport, clock: TestClock())
    let draft = PhoneNewThreadDraft(model: model)
    draft.text = "Keep this"
    transport.script(
      .threadStart,
      [.failure(WorkspaceError(.protocolInvalid, "That folder is not in this project."))])
    await draft.submit()
    #expect(!draft.finished)
    #expect(draft.text == "Keep this")
    #expect(draft.status == "That folder is not in this project.")
    #expect(draft.canSend)
    #expect(model.selectedThreadId == nil)

    // Sending again mints a new thread; the refused one is gone.
    let refused = try #require(model.pendingSends.values.first)
    transport.script(.threadStart, [.hold])
    let again = Task { await draft.submit() }
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
    let draft = PhoneNewThreadDraft(model: model)
    draft.text = "Maybe"
    transport.script(
      .threadStart,
      [
        .failure(
          WorkspaceError(
            .relayTimeout, "Not confirmed: your Mac may not have received this.",
            details: ["reason": "timeout"]))
      ])
    await draft.submit()
    #expect(!draft.finished)
    #expect(draft.text == "Maybe")
    #expect(draft.status == "Not confirmed: your Mac may not have received this.")
    // The Mac may have it, so a second start is not offered.
    #expect(!draft.canSend)
    await draft.submit()
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
    let draft = PhoneNewThreadDraft(model: model)
    draft.text = "Retry me"
    transport.script(
      .threadStart,
      [
        .failure(
          WorkspaceError(
            .relayTimeout, "Not confirmed: your Mac may not have received this.",
            details: ["reason": "link_dropped", "local": true]))
      ])
    await draft.submit()
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
    await draft.openStartedThread()
    #expect(model.detail?.thread.id == pending.threadId)
    #expect(transport.recorded(.threadStart).map(\.operationId) == [pending.id, pending.id])
    // The thread belongs to the project's Mac, so its controls follow that Mac.
    #expect(model.threads.first { $0.id == pending.threadId }?.ownerDeviceId == "mac-1")
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
    let draft = PhoneNewThreadDraft(model: model)
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
}
