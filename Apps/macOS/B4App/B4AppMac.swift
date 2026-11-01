import AppKit
import Coordinator
import NIOTransport
import ServiceManagement
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
        .frame(minWidth: LLA.Metrics.minimumWindow.width, minHeight: LLA.Metrics.minimumWindow.height)
        .task { CoordinatorHost.wire(sharedModel) }
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Coordinator") {
        Button("Restart Coordinator") { Task { await CoordinatorHost.restartAndReconnect(sharedModel) } }
        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        Divider()
        Button("Remove Background Agent…") { Task { await CoordinatorHost.removeAgent(sharedModel) } }
          .disabled(!LaunchAgent.isBundled)
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var quitDecided = false
  private var wakeObserver: (any NSObjectProtocol)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // `Agent Workspace --remove-agent` unregisters the Login Item without a window, for uninstall
    // scripts and for checks that must leave the Mac as they found it.
    if CommandLine.arguments.contains("--register-agent") {
      Task { @MainActor in
        let state = await LaunchAgent.enable()
        print("agent: \(state)")
        exit(0)
      }
      return
    }
    if CommandLine.arguments.contains("--remove-agent") {
      Task { @MainActor in
        do {
          try await LaunchAgent.remove()
          print("removed \(LaunchAgentControl.label)")
        } catch {
          FileHandle.standardError.write(
            Data("could not remove the agent: \(error.localizedDescription)\n".utf8))
        }
        exit(0)
      }
      return
    }
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

/// How the packaged app's LaunchAgent stands (M6, D-038). Dev builds from Xcode carry no agent.
enum LaunchAgent {
  nonisolated enum State: Sendable, Equatable { case notBundled, enabled, requiresApproval, failed(String) }

  static var plistURL: URL {
    Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Library/LaunchAgents/\(LaunchAgentControl.plistName)")
  }
  static var helperURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/b4app-coordinator")
  }
  static var isBundled: Bool {
    FileManager.default.fileExists(atPath: plistURL.path)
      && FileManager.default.isExecutableFile(atPath: helperURL.path)
  }

  /// Install (or refresh) the per-user LaunchAgent that runs the bundled coordinator (D-042): the
  /// plist is rewritten whenever it points elsewhere or launchd reports a spawn failure, and a
  /// leftover managed registration from the earlier design is unregistered once.
  static func enable() async -> State {
    guard isBundled else { return .notBundled }
    let managed = SMAppService.agent(plistName: LaunchAgentControl.plistName)
    if managed.status == .enabled || managed.status == .requiresApproval {
      try? await managed.unregister()
    }
    let program = helperURL.path
    let job = await LaunchAgentControl.jobState()
    let current = LaunchAgentControl.installedProgramPath()
    let stale = current != program || job == nil || (job?.state.contains("spawn") ?? false)
    do {
      if stale { try await LaunchAgentControl.install(programPath: program) }
      return .enabled
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  static func remove() async throws {
    let managed = SMAppService.agent(plistName: LaunchAgentControl.plistName)
    if managed.status != .notRegistered, managed.status != .notFound { try? await managed.unregister() }
    await LaunchAgentControl.remove()
  }
}

/// Connects to an existing coordinator, starts the bundled LaunchAgent, or hosts one in-process
/// (decisions D-004 and D-038). Either way the socket is the only channel, so the CLI and this app
/// always share one coordinator.
actor CoordinatorHost {
  static let shared = CoordinatorHost()
  private var running: RunningCoordinator?
  private(set) var agentState: LaunchAgent.State = .notBundled

  /// True while this process hosts the coordinator (and so owns local runtime processes).
  var isHosting: Bool { running != nil }

  @Sendable static func transport() async throws -> any WorkspaceTransport {
    try await shared.makeTransport()
  }

  private func connect(_ paths: PlatformPaths, within timeout: Duration) async -> (any WorkspaceTransport)? {
    let deadline = ContinuousClock.now + timeout
    repeat {
      if let transport = try? await UnixSocketTransport.connect(path: paths.socketPath, timeout: .seconds(2))
      {
        return transport
      }
      try? await Task.sleep(for: .milliseconds(150))
    } while ContinuousClock.now < deadline
    return nil
  }

  private func makeTransport() async throws -> any WorkspaceTransport {
    let paths = PlatformPaths.resolve()
    if let transport = try? await UnixSocketTransport.connect(path: paths.socketPath, timeout: .seconds(2)) {
      return transport
    }
    if running == nil {
      let state = await LaunchAgent.enable()
      agentState = state
      if state == .enabled, let transport = await connect(paths, within: .seconds(10)) {
        return transport
      }
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

  /// Replace the running coordinator: through launchd when the agent hosts it, by closing our own
  /// when we host it, otherwise by asking the other process to exit. The next connect starts anew.
  func restart() async throws {
    if running != nil {
      await shutdown()
    } else if await LaunchAgentControl.isLoaded() {
      try await LaunchAgentControl.kickstart()
    } else {
      _ = try await CoordinatorLauncher.stop()
    }
  }

  /// Hand the model the strings and actions the UI shows for hosting (the UI never touches launchd).
  @MainActor static func wire(_ model: WorkspaceModel) {
    model.expectedCoordinatorVersion = CoordinatorVersion.current
    model.restartCoordinator = { await restartAndReconnect(model) }
    Task {
      let state = await shared.agentState
      switch state {
      case .requiresApproval:
        model.hostNote =
          "Allow Agent Workspace under Login Items so conversations keep running when the window closes. Until then this window hosts the coordinator."
        model.hostActionTitle = "Open Login Items"
        model.hostAction = { SMAppService.openSystemSettingsLoginItems() }
      case .failed(let reason):
        model.hostNote =
          "The background coordinator could not be registered (\(reason)); this window hosts it."
        model.hostActionTitle = nil
        model.hostAction = nil
      case .enabled, .notBundled:
        model.hostNote = nil
        model.hostActionTitle = nil
        model.hostAction = nil
      }
    }
  }

  @MainActor static func restartAndReconnect(_ model: WorkspaceModel) async {
    await model.persistDraftNow()
    await model.disconnect()
    do {
      try await shared.restart()
    } catch {
      model.hostNote = "Restart failed: \(error.localizedDescription)"
    }
    model.connect()
    wire(model)
  }

  @MainActor static func removeAgent(_ model: WorkspaceModel) async {
    let alert = NSAlert()
    alert.messageText = "Remove the background coordinator?"
    alert.informativeText =
      "The Login Items entry is removed and the coordinator stops hosting conversations in the background. This window will host it while the app is open. Nothing stored is deleted."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try await LaunchAgent.remove()
      _ = try? await CoordinatorLauncher.stop()
      await model.disconnect()
      model.connect()
      model.hostNote = "Background agent removed; this window hosts the coordinator."
      model.hostActionTitle = nil
      model.hostAction = nil
    } catch {
      model.hostNote = "Could not remove the agent: \(error.localizedDescription)"
    }
  }
}
