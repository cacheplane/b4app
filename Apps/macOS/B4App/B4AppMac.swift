import AppKit
import Coordinator
import NIOTransport
import SwiftUI
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceUI

@main
struct B4AppMac: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
  @State private var model = WorkspaceModel(transportProvider: CoordinatorHost.transport)

  var body: some Scene {
    WindowGroup("Personal Agent Workspace") {
      WorkspaceRootView(model: model)
        .frame(minWidth: 900, minHeight: 600)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Window close preserves work: the coordinator keeps running (spec 10.3).
    false
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

/// Connects to an existing coordinator or hosts one in-process (decision D-004). Either way the
/// socket is the only channel, so the CLI and this app always share one coordinator.
actor CoordinatorHost {
  static let shared = CoordinatorHost()
  private var running: RunningCoordinator?

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
