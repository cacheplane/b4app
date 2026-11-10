import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The row under a composer (the new-thread composer spec, "The Mac" and "Inside a thread"): where
/// the thread starts on the leading side; its permission, then its runtime · model, on the trailing
/// side. Each is a system menu drawn as small muted text with a chevron, the runtime led by its
/// ghosted mark; no chips, icons, or colour (LLA).
///
/// For a new thread every menu is live and acts on the draft. For a thread the place is shown but
/// fixed (muted, no chevron), and the permission and model change what its next turn uses
/// (`setThreadRuntime`), the model limited to the thread's own connection; a B4 thread, whose route
/// decides both, shows neither. The items each menu lists are `PickerMenus`.
struct ComposerPickerRow: View {
  enum Source {
    case draft(NewThreadDraft)
    case thread(ConversationThread)
  }

  @Bindable var model: WorkspaceModel
  let source: Source
  @Environment(\.dynamicTypeSize) private var typeSize
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  #if os(macOS)
    @State private var choosingFolder = false
  #endif

  init(model: WorkspaceModel, _ source: Source) {
    self.model = model
    self.source = source
  }

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        // One picker a line, so none is cut to a sliver or pushed past the edge.
        VStack(alignment: .leading, spacing: 0) {
          place
          permissionMenu
          runtimeMenu
        }
      } else {
        HStack(alignment: .center, spacing: 2) {
          // The place gives way first, but keeps enough to show its name's ends.
          place.keepsWidth(Self.placeFloor)
          Spacer(minLength: LLA.Space.s)
          // Room goes to the permission first, then the runtime, so at the narrowest window the place
          // truncates first and the runtime's label (a long connection label and model id) next.
          permissionMenu.layoutPriority(2)
          runtimeMenu.layoutPriority(1)
        }
      }
    }
    .font(LLAFont.small)
    .foregroundStyle(LLA.Color.muted)
    #if os(iOS)
      // Row and label padding together match the field's inner text inset.
      .padding(.horizontal, ComposerField<EmptyView>.textLeading - PickerLabel.horizontalInset)
    #else
      .padding(.horizontal, LLA.Space.xs)
    #endif
    #if os(macOS)
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        guard case .success(let url) = result, case .draft(let draft) = source else { return }
        draft.chooseFolder(NewThreadDraft.folderPath(of: url))
      }
    #endif
  }

  /// The least the place keeps when the row is short of room (a shorter name keeps its own width).
  static let placeFloor: CGFloat = 88

  // MARK: What the source has chosen

  /// The connection the permission and runtime menus speak for.
  private var connection: Connection? {
    switch source {
    case .draft(let draft): draft.connection
    case .thread(let thread): model.connection(id: thread.connectionId)
    }
  }

  private var chosenModel: String? {
    switch source {
    case .draft(let draft): draft.model
    case .thread(let thread): thread.model
    }
  }

  private var chosenPermission: String? {
    switch source {
    case .draft(let draft): draft.permission
    case .thread(let thread): thread.permission
    }
  }

  private var isThread: Bool {
    if case .thread = source { return true }
    return false
  }

  /// The phone's compact width shortens the runtime to its mark and the model's name.
  private var compact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  // MARK: Project · folder

  @ViewBuilder private var place: some View {
    switch source {
    case .draft(let draft):
      if draft.isRemoteB4 {
        // A remote B4 has no project; the runtime menu is the way back to one.
        PickerLabel(text: "No project", chevron: false)
          .accessibilityLabel("Project")
          .accessibilityValue("No project")
          .accessibilityIdentifier("picker-project")
      } else {
        let text = placeText(draft)
        Menu {
          projectItems(draft)
        } label: {
          PickerLabel(text: text)
        }
        .pickerMenu()
        .accessibilityLabel("Project")
        .accessibilityValue(text)
        .accessibilityIdentifier("picker-project")
      }
    case .thread(let thread):
      PickerLabel(text: placeText(thread), chevron: false)
        .accessibilityLabel("Project")
        .accessibilityValue(placeText(thread))
        .accessibilityIdentifier("picker-project")
    }
  }

  /// The project's name, with the starting folder's name when it has several; a chosen folder (the
  /// Mac's "Choose folder…") by its own name until Send finds its project.
  private func placeText(_ draft: NewThreadDraft) -> String {
    if let chosen = draft.chosenFolder { return Self.folderName(chosen) }
    guard let project = draft.project else { return "No project" }
    guard draft.connection?.kind != .b4, project.folders.count > 1, let folder = draft.folder else {
      return project.displayName
    }
    return "\(project.displayName) · \(Self.folderName(folder))"
  }

  private func placeText(_ thread: ConversationThread) -> String {
    let project = thread.projectId.flatMap { id in model.projects.first { $0.id == id } }
    let b4 = connection?.kind == .b4
    guard let project else {
      guard !b4, let context = thread.context, !context.isEmpty else { return "No project" }
      return Self.folderName(context)
    }
    guard !b4, project.folders.count > 1, let context = thread.context else { return project.displayName }
    return "\(project.displayName) · \(Self.folderName(context))"
  }

  /// Each project a thread can start in: a project with one folder is one item; one with several is a
  /// group of its folders. Choosing a folder chooses its project. Then "Choose folder…" on the Mac.
  @ViewBuilder private func projectItems(_ draft: NewThreadDraft) -> some View {
    ForEach(draft.projects) { project in
      if project.folders.count > 1 {
        Section(project.displayName) {
          ForEach(project.folders) { folder in
            choice(
              Self.folderName(folder.path),
              selected: draft.chosenFolder == nil && draft.projectId == project.id
                && draft.folder == folder.path
            ) { draft.selectFolder(folder.path, in: project.id) }
          }
        }
      } else {
        choice(project.displayName, selected: draft.chosenFolder == nil && draft.projectId == project.id) {
          if let folder = project.folders.first {
            draft.selectFolder(folder.path, in: project.id)
          } else {
            draft.selectProject(project.id)
          }
        }
      }
    }
    #if os(macOS)
      if !model.relaysThroughHub {
        Divider()
        Button("Choose folder…") { choosingFolder = true }
          .accessibilityIdentifier("choose-folder")
      }
    #endif
  }

  // MARK: Permissions

  @ViewBuilder private var permissionMenu: some View {
    if let kind = connection?.kind, kind != .b4 {
      let text = RuntimeOptions.permissionLabel(chosenPermission, kind: kind)
      Menu {
        ForEach(PickerMenus.permissions(kind: kind, chosen: chosenPermission, forThread: isThread)) {
          item in
          choice(item.title, selected: item.selected) { choosePermission(item.value) }
        }
      } label: {
        PickerLabel(text: text)
      }
      .pickerMenu()
      .accessibilityLabel("Permissions")
      .accessibilityValue(text)
      .accessibilityIdentifier("picker-permission")
    }
  }

  private func choosePermission(_ id: String?) {
    switch source {
    case .draft(let draft): draft.selectPermission(id)
    case .thread(let thread):
      guard let id, thread.permission != id else { return }
      Task { await model.setThreadRuntime(threadId: thread.id, model: nil, permission: id) }
    }
  }

  // MARK: Runtime · model

  @ViewBuilder private var runtimeMenu: some View {
    switch source {
    case .draft(let draft):
      if !draft.connections.isEmpty {
        let label = runtimeLabel
        Menu {
          draftRuntimeItems(draft)
        } label: {
          PickerLabel(mark: connection?.kind, text: compact ? label.short : label.full)
        }
        .pickerMenu()
        .accessibilityLabel("Runtime and model")
        .accessibilityValue(label.full)
        .accessibilityIdentifier("picker-runtime")
      }
    case .thread(let thread):
      if let connection, connection.kind != .b4 {
        let label = runtimeLabel
        Menu {
          Section {
            modelItems(connection, chosen: thread.model, isChosenConnection: true) { chosen in
              guard let chosen, chosen != thread.model else { return }
              Task { await model.setThreadRuntime(threadId: thread.id, model: chosen, permission: nil) }
            }
          } header: {
            MenuHeader(title: connection.label, kind: connection.kind)
          }
        } label: {
          PickerLabel(mark: connection.kind, text: compact ? label.short : label.full)
        }
        .pickerMenu()
        .accessibilityLabel("Model")
        .accessibilityValue(label.full)
        .accessibilityIdentifier("picker-runtime")
      }
    }
  }

  /// "Claude Code · Sonnet" in full; "Sonnet" short, beside the mark. A B4 agent by its route's name.
  private var runtimeLabel: (full: String, short: String) {
    guard let connection else { return ("Runtime", "Runtime") }
    if connection.kind == .b4 {
      let name = model.startLabel(for: connection)
      return (name, name)
    }
    let name = Self.modelName(chosenModel, in: connection)
    return ("\(connection.label) · \(name)", name)
  }

  /// One group per Codex or Claude connection (Claude Code first, then Codex), then this project's
  /// local B4 agents, then on the Mac the remote ones. Built from what the draft offers, so no item is
  /// one `selectRuntime` would ignore.
  @ViewBuilder private func draftRuntimeItems(_ draft: NewThreadDraft) -> some View {
    let sections = PickerMenus.runtimeSections(draft.connections)
    ForEach(sections.harness) { connection in
      let selected = draft.connectionId == connection.id
      Section {
        modelItems(connection, chosen: selected ? draft.model : nil, isChosenConnection: selected) {
          chosen in
          draft.selectRuntime(connectionId: connection.id, model: chosen)
        }
      } header: {
        MenuHeader(title: connection.label, kind: connection.kind)
      }
    }
    if !sections.local.isEmpty {
      Section {
        agentItems(sections.local, draft)
      } header: {
        MenuHeader(
          title: draft.project.map { "B4 agents in \($0.displayName)" } ?? "B4 agents", kind: .b4)
      }
    }
    if !sections.remote.isEmpty {
      Section {
        agentItems(sections.remote, draft)
      } header: {
        MenuHeader(title: "Remote B4", kind: .b4)
      }
    }
  }

  private func agentItems(_ agents: [Connection], _ draft: NewThreadDraft) -> some View {
    ForEach(agents) { agent in
      choice(model.startLabel(for: agent), selected: draft.connectionId == agent.id) {
        draft.selectRuntime(connectionId: agent.id, model: nil)
      }
    }
  }

  private func modelItems(
    _ connection: Connection, chosen: String?, isChosenConnection: Bool,
    choose: @escaping (String?) -> Void
  ) -> some View {
    let items = PickerMenus.models(
      connection, chosen: chosen, isChosenConnection: isChosenConnection, forThread: isThread)
    return ForEach(items) { item in
      choice(item.title, selected: item.selected) { choose(item.value) }
    }
  }

  // MARK: Pieces

  /// A menu item with a checkmark while it is the current choice. Choosing the current one again
  /// changes nothing.
  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { selected }, set: { _ in action() }))
  }

  static func folderName(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
  }

  static func modelName(_ id: String?, in connection: Connection) -> String {
    guard let id else { return RuntimeOptions.defaultModelLabel }
    return connection.models?.first { $0.id == id }?.label ?? id
  }
}

/// A picker's face: the runtime's mark when there is one, the choice in one line, and a small chevron
/// when it opens a menu.
private struct PickerLabel: View {
  static let horizontalInset = LLA.Space.s
  var mark: ConnectionKind? = nil
  let text: String
  var chevron = true

  var body: some View {
    HStack(spacing: 6) {
      if let mark { RuntimeMark(kind: mark, height: 12) }
      Text(text).lineLimit(1).truncationMode(.middle)
      if chevron {
        Image(systemName: "chevron.down")
          .font(LLAFont.caption)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, Self.horizontalInset)
    .padding(.vertical, LLA.Space.xs)
    // The phone's target reaches 44 pt without making the row that tall.
    #if os(iOS)
      .contentShape(Rectangle().inset(by: -LLA.Space.s))
    #else
      .contentShape(Rectangle())
    #endif
  }
}

/// A menu group's header: the connection's label after its runtime's mark. A system menu draws only
/// images, so the mark is rendered once per runtime into a template image the menu tints.
private struct MenuHeader: View {
  let title: String
  let kind: ConnectionKind
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    Label {
      Text(title)
    } icon: {
      MenuMark.image(kind, scale: displayScale)
    }
  }
}

@MainActor private enum MenuMark {
  private struct Key: Hashable {
    var kind: ConnectionKind
    var scale: CGFloat
  }

  private static var cache: [Key: Image] = [:]

  static func image(_ kind: ConnectionKind, scale: CGFloat) -> Image {
    let key = Key(kind: kind, scale: scale)
    if let image = cache[key] { return image }
    let renderer = ImageRenderer(content: RuntimeMark(kind: kind, height: 14))
    renderer.scale = scale
    #if os(macOS)
      let rendered = renderer.nsImage ?? NSImage()
      rendered.isTemplate = true
      let image = Image(nsImage: rendered)
    #else
      let image = Image(uiImage: renderer.uiImage ?? UIImage()).renderingMode(.template)
    #endif
    cache[key] = image
    return image
  }
}

extension View {
  /// A system menu whose face is the label as drawn, with no button chrome or indicator.
  fileprivate func pickerMenu() -> some View {
    menuIndicator(.hidden).buttonStyle(.plain)
  }

  /// However narrow its container, this view keeps its ideal width up to `floor`: a stack short of
  /// room can cut it that far and no further, and a view narrower than `floor` is never widened.
  func keepsWidth(_ floor: CGFloat) -> some View {
    KeepsWidth(floor: floor) { self }
  }
}

/// `keepsWidth(_:)`'s layout: one subview, offered at least `min(ideal, floor)` of width.
private struct KeepsWidth: Layout {
  var floor: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    let least = min(view.sizeThatFits(.unspecified).width, floor)
    var offered = proposal
    if let width = offered.width { offered.width = max(width, least) }
    let size = view.sizeThatFits(offered)
    return CGSize(width: max(size.width, least), height: size.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(
      at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

// MARK: - What the menus list

/// One menu item: its title, what choosing it selects, and whether it is the current choice.
struct PickerChoice: Equatable, Identifiable {
  var title: String
  var value: String?
  var selected: Bool
  var id: String { value ?? "" }
}

/// The picker row's menus as lists, apart from the views that draw them.
enum PickerMenus {
  /// A runtime's permissions. "As configured" (nil) comes first for a new thread always, and for a
  /// thread only while it has no override: Codex keeps a `turn/start` override "for this turn and
  /// subsequent turns" and has no way to clear it, and Claude follows the same rule. A thread's own
  /// choice is listed even when the runtime no longer offers it. None for B4, whose route decides.
  static func permissions(kind: ConnectionKind, chosen: String?, forThread: Bool) -> [PickerChoice] {
    guard kind != .b4 else { return [] }
    var items: [PickerChoice] = []
    if !forThread || chosen == nil {
      items.append(PickerChoice(title: RuntimeOptions.asConfiguredLabel, value: nil, selected: chosen == nil))
    }
    let options = RuntimeOptions.permissions(for: kind)
    items += options.map { PickerChoice(title: $0.label, value: $0.id, selected: chosen == $0.id) }
    if let chosen, !options.contains(where: { $0.id == chosen }) {
      items.append(PickerChoice(title: chosen, value: chosen, selected: true))
    }
    return items
  }

  /// A connection's models. "Default" (nil) comes first for a new thread always, for every connection,
  /// and for a thread only while it has no override (the rule above). The chosen model is listed even
  /// when the connection's catalog lacks it, by its id. Only `isChosenConnection` has a checked item.
  /// None for B4, which has no model.
  static func models(
    _ connection: Connection, chosen: String?, isChosenConnection: Bool, forThread: Bool
  ) -> [PickerChoice] {
    guard connection.kind != .b4 else { return [] }
    let chosen = isChosenConnection ? chosen : nil
    var items: [PickerChoice] = []
    if !forThread || chosen == nil {
      items.append(
        PickerChoice(
          title: RuntimeOptions.defaultModelLabel, value: nil, selected: isChosenConnection && chosen == nil))
    }
    let catalog = connection.models ?? []
    items += catalog.map {
      PickerChoice(title: $0.label, value: $0.id, selected: isChosenConnection && chosen == $0.id)
    }
    if let chosen, !catalog.contains(where: { $0.id == chosen }) {
      items.append(PickerChoice(title: chosen, value: chosen, selected: true))
    }
    return items
  }

  /// The runtime menu's groups, from what a draft offers: Claude Code connections, then Codex (one
  /// group each), then local B4 agents, then remote B4 (which only the Mac offers).
  static func runtimeSections(
    _ offered: [Connection]
  ) -> (harness: [Connection], local: [Connection], remote: [Connection]) {
    (
      offered.filter { $0.kind == .claude } + offered.filter { $0.kind == .codex },
      offered.filter { $0.kind == .b4 && $0.b4Mode != .remote },
      offered.filter { $0.kind == .b4 && $0.b4Mode == .remote }
    )
  }
}
