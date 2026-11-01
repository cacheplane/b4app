import SwiftUI
import WorkspaceProtocol

// MARK: - Presentation logic

/// The Mac sidebar's collapsed project ids, kept as one comma-joined string in `@SceneStorage`
/// (per device and window, never synced).
enum CollapsedProjects {
  static func parse(_ raw: String) -> Set<String> {
    Set(raw.split(separator: ",").map(String.init))
  }

  static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }
}

extension AttentionBand {
  /// What the status dot says to VoiceOver: the dot carries the band, so it needs a name.
  var dotLabel: String {
    switch self {
    case .needsInput: return "Needs your input"
    case .unread: return "Unread reply"
    case .working: return "Working"
    case .quiet: return "Quiet"
    }
  }
}

extension WorkspaceModel {
  /// The display name of the project a thread belongs to; nil for "Other".
  func projectName(for thread: ConversationThread) -> String? {
    guard let id = thread.projectId else { return nil }
    return projects.first { $0.id == id }?.displayName
  }

  /// A read reply exists to un-read only when the thread is quiet and has a latest turn.
  func canMarkUnread(_ thread: ConversationThread) -> Bool {
    band(of: thread) == .quiet && thread.activity?.latestTurnId != nil
  }

  /// Projects for the filter menu: the one with the newest thread activity first, projects without
  /// threads last by name.
  var filterProjects: [Project] {
    var newest: [String: String] = [:]
    for thread in threads {
      guard let id = thread.projectId else { continue }
      let at = thread.activity?.lastActivityAt ?? thread.createdAt
      if at > (newest[id] ?? "") { newest[id] = at }
    }
    return projects.sorted { lhs, rhs in
      switch (newest[lhs.id], newest[rhs.id]) {
      case (let l?, let r?) where l != r: return l > r
      case (_?, nil): return true
      case (nil, _?): return false
      default: return (lhs.displayName, lhs.id) < (rhs.displayName, rhs.id)
      }
    }
  }

  /// Whether any live thread has no known project, so the menu offers "Other".
  var hasOtherThreads: Bool {
    threads.contains { thread in
      !thread.archived && (thread.projectId.map { id in !projects.contains { $0.id == id } } ?? true)
    }
  }

  /// The menu's title for the current project filter.
  var filterTitle: String {
    switch projectFilter {
    case .all: return "All projects"
    case .project(let id): return projects.first { $0.id == id }?.displayName ?? "Project"
    case .other: return "Other"
    case .archived: return "Archived"
    }
  }

  /// The Mac sidebar's sections: `projectSections`, plus manual projects that hold no listed thread
  /// (a new project, or one whose threads are pinned or archived) so they can still be renamed,
  /// given a folder, or deleted. A connection filter shows matches only. "Other" stays last.
  var sidebarSections: [ProjectSection] {
    let built = projectSections
    guard connectionFilter == nil, projectFilter == .all else { return built }
    let present = Set(built.map(\.id))
    let empty =
      projects
      .filter { $0.manual && !present.contains($0.id) }
      .sorted { ($0.displayName, $0.id) < ($1.displayName, $1.id) }
      .map { ProjectSection(id: $0.id, title: $0.displayName, threads: []) }
    let other = built.filter { $0.id == ProjectSection.otherId }
    return built.filter { $0.id != ProjectSection.otherId } + empty + other
  }
}

extension WorkspaceModel {
  /// Whether the detail column is already showing `lastError`: an open, loaded thread shows it in the
  /// composer (or in place of the transcript). No thread, or one still loading, prints nothing.
  var detailShowsError: Bool {
    guard let id = selectedThreadId, threads.contains(where: { $0.id == id }) else { return false }
    return !detailLoading
  }

  /// The failure the list prints where the action happened: a project or thread action failed and
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

// MARK: - Status dot

/// The attention band as an 8 pt dot (D-036, one accent): needs input is the accent, filled; unread is
/// ink, filled; working is an ink ring that breathes unless Reduce Motion is on; quiet is a small
/// muted hollow ring. The band is also the accessibility label, so colour is never the only signal.
struct AttentionDot: View {
  let band: AttentionBand
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dim = false

  /// The lowest opacity of a working ring. A working ring (ink, 8 pt, 1.5 pt stroke) must never read
  /// paler than a quiet ring (muted, 6 pt, 1 pt stroke), so the pulse stops well short of faint.
  static let pulseFloor = 0.65

  /// Whether the dot animates: only a working thread, and never under Reduce Motion.
  static func pulses(band: AttentionBand, reduceMotion: Bool) -> Bool {
    band == .working && !reduceMotion
  }

  private var pulses: Bool { Self.pulses(band: band, reduceMotion: reduceMotion) }

  var body: some View {
    ZStack {
      switch band {
      case .needsInput:
        Circle().fill(LLA.Color.accent)
      case .unread:
        Circle().fill(LLA.Color.ink)
      case .working:
        Circle().strokeBorder(LLA.Color.ink, lineWidth: 1.5).opacity(pulses && dim ? Self.pulseFloor : 1)
      case .quiet:
        Circle().strokeBorder(LLA.Color.muted, lineWidth: 1).frame(width: 6, height: 6)
      }
    }
    .frame(width: 8, height: 8)
    // Keyed by whether the dot pulses, not by appearance: a row keeps its identity when its band
    // changes in place, and Reduce Motion can change while it is on screen. Each change resets the
    // phase first, so a ring that goes working, quiet, working starts again at full opacity.
    .task(id: pulses) {
      var reset = Transaction()
      reset.disablesAnimations = true
      withTransaction(reset) { dim = false }
      guard pulses else { return }
      try? await Task.sleep(for: .milliseconds(30))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(band.dotLabel)
  }
}

// MARK: - Rows

/// One list row: the band dot, the title, and the runtime's ghosted mark. Why it sits there and which
/// connection runs it are spoken, not shown. The context menu holds the organization actions;
/// archiving never stops a turn (spec 3.3).
struct ThreadRow: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread
  @State private var renaming = false
  @State private var newTitle = ""
  @Environment(\.showDetail) private var showDetail

  var body: some View {
    let band = model.band(of: thread)
    let selected = model.selectedThreadId == thread.id
    let loud = selected || band == .needsInput || band == .unread
    Button {
      // Select before showing the detail, so the detail coming on screen cannot mark the thread that
      // was open before (still loaded until `openThread` replaces it) read.
      model.selectedThreadId = thread.id
      showDetail()
      Task { await model.openThread(id: thread.id) }
    } label: {
      HStack(spacing: LLA.Space.s) {
        AttentionDot(band: band)
        Text(thread.title.isEmpty ? "Untitled" : thread.title)
          .font(loud ? LLAFont.smallStrong : LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
          .lineLimit(1)
        Spacer(minLength: LLA.Space.s)
        if let kind = model.connection(id: thread.connectionId)?.kind { RuntimeMark(kind: kind) }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .fill(selected ? LLA.Color.surfaceRaised : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("thread-row")
    .accessibilityValue(model.threadState(thread).rawValue)
    .accessibilityHint(Self.accessibilityHint(model: model, thread: thread))
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
    }
    .alert("Rename thread", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") { Task { await model.updateThread(id: thread.id, title: newTitle) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The title is local to this app; the runtime's own history is not changed.")
    }
  }

  /// What the row no longer prints: the reason it sits where it does, the connection, and the
  /// connection's trouble when it is offline or errored.
  static func accessibilityHint(model: WorkspaceModel, thread: ConversationThread) -> String {
    var parts = [model.reasonLine(for: thread)]
    parts.append(model.connection(id: thread.connectionId)?.label ?? "Unknown connection")
    let state = model.threadState(thread)
    if [.reconnecting, .error, .unknown, .stopping].contains(state) { parts.append(state.label) }
    return parts.joined(separator: ", ")
  }
}

// MARK: - The list

/// The thread list for the sidebar: on the Mac a "Pinned" group, then one collapsible section per
/// project, then "Other"; on the iPhone one flat list in attention order, narrowed by the filter menu.
struct ThreadListView: View {
  @Bindable var model: WorkspaceModel
  #if os(macOS)
    @SceneStorage("collapsedProjects") private var collapsedRaw = ""
  #endif

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: 0) {
        SidebarErrorBanner(model: model)
        ProjectSectionsView(
          model: model,
          collapsed: Binding(
            get: { CollapsedProjects.parse(collapsedRaw) },
            set: { collapsedRaw = CollapsedProjects.encode($0) }))
      }
    #else
      // On the iPhone's single column the thread detail is not on screen, so the list says it.
      SidebarErrorBanner(model: model, detailVisible: sizeClass != .compact)
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
      FlatThreadRows(model: model)
    #endif
  }
}

/// The phone's rows: pinned threads first, then the rest, no band headings (the dots carry the band).
/// Meant to sit inside a `List`; it supplies the swipe actions.
struct FlatThreadRows: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    let rows = model.orderedThreads
    if rows.isEmpty {
      Text(model.projectFilter == .archived ? "No archived threads." : "No threads yet.")
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
  }
}

/// The flat list on its own: a plain `List` of `FlatThreadRows`.
struct FlatThreadList: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    List { FlatThreadRows(model: model) }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
  }
}

// MARK: - The Mac sections

#if os(macOS)
  /// The Mac sidebar's list: Pinned, then a collapsible section per project, "Other" last, the
  /// archive while More's switch is on, and "New Project…" at the end. Plain stacks, not `List`: a List drew nothing
  /// in the macOS 26 split-view sidebar (see `SidebarView`).
  struct ProjectSectionsView: View {
    @Bindable var model: WorkspaceModel
    @Binding var collapsed: Set<String>
    @State private var creating = false
    @State private var renaming: Project?
    @State private var deleting: Project?
    @State private var folderTarget: Project?
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
          ForEach(pinned) { ThreadRow(model: model, thread: $0) }
        }
        ForEach(sections) { section in
          sectionView(section)
        }
        archive
        Button {
          creating = true
        } label: {
          Text("New Project…")
            .font(LLAFont.small).foregroundStyle(LLA.Color.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, LLA.Space.m)
        .accessibilityIdentifier("new-project")
      }
      .sheet(isPresented: $creating) { NewProjectSheet(model: model) }
      .sheet(item: $renaming) { RenameProjectSheet(model: model, project: $0) }
      .confirmationDialog(
        deleting.map { "Delete \u{201C}\($0.displayName)\u{201D}?" } ?? "Delete project?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible, presenting: deleting
      ) { project in
        Button("Delete Project", role: .destructive) {
          Task { await model.deleteProject(id: project.id) }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Its folders return to automatic projects. No threads are deleted.")
      }
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        guard case .success(let url) = result, let project = folderTarget else { return }
        Task { await model.addFolder(projectId: project.id, path: url.path) }
      }
    }

    @ViewBuilder private func sectionView(_ section: ProjectSection) -> some View {
      let isCollapsed = collapsed.contains(section.id)
      VStack(alignment: .leading, spacing: 2) {
        header(section, isCollapsed: isCollapsed)
        if !isCollapsed {
          ForEach(section.threads) { ThreadRow(model: model, thread: $0) }
          if section.threads.isEmpty {
            Text("No threads.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 4)
          }
        }
      }
      .padding(.top, LLA.Space.xs)
    }

    private func header(_ section: ProjectSection, isCollapsed: Bool) -> some View {
      let project = model.projects.first { $0.id == section.id }
      // A collapsed section still shows a dot when something inside is waiting or unread.
      let urgent = section.threads.map { model.band(of: $0) }.min().flatMap {
        $0 == .needsInput || $0 == .unread ? $0 : nil
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
          if isCollapsed, let urgent { AttentionDot(band: urgent) }
          Text("\(section.threads.count)").font(LLAFont.caption).foregroundStyle(LLA.Color.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("project-header")
      .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
      .contextMenu {
        if let project {
          Button("Rename…", systemImage: "pencil") { renaming = project }
          Button("Add Folder…", systemImage: "folder.badge.plus") {
            folderTarget = project
            choosingFolder = true
          }
          if project.manual {
            Divider()
            Button("Delete Project", systemImage: "trash", role: .destructive) { deleting = project }
          }
        }
      }
    }

    /// The archived threads, listed last while More's "Show archived" is on.
    @ViewBuilder private var archive: some View {
      if model.showArchived {
        SidebarGroupLabel("Archived")
        if model.archivedThreads.isEmpty {
          Text("No archived threads.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 6)
        }
        ForEach(model.archivedThreads) { ThreadRow(model: model, thread: $0) }
      }
    }
  }
#endif
