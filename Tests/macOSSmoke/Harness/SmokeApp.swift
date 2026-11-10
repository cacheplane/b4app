import AppKit
import NIOTransport
import SwiftUI
import WorkspaceProtocol
import WorkspaceUI

@main struct SmokeApp: App {
  @NSApplicationDelegateAdaptor private var delegate: SmokeDelegate
  @State private var model: WorkspaceModel
  private let size: CGSize
  private let dark: Bool

  init() {
    let env = ProcessInfo.processInfo.environment
    let socket = env["SMOKE_SOCKET"] ?? ""
    size = CGSize(
      width: Double(env["SMOKE_WIDTH"] ?? "") ?? 900,
      height: Double(env["SMOKE_HEIGHT"] ?? "") ?? 600)
    dark = env["SMOKE_DARK"] == "1"
    let model = WorkspaceModel(transportProvider: {
      guard socket.hasPrefix("/tmp/b4smk-"), socket.hasSuffix("/rt/coordinator.sock") else {
        throw WorkspaceError(.protocolInvalid, "Missing explicit smoke fixture socket.")
      }
      return try await UnixSocketTransport.connect(path: socket)
    })
    model.preferences = InMemoryPreferences()
    SmokeDelegate.model = model
    _model = State(initialValue: model)
  }

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
        .frame(minWidth: LLA.Metrics.minimumWindow.width, minHeight: LLA.Metrics.minimumWindow.height)
        .preferredColorScheme(dark ? .dark : .light)
        .background(
          WindowSetup(size: size, socket: ProcessInfo.processInfo.environment["SMOKE_SOCKET"] ?? "")
            .allowsHitTesting(false))
    }
    .defaultSize(width: size.width, height: size.height)
    .restorationBehavior(.disabled)
    .defaultLaunchBehavior(.presented)
    .commands {
      CommandMenu("Fixture") {
        Button("Render recovery reference") {
          RecoveryReference.show(socket: ProcessInfo.processInfo.environment["SMOKE_SOCKET"] ?? "")
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
      }
    }
  }
}

final class SmokeDelegate: NSObject, NSApplicationDelegate {
  static var model: WorkspaceModel?
  private var quitting = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !quitting else { return .terminateNow }
    quitting = true
    Task { @MainActor in
      await Self.model?.persistDraftNow()
      await Self.model?.disconnect()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

/// Set content size explicitly: macOS window restoration must not weaken the compact journey.
private struct WindowSetup: NSViewRepresentable {
  let size: CGSize
  let socket: String
  func makeNSView(context: Context) -> NSView { SetupView(size: size, socket: socket) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class SetupView: NSView {
    let size: CGSize
    let socket: String
    private var adjustingSize = false
    init(size: CGSize, socket: String) {
      self.size = size
      self.socket = socket
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      window?.setContentSize(size)
      window?.center()
      if let window {
        NotificationCenter.default.addObserver(
          self, selector: #selector(reportGeometry), name: NSWindow.didResizeNotification, object: window)
      }
      reportGeometry()
    }

    override func layout() {
      super.layout()
      reportGeometry()
    }

    @objc private func reportGeometry() {
      if let window, let screen = window.screen, socket.hasPrefix("/tmp/b4smk-"), !adjustingSize {
        let content = window.contentLayoutRect.size
        if abs(content.width - size.width) > 1 || abs(content.height - size.height) > 1 {
          // Full-size content windows count the toolbar in setContentSize; reserve it explicitly.
          adjustingSize = true
          var frame = window.frame
          frame.size.width += size.width - content.width
          frame.size.height += size.height - content.height
          window.setFrame(frame, display: true)
          adjustingSize = false
        }
        let actual = window.contentLayoutRect.size
        let geometry = [
          "contentWidth": actual.width, "contentHeight": actual.height,
          "frameWidth": window.frame.width, "frameHeight": window.frame.height,
          "screenWidth": screen.visibleFrame.width, "screenHeight": screen.visibleFrame.height,
          "windowFitsScreen": screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame) ? 1 : 0,
        ]
        let url = URL(fileURLWithPath: socket).deletingLastPathComponent()
          .deletingLastPathComponent().appendingPathComponent("window.json")
        try? JSONEncoder().encode(geometry).write(to: url, options: .atomic)
      }
    }
  }
}
