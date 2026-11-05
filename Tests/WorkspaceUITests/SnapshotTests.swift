import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceUI

private let fakeClaude =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("ClaudeAdapterTests/Fixtures/fake-claude.py").path

/// Renders the real root view, over a real coordinator and the fixture runtimes, into PNGs for a
/// visual check without screen access. Opt in with `B4APP_SNAPSHOT_DIR=<dir> swift test --filter
/// SnapshotTests`; the files are `<view>-<light|dark>.png`. The window is never ordered on screen.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] != nil))
@MainActor struct SnapshotTests {
  @Test func rendersEverySurfaceInBothAppearances() async throws {
    let dir = ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"]!
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model

    let codex = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    _ = await model.addConnection(kind: .claude, label: "Claude Code", executablePath: fakeClaude)
    try FileManager.default.createDirectory(atPath: h.workDir + "/b", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: h.workDir + "/c", withIntermediateDirectories: true)

    // Threads 2 and 3 first: the fixture blocks while an approval is pending (thread 1, below).
    await model.createThread(
      connectionId: codex.id, directory: h.workDir + "/b", title: "Pricing page research")
    let research = try #require(model.threads.first { $0.title == "Pricing page research" })
    await model.updateThread(id: research.id, pinned: true)
    await model.openThread(id: research.id)
    model.composerText = "hang around while I think"
    await model.send()
    try await waitUntil("running") { model.threadState(research) == .running }
    await model.createThread(
      connectionId: codex.id, directory: h.workDir + "/c", title: "Old migration experiment")
    let old = try #require(model.threads.first { $0.title == "Old migration experiment" })
    await model.updateThread(id: old.id, archived: true)

    // Thread 1: a finished exchange, then a turn waiting on a command approval.
    await model.createThread(connectionId: codex.id, directory: h.workDir, title: "Release notes draft")
    let release = try #require(model.threads.first { $0.title == "Release notes draft" })
    await model.openThread(id: release.id)
    model.composerText = "Summarize the commits since the last tag and draft the release notes."
    await model.send()
    try await waitUntil("first turn done") {
      model.activeTurns[release.id] == nil && (model.detail?.items.count ?? 0) >= 2
    }
    model.composerText = "Now approve running the test suite before we publish."
    await model.send()
    try await waitUntil("approval pending") { model.detail?.requests.count == 1 }
    await model.refreshDiagnostics()
    model.composerText = "Ship it once the tests are green."

    let window = SnapshotWindow(rootView: SnapshotShell(model: model))
    // B4APP_SNAPSHOT_ROOT=1 renders the real NavigationSplitView root on screen instead (debugging aid).
    if ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_ROOT"] == "1" {
      let real = SnapshotWindow(rootView: SnapshotShell(model: model, useRoot: true), onScreen: true)
      try await real.capture(to: "\(dir)/root-light.png")
      model.selectedThreadId = nil
      try await real.capture(to: "\(dir)/root-empty-light.png")
      model.selectedThreadId = release.id
      await model.openThread(id: release.id)
      real.close()
    }
    let settings = SnapshotWindow(
      rootView: WorkspaceSettingsView(model: model), size: CGSize(width: 760, height: 500))
    let signedIn = WorkspaceAccount(username: "blove", displayName: "Brian Love")
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      settings.appearance = NSAppearance(named: appearance)
      model.account = signedIn
      try await window.capture(to: "\(dir)/sidebar-\(suffix).png")
      model.showProfileMenu = true
      try await window.capture(to: "\(dir)/profile-menu-\(suffix).png")
      model.showProfileMenu = false
      model.showSearch = true
      try await window.capture(to: "\(dir)/search-\(suffix).png")
      model.showSearch = false
      model.hostNote = "The background agent is not running. Open Login Items to allow it."
      model.hostActionTitle = "Open Login Items"
      model.hostAction = {}
      try await window.capture(to: "\(dir)/notice-\(suffix).png")
      model.hostNote = nil
      model.account = nil
      try await window.capture(to: "\(dir)/not-signed-in-\(suffix).png")
      model.account = signedIn
      model.hostDisconnected = true
      try await window.capture(to: "\(dir)/host-disconnected-\(suffix).png")
      model.hostDisconnected = false
      model.selectedThreadId = nil
      try await window.capture(to: "\(dir)/new-thread-\(suffix).png")
      model.selectedThreadId = release.id
      await model.openThread(id: release.id)
      for page in SettingsPage.allCases {
        model.settingsPage = page
        try await settings.capture(to: "\(dir)/settings-\(page.rawValue)-\(suffix).png")
      }
    }
    settings.close()
    window.close()
    #expect(FileManager.default.fileExists(atPath: "\(dir)/settings-diagnostics-dark.png"))
  }
}

/// The sidebar and the detail side by side without `NavigationSplitView`, whose sidebar column only
/// draws for a window the user can see. Every piece is the app's own view.
struct SnapshotShell: View {
  @Bindable var model: WorkspaceModel
  var useRoot = false

  var body: some View {
    if useRoot {
      WorkspaceRootView(model: model).frame(width: 1200, height: 800)
    } else {
      shell
    }
  }

  private var shell: some View {
    HStack(spacing: 0) {
      SidebarView(model: model).frame(width: 290)
      Rectangle().fill(LLA.Color.rule).frame(width: 1)
      ThreadsView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LLA.Color.bg)
    }
    .overlay { if model.showSearch { SearchPalette(model: model) } }
    .tint(LLA.Color.accent)
    .frame(width: 1200, height: 800)
  }
}

/// An offscreen window hosting a SwiftUI view; `capture` lets the run loop settle and draws the
/// content view into a bitmap (no screen recording permission needed).
@MainActor final class SnapshotWindow<Content: View> {
  let window: NSWindow
  let host: NSHostingView<Content>

  init(rootView: Content, onScreen: Bool = false, size: CGSize = CGSize(width: 1200, height: 800)) {
    host = NSHostingView(rootView: rootView)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    // AppKit populates the split view's sidebar only once the window is on screen, so the window is
    // ordered in beneath the desktop picture: the window server draws it, nobody sees it.
    if !onScreen {
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
      window.collectionBehavior = [.ignoresCycle, .stationary]
    }
    window.setFrameOrigin(NSPoint(x: 0, y: 0))
    window.orderFrontRegardless()
    window.layoutIfNeeded()
  }

  var appearance: NSAppearance? {
    get { window.appearance }
    set { window.appearance = newValue }
  }

  /// `crop` keeps the top-left corner of that size (points), for content smaller than the window.
  func capture(to path: String, crop: CGSize? = nil) async throws {
    // Timed on purpose: SwiftUI and AppKit render on later run-loop passes and report no "drawn" event.
    for _ in 0..<12 {
      pump()
      try await Task.sleep(for: .milliseconds(50))
    }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let bounds = host.bounds
    guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else {
      throw WorkspaceError(.internalError, "no bitmap for \(path)")
    }
    host.cacheDisplay(in: bounds, to: rep)
    var output = rep
    if let crop, let image = rep.cgImage {
      let scale = CGFloat(rep.pixelsWide) / bounds.width
      let rect = CGRect(x: 0, y: 0, width: crop.width * scale, height: crop.height * scale)
      if let cut = image.cropping(to: rect) { output = NSBitmapImageRep(cgImage: cut) }
    }
    guard let png = output.representation(using: .png, properties: [:]) else {
      throw WorkspaceError(.internalError, "no png for \(path)")
    }
    try png.write(to: URL(fileURLWithPath: path))
  }

  /// Spins the main run loop so AppKit and SwiftUI lay out and draw (synchronous by design).
  private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

  func close() { window.close() }
}

// MARK: - The lists (M8b)

/// The thread lists over a scripted coordinator, so the data is the same on every run. The tests run
/// by default (they only prove the views render); `B4APP_SNAPSHOT_DIR` also writes `<name>-<light|dark>.png`.
@Suite(.serialized) @MainActor struct ListSnapshotTests {
  private var directory: String? { ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] }

  private func render<V: View>(
    _ name: String, size: CGSize, @ViewBuilder _ content: () -> V
  ) async throws {
    // The window is larger than the content: a ScrollView drew nothing in a window as narrow as the
    // sidebar. The capture is cropped back to the content's size, from the window's top edge, so the
    // content ignores the title bar's safe area (which pushed its bottom out of the crop).
    let window = SnapshotWindow(
      rootView: content().frame(width: size.width, height: size.height).background(LLA.Color.surface)
        .tint(LLA.Color.accent).frame(width: 1200, height: 900, alignment: .topLeading)
        .ignoresSafeArea(),
      size: CGSize(width: 1200, height: 900))
    defer { window.close() }
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      guard let directory else {
        // Without an output directory, one draw proves the view lays out and renders.
        window.host.layoutSubtreeIfNeeded()
        #expect(window.host.fittingSize.width > 0)
        break
      }
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      let path = "\(directory)/\(name)-\(suffix).png"
      try await window.capture(to: path, crop: size)
      #expect(FileManager.default.fileExists(atPath: path))
    }
  }

  /// B4 project cards from fixed server rows: one running with an agent to connect, one starting, one
  /// that failed (settings connections design, card option A).
  @Test func b4ProjectCards() async throws {
    let model = try await ListFixture.model()
    let home = NSHomeDirectory()
    let servers = [
      LocalServer(
        id: "s1", name: "support-bot", projectPath: home + "/repos/support-bot", nodePath: "/n",
        cliPath: "/c",
        launchMode: .development, requestedPort: 3000, actualPort: 3000, pid: 4242, health: .ready,
        routes: [
          LocalServerRoute(id: "/chat", kind: "agent", entryFile: "src/app/chat/agent.ts"),
          LocalServerRoute(id: "/triage", kind: "agent", entryFile: "src/app/triage/agent.ts"),
        ]),
      LocalServer(
        id: "s2", name: "research-agent", projectPath: home + "/repos/research-agent", nodePath: "/n",
        cliPath: "/c", launchMode: .source, requestedPort: 3100, pid: 4343, health: .starting),
      LocalServer(
        id: "s3", name: "playground", projectPath: home + "/scratch/playground", nodePath: "/n",
        cliPath: "/c",
        launchMode: .development, requestedPort: 3200, health: .unhealthy,
        statusMessage: "The server exited during startup (exit 1)."),
    ]
    try await render("b4ProjectCards", size: CGSize(width: 560, height: 520)) {
      VStack(spacing: LLA.Space.m) {
        ForEach(servers) { B4ProjectCard(model: model, server: $0) }
      }
      .padding(LLA.Space.xl)
      .frame(maxHeight: .infinity, alignment: .top)
      .background(LLA.Color.bg)
    }
  }

  /// The settings sheets: adding a B4 connection, editing one with a saved key, and attaching a project.
  @Test func settingsSheets() async throws {
    let model = try await ListFixture.model()
    let saved = Connection(
      id: "b", kind: .b4, label: "Support", target: "https://agents.example.com", routeKey: "/chat#agent",
      authReference: "secret:x", status: .ready, authStatus: .notRequired)
    try await render("addB4Sheet", size: CGSize(width: 480, height: 400)) {
      B4ConnectionSheet(model: model, connection: nil).frame(maxHeight: .infinity, alignment: .top)
    }
    try await render("editB4Sheet", size: CGSize(width: 480, height: 380)) {
      B4ConnectionSheet(model: model, connection: saved).frame(maxHeight: .infinity, alignment: .top)
    }
    try await render("attachProjectSheet", size: CGSize(width: 480, height: 460)) {
      AttachB4ProjectSheet(model: model).frame(maxHeight: .infinity, alignment: .top)
    }
  }

  /// The blank new-thread composer, and the picker row under a thread's composer: the place fixed,
  /// its permission and model live.
  @Test func newThreadComposer() async throws {
    let model = try await ListFixture.model()
    model.preferences = InMemoryPreferences()
    try await render("newThreadComposer", size: CGSize(width: 760, height: 420)) {
      NewThreadView(model: model)
    }
    var thread = try #require(model.threads.first { $0.id == "busy" })
    thread.model = "sonnet"
    thread.permission = "plan"
    try await render("threadPickerRow", size: CGSize(width: 560, height: 120)) {
      ComposerPickerRow(model: model, .thread(thread))
        .padding(LLA.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LLA.Color.bg)
    }
    // A long model id at a narrow width: the place and then the runtime truncate; nothing overflows.
    thread.model = "claude-opus-5-20261101-with-a-very-long-suffix"
    thread.permission = "bypassPermissions"
    try await render("threadPickerRowNarrow", size: CGSize(width: 380, height: 120)) {
      ComposerPickerRow(model: model, .thread(thread))
        .padding(LLA.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LLA.Color.bg)
    }
  }

  @Test func macSidebarGroupsByProject() async throws {
    let model = try await ListFixture.model()
    try await render("macSidebarGroupsByProject", size: CGSize(width: 290, height: 800)) {
      SidebarView(model: model)
    }
  }

  @Test func macSidebarCollapsedProject() async throws {
    let model = try await ListFixture.model()
    try await render("macSidebarCollapsedProject", size: CGSize(width: 290, height: 640)) {
      ScrollView {
        ProjectSectionsView(model: model, collapsed: .constant([ListFixture.b4app]))
          .padding(.horizontal, 10)
      }
    }
  }

  @Test func macSidebarShowsAFailedProjectAction() async throws {
    let model = try await ListFixture.model()
    model.lastError = "That folder already belongs to the project \u{201C}Marketing site\u{201D}."
    try await render("macSidebarShowsAFailedProjectAction", size: CGSize(width: 290, height: 420)) {
      ScrollView { ThreadListView(model: model).padding(.horizontal, 10) }
    }
  }

  @Test func iosListFlatWithFilter() async throws {
    let model = try await ListFixture.model()
    try await render("iosListFlatWithFilter", size: CGSize(width: 390, height: 760)) {
      VStack(spacing: 0) {
        HStack {
          MoreMenu(model: model)
          Spacer()
        }
        .padding(LLA.Space.l)
        Hairline()
        FlatThreadList(model: model)
      }
    }
  }

  @Test func iosListFilteredToProject() async throws {
    let model = try await ListFixture.model()
    model.projectFilter = .project(ListFixture.marketing)
    try await render("iosListFilteredToProject", size: CGSize(width: 390, height: 420)) {
      VStack(spacing: 0) {
        HStack {
          MoreMenu(model: model)
          Spacer()
        }
        .padding(LLA.Space.l)
        Hairline()
        FlatThreadList(model: model)
      }
    }
  }

  /// The iPhone list (new-thread composer spec, "The iPhone"; mockup screen 1): the header's avatar,
  /// filter, and search, the threads, and the "New thread" field at the bottom; then the same with a
  /// notice above the field. The header is the iOS navigation bar, which macOS cannot draw, so a row of
  /// the same pieces stands in for it.
  @Test func iosListHeaderAndDock() async throws {
    let model = try await ListFixture.model()
    model.account = WorkspaceAccount(username: "blove", displayName: "Brian Love")
    #expect(model.newThreadEntryReason == nil)
    let list = VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: LLA.Space.m) {
        ProfileAvatar(model: model, size: 32)
        Spacer()
        Image(systemName: "line.3.horizontal.decrease.circle")
        Image(systemName: "magnifyingglass")
      }
      .font(.system(size: 17))
      .foregroundStyle(LLA.Color.ink)
      .padding(.horizontal, LLA.Space.l)
      .frame(height: 44)
      Text("Threads").font(LLAFont.display).foregroundStyle(LLA.Color.ink)
        .padding(.horizontal, LLA.Space.l)
        .padding(.bottom, LLA.Space.s)
      FlatThreadList(model: model)
        .safeAreaInset(edge: .bottom, spacing: 0) { NewThreadDock(model: model) }
    }
    try await render("ios-list-dock", size: CGSize(width: 390, height: 844)) { list }
    model.hostNote = "The background agent is not running. Open Login Items to allow it."
    model.hostActionTitle = "Open Login Items"
    model.hostAction = {}
    try await render("ios-list-dock-notice", size: CGSize(width: 390, height: 844)) { list }
  }

  /// The dock while no project's Mac can take a thread: the field is off and the reason shows above
  /// it, since a compact width cannot reach the new-thread screen that would say why.
  @Test func iosDockBlocked() async throws {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    let reason = try #require(model.newThreadEntryReason)
    #expect(reason == "Add a ready Codex connection first")
    try await render("ios-dock-blocked", size: CGSize(width: 390, height: 140)) {
      NewThreadDock(model: model).frame(maxHeight: .infinity, alignment: .bottom)
    }
  }

  @Test func rowShowsEachBandDot() async throws {
    let model = try await ListFixture.model()
    let rows = [
      model.threads.first { $0.id == "asks" }, model.threads.first { $0.id == "unread" },
      model.threads.first { $0.id == "busy" }, model.threads.first { $0.id == "quiet" },
    ].compactMap { $0 }
    #expect(rows.map { model.band(of: $0) } == [.needsInput, .unread, .working, .quiet])
    try await render("rowShowsEachBandDot", size: CGSize(width: 290, height: 420)) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(rows) { ThreadRow(model: model, thread: $0) }
        Hairline().padding(.vertical, LLA.Space.m)
        HStack(spacing: LLA.Space.l) {
          ForEach([AttentionBand.needsInput, .unread, .working, .quiet], id: \.rawValue) {
            AttentionDot(band: $0)
          }
        }
      }
      .padding(10)
    }
  }
}

/// A fixed set of threads in every band, across two projects, "Other", and one empty manual project.
@MainActor enum ListFixture {
  static let b4app = "p-b4app"
  static let marketing = "p-marketing"
  static let docs = "p-docs"
  static let base = 1_793_000_000.0

  static func stamp(_ minute: Int) -> String {
    Timestamp.string(from: Date(timeIntervalSince1970: base + Double(minute) * 60))
  }

  static func thread(
    _ id: String, _ title: String, project: String?, pinned: Bool = false, connection: String = "c1",
    turn: String? = nil, status: TurnStatus? = nil, outcome: TurnOutcome? = nil, read: String? = nil,
    pending: Int = 0, at: Int
  ) -> ConversationThread {
    ConversationThread(
      id: id, connectionId: connection, nativeThreadId: "n-\(id)", title: title, pinned: pinned,
      createdAt: stamp(0), updatedAt: stamp(0), projectId: project, readTurnId: read,
      activity: ThreadActivity(
        latestTurnId: turn, latestTurnStatus: status, latestTurnOutcome: outcome, pendingRequests: pending,
        lastActivityAt: stamp(at)))
  }

  static let threads: [ConversationThread] = [
    thread(
      "pinned", "Release checklist", project: b4app, pinned: true, turn: "t1", status: .running, at: 58),
    thread(
      "asks", "Approve the migration run", project: b4app, turn: "t2", status: .waitingForUser, pending: 1,
      at: 55),
    thread(
      "unread", "Hub retention question", project: b4app, turn: "t3", status: .terminal, outcome: .completed,
      at: 57),
    thread(
      "failed", "Flaky test triage", project: b4app, turn: "t4", status: .terminal, outcome: .failed, at: 40),
    thread(
      "quiet", "Mirror outbox review", project: b4app, turn: "t5", status: .terminal, outcome: .completed,
      read: "t5", at: 30),
    thread(
      "busy", "Pricing page research", project: marketing, connection: "c2", turn: "t6", status: .running,
      at: 50),
    thread(
      "copy", "Landing copy pass", project: marketing, connection: "c2", turn: "t7", status: .terminal,
      outcome: .completed, read: "t7", at: 20),
    thread(
      "loose", "Scratch: regex help", project: nil, turn: "t8", status: .terminal, outcome: .completed,
      read: "t8", at: 10),
  ]

  static let projects: [Project] = [
    Project(
      id: b4app, name: "",
      folders: [ProjectFolder(id: "f1", projectId: b4app, path: "/Users/brian/repos/b4app")]),
    Project(id: marketing, name: "Marketing site", manual: true),
    Project(id: docs, name: "Docs", manual: true),
  ]

  static func model(_ transport: ScriptedTransport = ScriptedTransport()) async throws -> WorkspaceModel {
    transport.set(
      connections: [
        Connection(id: "c1", kind: .codex, label: "Codex", target: "codex", status: .ready),
        Connection(id: "c2", kind: .claude, label: "Claude Code", target: "claude", status: .ready),
      ], threads: threads, projects: projects)
    let model = WorkspaceModel(transportProvider: { transport })
    let now = Date(timeIntervalSince1970: base + 60 * 60)
    model.now = { now }
    model.connect()
    // Projects load with the snapshot, before the link turns ready.
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    try #require(model.projects.count == 3)
    return model
  }
}
