import AppKit
import Coordinator
import NIOTransport
import SwiftUI
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceUI

/// One model for the scene and the app delegate (Quit needs it to flush the draft and ask about work).
@MainActor let sharedModel = WorkspaceModel(transportProvider: CoordinatorHost.transport)

@main
struct B4AppMac: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

  var body: some Scene {
    WindowGroup("Personal Agent Workspace") {
      WorkspaceRootView(model: sharedModel)
        .frame(minWidth: 900, minHeight: 600)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var quitDecided = false
  private var wakeObserver: (any NSObjectProtocol)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Spec 10.3 sleep/wake: reconnect and reconcile; remote execution may have continued.
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in await sharedModel.reconcileAfter("wake") }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Window close preserves work: the coordinator keeps running (spec 10.3).
    false
  }

  /// Spec 10.3 full Quit (D-032): with local work in flight, offer "Quit" (local turns stop with the
  /// app, owned servers keep running, remote runs continue and reconcile next launch) or "Stop local
  /// work and quit". The coordinator lives in this process until the M6 LaunchAgent, so "keep
  /// running in the background" is not offered. When another process hosts the coordinator the app
  /// owns nothing and quits at once.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitDecided { return .terminateNow }
    Task { @MainActor in
      await sharedModel.persistDraftNow()
      let hosting = await CoordinatorHost.shared.isHosting
      guard hosting, let work = await sharedModel.activeWork(),
        !work.localTurns.isEmpty || !work.servers.isEmpty
      else {
        quitDecided = true
        NSApp.reply(toApplicationShouldTerminate: true)
        return
      }
      switch QuitDialog.ask(work) {
      case .quit:
        quitDecided = true
        NSApp.reply(toApplicationShouldTerminate: true)
      case .stopAndQuit:
        _ = await sharedModel.stopLocalWork()
        quitDecided = true
        NSApp.reply(toApplicationShouldTerminate: true)
      case .cancel:
        NSApp.reply(toApplicationShouldTerminate: false)
      }
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
      await CoordinatorHost.shared.shutdown()
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 3)
  }
}

enum QuitDialog {
  enum Choice { case quit, stopAndQuit, cancel }

  @MainActor static func ask(_ work: WorkspaceActiveWork.Result) -> Choice {
    let alert = NSAlert()
    alert.messageText = "Work is still running"
    alert.informativeText = describe(work)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Stop local work and quit")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .quit
    case .alertSecondButtonReturn: return .stopAndQuit
    default: return .cancel
    }
  }

  static func describe(_ work: WorkspaceActiveWork.Result) -> String {
    var lines: [String] = []
    let local = work.localTurns
    if !local.isEmpty {
      lines.append(
        "Local turns (\(local.count)): "
          + local.map { "\($0.threadTitle) on \($0.connectionLabel), \($0.status.rawValue)" }
          .joined(separator: "; ")
          + ". Quit stops them with the app and their outcome shows as unknown next time; \"Stop local work and quit\" cancels them first and waits for the runtime to confirm."
      )
    }
    if !work.servers.isEmpty {
      lines.append(
        "Owned B4 servers (\(work.servers.map(\.name).joined(separator: ", "))) keep running after Quit; \"Stop local work and quit\" stops them."
      )
    }
    let remote = work.remoteTurns
    if !remote.isEmpty {
      lines.append(
        "Remote or attached B4 runs (\(remote.count)) continue on their server either way; the app detaches and reconciles them next launch. Nothing is cancelled there."
      )
    }
    return lines.joined(separator: "\n\n")
  }
}

/// Connects to an existing coordinator or hosts one in-process (decision D-004). Either way the
/// socket is the only channel, so the CLI and this app always share one coordinator.
actor CoordinatorHost {
  static let shared = CoordinatorHost()
  private var running: RunningCoordinator?

  /// True while this process hosts the coordinator (and so owns local runtime processes).
  var isHosting: Bool { running != nil }

  @Sendable static func transport() async throws -> any WorkspaceTransport {
    try await shared.makeTransport()
  }

  private func makeTransport() async throws -> any WorkspaceTransport {
    let paths = PlatformPaths.resolve()
    if let transport = try? await UnixSocketTransport.connect(path: paths.socketPath, timeout: .seconds(2)) {
      return transport
    }
    if running == nil {
      switch try await Coordinator.start(options: CoordinatorOptions(paths: paths)) {
      case .running(let coordinator): running = coordinator
      case .alreadyRunning: break
      }
    }
    return try await UnixSocketTransport.connect(path: paths.socketPath, timeout: .seconds(5))
  }

  func shutdown() async {
    await running?.close()
    running = nil
  }
}
