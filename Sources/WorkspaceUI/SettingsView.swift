import SwiftUI
import WorkspaceProtocol

extension EnvironmentValues {
  /// Set inside the Mac's Settings window, whose page heading carries the page's action; the pages
  /// then add no toolbar button of their own.
  @Entry var inSettingsWindow = false
}

/// Which device the app runs on, for what Settings offers. The Mac runs the runtimes, servers, and
/// connections it lists; the phone shows the Mac's through the mirror, which refuses managing them
/// (`MirrorTransport`), and M8c keeps that on the Mac. So the phone's Settings pages are read-only:
/// no control that would only answer "done on the Mac" (D-060).
enum WorkspaceDevice {
  static var managesWorkspace: Bool {
    #if os(iOS)
      false
    #else
      true
    #endif
  }

  /// The sentence a read-only page shows in place of its controls.
  static let managedOnMac = "Connections, their sign-in, and B4 projects are managed on your Mac."
}

/// A Settings page's one action (re-check, refresh): a toolbar button, except in the Mac's Settings
/// window, where the heading shows it, and on a read-only page.
struct SettingsPageAction: ViewModifier {
  let title: String
  let disabled: Bool
  var shown = true
  let action: () -> Void
  @Environment(\.inSettingsWindow) private var inSettingsWindow

  func body(content: Content) -> some View {
    if inSettingsWindow || !shown {
      content
    } else {
      content.toolbar {
        ToolbarItem { Button(title, action: action).disabled(disabled) }
      }
    }
  }
}

extension SettingsPage {
  @MainActor @ViewBuilder func view(model: WorkspaceModel) -> some View {
    switch self {
    case .account: AccountSettingsView(model: model)
    case .connections: ConnectionsView(model: model)
    case .servers: B4ProjectsView(model: model)
    case .remoteAccess:
      #if os(macOS)
        RemoteAccessView(model: model)
      #else
        EmptyView()
      #endif
    case .diagnostics: DiagnosticsView(model: model)
    }
  }
}

/// The Mac's Settings window, in the manner of Xcode's: a sidenav of pages on the left in the
/// sidebar's style, the page on the right. A plain stack rather than a nested split view, so the
/// window keeps one sidebar and a fixed minimum.
public struct WorkspaceSettingsView: View {
  @Bindable var model: WorkspaceModel
  @State private var addingB4 = false
  @State private var attachingProject = false

  public init(model: WorkspaceModel) {
    LLAFonts.register()
    self.model = model
  }

  public var body: some View {
    Group {
      if model.settingsAvailable {
        // Keyed by the account, so a switch also drops every page's sheets and flows.
        pages.id(model.accountStatus?.account?.id)
      } else {
        // Signed out while the window was open: it closes (below); until then nothing of the account
        // shows.
        LLAEmptyState(SettingsCopy.signedOutTitle, text: SettingsCopy.signedOutText)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .background(LLA.Color.bg)
          .accessibilityIdentifier("settings-signed-out")
      }
    }
    .tint(LLA.Color.accent)
    .frame(minWidth: 760, minHeight: 500)
    .onAppear { model.settingsVisible = true }
    .onDisappear { model.settingsVisible = false }
    #if os(macOS)
      .background(WindowCloser(request: model.settingsCloseRequest))
    #endif
  }

  private var pages: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(SettingsPage.allCases) { page in
            SidebarActionRow(
              title: page.title, systemImage: page.systemImage, shortcut: nil,
              selected: model.settingsPage == page
            ) {
              model.settingsPage = page
            }
            .accessibilityAddTraits(model.settingsPage == page ? .isSelected : [])
          }
        }
        .padding(10)
      }
      .frame(width: 200)
      .background(LLA.Color.surface)
      .accessibilityIdentifier("settings-sidenav")
      Rectangle().fill(LLA.Color.rule).frame(width: 1)
      VStack(alignment: .leading, spacing: 0) {
        heading
        model.settingsPage.view(model: model)
          .environment(\.inSettingsWindow, true)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(LLA.Color.bg)
    }
  }

  private var heading: some View {
    HStack(spacing: LLA.Space.m) {
      Text(model.settingsPage.title).llaDisplay().lineLimit(1)
      Spacer(minLength: LLA.Space.m)
      switch model.settingsPage {
      case .connections:
        ConnectionAddMenu(model: model) { addingB4 = true }
      case .diagnostics:
        Button("Refresh") { Task { await model.refreshDiagnostics() } }
          .buttonStyle(.llaSecondary)
          .disabled(model.link != .ready || model.diagnosticsLoading)
      case .servers:
        Button("Attach B4 project…") { attachingProject = true }
          .buttonStyle(.llaSecondary)
          .disabled(model.link != .ready || model.busy)
      case .account, .remoteAccess:
        EmptyView()
      }
    }
    .padding(.horizontal, LLA.Space.xl)
    .padding(.top, LLA.Space.xl)
    .sheet(isPresented: $addingB4) { B4ConnectionSheet(model: model, connection: nil) }
    .sheet(isPresented: $attachingProject) { AttachB4ProjectSheet(model: model) }
  }
}

/// What Settings says while nobody is signed in.
enum SettingsCopy {
  static let signedOutTitle = "Nobody is signed in"
  static let signedOutText = "Sign in from the Agent Workspace window to see Settings."
}

#if os(macOS)
  /// Closes the window it sits in whenever `request` changes after it first appears (the Settings
  /// window, when the account signs out).
  struct WindowCloser: NSViewRepresentable {
    let request: Int

    final class Coordinator {
      var seen: Int
      init(_ seen: Int) { self.seen = seen }
    }

    func makeCoordinator() -> Coordinator { Coordinator(request) }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
      guard context.coordinator.seen != request else { return }
      context.coordinator.seen = request
      DispatchQueue.main.async { view.window?.close() }
    }
  }
#endif

#if os(iOS)
  /// A page row's label: the symbol and the title, or the title alone at accessibility sizes.
  struct SettingsRowLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
      if typeSize.isAccessibilitySize {
        configuration.title
      } else {
        Label(configuration)
      }
    }
  }

  /// The iPhone's Settings: a sheet with the pages in a list, each pushing its view.
  struct SettingsSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        List(SettingsPage.allCases) { page in
          NavigationLink(value: page) {
            Label(page.title, systemImage: page.systemImage)
              .font(LLAFont.body)
              .foregroundStyle(LLA.Color.ink)
              // At accessibility sizes the symbol column left "Connections" a letter-by-letter wrap.
              .labelStyle(SettingsRowLabelStyle())
          }
          .listRowBackground(LLA.Color.surface)
        }
        .listStyle(.insetGrouped)
        // Surface rows on the page background, as the theme's cards sit, in place of the system's
        // grouped greys (which differ from the palette in both appearances).
        .scrollContentBackground(.hidden)
        .background(LLA.Color.bg)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsPage.self) { page in
          page.view(model: model)
            .onAppear { model.settingsPage = page }
        }
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
      }
      .tint(LLA.Color.accent)
      .onAppear { model.settingsVisible = true }
      .onDisappear { model.settingsVisible = false }
    }
  }
#endif
