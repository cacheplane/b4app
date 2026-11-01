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
    } detail: {
      ThreadsView(model: model)
        .modifier(WorkspaceWindowBackground())
    }
    // On the split view, not the sidebar: the search sheet hangs off the split view and must move
    // the iPhone to the thread it opens too.
    .environment(\.showDetail, { compactColumn = .detail })
    .tint(LLA.Color.accent)
    .onChange(of: detailOnScreen, initial: true) { _, onScreen in model.isDetailOnScreen = onScreen }
    .task { model.connect() }
    .sheet(isPresented: $model.showNewThread) { NewThreadSheet(model: model) }
    #if os(macOS)
      .overlay { if model.showSearch { SearchPalette(model: model) } }
    #else
      .sheet(isPresented: $model.showSearch) { SearchPalette(model: model) }
    #endif
    #if os(macOS)
      .onChange(of: model.settingsRequest) { openSettings() }
      // A join or leave from the CLI, or a name the hub answered late, shows when the window is back.
      .onChange(of: appearsActive) { _, active in if active { Task { await model.refreshAccount() } } }
    #else
      .onChange(of: model.settingsRequest) { model.showSettingsSheet = true }
      .sheet(isPresented: $model.showSettingsSheet) { SettingsSheet(model: model) }
    #endif
    .onChange(of: model.pendingLoginURL) { _, url in
      guard let url else { return }
      openURL(url)
      model.pendingLoginURL = nil
    }
  }

  @Environment(\.openURL) private var openURL
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

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
