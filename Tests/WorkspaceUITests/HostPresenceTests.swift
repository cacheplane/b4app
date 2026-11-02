import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite(.serialized) @MainActor struct HostPresenceTests {
  private func offlineNotice(lastSeen seconds: Double, now: Date) -> String {
    let seen = HostNoticeMessage.lastSeen(TestClock.start.addingTimeInterval(seconds), now: now)
    return "\(PhoneFixture.macName) is offline · last seen \(seen)"
  }

  @Test func phasesConnectedReconnectingDisconnectedConnected() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    let model = try await PhoneFixture.model(transport, clock: clock)
    let thread = PhoneFixture.thread()
    #expect(model.hostPhase(deviceId: "mac-1") == .connected)
    #expect(model.threadNotice(for: thread) == nil)

    // Offline, last seen now: reconnecting for 60 s from `lastSeenAt`, one quiet line in the thread.
    transport.emit(PhoneFixture.presence(online: false, lastSeen: 0))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    let until = TestClock.start.addingTimeInterval(60)
    #expect(model.hostPhase(deviceId: "mac-1") == .reconnecting(until: until))
    #expect(
      model.threadNotice(for: thread)
        == HostNoticeMessage(kind: .reconnecting, text: "Reconnecting to your Mac…"))
    #expect(model.listNotice == nil)
    // Sending is not blocked by the phone while reconnecting.
    #expect(model.sendBlockedReason(for: thread) == nil)
    #expect(model.controlsDisabledReason(for: thread) == nil)

    clock.advance(by: .milliseconds(59_999))
    #expect(model.hostPhase(deviceId: "mac-1") == .reconnecting(until: until))
    // Exactly 60 s: disconnected, and the views hear it from the model's own timer.
    clock.advance(by: .milliseconds(1))
    try await waitUntil("disconnected") { model.threadNotice(for: thread)?.kind == .offline }
    #expect(model.hostPhase(deviceId: "mac-1") == .disconnected(lastSeen: TestClock.start))
    let notice = offlineNotice(lastSeen: 0, now: clock.date)
    #expect(model.threadNotice(for: thread)?.text == notice)
    #expect(model.listNotice?.text == notice)

    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("back") { model.hostPhase(deviceId: "mac-1") == .connected }
    #expect(model.threadNotice(for: thread) == nil)
    #expect(model.listNotice == nil)
    #expect(model.controlsDisabledReason(for: thread) == nil)
    await model.disconnect()
  }

  @Test func presenceBeforeTheFirstSnapshotIsKept() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    // Emitted before the model connects, and carried by the snapshot: the events the snapshot
    // covers may or may not reach the model, and either way the snapshot's presence stands.
    let offline = HostPresence(
      deviceId: "mac-1", name: PhoneFixture.macName, online: false, lastSeenAt: PhoneFixture.at(-120))
    transport.emit(PhoneFixture.link(.connecting))
    transport.emit(PhoneFixture.link(.connected))
    transport.emit(try AdapterEvent.hostPresence(offline, link: .connected))
    transport.setPresence(PresenceSnapshot(link: .connected, hosts: [offline]))
    let model = try await PhoneFixture.model(transport, clock: clock, online: nil, open: nil)
    #expect(model.hubLinkPhase == .connected)
    #expect(model.hostPresence["mac-1"] == offline)
    #expect(
      model.hostPhase(deviceId: "mac-1") == .disconnected(lastSeen: TestClock.start.addingTimeInterval(-120)))
    // Events after the snapshot still arrive: the model subscribed before asking for it.
    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("online", timeout: .seconds(10)) { model.hostPhase(deviceId: "mac-1") == .connected }
    await model.disconnect()
  }

  @Test func primaryMacIsTheOwnerOfTheMostRecentThread() async throws {
    let clock = TestClock()
    let stale = PhoneFixture.thread("old", owner: "mac-old", at: -86_400)
    let recent = PhoneFixture.thread("new", owner: "mac-1", at: -60)
    let transport = PhoneFixture.transport(threads: [stale, recent])
    let model = try await PhoneFixture.model(transport, clock: clock, open: nil)
    transport.emit(PhoneFixture.presence("mac-old", name: "Old Mac", online: false, lastSeen: -86_400))
    try await waitUntil("old presence") { model.hostPresence["mac-old"] != nil }
    #expect(model.primaryHostId == "mac-1")
    // A stale second Mac raises no notice in the list; its own thread shows it when opened.
    #expect(model.listNotice == nil)
    #expect(model.threadNotice(for: stale)?.kind == .offline)
    #expect(model.threadNotice(for: stale)?.text.hasPrefix("Old Mac is offline · last seen ") == true)
    #expect(model.controlsDisabledReason(for: stale) != nil)
    #expect(model.controlsDisabledReason(for: recent) == nil)
    await model.disconnect()

    // With no threads, the most recently seen host.
    let empty = PhoneFixture.transport(threads: [])
    let other = try await PhoneFixture.model(empty, clock: clock, online: false, open: nil)
    empty.emit(PhoneFixture.presence("mac-old", name: "Old Mac", online: false, lastSeen: -86_400))
    try await waitUntil("old presence") { other.hostPresence["mac-old"] != nil }
    #expect(other.primaryHostId == "mac-1")
    #expect(other.listNotice == nil)  // mac-1 was seen just now: still reconnecting
    clock.advance(by: .seconds(60))
    try await waitUntil("disconnected") { other.listNotice != nil }
    #expect(other.listNotice?.text == offlineNotice(lastSeen: 0, now: clock.date))
    #expect(other.newThreadDisabledReason == other.listNotice?.text)
    await other.disconnect()
  }

  @Test func disconnectedDisablesControlsButListAndTranscriptsLoad() async throws {
    let clock = TestClock()
    let running = PhoneFixture.turn("turn-1", operationId: "op-1")
    var working = PhoneFixture.thread("t1")
    working.activity?.latestTurnId = "turn-1"
    working.activity?.latestTurnStatus = .running
    let threads = [working, PhoneFixture.thread("t2", at: -900)]
    let transport = PhoneFixture.transport(threads: threads, turns: [running])
    let model = try await PhoneFixture.model(transport, clock: clock, online: false, open: nil)
    clock.advance(by: .seconds(61))
    try await waitUntil("disconnected") { model.listNotice != nil }
    let notice = offlineNotice(lastSeen: 0, now: clock.date)

    // Browsable: every thread listed, and a transcript opens.
    #expect(model.orderedThreads.map(\.id).sorted() == ["t1", "t2"])
    await model.openThread(id: "t1")
    #expect(model.detail?.thread.id == "t1")
    #expect(model.detail?.activeTurn?.id == "turn-1")

    // Composer, Stop, approvals, and New thread are off, with the notice as the reason.
    let thread = threads[0]
    #expect(model.controlsDisabledReason(for: thread) == notice)
    #expect(model.sendBlockedReason(for: thread) == notice)
    #expect(!model.canStop(thread))
    let request = RuntimeRequest(
      id: "r1", nativeRequestId: "n-r1", threadId: "t1", adapterGeneration: 1, kind: .commandApproval,
      payload: ["answerable": true])
    #expect(!model.canAnswer(request))
    #expect(model.newThreadDisabledReason == notice)
    // The running turn is not shown as working: the phone does not invent an outcome.
    #expect(model.activeTurnLabel(for: thread) == "Not confirmed while your Mac is offline")
    #expect(
      model.reasonLine(for: model.threads.first { $0.id == "t1" }!)
        == "Not confirmed while your Mac is offline")
    #expect(model.band(of: model.threads.first { $0.id == "t1" }!) == .working)
    await model.send()
    await model.stop()
    #expect(transport.recorded(.turnSend).isEmpty && transport.recorded(.turnInterrupt).isEmpty)
    await model.disconnect()
  }

  @Test func leftHubShowsNoticeAboveTheList() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    let model = try await PhoneFixture.model(transport, clock: clock, online: nil, open: nil)
    model.hostDisconnected = true
    let text = "Your Mac has left the hub. Its threads come back when it joins again."
    #expect(model.listNotice == HostNoticeMessage(kind: .leftHub, text: text))
    // Above a browsable list, not instead of it.
    #expect(model.orderedThreads.map(\.id) == ["t1"])
    await model.openThread(id: "t1")
    #expect(model.detail?.thread.id == "t1")
    let thread = PhoneFixture.thread()
    #expect(model.threadNotice(for: thread)?.text == text)
    #expect(model.controlsDisabledReason(for: thread) == text)
    #expect(model.newThreadDisabledReason == text)
    model.hostDisconnected = false
    #expect(model.listNotice == nil)
    await model.disconnect()
  }

  @Test func phoneLinkDownShowsConnectingToTheHub() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    let model = try await PhoneFixture.model(transport, clock: clock, online: false)
    clock.advance(by: .seconds(120))
    try await waitUntil("disconnected") { model.listNotice != nil }
    // The phone's own link drops: every host's presence is unknown, so no host notice.
    transport.emit(PhoneFixture.link(.connecting))
    try await waitUntil("link down") { model.hubLinkPhase == .connecting }
    let thread = PhoneFixture.thread()
    #expect(model.hostPhase(deviceId: "mac-1") == .unknown)
    #expect(model.listNotice == nil)
    #expect(model.threadNotice(for: thread) == nil)
    #expect(model.hubLinkNotice == "Connecting to the hub…")
    #expect(model.sendBlockedReason(for: thread) == "Connecting to the hub…")
    #expect(model.controlsDisabledReason(for: thread) == nil)
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("link up") { model.hubLinkPhase == .connected }
    #expect(model.hubLinkNotice == nil)
    await model.disconnect()
  }

  @Test func macModelIgnoresPresence() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport(threads: [PhoneFixture.thread(owner: nil)])
    transport.script(.turnSend, [.hold])
    // The Mac: the coordinator owns the account, and its transport never emits `host.presence`. Even
    // if one arrived, nothing would change.
    let model = WorkspaceModel(transportProvider: { transport })
    model.clock = clock
    model.now = { clock.date }
    model.connect()
    try #require(await model.settledLink() == .ready)
    #expect(model.accountSource == .coordinator)
    transport.emit(PhoneFixture.link(.offline))
    transport.emit(PhoneFixture.presence(online: false, lastSeen: -600))
    clock.advance(by: .seconds(120))
    await model.openThread(id: "t1")
    let thread = PhoneFixture.thread(owner: nil)
    #expect(model.hostPhase(for: thread) == .unknown)
    #expect(model.listNotice == nil)
    #expect(model.threadNotice(for: thread) == nil)
    #expect(model.controlsDisabledReason(for: thread) == nil)
    #expect(model.sendBlockedReason(for: thread) == nil)
    #expect(model.hubLinkNotice == nil)
    #expect(model.newThreadDisabledReason == nil)
    #expect(model.canStop(thread))

    // Sending is the Mac's as before: the composer clears at once and no send state is kept.
    model.composerText = "hello"
    let task = Task { await model.send() }
    try await waitUntil("sent") { transport.heldCount(.turnSend) == 1 }
    #expect(model.composerText.isEmpty)
    #expect(model.pendingSends.isEmpty)
    transport.release(.turnSend, with: PhoneFixture.sent(PhoneFixture.turn("turn-9", operationId: "op")))
    await task.value
    #expect(model.pendingSends.isEmpty)
    #expect(transport.recorded(.turnSend).first?.operationId != nil)
    await model.disconnect()
  }
}
