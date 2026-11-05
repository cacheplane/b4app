import SwiftUI
import WorkspaceProtocol

/// The app's root on both platforms: the sign-in screen, onboarding, or the workspace, by the account
/// state (`WorkspaceModel.rootScreen`). Nothing of the workspace (Settings, New Thread, ⌘K) is
/// reachable until someone is signed in. Styling comes from `Theme/` (LLA visual system).
public struct WorkspaceRootView: View {
  @Bindable var model: WorkspaceModel

  public init(model: WorkspaceModel) {
    LLAFonts.register()
    #if os(iOS)
      LLANavigationBar.apply()
    #endif
    self.model = model
  }

  public var body: some View {
    RootScreenView(model: model)
      .task { model.connect() }
  }
}

/// The screen for the account state. A container, not a `Group`, so what is attached to it runs once
/// rather than once per screen.
struct RootScreenView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    ZStack {
      switch model.rootScreen {
      case .loading:
        // Not known yet: a blank themed window, so a restart never flashes the sign-in screen.
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(LLA.Color.bg)
          .modifier(WorkspaceWindowBackground())
          .accessibilityHidden(true)
      case .signIn:
        SignInView(model: model)
      case .onboarding:
        OnboardingView(model: model)
      case .workspace:
        WorkspaceShell(model: model)
      }
    }
    .tint(LLA.Color.accent)
  }
}

/// Sidebar plus detail on both platforms. The sidebar holds the actions and the thread list; the
/// detail shows the selected thread.
struct WorkspaceShell: View {
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

  var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 290)
    } detail: {
      ThreadsView(model: model)
        .modifier(WorkspaceWindowBackground())
    }
    .environment(\.showDetail, showDetail)
    .onChange(of: detailOnScreen, initial: true) { _, onScreen in model.isDetailOnScreen = onScreen }
    // `initial` so a request made before this view mounted (a cold launch from a notification tap)
    // still moves the iPhone to the thread column.
    .onChange(of: model.detailRequest, initial: true) { _, count in
      if count > 0 { compactColumn = .detail }
    }
    // The open thread was deleted (here or on another device), or the account ended: the iPhone goes
    // back to the list. A selection cleared for a new thread keeps the detail column, which shows it.
    .onChange(of: model.sidebarRequest) { compactColumn = .sidebar }
    .onDisappear { model.isDetailOnScreen = false }
    // The phone's New project and Edit project; the Mac's sheets hang off its sidebar.
    .sheet(item: $model.projectSheet) { PhoneProjectSheet(model: model, request: $0) }
    #if os(macOS)
      // "Add your iPhone", once after a new account's onboarding (sign-in plan, Task 12).
      .sheet(isPresented: $model.showAddPhone) { AddPhoneView(model: model) }
      .overlay { if model.showSearch { SearchPalette(model: model) } }
    #else
      .sheet(isPresented: $model.showSearch) {
        SearchPalette(model: model).environment(\.showDetail, showDetail)
      }
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

  /// Moves the collapsed iPhone to the thread column. A sheet takes its environment from where
  /// `.sheet` is attached, outside the `.environment` above, so each sheet is given it explicitly.
  private var showDetail: @MainActor @Sendable () -> Void { { compactColumn = .detail } }

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
