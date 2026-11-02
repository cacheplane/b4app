import Foundation
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

@Suite(.serialized) struct KeepAwakeTests {
  @Test func assertionHeldOnlyWhenEnabledAndJoined() {
    let fake = FakePowerAssertions()
    let awake = KeepAwake(assertions: fake)
    #expect(!awake.isHeld && !fake.isHeld)

    awake.apply(enabled: true, joined: false)
    #expect(!awake.isHeld && !fake.isHeld)
    awake.apply(enabled: false, joined: true)
    #expect(!awake.isHeld && !fake.isHeld)
    #expect(fake.takes == 0)

    awake.apply(enabled: true, joined: true)
    #expect(awake.isHeld && fake.isHeld)
    #expect(fake.names == ["Agent Workspace keeps this Mac reachable from your phone"])
    // Applying the same state again does not take a second assertion.
    awake.apply(enabled: true, joined: true)
    #expect(fake.takes == 1)

    awake.apply(enabled: false, joined: true)
    #expect(!awake.isHeld && !fake.isHeld && fake.drops == 1)
    awake.apply(enabled: true, joined: true)
    #expect(awake.isHeld && fake.takes == 2)
    awake.apply(enabled: true, joined: false)
    #expect(!awake.isHeld && fake.drops == 2)

    awake.apply(enabled: true, joined: true)
    awake.release()
    #expect(!awake.isHeld && !fake.isHeld && fake.drops == 3)
    awake.release()
    #expect(fake.drops == 3)
  }

  @Test func aRefusedAssertionIsReportedAsNotHeld() {
    let fake = FakePowerAssertions()
    fake.refuse = true
    let awake = KeepAwake(assertions: fake)
    awake.apply(enabled: true, joined: true)
    #expect(!awake.isHeld)
    // Asking again tries again.
    fake.refuse = false
    awake.apply(enabled: true, joined: true)
    #expect(awake.isHeld)
  }

  @Test func leaveReleasesTheAssertion() async throws {
    let rig = try await SyncRig.make(joined: false)
    #expect(!rig.assertions.isHeld)
    #expect(try await rig.sync.status().keepAwakeHeld == false)

    let joined = try await rig.join()
    #expect(joined.keepAwakeHeld == true && rig.assertions.isHeld)
    #expect(try await rig.sync.status().keepAwakeHeld == true)

    try await rig.sync.leave()
    #expect(!rig.assertions.isHeld)
    #expect(try await rig.sync.status().keepAwakeHeld == false)
    #expect(await rig.sync.keepAwakeHeld() == false)
  }

  @Test func stoppingTheCoordinatorReleasesTheAssertion() async throws {
    let rig = try await SyncRig.make()
    #expect(rig.assertions.isHeld)
    await rig.sync.stop()
    #expect(!rig.assertions.isHeld)
  }

  @Test func turningTheToggleOffReleasesAndOnTakesAgain() async throws {
    let rig = try await SyncRig.make()
    #expect(rig.assertions.isHeld)
    let off = try await rig.sync.updateSettings(SettingsUpdate.Params(keepAwake: false))
    #expect(off == SettingsRead.Result(keepAwake: false) && !rig.assertions.isHeld)
    let on = try await rig.sync.updateSettings(SettingsUpdate.Params(keepAwake: true))
    #expect(on.keepAwake && rig.assertions.isHeld)
    // An update that names nothing changes nothing.
    #expect(try await rig.sync.updateSettings(SettingsUpdate.Params()).keepAwake)
    #expect(rig.assertions.isHeld)
  }

  @Test func theToggleOnAnUnjoinedMacHoldsNothing() async throws {
    let rig = try await SyncRig.make(joined: false)
    _ = try await rig.sync.updateSettings(SettingsUpdate.Params(keepAwake: true))
    #expect(!rig.assertions.isHeld)
    _ = try await rig.join()
    #expect(rig.assertions.isHeld)
  }

  @Test func toggleDefaultsOnAndPersists() async throws {
    let rig = try await SyncRig.make(joined: false)
    #expect(try await rig.sync.settings() == SettingsRead.Result(keepAwake: true))
    #expect(try rig.database.settings(key: "keepAwake") == nil)

    _ = try await rig.join()
    _ = try await rig.sync.updateSettings(SettingsUpdate.Params(keepAwake: false))
    #expect(try await rig.sync.settings().keepAwake == false)
    #expect(try rig.database.settings(key: "keepAwake") == .bool(false))
    await rig.sync.stop()

    // A restarted coordinator reads the stored preference: joined, but the toggle is off.
    let restarted = rig.restarted()
    #expect(try await restarted.settings().keepAwake == false)
    await restarted.start()
    #expect(!rig.assertions.isHeld)
    _ = try await restarted.updateSettings(SettingsUpdate.Params(keepAwake: true))
    #expect(rig.assertions.isHeld)
    await restarted.stop()
    #expect(!rig.assertions.isHeld)

    // And with the toggle on, a restart on an existing link holds the assertion at once.
    let again = rig.restarted()
    await again.start()
    #expect(rig.assertions.isHeld)
    await again.stop()
  }

  @Test func settingsAreServedOverTheSocketAndDiagnosticsShowTheAssertion() async throws {
    let rig = try await SocketRig.start()
    defer { Task { await rig.close() } }
    #expect(try await rig.client.request(SettingsRead.self, EmptyParams()).keepAwake)
    var report = try await rig.client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.keepAwakeHeld == false)

    _ = try await rig.join()
    #expect(rig.assertions.isHeld)
    report = try await rig.client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.keepAwakeHeld == true)
    #expect(try await rig.client.request(HubStatus.self, EmptyParams()).keepAwakeHeld == true)

    let off = try await rig.client.request(
      SettingsUpdate.self, SettingsUpdate.Params(keepAwake: false),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(10)))
    #expect(off.keepAwake == false && !rig.assertions.isHeld)
    #expect(try await rig.client.request(SettingsRead.self, EmptyParams()).keepAwake == false)
    #expect(try await rig.client.request(HubStatus.self, EmptyParams()).keepAwakeHeld == false)
    report = try await rig.client.request(DiagnosticsRead.self, EmptyParams())
    #expect(report.keepAwakeHeld == false)
  }
}
