import Foundation
import Testing
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync

@testable import WorkspaceUI

// "Connect your Mac" (sign-in plan, Task 15; `pairing.html`, middle): the phone's thread list gives way
// to it while the account has no Mac. The copy, the links, and when it shows; the app draws it.

private let beta = SignInConfiguration(siteDomain: "test.b4.run", appleSignIn: true, badge: "Test hub")

/// Holds each sleep until the test lets it go, and records how long it was asked to be.
@MainActor
private final class HeldSleep {
  private(set) var asked: [Duration] = []
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func sleep(_ duration: Duration) async {
    asked.append(duration)
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    let all = waiting
    waiting = []
    all.forEach { $0.resume() }
  }
}

/// Checks `condition` every few milliseconds, for state no observation reaches (the test's own).
@MainActor
private func poll(_ what: String, _ condition: @MainActor () -> Bool) async {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(what)")
      return
    }
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
@Suite struct ConnectMacTests {
  @Test func theCopyIsTheSpecs() {
    #expect(ConnectMacCopy.title == "Connect your Mac")
    #expect(
      ConnectMacCopy.message
        == "Your threads run on your Mac. Install Agent Workspace there, sign in, and scan the code it shows."
    )
    #expect(ConnectMacCopy.scan == "Scan the code")
    #expect(ConnectMacCopy.copyLink == "Copy download link")
    #expect(ConnectMacCopy.copied == "Copied")
    #expect(ConnectMacCopy.help == "Help")
  }

  @Test func connectMacShownWithoutMacosDevice() async throws {
    let store = try MirrorStore.inMemory()
    let fake = FakeHubAPI()
    let account = MirrorAccount(
      store: store, secrets: MemorySecretStore(),
      configuration: MirrorAccount.Configuration(
        hubURL: URL(string: "https://hub.test.b4.run")!, deviceName: "Brian's iPhone",
        syncBackoff: .milliseconds(20)),
      memory: MirrorDeviceMemory(url: nil), makeAPI: { _, _ in fake })
    let model = WorkspaceModel(
      transportProvider: { MirrorTransport(store: store, version: "test") }, accountSource: .host)
    model.signInConfiguration = beta
    model.accountHost = account
    account.onChange = { [weak model] in model?.applyHostAccount($0) }
    model.connect()
    try #require(await model.settledLink() == .ready)
    defer {
      Task {
        await account.stopSync()
        await model.disconnect()
      }
    }

    // Signed out: the sign-in screen, never "Connect your Mac", whatever the host last said.
    model.accountHasNoMac = true
    #expect(model.rootScreen == .signIn)
    #expect(!model.showsConnectMac)

    await fake.setSession(
      AuthSession(
        deviceId: "dev-phone", token: "tok-phone", org: OrgInfo(slug: "o-abc", name: "Brian's Org"),
        user: UserInfo(username: "u-abc", displayName: "Brian Love"), needsOnboarding: false))
    let begun = try await account.passkeyBegin()
    _ = try await account.signIn(
      passkey: AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, assertion: ["id": "cred"]))
    try await waitUntil("the workspace") { model.rootScreen == .workspace }

    // Signed in, with no Mac in the account: it replaces the thread list.
    #expect(model.showsConnectMac)
    // A Mac in the account (or a list not read yet): the threads.
    model.accountHasNoMac = false
    #expect(!model.showsConnectMac)

    // The Mac never shows it: its account is the coordinator's.
    let mac = WorkspaceModel(transportProvider: { ScriptedTransport() })
    mac.accountHasNoMac = true
    #expect(!mac.showsConnectMac)
  }

  @Test func copyDownloadLinkCopiesSiteURL() async {
    var copied: [String] = []
    let held = HeldSleep()
    let state = ConnectMac(
      siteDomain: "test.b4.run", hasCamera: true, copy: { copied.append($0) }, sleep: { await held.sleep($0) }
    )
    #expect(state.copyLabel == "Copy download link")
    #expect(state.downloadURL.absoluteString == "https://test.b4.run/app/download")

    let tap = Task { await state.copyDownloadLink() }
    await poll("the copy") { !copied.isEmpty }
    #expect(copied == ["https://test.b4.run/app/download"])
    #expect(state.copyLabel == "Copied")
    // For two seconds.
    await poll("the wait") { held.asked == [.seconds(2)] }
    #expect(state.copyLabel == "Copied")
    held.release()
    await tap.value
    #expect(state.copyLabel == "Copy download link")
  }

  @Test func aSecondCopyKeepsCopiedForTwoSecondsFromItself() async {
    var copied = 0
    let held = HeldSleep()
    let state = ConnectMac(
      siteDomain: "b4.run", hasCamera: true, copy: { _ in copied += 1 }, sleep: { await held.sleep($0) })
    let first = Task { await state.copyDownloadLink() }
    await poll("the first wait") { held.asked.count == 1 }
    let second = Task { await state.copyDownloadLink() }
    await poll("the second wait") { held.asked.count == 2 }
    #expect(copied == 2)
    // Both waits end; only the latest tap's wait may put the label back, and it did not end first.
    held.release()
    await first.value
    await second.value
    #expect(state.copyLabel == "Copy download link")
  }

  @Test func helpOpensSafariSheetAtHelpURL() {
    let state = ConnectMac(siteDomain: "test.b4.run", hasCamera: true, copy: { _ in })
    #expect(state.help == nil)
    state.openHelp()
    #expect(state.help?.url.absoluteString == "https://test.b4.run/app/help/iphone")
    #expect(beta.iPhoneHelpURL == state.help?.url)
    #expect(beta.downloadURL.absoluteString == "https://test.b4.run/app/download")
  }

  @Test func scanTheCodeNeedsACamera() {
    #expect(ConnectMac(siteDomain: "b4.run", hasCamera: true, copy: { _ in }).showsScan)
    #expect(!ConnectMac(siteDomain: "b4.run", hasCamera: false, copy: { _ in }).showsScan)
  }
}
