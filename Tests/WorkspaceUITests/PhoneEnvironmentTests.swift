import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - Fixture

/// Two Macs. `mac-1` owns the automatic environments `auto-a` and `auto-b` and the manual `work`; `mac-2`
/// owns the automatic `studio`. The phone only edits and deletes them (D-212).
private enum Environments {
  static func folder(_ id: String, _ environmentId: String, _ path: String) -> EnvironmentFolder {
    EnvironmentFolder(id: id, environmentId: environmentId, path: path, createdAt: PhoneFixture.at(-1000))
  }

  static func environment(
    _ id: String, manual: Bool = false, owner: String = "mac-1", _ paths: [String]
  ) -> WorkEnvironment {
    WorkEnvironment(
      id: id, name: manual ? "Work" : "", manual: manual, createdAt: PhoneFixture.at(-1000),
      updatedAt: PhoneFixture.at(-1000),
      folders: paths.enumerated().map { folder("\(id)-\($0.offset)", id, $0.element) }, ownerDeviceId: owner)
  }

  static let autoA = environment("auto-a", ["/work/a"])
  static let autoB = environment("auto-b", ["/work/b"])
  static let work = environment("work", manual: true, ["/work/w"])
  static let studio = environment("studio", owner: "mac-2", ["/studio/s"])

  @MainActor
  static func model(
    _ transport: ScriptedTransport, clock: TestClock = TestClock()
  ) async throws
    -> WorkspaceModel
  {
    transport.set(connections: [], threads: [], environments: [autoA, autoB, work, studio])
    let model = try await PhoneFixture.model(transport, clock: clock, online: nil, open: nil)
    transport.emit(PhoneFixture.presence("mac-1", online: true))
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: true))
    try await waitUntil("presence") {
      model.hostPresence["mac-1"] != nil && model.hostPresence["mac-2"] != nil
    }
    try await waitUntil("environments") { model.environments.count == 4 }
    return model
  }

  static func reply(_ environment: WorkEnvironment) -> ScriptedTransport.Reply {
    .result(try! JSONValue(encoding: EnvironmentCreate.Result(environment: environment)))
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct PhoneEnvironmentTests {
  @Test func theMacsRefusalAndAnOfflineMacShowInTheSheet() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "work"))
    draft.typed = "/not/here"
    draft.addTyped()

    // The Mac checks the folder and says why it refused; the sheet stays open with the text.
    transport.script(
      .environmentUpdate,
      [.failure(WorkspaceError(.protocolInvalid, "Folder /not/here does not exist."))])
    await draft.submit()
    #expect(!draft.finished)
    #expect(draft.failure == "Folder /not/here does not exist.")

    // The hub says the Mac went offline: worded with its name and when it was last seen.
    transport.script(
      .environmentUpdate,
      [
        .failure(
          WorkspaceError(
            .deviceOffline, "offline",
            details: ["deviceName": "Brian's Mac", "lastSeenAt": .string(PhoneFixture.at(-120))]))
      ])
    await draft.submit()
    #expect(draft.failure?.hasPrefix("Brian's Mac is offline · last seen ") == true)

    // Once the phone knows the Mac is offline, nothing is sent: Save is off with the notice.
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    let reason = try #require(draft.blockedReason)
    #expect(reason.hasPrefix("\(PhoneFixture.macName) is offline · last seen "))
    #expect(!draft.canSave)
    #expect(transport.recorded(.environmentUpdate).count == 2)
    await model.disconnect()
  }

  @Test func theNameStartsAsShownAndAnUntouchedNameSavesNothing() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "auto-a"))
    // An automatic environment's generated name is in the field, and leaving it is no rename.
    #expect(draft.name == "a" && !draft.canSave)
    draft.name = " a "
    #expect(!draft.canSave)
    // Its stored name is already empty, so clearing the field changes nothing either.
    draft.name = ""
    #expect(!draft.canSave)
    draft.name = "App"
    #expect(draft.canSave)
    transport.script(.environmentRename, [Environments.reply(Environments.autoA)])
    await draft.submit()
    #expect(transport.recorded(.environmentRename).first?.params["name"] == "App")
    await model.disconnect()
  }

  @Test func aNameAloneIsARenameThatNeedsNoMac() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }

    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "work"))
    #expect(draft.folders == ["/work/w"])
    #expect(!draft.canSave)
    draft.name = "Renamed"
    // The Mac is offline, and still a rename saves: it goes through the change log.
    #expect(draft.blockedReason == nil && draft.canSave)
    var renamed = Environments.work
    renamed.name = "Renamed"
    transport.script(.environmentRename, [Environments.reply(renamed)])
    await draft.submit()
    #expect(draft.finished)
    #expect(transport.recorded(.environmentRename).first?.params["name"] == "Renamed")
    #expect(transport.recorded(.environmentUpdate).isEmpty)

    // A folder change does need the Mac.
    let folders = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "work"))
    folders.add("/work/a")
    #expect(folders.blockedReason?.hasPrefix("\(PhoneFixture.macName) is offline") == true)
    #expect(!folders.canSave)
    await model.disconnect()
  }

  @Test func folderChangesGoToTheMacInOneUpdate() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "work"))
    draft.add("/work/b")
    draft.remove("/work/w")
    draft.name = "Both"
    #expect(draft.added == ["/work/b"] && draft.removed == ["/work/w"])
    transport.script(.environmentUpdate, [Environments.reply(Environments.work)])
    await draft.submit()
    #expect(draft.finished)
    let call = try #require(transport.recorded(.environmentUpdate).first)
    #expect(call.params["environmentId"] == "work")
    #expect(call.params["name"] == "Both")
    #expect(call.params["addFolders"] == ["/work/b"])
    #expect(call.params["removeFolders"] == ["/work/w"])
    #expect(transport.recorded(.environmentRename).isEmpty)
    await model.disconnect()
  }

  @Test func anEnvironmentKeepsItsLastFolderAndAnyCanBeDeleted() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "auto-a"))
    #expect(!draft.canRemove("/work/a") && draft.canDelete)
    draft.remove("/work/a")
    #expect(draft.folders == ["/work/a"])
    // With a second folder either can go, the first too.
    draft.add("/work/b")
    #expect(draft.canRemove("/work/a") && draft.canRemove("/work/b"))
    // Every other environment's folder on this Mac is offered, a manual one's too: adding moves it.
    #expect(
      Set(PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "auto-b")).suggestions) == [
        "/work/a", "/work/w",
      ])
    await model.disconnect()
  }

  @Test func deletingAnEnvironmentAsksItsMac() async throws {
    let transport = ScriptedTransport()
    let model = try await Environments.model(transport)
    let draft = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "work"))
    #expect(draft.canDelete && draft.deleteBlockedReason == nil)
    transport.script(
      .environmentDelete, [.result(try JSONValue(encoding: EnvironmentDelete.Result(environmentId: "work")))])
    await draft.delete()
    #expect(draft.finished)
    #expect(transport.recorded(.environmentDelete).first?.params["environmentId"] == "work")
    #expect(!model.environments.contains { $0.id == "work" })

    // An environment the phone made whose row has not synced has no Mac to send to yet.
    let fresh = WorkEnvironment(id: "fresh", name: "Fresh", manual: true, folders: [])
    model.merge(fresh)
    let pending = PhoneEnvironmentDraft(model: model, request: .edit(environmentId: "fresh"))
    #expect(pending.deleteBlockedReason == RelayCopy.environmentNotSynced)
    await model.disconnect()
  }
}
