import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The account's view settings in the model (arrangements plan, Task 4): read with the first snapshot,
/// followed through `viewSettings.changed`, written optimistically with only the field that changed,
/// and forgotten when the account ends.
@Suite @MainActor struct ViewSettingsModelTests {
  private static let stored = ViewSettings(
    arrangement: .byEnvironment, quietThreads: .hidden, showArchived: true)

  private static func reply(_ settings: ViewSettings) throws -> ScriptedTransport.Reply {
    .result(try JSONValue(encoding: settings))
  }

  /// A connected model: the Mac's (`.coordinator`), or the phone's (`.host`, which relays through the hub).
  private static func connected(
    _ transport: ScriptedTransport, phone: Bool = false
  ) async throws -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: phone ? .host : .coordinator)
    model.connect()
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    return model
  }

  private static func thread(_ id: String) -> ConversationThread {
    ConversationThread(
      id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, createdAt: "2026-11-11T10:00:00Z",
      updatedAt: "2026-11-11T10:00:00Z")
  }

  @Test func settingsLoadOnConnect() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [Self.thread("t1")])
    transport.script(.viewSettingsGet, [try Self.reply(Self.stored)])
    let model = try await Self.connected(transport)
    #expect(model.viewSettings == Self.stored)
    #expect(model.threads.map(\.id) == ["t1"])

    // A read that fails leaves the defaults and does not hold the list back.
    let failing = ScriptedTransport()
    failing.set(threads: [Self.thread("t2")])
    failing.script(.viewSettingsGet, [.failure(WorkspaceError(.internalError, "no settings"))])
    let other = try await Self.connected(failing)
    #expect(other.viewSettings == ViewSettings())
    #expect(other.threads.map(\.id) == ["t2"])
    #expect(other.lastError == nil)
    await model.disconnect()
    await other.disconnect()
  }

  @Test func aChangeFromAnotherDeviceUpdatesTheModel() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    #expect(model.viewSettings == ViewSettings())
    transport.emit(try .viewSettingsChanged(Self.stored))
    try await waitUntil("the change") { model.viewSettings == Self.stored }
    #expect(transport.recorded(.viewSettingsSet).isEmpty)
    await model.disconnect()
  }

  @Test func aSetShowsAtOnceAndIsSent() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold])
    let write = Task { await model.setQuietThreads(.collapsed) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    // Shown before the answer.
    #expect(model.viewSettings.quietThreads == .collapsed)
    let call = try #require(transport.recorded(.viewSettingsSet).first)
    #expect(call.params == ["quietThreads": "collapsed"])
    #expect(call.operationId != nil)
    #expect(
      transport.release(.viewSettingsSet, with: try Self.reply(ViewSettings(quietThreads: .collapsed))))
    await write.value
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed))

    // The other two setters send only their own field too.
    transport.script(
      .viewSettingsSet,
      [
        try Self.reply(ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed)),
        try Self.reply(
          ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed, showArchived: true)),
      ])
    await model.setArrangement(.byEnvironment)
    await model.setShowArchived(true)
    #expect(
      transport.recorded(.viewSettingsSet).map(\.params) == [
        ["quietThreads": "collapsed"], ["arrangement": "byEnvironment"], ["showArchived": true],
      ])
    #expect(
      model.viewSettings
        == ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed, showArchived: true))
    await model.disconnect()
  }

  @Test func aRefusedSetPutsTheOldValueBack() async throws {
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: .dense))])
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.failure(WorkspaceError(.endpointUnavailable, "The Mac is away."))])
    await model.setArrangement(.byEnvironment)
    #expect(model.viewSettings == ViewSettings(density: .dense))
    // The sidebar's error line says why.
    #expect(model.lastError?.contains("The Mac is away.") == true)

    // A refusal puts back only its own field: a change from elsewhere meanwhile stays.
    transport.script(.viewSettingsSet, [.hold])
    let write = Task { await model.setShowArchived(true) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    transport.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .hidden, showArchived: true)))
    try await waitUntil("the change") { model.viewSettings.quietThreads == .hidden }
    transport.release(.viewSettingsSet, with: .failure(WorkspaceError(.internalError, "refused")))
    await write.value
    #expect(model.viewSettings == ViewSettings(quietThreads: .hidden, showArchived: false))
    await model.disconnect()
  }

  @Test func overlappingSetsKeepEachOthersValues() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold, .hold])
    let first = Task { await model.setArrangement(.byEnvironment) }
    try await waitUntil("the first set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    let second = Task { await model.setQuietThreads(.hidden) }
    try await waitUntil("the second set is out") { transport.heldCount(.viewSettingsSet) == 2 }
    // The first answer was made before the second set: it still carries the old quietThreads.
    transport.release(.viewSettingsSet, with: try Self.reply(ViewSettings(arrangement: .byEnvironment)))
    await first.value
    #expect(model.viewSettings == ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden))
    transport.release(
      .viewSettingsSet, with: try Self.reply(ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden))
    )
    await second.value
    #expect(model.viewSettings == ViewSettings(arrangement: .byEnvironment, quietThreads: .hidden))
    await model.disconnect()
  }

  @Test func aLateAnswerDoesNotUndoAChangeFromElsewhere() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold])
    let write = Task { await model.setShowArchived(true) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    transport.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .collapsed, showArchived: true)))
    try await waitUntil("the change") { model.viewSettings.quietThreads == .collapsed }
    // The answer was made before the other device's change.
    transport.release(.viewSettingsSet, with: try Self.reply(ViewSettings(showArchived: true)))
    await write.value
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed, showArchived: true))
    await model.disconnect()
  }

  @Test func aSlowReadDoesNotUndoNewerValues() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    // The overtaken read is made again, and that one sees what the store now holds: the two newer
    // values, and a field neither of them touched.
    let current = ViewSettings(arrangement: .byEnvironment, density: .dense)
    let reread = ViewSettings(arrangement: .byEnvironment, showArchived: true, density: .dense)
    transport.script(.viewSettingsGet, [.hold, try Self.reply(reread)])
    let read = Task { await model.refreshViewSettings() }
    try await waitUntil("the read is out") { transport.heldCount(.viewSettingsGet) == 1 }
    transport.script(.viewSettingsSet, [try Self.reply(ViewSettings(arrangement: .byEnvironment))])
    await model.setArrangement(.byEnvironment)
    transport.emit(try .viewSettingsChanged(current))
    try await waitUntil("the change") { model.viewSettings.density == .dense }
    // The read's row is from before both.
    transport.release(.viewSettingsGet, with: try Self.reply(ViewSettings()))
    await read.value
    #expect(model.viewSettings == reread)
    await model.disconnect()
  }

  /// A set made during the first read overtakes it. The read is made again, so the fields the set did
  /// not touch still load instead of staying on their defaults until the next snapshot.
  @Test func aReadOvertakenByASetIsReadAgain() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsGet, [.hold, try Self.reply(Self.stored)])
    let read = Task { await model.refreshViewSettings() }
    try await waitUntil("the read is out") { transport.heldCount(.viewSettingsGet) == 1 }
    transport.script(.viewSettingsSet, [try Self.reply(Self.stored)])
    await model.setArrangement(.byEnvironment)
    #expect(model.viewSettings == ViewSettings(arrangement: .byEnvironment))
    transport.release(.viewSettingsGet, with: try Self.reply(ViewSettings()))
    await read.value
    #expect(model.viewSettings == Self.stored)
    await model.disconnect()
  }

  /// A read that answers while a set is still out may carry the row from before the set. It is not
  /// shown; the read is made again once the set has settled.
  @Test func aReadThatAnswersDuringASetWaitsForIt() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold])
    let set = Task { await model.setQuietThreads(.collapsed) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    // The store's row from before the set, then the row after it.
    transport.script(
      .viewSettingsGet,
      [
        try Self.reply(Self.stored),
        try Self.reply(ViewSettings(quietThreads: .collapsed, showArchived: true)),
      ])
    await model.refreshViewSettings()
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed))
    transport.release(.viewSettingsSet, with: try Self.reply(ViewSettings(quietThreads: .collapsed)))
    await set.value
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed, showArchived: true))
    await model.disconnect()
  }

  /// A set still out when its account ends neither holds back the next account's read nor undoes it
  /// when it finally answers.
  @Test func aSetLeftOutByAnEndedAccountDoesNotHoldTheNextRead() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold])
    let set = Task { await model.setQuietThreads(.collapsed) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    model.forgetWorkspace()
    transport.script(.viewSettingsGet, [try Self.reply(Self.stored)])
    await model.refreshViewSettings()
    #expect(model.viewSettings == Self.stored)
    transport.release(.viewSettingsSet, with: try Self.reply(ViewSettings(quietThreads: .collapsed)))
    await set.value
    #expect(model.viewSettings == Self.stored)
    await model.disconnect()
  }

  @Test func thePhoneReadsTheStoredValuesAndSendsNothing() async throws {
    let dense = ViewSettings(density: .dense)
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(dense)])
    let phone = try await Self.connected(transport, phone: true)
    #expect(phone.viewSettings == dense)
    transport.emit(try .viewSettingsChanged(ViewSettings(showArchived: true, density: .dense)))
    try await waitUntil("the change") { phone.viewSettings.showArchived }
    #expect(phone.viewSettings.density == .dense)
    // Reading alone never writes.
    #expect(transport.recorded(.viewSettingsSet).isEmpty)
    await phone.disconnect()
  }

  @Test func choosingOnThePhoneStoresTheValue() async throws {
    let transport = ScriptedTransport()
    let phone = try await Self.connected(transport, phone: true)
    transport.script(.viewSettingsSet, [try Self.reply(ViewSettings(quietThreads: .collapsed))])
    await phone.setQuietThreads(.collapsed)
    #expect(transport.recorded(.viewSettingsSet).map(\.params) == [["quietThreads": "collapsed"]])
    #expect(phone.viewSettings.quietThreads == .collapsed)
    await phone.disconnect()
  }

  @Test func aDensitySetShowsAtOnceAndSendsOnlyDensity() async throws {
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(quietThreads: .collapsed))])
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsSet, [.hold])
    let write = Task { await model.setDensity(.dense) }
    try await waitUntil("the set is out") { transport.heldCount(.viewSettingsSet) == 1 }
    // Shown before the answer, the other fields untouched.
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed, density: .dense))
    let call = try #require(transport.recorded(.viewSettingsSet).first)
    #expect(call.params == ["density": "dense"])
    #expect(call.operationId != nil)
    #expect(
      transport.release(
        .viewSettingsSet, with: try Self.reply(ViewSettings(quietThreads: .collapsed, density: .dense))))
    await write.value
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed, density: .dense))

    // A refusal puts the old density back.
    transport.script(.viewSettingsSet, [.failure(WorkspaceError(.endpointUnavailable, "The Mac is away."))])
    await model.setDensity(.normal)
    #expect(model.viewSettings == ViewSettings(quietThreads: .collapsed, density: .dense))
    await model.disconnect()
  }

  @Test func aSlowReadDoesNotUndoADensitySet() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.viewSettingsGet, [.hold])
    let read = Task { await model.refreshViewSettings() }
    try await waitUntil("the read is out") { transport.heldCount(.viewSettingsGet) == 1 }
    transport.script(.viewSettingsSet, [try Self.reply(ViewSettings(density: .dense))])
    await model.setDensity(.dense)
    // The read's row is from before the set.
    transport.release(.viewSettingsGet, with: try Self.reply(ViewSettings()))
    await read.value
    #expect(model.viewSettings == ViewSettings(density: .dense))
    await model.disconnect()
  }

  /// Tight quiet rows are the Mac's: dense on the Mac's model; never on the phone's, which relays
  /// through the hub and keeps its 44 pt rows at either density.
  @Test func tightQuietRowsAreTheMacsAtDense() async throws {
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: .dense))])
    let mac = try await Self.connected(transport)
    #expect(mac.tightQuietRows)
    transport.emit(try .viewSettingsChanged(ViewSettings()))
    try await waitUntil("normal") { mac.viewSettings.density == .normal }
    #expect(!mac.tightQuietRows)
    await mac.disconnect()

    let phoneTransport = ScriptedTransport()
    phoneTransport.set(threads: [Self.thread("t1")])
    phoneTransport.script(
      .viewSettingsGet, [try Self.reply(ViewSettings(quietThreads: .shown, density: .dense))])
    let phone = try await Self.connected(phoneTransport, phone: true)
    #expect(phone.viewSettings.density == .dense)
    #expect(!phone.tightQuietRows)
    // The layout carries no row size: the phone draws Shown's rows as it always does.
    #expect(phone.listLayout.body == .needsYouFirst(top: [], lower: .rows(phone.threads)))
    await phone.disconnect()
  }

  /// A dense thread is the setting's, on either platform's model.
  @Test func aDenseThreadIsTheStoredDensity() async throws {
    for phone in [false, true] {
      let transport = ScriptedTransport()
      transport.set(threads: [Self.thread("t1")])
      transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: .dense))])
      let model = try await Self.connected(transport, phone: phone)
      #expect(model.denseThread, "phone: \(phone)")
      transport.emit(try .viewSettingsChanged(ViewSettings()))
      try await waitUntil("normal") { model.viewSettings.density == .normal }
      #expect(!model.denseThread, "phone: \(phone)")
      await model.disconnect()
    }
  }

  /// A dense composer (one line for the pickers) is the Mac's: the phone and the iPad keep their
  /// pickers at either density.
  @Test func aDenseComposerIsTheMacsAlone() async throws {
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: .dense))])
    let model = try await Self.connected(transport)
    #expect(model.viewSettings.density == .dense)
    #if os(iOS)
      #expect(!model.denseComposer)
    #else
      #expect(model.denseComposer)
    #endif
    await model.disconnect()
  }

  @Test func quietThreadsIsDisabledByEnvironment() {
    #expect(!ViewOptions.quietThreadsDisabled(ViewSettings()))
    #expect(!ViewOptions.quietThreadsDisabled(ViewSettings(quietThreads: .hidden)))
    #expect(ViewOptions.quietThreadsDisabled(ViewSettings(arrangement: .byEnvironment)))
    #expect(ViewOptions.title(.needsYouFirst) == "Needs you first")
    #expect(ViewOptions.title(.byEnvironment) == "By environment")
    #expect(ViewOptions.quietThreads.map(ViewOptions.title) == ["Shown", "Collapsed", "Hidden"])
  }

  @Test func signingOutForgetsTheSettings() async throws {
    let transport = ScriptedTransport()
    transport.script(.viewSettingsGet, [try Self.reply(Self.stored)])
    let model = try await Self.connected(transport)
    #expect(model.viewSettings == Self.stored)
    transport.emit(try .accountChanged(AccountStatus.Result(state: .signedOut)))
    try await waitUntil("signed out") { model.rootScreen == .signIn }
    #expect(model.viewSettings == ViewSettings())
    await model.disconnect()
  }
}
