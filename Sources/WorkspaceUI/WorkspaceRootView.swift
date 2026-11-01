import SwiftUI
import WorkspaceProtocol

/// Sidebar plus detail on both platforms. The sidebar holds the actions and the thread list; the
/// detail shows the selected thread. Styling comes from `Theme/` (LLA visual system).
public struct WorkspaceRootView: View {
  @Bindable var model: WorkspaceModel
  /// On a compact width (iPhone) the split view shows one column; choosing a thread in the sidebar
  /// moves to the detail. Ignored where both columns show.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @Environment(\.scenePhase) private var scenePhase
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
  #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  /// Whether the selected thread is in front of the owner, for read marks: the scene is active and,
  /// on the Mac, its window is the active one; on a compact width (iPhone), the detail column is the
  /// one showing, since going back to the list keeps the thread loaded behind it.
  private var detailOnScreen: Bool {
    guard scenePhase == .active, model.selectedThreadId != nil else {
      return false
    }
    #if os(macOS)
      return appearsActive
    #else
      return horizontalSizeClass != .compact || compactColumn == .detail
    #endif
  }

  public init(model: WorkspaceModel) {
    LLAFonts.register()
    self.model = model
  }

  public var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        .environment(\.showDetail, { compactColumn = .detail })
    } detail: {
      ThreadsView(model: model)
        .modifier(WorkspaceWindowBackground())
    }
    .tint(LLA.Color.accent)
    .onChange(of: detailOnScreen, initial: true) { _, onScreen in model.isDetailOnScreen = onScreen }
    .task { model.connect() }
    .sheet(isPresented: $model.showNewThread) { NewThreadSheet(model: model) }
    #if os(macOS)
      .overlay { if model.showSearch { SearchPalette(model: model) } }
    #else
      .sheet(isPresented: $model.showSearch) { SearchPalette(model: model) }
    #endif
    .onChange(of: model.pendingLoginURL) { _, url in
      guard let url else { return }
      openURL(url)
      model.pendingLoginURL = nil
    }
  }

  @Environment(\.openURL) private var openURL

}

/// The window's own background in the theme colour on macOS; iOS has no window container.
struct WorkspaceWindowBackground: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.containerBackground(LLA.Color.bg, for: .window)
    #else
      content.background(LLA.Color.bg)
    #endif
  }
}

extension EnvironmentValues {
  /// Moves a collapsed split view to its detail column (set by `WorkspaceRootView`).
  @Entry var showDetail: @MainActor @Sendable () -> Void = {}
}

struct LinkStatusView: View {
  let model: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: LLA.Space.s) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(text).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(2)
        Spacer()
        if model.link == .unavailable {
          Button("Retry") { model.connect() }.buttonStyle(.llaLink).font(LLAFont.caption)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      if let note = model.hostNote {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          Text(note).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).fixedSize(
            horizontal: false, vertical: true)
          Spacer()
          if let title = model.hostActionTitle, let action = model.hostAction {
            Button(title) { Task { await action() } }.buttonStyle(.llaLink).font(LLAFont.caption)
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("host-note")
      }
      if let mismatch = model.versionMismatch {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          Text(mismatch).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).fixedSize(
            horizontal: false, vertical: true)
          Spacer()
          if let restart = model.restartCoordinator {
            Button("Restart coordinator") { Task { await restart() } }.buttonStyle(.llaLink).font(
              LLAFont.caption)
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("version-note")
      }
    }
    .background(LLA.Color.surface)
    .accessibilityIdentifier("link-status")
  }

  private var color: Color {
    switch model.link {
    case .ready: return LLA.Color.ink
    case .connecting: return LLA.Color.muted
    case .unavailable: return LLA.Color.danger
    }
  }

  private var text: String {
    switch model.link {
    case .ready: return "Coordinator connected"
    case .connecting: return "Connecting to coordinator…"
    case .unavailable: return "Coordinator unavailable: \(model.linkMessage ?? "")"
    }
  }
}
