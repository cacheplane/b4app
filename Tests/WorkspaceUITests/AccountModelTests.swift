import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

@MainActor
private func connectedModel(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
  let model = WorkspaceModel(transportProvider: { transport })
  model.connect()
  let link = await model.settledLink()
  try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
  return model
}

private let joined = HubStatus.Result(
  joined: true, url: "http://localhost:8080", deviceId: "dev-mac", deviceName: "Mac", orgSlug: "acme",
  username: "blove", displayName: "Brian Love", unsyncedChanges: 0)

@MainActor
@Suite struct AccountModelTests {
  @Test func initialsHandleOddNames() {
    #expect(WorkspaceAccount(username: "blove", displayName: "Brian Love").initials == "BL")
    #expect(WorkspaceAccount(username: "blove", displayName: "  Brian   de  Love ").initials == "BL")
    #expect(WorkspaceAccount(username: "cher", displayName: "Cher").initials == "C")
    #expect(WorkspaceAccount(username: "blove", displayName: "").initials == "BL")
    #expect(WorkspaceAccount(username: "blove", displayName: "").name == "blove")
    #expect(WorkspaceAccount(username: "blove", displayName: nil).name == "blove")
    #expect(WorkspaceAccount(username: "blove", displayName: "   ").initials == "BL")
    let smile = WorkspaceAccount(username: "x", displayName: "🙂 Smile").initials
    #expect(smile == "🙂S")
  }

  @Test func accountFromStatusNeedsAJoinedUser() {
    #expect(WorkspaceAccount(status: HubStatus.Result(joined: false, unsyncedChanges: 0)) == nil)
    var noUser = joined
    noUser.username = nil
    #expect(WorkspaceAccount(status: noUser) == nil)
    #expect(WorkspaceAccount(status: joined)?.name == "Brian Love")
  }

  @Test func notJoinedIsNotSignedIn() async throws {
    let transport = ScriptedTransport()
    let model = try await connectedModel(transport)
    await model.refreshAccount()
    #expect(model.account == nil)
    #expect(model.canLogOut == false)
  }

  @Test func joinedStatusFillsTheAccount() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    let model = try await connectedModel(transport)
    // `connect()` asks once on its own.
    #expect(model.account?.name == "Brian Love")
    #expect(model.account?.initials == "BL")
    #expect(model.canLogOut)
  }

  @Test func logOutSendsHubLeaveAndClearsTheAccount() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    let model = try await connectedModel(transport)
    await model.logOut()
    #expect(transport.calls(.hubLeave).count == 1)
    #expect(model.account == nil)
    #expect(model.lastError == nil)
  }

  @Test func logOutFailureKeepsTheAccount() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined, leaveError: WorkspaceError(.internalError, "the hub is down"))
    let model = try await connectedModel(transport)
    await model.logOut()
    #expect(transport.calls(.hubLeave).count == 1)
    #expect(model.account?.name == "Brian Love")
    #expect(model.lastError != nil)
  }

  @Test func hostSourceIsNeverOverwritten() async throws {
    let transport = ScriptedTransport()
    let model = try await connectedModel(transport)
    let before = transport.calls(.hubStatus).count
    model.accountSource = .host
    model.account = WorkspaceAccount(username: "blove", displayName: "Brian Love")
    #expect(model.canLogOut == false)  // no host log-out wired yet
    var loggedOut = 0
    model.hostLogOut = { loggedOut += 1 }
    #expect(model.canLogOut)
    await model.refreshAccount()
    #expect(model.account?.name == "Brian Love")
    #expect(transport.calls(.hubStatus).count == before)
    await model.logOut()
    #expect(loggedOut == 1)
    #expect(transport.calls(.hubLeave).isEmpty)
  }

  @Test func linkStatusTextNamesTheState() async throws {
    let failing = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "gone") })
    #expect(failing.linkStatusText == "Connecting to coordinator…")
    failing.connect()
    _ = await failing.settledLink()
    // The status line under the name stays short; the error itself goes in the notice above.
    #expect(failing.linkStatusText == "Coordinator unavailable")
    let model = try await connectedModel(ScriptedTransport())
    #expect(model.linkStatusText == "Coordinator connected")
  }
}
