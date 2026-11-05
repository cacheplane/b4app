import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - Fixture

/// Two Macs. `mac-1` owns the automatic projects `auto-a` and `auto-b` and the manual `work`; `mac-2`
/// owns the automatic `studio`.
private enum Projects {
  static func folder(_ id: String, _ projectId: String, _ path: String) -> ProjectFolder {
    ProjectFolder(id: id, projectId: projectId, path: path, createdAt: PhoneFixture.at(-1000))
  }

  static func project(
    _ id: String, manual: Bool = false, owner: String = "mac-1", _ paths: [String]
  ) -> Project {
    Project(
      id: id, name: manual ? "Work" : "", manual: manual, createdAt: PhoneFixture.at(-1000),
      updatedAt: PhoneFixture.at(-1000),
      folders: paths.enumerated().map { folder("\(id)-\($0.offset)", id, $0.element) }, ownerDeviceId: owner)
  }

  static let autoA = project("auto-a", ["/work/a"])
  static let autoB = project("auto-b", ["/work/b"])
  static let work = project("work", manual: true, ["/work/w"])
  static let studio = project("studio", owner: "mac-2", ["/studio/s"])

  @MainActor
  static func model(
    _ transport: ScriptedTransport, clock: TestClock = TestClock()
  ) async throws
    -> WorkspaceModel
  {
    transport.set(connections: [], threads: [], projects: [autoA, autoB, work, studio])
    let model = try await PhoneFixture.model(transport, clock: clock, online: nil, open: nil)
    transport.emit(PhoneFixture.presence("mac-1", online: true))
    transport.emit(PhoneFixture.presence("mac-2", name: "Studio", online: true))
    try await waitUntil("presence") {
      model.hostPresence["mac-1"] != nil && model.hostPresence["mac-2"] != nil
    }
    try await waitUntil("projects") { model.projects.count == 4 }
    return model
  }

  static func reply(_ project: Project) -> ScriptedTransport.Reply {
    .result(try! JSONValue(encoding: ProjectCreate.Result(project: project)))
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct PhoneProjectTests {
  @Test func aNewProjectGoesToTheChosenMacWithItsOwnId() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    let draft = PhoneProjectDraft(model: model, request: .create)
    #expect(draft.isNew && draft.macs.count == 2)
    let mac = try #require(draft.deviceId)
    // Only the chosen Mac's automatic projects' folders are offered: a manual project's folder would be
    // refused, and the other Mac's are not on this one.
    let expected = mac == "mac-1" ? ["/work/a", "/work/b"] : ["/studio/s"]
    #expect(Set(draft.suggestions) == Set(expected))
    draft.selectMac("mac-1")
    #expect(draft.blockedReason == "Add a folder on \(PhoneFixture.macName).")
    #expect(!draft.canSave)

    draft.add("/work/a")
    draft.typed = "  ~/repos/new  "
    draft.addTyped()
    #expect(draft.folders == ["/work/a", "~/repos/new"] && draft.typed.isEmpty)
    #expect(draft.suggestions == ["/work/b"])
    draft.name = " New "
    #expect(draft.canSave)

    let created = Project(id: draft.projectId, name: "New", manual: true, folders: [])
    transport.script(.projectCreate, [Projects.reply(created)])
    await draft.submit()
    #expect(draft.finished && draft.failure == nil)
    let call = try #require(transport.recorded(.projectCreate).first)
    #expect(call.params["deviceId"] == "mac-1")
    #expect(call.params["projectId"] == .string(draft.projectId))
    #expect(call.params["name"] == "New")
    #expect(call.params["folders"] == ["/work/a", "~/repos/new"])
    // The list moves to the new project.
    #expect(model.projectFilter == .project(draft.projectId))
    #expect(model.projects.contains { $0.id == draft.projectId })
    await model.disconnect()
  }

  @Test func switchingMacsDropsTheOtherMacsFolders() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    let draft = PhoneProjectDraft(model: model, request: .create)
    draft.selectMac("mac-1")
    draft.add("/work/a")
    draft.typed = "/typed"
    draft.addTyped()
    draft.selectMac("mac-2")
    #expect(draft.folders == ["/typed"])
    #expect(draft.suggestions == ["/studio/s"])
    await model.disconnect()
  }

  @Test func theMacsRefusalAndAnOfflineMacShowInTheSheet() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    let draft = PhoneProjectDraft(model: model, request: .create)
    draft.selectMac("mac-1")
    draft.typed = "/not/here"
    draft.addTyped()

    // The Mac checks the folder and says why it refused; the sheet stays open with the text.
    transport.script(
      .projectCreate,
      [.failure(WorkspaceError(.protocolInvalid, "Folder /not/here does not exist."))])
    await draft.submit()
    #expect(!draft.finished)
    #expect(draft.failure == "Folder /not/here does not exist.")

    // The hub says the Mac went offline: worded with its name and when it was last seen.
    transport.script(
      .projectCreate,
      [
        .failure(
          WorkspaceError(
            .deviceOffline, "offline",
            details: ["deviceName": "Brian's Mac", "lastSeenAt": .string(PhoneFixture.at(-120))]))
      ])
    await draft.submit()
    #expect(draft.failure?.hasPrefix("Brian's Mac is offline · last seen ") == true)

    // Once the phone knows the Mac is offline, nothing is sent: Create is off with the notice.
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    let reason = try #require(draft.blockedReason)
    #expect(reason.hasPrefix("\(PhoneFixture.macName) is offline · last seen "))
    #expect(!draft.canSave)
    #expect(transport.recorded(.projectCreate).count == 2)
    // The other Mac can still take a new project.
    draft.selectMac("mac-2")
    #expect(draft.blockedReason == nil)
    // A new sheet opens on the Mac that can take it.
    #expect(PhoneProjectDraft(model: model, request: .create).deviceId == "mac-2")
    await model.disconnect()
  }

  @Test func aNameAloneIsARenameThatNeedsNoMac() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    transport.emit(PhoneFixture.presence("mac-1", online: false, lastSeen: -120))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }

    let draft = PhoneProjectDraft(model: model, request: .edit(projectId: "work"))
    #expect(!draft.isNew && draft.folders == ["/work/w"])
    #expect(!draft.canSave)
    draft.name = "Renamed"
    // The Mac is offline, and still a rename saves: it goes through the change log.
    #expect(draft.blockedReason == nil && draft.canSave)
    var renamed = Projects.work
    renamed.name = "Renamed"
    transport.script(.projectRename, [Projects.reply(renamed)])
    await draft.submit()
    #expect(draft.finished)
    #expect(transport.recorded(.projectRename).first?.params["name"] == "Renamed")
    #expect(transport.recorded(.projectUpdate).isEmpty)

    // A folder change does need the Mac.
    let folders = PhoneProjectDraft(model: model, request: .edit(projectId: "work"))
    folders.add("/work/a")
    #expect(folders.blockedReason?.hasPrefix("\(PhoneFixture.macName) is offline") == true)
    #expect(!folders.canSave)
    await model.disconnect()
  }

  @Test func folderChangesGoToTheMacInOneUpdate() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    let draft = PhoneProjectDraft(model: model, request: .edit(projectId: "work"))
    draft.add("/work/b")
    draft.remove("/work/w")
    draft.name = "Both"
    #expect(draft.added == ["/work/b"] && draft.removed == ["/work/w"])
    transport.script(.projectUpdate, [Projects.reply(Projects.work)])
    await draft.submit()
    #expect(draft.finished)
    let call = try #require(transport.recorded(.projectUpdate).first)
    #expect(call.params["projectId"] == "work")
    #expect(call.params["name"] == "Both")
    #expect(call.params["addFolders"] == ["/work/b"])
    #expect(call.params["removeFolders"] == ["/work/w"])
    #expect(transport.recorded(.projectRename).isEmpty)
    await model.disconnect()
  }

  @Test func anAutomaticProjectKeepsItsFolderAndCannotBeDeleted() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    let draft = PhoneProjectDraft(model: model, request: .edit(projectId: "auto-a"))
    #expect(!draft.canRemove("/work/a") && !draft.canDelete)
    draft.remove("/work/a")
    #expect(draft.folders == ["/work/a"])
    // A folder it gains can be taken back out before saving.
    draft.add("/work/b")
    #expect(draft.canRemove("/work/b"))
    await model.disconnect()
  }

  @Test func deletingAManualProjectAsksItsMac() async throws {
    let transport = ScriptedTransport()
    let model = try await Projects.model(transport)
    model.projectFilter = .project("work")
    let draft = PhoneProjectDraft(model: model, request: .edit(projectId: "work"))
    #expect(draft.canDelete && draft.deleteBlockedReason == nil)
    transport.script(
      .projectDelete, [.result(try JSONValue(encoding: ProjectDelete.Result(projectId: "work")))])
    await draft.delete()
    #expect(draft.finished)
    #expect(transport.recorded(.projectDelete).first?.params["projectId"] == "work")
    #expect(!model.projects.contains { $0.id == "work" })
    #expect(model.projectFilter == .all)

    // A project the phone made whose row has not synced has no Mac to send to yet.
    let fresh = Project(id: "fresh", name: "Fresh", manual: true, folders: [])
    model.merge(fresh)
    let pending = PhoneProjectDraft(model: model, request: .edit(projectId: "fresh"))
    #expect(pending.deleteBlockedReason == RelayCopy.projectNotSynced)
    await model.disconnect()
  }
}
