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
/// SnapshotTests`; the files are `<surface>-<light|dark>.png`. The window is never ordered on screen.
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
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      try await window.capture(to: "\(dir)/threads-\(suffix).png")
      model.surface = .connections
      model.selectedThreadId = nil
      try await window.capture(to: "\(dir)/connections-\(suffix).png")
      model.surface = .servers
      try await window.capture(to: "\(dir)/servers-\(suffix).png")
      model.surface = .diagnostics
      try await window.capture(to: "\(dir)/diagnostics-\(suffix).png")
      model.surface = .threads
      try await window.capture(to: "\(dir)/threads-empty-\(suffix).png")
      model.selectedThreadId = release.id
      await model.openThread(id: release.id)
    }
    window.close()
    #expect(FileManager.default.fileExists(atPath: "\(dir)/threads-dark.png"))
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
      Group {
        switch model.surface {
        case .threads: ThreadsView(model: model)
        case .connections: ConnectionsView(model: model)
        case .servers: LocalServersView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(LLA.Color.bg)
    }
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
    // sidebar. The capture is cropped back to the content's size.
    let window = SnapshotWindow(
      rootView: content().frame(width: size.width, height: size.height).background(LLA.Color.surface)
        .tint(LLA.Color.accent).frame(width: 1200, height: 900, alignment: .topLeading),
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
          ProjectFilterMenu(model: model)
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
          ProjectFilterMenu(model: model)
          Spacer()
        }
        .padding(LLA.Space.l)
        Hairline()
        FlatThreadList(model: model)
      }
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
        ForEach(rows) { ThreadRow(model: model, thread: $0, showsProject: true) }
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

  static func model() async throws -> WorkspaceModel {
    let transport = ScriptedTransport()
    transport.set(
      connections: [
        Connection(id: "c1", kind: .codex, label: "Codex", target: "codex", status: .ready),
        Connection(id: "c2", kind: .claude, label: "Claude Code", target: "claude", status: .ready),
      ], threads: threads, projects: projects)
    let model = WorkspaceModel(transportProvider: { transport })
    let now = Date(timeIntervalSince1970: base + 60 * 60)
    model.now = { now }
    model.connect()
    try await waitUntil("list fixture ready") { model.link == .ready && model.projects.count == 3 }
    return model
  }
}
