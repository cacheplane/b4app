import SwiftUI
import WorkspaceProtocol

extension EnvironmentValues {
  /// Set inside the Mac's Settings window, whose page heading carries the page's action; the pages
  /// then add no toolbar button of their own.
  @Entry var inSettingsWindow = false
}

/// A Settings page's one action (re-check, refresh): a toolbar button, except in the Mac's Settings
/// window, where the heading shows it.
struct SettingsPageAction: ViewModifier {
  let title: String
  let disabled: Bool
  let action: () -> Void
  @Environment(\.inSettingsWindow) private var inSettingsWindow

  func body(content: Content) -> some View {
    if inSettingsWindow {
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
    case .connections: ConnectionsView(model: model)
    case .servers: LocalServersView(model: model)
    case .diagnostics: DiagnosticsView(model: model)
    }
  }
}

/// The Mac's Settings window, in the manner of Xcode's: a sidenav of pages on the left in the
/// sidebar's style, the page on the right. A plain stack rather than a nested split view, so the
/// window keeps one sidebar and a fixed minimum.
public struct WorkspaceSettingsView: View {
  @Bindable var model: WorkspaceModel

  public init(model: WorkspaceModel) {
    LLAFonts.register()
    self.model = model
  }

  public var body: some View {
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
    .tint(LLA.Color.accent)
    .frame(minWidth: 760, minHeight: 500)
    .onAppear { model.settingsVisible = true }
    .onDisappear { model.settingsVisible = false }
  }

  private var heading: some View {
    HStack(spacing: LLA.Space.m) {
      Text(model.settingsPage.title).llaDisplay().lineLimit(1)
      Spacer(minLength: LLA.Space.m)
      switch model.settingsPage {
      case .connections:
        Button("Re-check runtimes") { Task { await model.refreshDiagnostics() } }
          .buttonStyle(.llaSecondary)
          .disabled(model.link != .ready || model.diagnosticsLoading)
      case .diagnostics:
        Button("Refresh") { Task { await model.refreshDiagnostics() } }
          .buttonStyle(.llaSecondary)
          .disabled(model.link != .ready || model.diagnosticsLoading)
      case .servers:
        EmptyView()
      }
    }
    .padding(.horizontal, LLA.Space.xl)
    .padding(.top, LLA.Space.xl)
  }
}

#if os(iOS)
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
          }
        }
        .listStyle(.insetGrouped)
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
