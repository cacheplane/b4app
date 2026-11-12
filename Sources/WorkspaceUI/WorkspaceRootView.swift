import SwiftUI
import WorkspaceProtocol

/// The app's root on both platforms: the sign-in screen, onboarding, or the workspace, by the account
/// state (`WorkspaceModel.rootScreen`). Nothing of the workspace (Settings, New Thread, the palette) is
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
  @Environment(\.workspaceStatusBanner) private var statusBanner
  /// On a compact width (iPhone) the split view shows one column; choosing a thread in the sidebar
  /// moves to the detail. Ignored where both columns show.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  /// Whether the Mac's sidebar is showing: while it is hidden, search and new thread move from its top
  /// bar to the main view's toolbar.
  @State private var columnVisibility = NavigationSplitViewVisibility.automatic
  @Environment(\.scenePhase) private var scenePhase
  #if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
  #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  /// Whether the selected thread is in front of the owner, for read marks: the scene is active and,
  /// on the Mac, its window is the active one; on a compact width (iPhone), the detail column is the
  /// one showing, since going back to the list keeps the thread loaded behind it.
  /// Whether the detail column shows: on a compact width (iPhone) only while it is the column showing;
  /// always on the Mac and a regular width. The selected thread's hold lasts only while it does.
  private var detailColumnShown: Bool {
    #if os(macOS)
      return true
    #else
      return horizontalSizeClass != .compact || compactColumn == .detail
    #endif
  }

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
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      SidebarView(model: model)
        #if os(macOS)
          .environment(\.sidebarVisibility, columnVisibility)
          // Fixed, so the thread rows' geometry (fill, title, mark) is exact.
          .navigationSplitViewColumnWidth(LLA.Metrics.sidebarWidth)
        #else
          .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        #endif
    } detail: {
      ThreadsView(model: model)
        .modifier(WorkspaceWindowBackground())
        #if os(iOS)
          // Empty detail has no scrolling large-title host; use the thread's inline mode there too.
          .navigationBarTitleDisplayMode(.inline)
        #else
          // Beside the sidebar toggle, where the sidebar's own buttons were.
          .toolbar {
            TopBarItems(
              model: model, buttons: TopBarButton.mainView(columnVisibility), placement: .navigation)
          }
        #endif
        .safeAreaInset(edge: .top, spacing: 0) { statusBanner?() }
    }
    .environment(\.showDetail, showDetail)
    // The column first, so a thread opened from the list holds its state before it is marked read.
    .onChange(of: detailColumnShown, initial: true) { _, shown in model.isDetailColumnShown = shown }
    .onChange(of: detailOnScreen, initial: true) { _, onScreen in
      model.isDetailColumnShown = detailColumnShown
      model.isDetailOnScreen = onScreen
    }
    // `initial` so a request made before this view mounted (a cold launch from a notification tap)
    // still moves the iPhone to the thread column.
    .onChange(of: model.detailRequest, initial: true) { _, count in
      if count > 0 { compactColumn = .detail }
    }
    // The open thread was deleted (here or on another device), or the account ended: the iPhone goes
    // back to the list. A selection cleared for a new thread keeps the detail column, which shows it.
    .onChange(of: model.sidebarRequest) { compactColumn = .sidebar }
    .onChange(of: compactColumn) { _, column in
      if column == .sidebar { model.cancelThreadOpen() }
    }
    .onDisappear { model.isDetailOnScreen = false }
    // The phone's New environment and Edit environment; the Mac's sheets hang off its sidebar.
    .sheet(item: $model.environmentSheet) { PhoneEnvironmentSheet(model: model, request: $0) }
    #if os(macOS)
      // "Add your iPhone", once after a new account's onboarding (sign-in plan, Task 12).
      .sheet(isPresented: $model.showAddPhone) { AddPhoneView(model: model) }
      // The palette, in a panel of its own over the window: a small window does not cut it, and it
      // can be dragged (it opens where it was left, until the app quits).
      .background(
        FloatingPanel(
          isPresented: model.showSearch,
          size: CGSize(width: MacPalette.width, height: MacPalette.fullHeight),
          placement: .top(MacPalette.topOffset), rememberAs: "palette",
          dismiss: { model.dismissPalette() }
        ) {
          PaletteView(model: model, floating: true)
        }
      )
      .environment(\.floatsPalettes, true)
    #else
      .sheet(isPresented: $model.showSearch) {
        PaletteView(model: model).environment(\.showDetail, showDetail)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
  /// The app's sync or account notice, placed inside each navigation column so the phone's Back and
  /// toolbar buttons keep their own space. The shared UI receives only a view, never mirror state.
  @Entry public var workspaceStatusBanner: (@MainActor () -> AnyView)? = nil

  /// Moves a collapsed split view to its detail column (set by `WorkspaceRootView`).
  @Entry var showDetail: @MainActor @Sendable () -> Void = {}
}
