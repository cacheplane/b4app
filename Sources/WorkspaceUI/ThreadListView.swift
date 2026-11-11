import SwiftUI
import WorkspaceProtocol

// MARK: - Presentation logic

/// The Mac sidebar's collapsed environment ids, kept as one comma-joined string in `@SceneStorage`
/// (per device and window, never synced).
enum CollapsedEnvironments {
  static func parse(_ raw: String) -> Set<String> {
    Set(raw.split(separator: ",").map(String.init))
  }

  static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

extension WorkspaceModel {
  /// The display name of the environment a thread belongs to; nil for "No folder".
  func environmentName(for thread: ConversationThread) -> String? {
    guard let id = thread.environmentId else { return nil }
    return environments.first { $0.id == id }?.displayName
  }

  /// A read reply exists to un-read only when the thread has a latest turn, it ended, and it was read:
  /// quiet, or failed and read (a failure stays failed once read, but un-reading it puts it back in
  /// the badge).
  func canMarkUnread(_ thread: ConversationThread) -> Bool {
    guard let latest = thread.activity?.latestTurnId else { return false }
    let state = state(of: thread)
    return state == .quiet || (state == .failed && thread.readTurnId == latest)
  }

  /// Environments for menus (the phone's "Edit Environment", the composer's places): the one with the
  /// newest thread activity first, environments without threads last by name.
  var filterEnvironments: [WorkEnvironment] {
    var newest: [String: String] = [:]
    for thread in threads {
      guard let id = thread.environmentId else { continue }
      let at = thread.activity?.lastActivityAt ?? thread.createdAt
      if at > (newest[id] ?? "") { newest[id] = at }
    }
    return environments.sorted { lhs, rhs in
      switch (newest[lhs.id], newest[rhs.id]) {
      case (let l?, let r?) where l != r: return l > r
      case (_?, nil): return true
      case (nil, _?): return false
      default: return (lhs.displayName, lhs.id) < (rhs.displayName, rhs.id)
      }
    }
  }

  /// The Mac sidebar's sections: `environmentSections`, plus manual environments that hold no listed thread
  /// (a new environment, or one whose threads are pinned or archived) so they can still be renamed,
  /// given a folder, or deleted. A connection filter shows matches only. "No folder" stays last.
  var sidebarSections: [EnvironmentSection] {
    let built = environmentSections
    guard connectionFilter == nil else { return built }
    let present = Set(built.map(\.id))
    let empty =
      environments
      .filter { $0.manual && !present.contains($0.id) }
      .sorted { ($0.displayName, $0.id) < ($1.displayName, $1.id) }
      .map { EnvironmentSection(id: $0.id, title: $0.displayName, threads: []) }
    let other = built.filter { $0.id == EnvironmentSection.otherId }
    return built.filter { $0.id != EnvironmentSection.otherId } + empty + other
  }
}

extension WorkspaceModel {
  /// Whether the detail column is already showing `lastError`: an open, loaded thread shows it in the
  /// composer (or in place of the transcript). No thread, or one still loading, prints nothing.
  var detailShowsError: Bool {
    guard let id = selectedThreadId, threads.contains(where: { $0.id == id }) else { return false }
    return !detailLoading
  }

  /// The failure the list prints where the action happened: an environment or thread action failed and
  /// nothing else on screen says so. `detailVisible` is false where the detail is not on screen (the
  /// iPhone's single column). A sheet prints its own copy of the error, and the banner is hidden
  /// behind it, so the sheets are unaffected.
  func sidebarError(detailVisible: Bool = true) -> String? {
    guard let error = lastError else { return nil }
    return detailVisible && detailShowsError ? nil : (remediation?.message ?? error)
  }
}

/// A dismissible error line at the top of the thread list, in the style of the composer's banner.
struct SidebarErrorBanner: View {
  @Bindable var model: WorkspaceModel
  var detailVisible = true

  var body: some View {
    if let message = model.sidebarError(detailVisible: detailVisible) {
      LLACard(fill: .surface, padding: LLA.Space.m) {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          Text(message).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Dismiss") { model.lastError = nil }.buttonStyle(.llaLink).font(LLAFont.small)
        }
      }
      .padding(.vertical, LLA.Space.xs)
      .accessibilityIdentifier("sidebar-error")
    }
  }
}

// MARK: - Rows

/// One list row on one line: the title, then the state's mark at the trailing edge. The pin, the
/// runtime, why the thread sits where it does, and which connection runs it are spoken, not shown
/// (decision 10). The context menu holds the organization actions; archiving never stops a turn
/// (spec 3.3).
struct ThreadRow: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread
  @State private var renaming = false
  @State private var newTitle = ""
  @State private var deleting: ConversationThread?
  @Environment(\.showDetail) private var showDetail
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The pointer is over the row (the Mac only).
  @State private var hovering = false

  #if os(macOS)
    /// The fill's inset from the sidebar's edges: it spans x 8–232 of the 240 pt column.
    static let fillInset: CGFloat = LLA.Space.s
    /// The title's and the mark's inset inside the fill: the title starts at x 16, the mark's box ends
    /// at x 224.
    static let contentInset: CGFloat = LLA.Space.s
    /// The horizontal padding the sidebar puts around its stacks (`SidebarView`); the row reaches past
    /// it to its own fill inset.
    private static let sidebarPadding: CGFloat = 10
  #else
    /// With the list's 6 pt row inset, the title and the mark sit 16 pt in, on the phone's margin.
    static let contentInset: CGFloat = 10
  #endif

  /// The fill's strength, of `surfaceRaised`: full when selected, 60% under the pointer, else none.
  static func fillOpacity(selected: Bool, hovering: Bool) -> Double {
    selected ? 1 : hovering ? 0.6 : 0
  }

  /// Act-level titles (approve, reply, failed) are medium; every other title is regular.
  static func titleWeight(for state: ThreadState) -> Font.Weight {
    state.isActLevel ? .medium : .regular
  }

  var body: some View {
    let state = model.state(of: thread)
    let selected = model.selectedThreadId == thread.id
    Button {
      // Select before showing the detail, so the detail coming on screen cannot mark the thread that
      // was open before (still loaded until `openThread` replaces it) read.
      model.selectedThreadId = thread.id
      showDetail()
      Task { await model.openThread(id: thread.id) }
    } label: {
      HStack(spacing: LLA.Space.s) {
        title(state: state)
          .frame(maxWidth: .infinity, alignment: .leading)
        ThreadMark(state: state, acknowledged: model.isAcknowledged(thread))
      }
      .padding(.horizontal, Self.contentInset)
      #if os(iOS)
        .padding(.vertical, 6)
      #endif
      .frame(minHeight: LLA.Metrics.threadRow)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .fill(LLA.Color.surfaceRaised.opacity(Self.fillOpacity(selected: selected, hovering: hovering)))
      )
      // On the fill's frame, so the trace follows its rounded edge (x 8–232 on the Mac).
      .arrivalTrace(model.arrival(for: thread), reduceMotion: reduceMotion)
      .contentShape(Rectangle())
      #if os(macOS)
        .onHover { hovering = $0 }
      #endif
    }
    .buttonStyle(.llaRow)
    #if os(macOS)
      // Outside the button, so the pressed fill spans the same 8–232 as the selection.
      .padding(.horizontal, Self.fillInset - Self.sidebarPadding)
    #endif
    .accessibilityIdentifier("thread-row")
    .accessibilityValue(model.threadState(thread).rawValue)
    .accessibilityLabel(Self.accessibilityLabel(model: model, thread: thread))
    .contextMenu {
      Button("Rename…", systemImage: "pencil") {
        newTitle = thread.title
        renaming = true
      }
      Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
        Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
      }
      if model.canMarkUnread(thread) {
        Button("Mark as Unread", systemImage: "circle.fill") {
          Task { await model.markUnread(id: thread.id) }
        }
      }
      Button(
        thread.archived ? "Unarchive" : "Archive",
        systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
      ) {
        Task { await model.updateThread(id: thread.id, archived: !thread.archived) }
      }
      Divider()
      Button("Delete…", systemImage: "trash", role: .destructive) { deleting = thread }
    }
    .deleteThreadAlert(model: model, thread: $deleting)
    .alert("Rename thread", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") { Task { await model.updateThread(id: thread.id, title: newTitle) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The title is local to this app; the runtime's own history is not changed.")
    }
  }

  /// The title, in the state's weight and colour: a working title shimmers, a quiet one is muted and
  /// fades with age. The text itself never blinks.
  private func title(state: ThreadState) -> some View {
    Text(thread.title.isEmpty ? "Untitled" : thread.title)
      .font(Self.titleWeight(for: state) == .medium ? LLAFont.rowMedium : LLAFont.row)
      .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
      .workingShimmer(active: state == .working)
      .foregroundStyle(state == .quiet ? LLA.Color.muted : LLA.Color.ink)
      .opacity(state == .quiet ? quietOpacity : 1)
  }

  /// A quiet title's fade, by the age of the thread's last activity (or its creation, without any).
  private var quietOpacity: Double {
    guard let date = Timestamp.date(from: thread.activity?.lastActivityAt ?? thread.createdAt) else {
      return 1
    }
    return QuietFade.opacity(ageInDays: model.now().timeIntervalSince(date) / 86_400)
  }

  /// The title plus what the row no longer prints: whether it is pinned, the state its mark draws,
  /// the reason it sits where it does, the connection, and the connection's trouble when it is offline
  /// or errored. The state is left out where the reason already starts with it ("Failed 3 min. ago").
  static func accessibilityLabel(model: WorkspaceModel, thread: ConversationThread) -> String {
    var parts = thread.pinned ? ["Pinned"] : []
    parts.append(thread.title.isEmpty ? "Untitled" : thread.title)
    let spoken = model.state(of: thread).spokenLabel
    let reason = model.reasonLine(for: thread)
    if !reason.hasPrefix(spoken) { parts.append(spoken) }
    parts.append(reason)
    parts.append(model.connection(id: thread.connectionId)?.label ?? "Unknown connection")
    let state = model.threadState(thread)
    if [.reconnecting, .error, .unknown, .stopping].contains(state) { parts.append(state.label) }
    return parts.joined(separator: ", ")
  }
}

// MARK: - The list

/// The thread list for the sidebar: on the Mac a "Pinned" group, then one collapsible section per
/// environment, then "No folder"; on the iPhone one flat list in attention order, narrowed by the
/// connection filter. Both end with the archived threads while "Show archived" is on.
struct ThreadListView: View {
  @Bindable var model: WorkspaceModel
  #if os(macOS)
    @SceneStorage("collapsedEnvironments") private var collapsedRaw = ""
  #endif

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: 0) {
        SidebarErrorBanner(model: model)
        EnvironmentSectionsView(
          model: model,
          collapsed: Binding(
            get: { CollapsedEnvironments.parse(collapsedRaw) },
            set: { collapsedRaw = CollapsedEnvironments.encode($0) }))
      }
    #else
      // On the iPhone's single column the thread detail is not on screen, so the list says it.
      SidebarErrorBanner(model: model, detailVisible: sizeClass != .compact)
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
      FlatThreadRows(model: model)
    #endif
  }
}

/// The phone's rows in attention order: by state, pinned first inside each, no state headings (the marks
/// carry the state); then the archived threads, in the same order, while "Show archived" is on.
/// Meant to sit inside a `List`; it supplies the swipe actions.
struct FlatThreadRows: View {
  @Bindable var model: WorkspaceModel
  @State private var deleting: ConversationThread?

  var body: some View {
    let rows = model.orderedThreads + (model.shownSettings.showArchived ? model.archivedThreads : [])
    if rows.isEmpty {
      Text("No threads yet.")
        .llaSmallMuted()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    ForEach(rows) { thread in
      ThreadRow(model: model, thread: thread)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          // Not `role: .destructive`, which would remove the row before the confirmation is answered.
          Button("Delete", systemImage: "trash") { deleting = thread }
            .tint(.red)
            .accessibilityIdentifier("swipe-delete")
          Button(
            thread.archived ? "Unarchive" : "Archive",
            systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
          ) {
            Task { await model.updateThread(id: thread.id, archived: !thread.archived) }
          }
          .tint(LLA.Color.muted)
          Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
            Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
          }
          .tint(LLA.Color.accent)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          if model.canMarkUnread(thread) {
            Button("Mark as Unread", systemImage: "circle.fill") {
              Task { await model.markUnread(id: thread.id) }
            }
            .tint(LLA.Color.ink)
          }
        }
    }
    .deleteThreadAlert(model: model, thread: $deleting)
  }
}

/// The flat list on its own: a plain `List` of `FlatThreadRows`.
struct FlatThreadList: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    List { FlatThreadRows(model: model) }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, LLA.Metrics.row)
  }
}

// MARK: - The Mac sections

#if os(macOS)
  /// The Mac sidebar's list: Pinned, then a collapsible section per environment, "No folder" last, and
  /// the archive while view options' switch is on. Plain stacks, not `List`: a List drew nothing in the
  /// macOS 26 split-view sidebar (see `SidebarView`).
  struct EnvironmentSectionsView: View {
    @Bindable var model: WorkspaceModel
    @Binding var collapsed: Set<String>
    @State private var renaming: WorkEnvironment?
    @State private var deleting: WorkEnvironment?
    @State private var folderTarget: WorkEnvironment?
    @State private var choosingFolder = false

    var body: some View {
      let pinned = model.pinnedThreads
      let sections = model.sidebarSections
      VStack(alignment: .leading, spacing: 2) {
        if pinned.isEmpty && sections.allSatisfy({ $0.threads.isEmpty }) {
          Text("No threads yet.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 6)
        }
        if !pinned.isEmpty {
          SidebarGroupLabel("Pinned")
          rows(pinned)
        }
        ForEach(sections) { section in
          sectionView(section)
        }
        archive
      }
      .sheet(item: $renaming) { RenameEnvironmentSheet(model: model, environment: $0) }
      .confirmationDialog(
        deleting.map { "Delete \u{201C}\($0.displayName)\u{201D}?" } ?? "Delete environment?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible, presenting: deleting
      ) { environment in
        Button("Delete Environment", role: .destructive) {
          Task { await model.deleteEnvironment(id: environment.id) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Its folders return to automatic environments. No threads are deleted.")
      }
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        guard case .success(let url) = result, let environment = folderTarget else { return }
        Task { await model.addFolder(environmentId: environment.id, path: url.path) }
      }
    }

    @ViewBuilder private func sectionView(_ section: EnvironmentSection) -> some View {
      let isCollapsed = collapsed.contains(section.id)
      VStack(alignment: .leading, spacing: 2) {
        header(section, isCollapsed: isCollapsed)
        if !isCollapsed {
          if section.threads.isEmpty {
            Text("No threads.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 4)
          } else {
            rows(section.threads)
          }
        }
      }
      .padding(.top, LLA.Space.xs)
    }

    private func header(_ section: EnvironmentSection, isCollapsed: Bool) -> some View {
      let environment = model.environments.first { $0.id == section.id }
      // A collapsed section still shows the most urgent mark of a top-list thread inside; an approve
      // mark pulses until every approve thread in it has been opened.
      let urgent = section.threads.map { model.state(of: $0) }.min().flatMap { $0.isTopList ? $0 : nil }
      let acknowledged = section.threads.allSatisfy {
        model.state(of: $0) != urgent || model.isAcknowledged($0)
      }
      return Button {
        if isCollapsed { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
      } label: {
        HStack(spacing: LLA.Space.s) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(LLA.Color.muted)
            .frame(width: 10)
          Text(section.title).font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink).lineLimit(1)
          Spacer(minLength: 0)
          if isCollapsed, let urgent { ThreadMark(state: urgent, acknowledged: acknowledged) }
          Text("\(section.threads.count)").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("environment-header")
      .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
      .contextMenu {
        if let environment {
          Button("Rename…", systemImage: "pencil") { renaming = environment }
          Button("Add Folder…", systemImage: "folder.badge.plus") {
            folderTarget = environment
            choosingFolder = true
          }
          if environment.manual {
            Divider()
            Button("Delete Environment", systemImage: "trash", role: .destructive) { deleting = environment }
          }
        }
      }
    }

    /// Thread rows, touching: no gap between one row's fill and the next.
    private func rows(_ threads: [ConversationThread]) -> some View {
      VStack(spacing: 0) { ForEach(threads) { ThreadRow(model: model, thread: $0) } }
    }

    /// The archived threads, listed last while view options' "Show archived" is on.
    @ViewBuilder private var archive: some View {
      if model.shownSettings.showArchived {
        SidebarGroupLabel("Archived")
        if model.archivedThreads.isEmpty {
          Text("No archived threads.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 6)
        } else {
          rows(model.archivedThreads)
        }
      }
    }
  }
#endif
