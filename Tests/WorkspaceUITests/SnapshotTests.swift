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

  var body: some View {
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
@MainActor final class SnapshotWindow {
  let window: NSWindow
  let host: NSHostingView<SnapshotShell>

  init(rootView: SnapshotShell) {
    host = NSHostingView(rootView: rootView)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    // AppKit populates the split view's sidebar only once the window is on screen, so the window is
    // ordered in beneath the desktop picture: the window server draws it, nobody sees it.
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    window.collectionBehavior = [.ignoresCycle, .stationary]
    window.setFrameOrigin(NSPoint(x: 0, y: 0))
    window.orderFrontRegardless()
    window.layoutIfNeeded()
  }

  var appearance: NSAppearance? {
    get { window.appearance }
    set { window.appearance = newValue }
  }

  func capture(to path: String) async throws {
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
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw WorkspaceError(.internalError, "no png for \(path)")
    }
    try png.write(to: URL(fileURLWithPath: path))
  }

  /// Spins the main run loop so AppKit and SwiftUI lay out and draw (synchronous by design).
  private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

  func close() { window.close() }
}
