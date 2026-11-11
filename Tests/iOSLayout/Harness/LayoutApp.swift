import SwiftUI
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import WorkspaceUI

// This target is a fixture app only. It renders the shipped shell and banner over an in-memory
// mirror, with a fake relay; it never opens the owner's mirror, Keychain, hub, or installed app.
extension MirrorAccount: @retroactive AccountHost {}

/// The banner's status, observed as the app observes `MirrorHost.syncStatus`, so a fixture change
/// reaches the banner by the shipped path rather than through an `App`-level `@State`.
@MainActor @Observable final class FixtureSync {
  var status: MirrorSyncStatus
  init(_ status: MirrorSyncStatus) { self.status = status }
}

/// A clock whose `now` stands still while its sleeps take real time. The model's 15 s wait for a
/// notified thread then never expires by itself, so a test of Back during that wait does not race a
/// stalled runner.
struct HeldClock: Clock {
  let now = ContinuousClock.now
  var minimumResolution: Duration { ContinuousClock().minimumResolution }
  func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    try await ContinuousClock().sleep(for: now.duration(to: deadline), tolerance: tolerance)
  }
}

@main
struct LayoutApp: App {
  @State private var model: WorkspaceModel
  @State private var sync: FixtureSync
  @State private var connect = ConnectMac(siteDomain: "example.invalid", hasCamera: true, copy: { _ in })
  private let account: MirrorAccount
  private let relay: MirrorRelay
  private let connection: FakeHubLinkConnection
  private let completeNotificationSync: () -> Void
  @State private var notificationSynced = false
  private let screen = ProcessInfo.processInfo.environment["LAYOUT_SCREEN"] ?? "list"
  private let notice = ProcessInfo.processInfo.environment["LAYOUT_NOTICE"] ?? "sync"

  init() {
    let screen = ProcessInfo.processInfo.environment["LAYOUT_SCREEN"] ?? "list"
    let notice = ProcessInfo.processInfo.environment["LAYOUT_NOTICE"] ?? "sync"
    let store = try! MirrorStore.inMemory()
    if !screen.hasPrefix("sign-in") {
      try! store.saveLink(
        MirrorLink(
          hubURL: "https://example.invalid", deviceId: "phone-1", deviceName: "Fixture iPhone",
          tokenRef: "secret:layout-fixture", orgSlug: "layout", username: "fixture",
          userId: "fixture-user", displayName: "Layout Fixture", orgName: "Fixture Workspace",
          needsOnboarding: screen == "onboarding"))
    }
    let url = Bundle.main.url(forResource: "changes", withExtension: "json")!
    let changes = try! JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
    let count =
      screen == "no-ready-detail" || screen.hasPrefix("notification")
      ? 0 : screen == "empty" || screen == "connect-mac" ? 1 : 2
    let rows =
      changes
      .enumerated().map { index, change in
        StoredChange(
          hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
          table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
      }
    _ = try! store.apply(Array(rows.prefix(count)))
    if screen != "connect-mac" {
      let at = Timestamp.now()
      let project: JSONValue = [
        "id": "project-1", "name": "Layout project", "manual": true,
        "createdAt": .string(at), "updatedAt": .string(at),
      ]
      let folder = ProjectFolder(id: "folder-1", projectId: "project-1", path: "/tmp/layout-fixture")
      _ = try! store.apply([
        StoredChange(
          hubSeq: 1000, deviceId: "mac-1", deviceSeq: 1000, wall: changes[1].wall,
          table: "projects", rowId: "project-1", op: "insert", column: nil, value: project),
        StoredChange(
          hubSeq: 1001, deviceId: "mac-1", deviceSeq: 1001, wall: changes[1].wall,
          table: "projectFolders", rowId: "folder-1", op: "insert", column: nil,
          value: try! JSONValue(encoding: folder)),
      ])
    }
    if screen == "scrolling", let template = changes[1].value?.objectValue {
      for index in 2...35 {
        let id = "thread-\(index)"
        var value = template
        value["id"] = .string(id)
        value["nativeThreadId"] = .string("native-\(index)")
        value["title"] = .string(String(format: "Layout thread %02d", index))
        _ = try! store.apply([
          StoredChange(
            hubSeq: index + 1, deviceId: "mac-1", deviceSeq: index + 1, wall: changes[1].wall,
            table: "threads", rowId: id, op: "insert", column: nil, value: .object(value))
        ])
      }
    }
    let connection = FakeHubLinkConnection()
    self.connection = connection
    let relay = MirrorRelay(
      url: URL(string: "https://example.invalid")!, token: { "fixture-token" }, connection: connection)
    self.relay = relay
    let transport = MirrorTransport(store: store, version: "layout-fixture", relay: relay)
    completeNotificationSync = {
      transport.publish(try! store.apply(Array(rows.prefix(9))))
    }
    let account = MirrorAccount(
      store: store, secrets: MemorySecretStore(),
      configuration: .init(hubURL: URL(string: "https://example.invalid")!, deviceName: "Fixture iPhone"),
      memory: MirrorDeviceMemory(url: nil), makeAPI: { _, _ in FakeHubAPI() })
    self.account = account
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.accountHost = account
    if ProcessInfo.processInfo.environment["LAYOUT_HOLD_THREAD_OPEN"] == "1" { model.clock = HeldClock() }
    model.accountHasNoMac = screen == "connect-mac"
    if screen == "archived" { model.projectFilter = .archived }
    if screen == "detail" || screen == "notification-cold" { model.requestOpenThread("thread-1") }
    _model = State(initialValue: model)
    _sync = State(
      initialValue: FixtureSync(
        MirrorSyncStatus(
          lastError: ["sync", "stale", "refused", "blocked"].contains(notice)
            || ProcessInfo.processInfo.environment["LAYOUT_SYNC_FAILURE"] == "1"
            ? ProcessInfo.processInfo.environment["LAYOUT_SYNC_ERROR"]
              ?? "The Internet connection appears to be offline." : nil,
          lastSyncAt: ProcessInfo.processInfo.environment["LAYOUT_LAST_SYNC"]
            ?? (notice == "stale" ? Timestamp.now() : nil))))
  }

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
        .environment(
          \.workspaceStatusBanner,
          {
            AnyView(
              SyncBanner(
                status: sync.status,
                relayRefused: notice == "refused"
                  ? SyncBanner.signInRequiredMessage : nil,
                syncPaused: notice == "blocked"))
          }
        )
        .environment(\.connectMacContent, { AnyView(ConnectMacScreen(state: connect, onScan: {})) })
        .environment(
          \.phoneSignIn,
          PhoneSignInHooks(
            hasCamera: screen != "sign-in-no-camera", scan: {}, enroll: {}, sheetClosed: {})
        )
        .preferredColorScheme(ProcessInfo.processInfo.environment["LAYOUT_DARK"] == "1" ? .dark : .light)
        .overlay(alignment: .bottomTrailing) {
          if screen.hasPrefix("notification"), !notificationSynced {
            VStack {
              if screen == "notification-warm" {
                Button("Open notification") { model.requestOpenThread("thread-1") }
                  .accessibilityIdentifier("fixture.open-notification")
              }
              Button("Finish sync") {
                completeNotificationSync()
                notificationSynced = true
              }
              .accessibilityIdentifier("fixture.finish-sync")
            }
            .buttonStyle(.borderedProminent)
            .padding()
          }
          if ProcessInfo.processInfo.environment["LAYOUT_RECOVER"] == "1", sync.status.lastError != nil {
            // Fixture-only trigger: no timer can race the UI test's initial assertions. It goes once the
            // status has changed, so the test can tell a lost tap from a banner that did not clear.
            Button("Restore fixture connection") {
              sync.status = MirrorSyncStatus(lastSyncAt: Timestamp.now())
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("fixture.recover")
            .padding()
          }
        }
        .onChange(of: model.detail?.thread.id, initial: true) { _, id in
          if notice == "action-error", screen == "detail", id != nil {
            // A successful initial thread read clears errors; inject this fixture afterwards.
            model.lastError = "The requested action could not be completed."
          }
        }
        .task {
          await relay.start()
          // The fake hub answers every link as the hub does: it greets each one and answers its pings.
          // The relay drops a link after 30 s without a frame and opens another, so a slow runner that
          // stalls the app would otherwise leave "Connecting to the hub…" on screen for the rest of a test.
          var prepared = false
          while let socket = try? await connection.nextSocket() {
            // Leave the link awaiting hello to render the shipped connection notices on both screens.
            guard notice != "connecting" else { continue }
            socket.deliver(
              .hello(
                protocol: 1, minClientProtocol: 1, deviceId: "phone-1", role: .client, heartbeatSeconds: 10,
                hubTime: Timestamp.now()))
            socket.deliver(
              .presence(hosts: [
                RelayHostPresence(
                  deviceId: "mac-1", name: "Fixture Mac", online: notice != "host-offline",
                  lastSeenAt: Timestamp.string(from: Date().addingTimeInterval(-120)))
              ]))
            Task {
              while let frame = try? await socket.nextSent() {
                if case .ping = frame { socket.deliver(.pong(hubTime: Timestamp.now())) }
              }
            }
            guard !prepared else { continue }
            prepared = true
            await prepare()
          }
        }
    }
  }

  /// The fixture's state that needs a settled link, set up once, after the first hello.
  private func prepare() async {
    if screen == "new-thread" || screen == "no-ready-detail" {
      _ = await model.settledLink()
      await model.openNewThread()
    }
    if notice == "account" {
      _ = await model.settledLink()
      var accountStatus = account.accountStatus
      accountStatus.notice =
        "The last sign-out could not reach the hub; that session was left open there."
      model.applyHostAccount(accountStatus)
    }
    if notice == "action-error", screen != "detail" {
      _ = await model.settledLink()
      model.lastError = "The requested action could not be completed."
    }
  }
}
