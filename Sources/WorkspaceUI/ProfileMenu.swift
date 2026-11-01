import SwiftUI
import WorkspaceProtocol

/// Links the app opens in the default browser.
enum WorkspaceLinks {
  static let github = URL(string: "https://github.com/cacheplane/b4app")!
}

extension WorkspaceModel {
  /// The line under the account name: the coordinator link in a few words. The error itself, when
  /// there is one, goes in the notice above the button.
  var linkStatusText: String {
    switch link {
    case .ready: return "Coordinator connected"
    case .connecting: return "Connecting to coordinator…"
    case .unavailable: return "Coordinator unavailable"
    }
  }
}

/// The bottom of the sidebar: any notice (the coordinator is unreachable, the host's note, a version
/// mismatch), then the profile button, whose menu opens upward over the list. It sits outside the
/// sidebar's scroll view, so every notice is clamped to three lines (D-047).
struct SidebarFooter: View {
  @Bindable var model: WorkspaceModel
  @State private var hovering = false
  @State private var confirmingLogOut = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: WorkspaceModel) { self.model = model }

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      notices
      profileButton
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
          if model.showProfileMenu {
            ProfileMenuPanel(model: model, dismiss: { setMenu(open: false) }) {
              setMenu(open: false)
              confirmingLogOut = true
            }
            .padding(.horizontal, 6)
            // The panel's bottom edge sits 6 pt above the button's top.
            .alignmentGuide(.top) { $0[.bottom] + 6 }
            .transition(
              reduceMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
          }
        }
    }
    .background(LLA.Color.surface)
    .alert("Log out of the hub?", isPresented: $confirmingLogOut) {
      Button("Log out", role: .destructive) { Task { await model.logOut() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.logOutMessage)
    }
  }

  static var logOutMessage: String {
    #if os(macOS)
      "This Mac stops syncing and the phone stops receiving its threads. Threads, connections, and servers stay on this Mac. To join again, run `agent-workspace hub join` with a new enrollment code."
    #else
      "This iPhone stops showing your threads until it joins again with a new enrollment code."
    #endif
  }

  private func setMenu(open: Bool) {
    if open { Task { await model.refreshAccount() } }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { model.showProfileMenu = open }
  }

  // MARK: Notices

  @ViewBuilder private var notices: some View {
    if model.link == .unavailable {
      notice(
        "Coordinator unavailable: \(model.linkMessage ?? "")", id: "link-note", actionTitle: "Retry"
      ) { model.connect() }
    }
    if let note = model.hostNote {
      notice(note, id: "host-note", actionTitle: model.hostActionTitle) {
        if let action = model.hostAction { Task { await action() } }
      }
    }
    if let mismatch = model.versionMismatch {
      notice(
        mismatch, id: "version-note",
        actionTitle: model.restartCoordinator == nil ? nil : "Restart coordinator"
      ) {
        if let restart = model.restartCoordinator { Task { await restart() } }
      }
    }
  }

  private func notice(
    _ text: String, id: String, actionTitle: String?, action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: LLA.Space.s) {
      Text(text).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(3)
      Spacer(minLength: 0)
      if let actionTitle {
        Button(actionTitle, action: action).buttonStyle(.llaLink).font(LLAFont.caption).fixedSize()
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }

  // MARK: The button

  private var profileButton: some View {
    Button {
      setMenu(open: !model.showProfileMenu)
    } label: {
      HStack(spacing: LLA.Space.s) {
        avatar
        VStack(alignment: .leading, spacing: 1) {
          Text(model.account?.name ?? "Not signed in")
            .font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink).lineLimit(1)
          Text(model.linkStatusText)
            .font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
        }
        Spacer(minLength: LLA.Space.xs)
        Image(systemName: "chevron.up.chevron.down")
          .font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
      }
      .padding(.horizontal, LLA.Space.s)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .fill(hovering || model.showProfileMenu ? LLA.Color.surfaceRaised : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityLabel(model.account?.name ?? "Not signed in")
    .accessibilityValue(model.linkStatusText)
    .accessibilityHint("Opens the profile menu")
    .accessibilityIdentifier("profile-button")
  }

  private var avatar: some View {
    ZStack(alignment: .bottomTrailing) {
      Circle().fill(LLA.Color.ink).frame(width: 26, height: 26)
        .overlay {
          if let account = model.account {
            Text(account.initials)
              .font(LLAFont.sans(10, weight: .semibold)).foregroundStyle(LLA.Color.bg)
              .lineLimit(1).minimumScaleFactor(0.6)
          } else {
            Image(systemName: "person.fill").font(LLAFont.caption).foregroundStyle(LLA.Color.bg)
          }
        }
      Circle().fill(statusColor).frame(width: 7, height: 7)
        .overlay(Circle().strokeBorder(LLA.Color.surface, lineWidth: 1.5))
        .offset(x: 1, y: 1)
    }
    .accessibilityHidden(true)
  }

  private var statusColor: Color {
    switch model.link {
    case .ready: return LLA.Color.ink
    case .connecting: return LLA.Color.muted
    case .unavailable: return LLA.Color.danger
    }
  }
}

/// The profile menu: Settings, GitHub, and Log out. The app's own panel rather than `Menu`, so it can
/// open upward from the button at the button's width on both platforms. Up, Down, and Return choose;
/// Escape closes.
struct ProfileMenuPanel: View {
  @Bindable var model: WorkspaceModel
  let dismiss: () -> Void
  let requestLogOut: () -> Void
  @State private var highlighted: Int?
  @FocusState private var focused: Bool
  @Environment(\.openURL) private var openURL

  init(model: WorkspaceModel, dismiss: @escaping () -> Void, requestLogOut: @escaping () -> Void = {}) {
    self.model = model
    self.dismiss = dismiss
    self.requestLogOut = requestLogOut
  }

  private struct Item {
    var title: String
    var systemImage: String
    var shortcut: String?
    var dividerBefore = false
    var choose: () -> Void
  }

  private var items: [Item] {
    var items = [
      Item(title: "Settings", systemImage: "gearshape", shortcut: shortcut("⌘,")) {
        dismiss()
        model.openSettings()
      },
      Item(title: "GitHub", systemImage: "arrow.up.right.square", shortcut: nil) {
        dismiss()
        openURL(WorkspaceLinks.github)
      },
    ]
    if model.canLogOut {
      items.append(
        Item(
          title: "Log out", systemImage: "rectangle.portrait.and.arrow.right", shortcut: nil,
          dividerBefore: true, choose: requestLogOut))
    }
    return items
  }

  private func shortcut(_ text: String) -> String? {
    #if os(macOS)
      return text
    #else
      return nil
    #endif
  }

  var body: some View {
    let items = self.items
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        if item.dividerBefore { Hairline().padding(.vertical, LLA.Space.xs) }
        Button(action: item.choose) {
          SidebarRowLabel(
            title: item.title, systemImage: item.systemImage, trailing: item.shortcut,
            selected: highlighted == index)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = index } }
      }
    }
    .padding(6)
    .background(LLA.Color.bg, in: RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: LLA.Radius.menu, style: .continuous).strokeBorder(LLA.Color.rule))
    .llaPopoverShadow()
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onAppear { focused = true }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .onKeyPress(.downArrow) {
      highlighted = ThreadSearch.step((highlighted ?? -1), by: 1, count: items.count)
      return .handled
    }
    .onKeyPress(.upArrow) {
      highlighted = ThreadSearch.step((highlighted ?? items.count), by: -1, count: items.count)
      return .handled
    }
    .onKeyPress(.return) {
      guard let highlighted, items.indices.contains(highlighted) else { return .ignored }
      items[highlighted].choose()
      return .handled
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("profile-menu")
  }
}
