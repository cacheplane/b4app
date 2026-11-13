import SwiftUI
import WorkspaceProtocol

// MARK: - Presentation logic

/// The collapsed "By environment" groups' ids (`ListLayout.Group.id`), kept as one comma-joined string
/// in `@SceneStorage` (per device and window, never synced; decision 13).
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
  /// The Mac's lower list under Dense: a 20 pt row, 11 pt title, and 8 pt mark; nothing else changes.
  var tiny = false
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
    static let sidebarPadding: CGFloat = 10
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
        ThreadMark(state: state, acknowledged: model.isAcknowledged(thread), tiny: tiny)
      }
      .padding(.horizontal, Self.contentInset)
      #if os(iOS)
        .padding(.vertical, 6)
      #endif
      .frame(minHeight: tiny ? LLA.Metrics.threadRowTiny : LLA.Metrics.threadRow)
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
      .font(titleFont(medium: Self.titleWeight(for: state) == .medium))
      .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
      .workingShimmer(active: state == .working)
      .foregroundStyle(state == .quiet ? LLA.Color.muted : LLA.Color.ink)
      .opacity(state == .quiet ? quietOpacity : 1)
  }

  private func titleFont(medium: Bool) -> Font {
    if tiny { return medium ? LLAFont.rowTinyMedium : LLAFont.rowTiny }
    return medium ? LLAFont.rowMedium : LLAFont.row
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

// MARK: - Stowed threads

/// The one row that stands for the threads the lower list stows: Collapsed's "9 more, 2 working", or
/// Hidden's "2 working". Muted 13 pt text in a thread row's geometry, the orbiting working mark at the
/// trailing edge while any of them runs, the hover fill on the Mac. Activating it shows the stowed
/// threads beneath it.
struct StowedThreadsRow: View {
  let text: String
  let working: Bool
  let open: Bool
  let action: () -> Void
  @State private var hovering = false

  static func accessibilityLabel(_ text: String) -> String { "\(text), Show threads that don't need you" }

  var body: some View {
    Button(action: action) {
      HStack(spacing: LLA.Space.s) {
        Text(text)
          .font(LLAFont.sans(13, relativeTo: .subheadline))
          .foregroundStyle(LLA.Color.muted)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        // Quiet draws nothing and keeps the box's place.
        ThreadMark(state: working ? .working : .quiet)
      }
      .padding(.horizontal, ThreadRow.contentInset)
      #if os(iOS)
        .padding(.vertical, 6)
      #endif
      .frame(minHeight: LLA.Metrics.threadRow)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .fill(LLA.Color.surfaceRaised.opacity(ThreadRow.fillOpacity(selected: false, hovering: hovering)))
      )
      .contentShape(Rectangle())
      #if os(macOS)
        .onHover { hovering = $0 }
      #endif
    }
    .buttonStyle(.llaRow)
    #if os(macOS)
      .padding(.horizontal, ThreadRow.fillInset - ThreadRow.sidebarPadding)
    #endif
    .accessibilityLabel(Self.accessibilityLabel(text))
    .accessibilityValue(open ? "expanded" : "collapsed")
  }
}

// MARK: - The list

/// The thread list for the sidebar, drawn from `ListLayout` on both platforms: under "Needs you first"
/// the top list, a 24 pt gap, then the lower list as `quietThreads` draws it; under "By environment"
/// a heading per group with its threads beneath, 8 pt between groups. The archived block follows a
/// 24 pt gap while "Show archived" is on. Hidden's row is the sidebar's on the Mac
/// (`HiddenWorkingRow`, pinned above the profile footer, the rows it opens last in this list) and the
/// list's last row on the phone. Consecutive rows are `LLA.Metrics.rowGap` apart; a section gap above a
/// list's first row replaces that gap (`gapAbove`).
struct ThreadListView: View {
  @Bindable var model: WorkspaceModel
  /// Whether the stowed threads (Collapsed or Hidden) are shown: per window, never stored.
  @Binding var showsStowed: Bool
  #if os(macOS)
    @SceneStorage("collapsedEnvironments") private var collapsedRaw = ""
  #endif

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Between the top list and the lower list, and before the archived block.
  static let gap: CGFloat = LLA.Space.xl

  /// The space above a row: `sectionGap` (24 pt, 8 pt, or none after a heading or at the top) above a
  /// list's first row, else the hairline `LLA.Metrics.rowGap`; the two never add up.
  static func gapAbove(isFirst: Bool, sectionGap: CGFloat) -> CGFloat {
    isFirst ? sectionGap : LLA.Metrics.rowGap
  }

  /// A working row's scroll id among the rows Hidden's row opens.
  static func hiddenOpenedId(_ thread: ConversationThread) -> String { "hidden-opened-\(thread.id)" }

  /// The scroll id of the first working row Hidden's row opens, which the sidebar brings into view as
  /// they open; nil unless Hidden stows something.
  static func hiddenOpenedScrollTarget(_ layout: ListLayout) -> String? {
    guard case .needsYouFirst(_, .hidden(let working, _)) = layout.body else { return nil }
    return working.first.map(hiddenOpenedId)
  }

  var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: 0) {
        SidebarErrorBanner(model: model)
        macList(model.listLayout)
      }
    #else
      // On the iPhone's single column the thread detail is not on screen, so the list says it.
      SidebarErrorBanner(model: model, detailVisible: sizeClass != .compact)
        .listRowBackground(Color.clear).listRowSeparator(.hidden)
      FlatThreadRows(model: model, showsStowed: $showsStowed)
    #endif
  }

  #if os(macOS)
    @ViewBuilder private func macList(_ layout: ListLayout) -> some View {
      if layout.saysNoThreadsYet(hasLiveThreads: !model.orderedThreads.isEmpty) {
        Text("No threads yet.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 6)
      }
      switch layout.body {
      case .needsYouFirst(let top, let lower):
        ThreadRows(model: model, threads: top)
        // Under Hidden only the selected row, if any, is drawn here: Hidden's row is the sidebar's, and
        // the rows it opens come last. Nothing drawn, no gap.
        if lower.drawsInList { macLower(lower).padding(.top, top.isEmpty ? 0 : Self.gap) }
      case .byEnvironment(let groups):
        EnvironmentGroupsView(
          model: model, groups: groups,
          collapsed: Binding(
            get: { CollapsedEnvironments.parse(collapsedRaw) },
            set: { collapsedRaw = CollapsedEnvironments.encode($0) }))
      }
      if !layout.archived.isEmpty {
        ThreadRows(model: model, threads: layout.archived)
          .padding(.top, layout.body.drawsAboveArchive ? Self.gap : 0)
      }
      // The working threads Hidden's row opens: the scrolling list's last rows, so many of them scroll.
      // The first carries a scroll id, so the sidebar brings it into view as they open.
      if showsStowed, case .needsYouFirst(_, .hidden(let working, _)) = layout.body, !working.isEmpty {
        VStack(spacing: ThreadRows.spacing) {
          ForEach(working) { ThreadRow(model: model, thread: $0).id(Self.hiddenOpenedId($0)) }
        }
        .padding(.top, layout.body.drawsAboveArchive || !layout.archived.isEmpty ? Self.gap : 0)
      }
    }

    @ViewBuilder private func macLower(_ lower: ListLayout.Lower) -> some View {
      switch lower {
      case .rows(let threads, let tiny):
        ThreadRows(model: model, threads: threads, tiny: tiny)
      case .collapsed(let count, let working, let threads, let selected):
        // The selected thread first, as an ordinary row; then the row standing for the rest (absent with
        // nothing else stowed) and, opened, the rest beneath it.
        VStack(spacing: ThreadRows.spacing) {
          if let selected { ThreadRow(model: model, thread: selected) }
          if count > 0 {
            StowedThreadsRow(
              text: ListLayout.collapsedLabel(count: count, working: working), working: working > 0,
              open: showsStowed
            ) { showsStowed.toggle() }
            .accessibilityIdentifier("collapsed-threads")
            if showsStowed { ThreadRows(model: model, threads: threads) }
          }
        }
      case .hidden(_, let selected):
        // Only the selected row: `macList` draws Hidden's opened rows last, and the sidebar draws its row.
        if let selected { ThreadRow(model: model, thread: selected) }
      }
    }
  #endif
}

/// Thread rows with a hairline of space between one row's fill and the next (the Mac's stacks).
struct ThreadRows: View {
  @Bindable var model: WorkspaceModel
  let threads: [ConversationThread]
  var tiny = false

  /// Between consecutive rows; nesting stacks use it too, so a stack's last row and the next stack's
  /// first are as far apart as any two rows.
  static let spacing = LLA.Metrics.rowGap

  var body: some View {
    VStack(spacing: Self.spacing) { ForEach(threads) { ThreadRow(model: model, thread: $0, tiny: tiny) } }
  }
}

/// The Mac's Hidden row, "2 working" with the orbit, while agents run, pinned above the profile footer
/// outside the list's scroll view; activating it shows those threads as the scrolling list's last rows
/// (`ThreadListView`).
struct HiddenWorkingRow: View {
  let working: Int
  @Binding var open: Bool

  var body: some View {
    if let text = ListLayout.hiddenLabel(working: working) {
      StowedThreadsRow(text: text, working: true, open: open) { open.toggle() }
        .accessibilityIdentifier("hidden-working")
    }
  }
}

/// The phone's rows, from `ListLayout`: the top list, then the lower list after a 24 pt gap (or
/// Collapsed's row, opened and closed by a tap); under "By environment" a heading per group, 8 pt
/// apart, a tap collapsing it; the archived block after a 24 pt gap; and last, Hidden's row while
/// agents run. Meant to sit inside a `List`; it supplies the swipe actions.
struct FlatThreadRows: View {
  @Bindable var model: WorkspaceModel
  @Binding var showsStowed: Bool
  @State private var deleting: ConversationThread?
  @SceneStorage("collapsedEnvironments") private var collapsedRaw = ""

  var body: some View {
    let layout = model.listLayout
    let gap = ThreadListView.gap
    if layout.saysNoThreadsYet(hasLiveThreads: !model.orderedThreads.isEmpty) {
      Text("No threads yet.")
        .llaSmallMuted()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    let hidden: [ConversationThread] = {
      if case .needsYouFirst(_, .hidden(let working, _)) = layout.body { return working }
      return []
    }()
    let drawn = layout.body.drawsAboveArchive
    Group {
      switch layout.body {
      case .needsYouFirst(let top, let lower):
        rows(top, gap: 0)
        let lowerGap = top.isEmpty ? 0 : gap
        // The selected thread that would be stowed, as an ordinary row where the lower list starts.
        let selected = lower.selected.map { [$0] } ?? []
        rows(selected, gap: lowerGap)
        let afterSelected = selected.isEmpty ? lowerGap : LLA.Metrics.rowGap
        switch lower {
        case .rows(let threads, _):
          // The phone keeps its 44 pt rows whatever the density.
          rows(threads, gap: lowerGap)
        case .collapsed(let count, let working, let threads, _) where count > 0:
          StowedThreadsRow(
            text: ListLayout.collapsedLabel(count: count, working: working), working: working > 0,
            open: showsStowed
          ) { showsStowed.toggle() }
          .accessibilityIdentifier("collapsed-threads")
          .modifier(PhoneRowChrome(gap: afterSelected))
          if showsStowed { rows(threads, gap: LLA.Metrics.rowGap) }
        case .collapsed, .hidden:
          EmptyView()
        }
      case .byEnvironment(let groups):
        let collapsed = CollapsedEnvironments.parse(collapsedRaw)
        ForEach(groups) { group in
          let isCollapsed = collapsed.contains(group.id)
          EnvironmentHeading(model: model, group: group, isCollapsed: isCollapsed) {
            var next = collapsed
            if isCollapsed { next.remove(group.id) } else { next.insert(group.id) }
            collapsedRaw = CollapsedEnvironments.encode(next)
          }
          .modifier(PhoneRowChrome(gap: group.id == groups.first?.id ? 0 : EnvironmentHeading.groupGap))
          if !isCollapsed { rows(group.threads, gap: 0) }
        }
      }
      rows(layout.archived, gap: drawn ? gap : 0)
      if let text = ListLayout.hiddenLabel(working: hidden.count) {
        StowedThreadsRow(text: text, working: true, open: showsStowed) { showsStowed.toggle() }
          .accessibilityIdentifier("hidden-working")
          .modifier(PhoneRowChrome(gap: drawn || !layout.archived.isEmpty ? gap : 0))
        if showsStowed { rows(hidden, gap: LLA.Metrics.rowGap) }
      }
    }
    .deleteThreadAlert(model: model, thread: $deleting)
  }

  /// Rows with their swipe actions; `gap` opens above the first, the hairline row gap above the others.
  private func rows(_ threads: [ConversationThread], gap: CGFloat) -> some View {
    ForEach(threads) { thread in
      ThreadRow(model: model, thread: thread)
        .modifier(
          PhoneRowChrome(
            gap: ThreadListView.gapAbove(isFirst: thread.id == threads.first?.id, sectionGap: gap))
        )
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
  }
}

/// A list row on the phone: the 6 pt side inset, no separator or background, and `gap` of empty space
/// above it, outside its button (the 24 pt between the list's parts, or the 1 pt row gap; a list has no
/// spacer row shorter than its least row height). The button keeps its 44 pt height.
private struct PhoneRowChrome: ViewModifier {
  let gap: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(.top, gap)
      .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

/// The flat list on its own: a plain `List` of `FlatThreadRows`.
struct FlatThreadList: View {
  @Bindable var model: WorkspaceModel
  @Binding var showsStowed: Bool

  var body: some View {
    List { FlatThreadRows(model: model, showsStowed: $showsStowed) }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, LLA.Metrics.row)
  }
}

// MARK: - By environment

/// A "By environment" group's heading (decision 9): the name at 12 pt, weight 500, muted, where thread
/// titles start; no count and no rule. A 28 pt row on the Mac, 44 on the phone. Activating it collapses
/// or expands the group. A collapsed group shows its most urgent thread's mark in the marks' column,
/// acknowledged only when every thread in that state is. On the Mac, under the pointer, the name turns
/// ink, a chevron appears beside it, and a new-thread button takes the mark's column; on the phone a
/// long press offers "New thread here". Either opens the composer in the group's environment, or with
/// no folder under "No folder".
struct EnvironmentHeading: View {
  @Bindable var model: WorkspaceModel
  let group: ListLayout.Group
  let isCollapsed: Bool
  let toggle: () -> Void
  #if os(macOS)
    @State private var hovering = false
  #endif

  /// Between one group's last row and the next heading.
  static let groupGap: CGFloat = LLA.Space.s
  #if os(macOS)
    static let height: CGFloat = 28
  #else
    static let height: CGFloat = 44
  #endif

  static func newThreadTitle(_ group: ListLayout.Group) -> String { "New thread in \(group.title)" }
  static func editTitle(_ group: ListLayout.Group) -> String { "Edit \(group.title)" }

  /// "expanded", or "collapsed" and the spoken label of the group's most urgent state.
  static func accessibilityValue(isCollapsed: Bool, mostUrgent: ThreadState?) -> String {
    guard isCollapsed else { return "expanded" }
    return ["collapsed", mostUrgent?.spokenLabel].compactMap { $0 }.joined(separator: ", ")
  }

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: LLA.Space.xs) {
        Text(group.title)
          .font(LLAFont.sans(12, weight: .medium, relativeTo: .caption))
          .foregroundStyle(highlighted ? LLA.Color.ink : LLA.Color.muted)
          .lineLimit(1)
        if highlighted {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(LLA.Color.ink)
        }
        Spacer(minLength: LLA.Space.s)
        mark.opacity(highlighted ? 0 : 1)
      }
      .padding(.horizontal, ThreadRow.contentInset)
      .frame(minHeight: Self.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #if os(macOS)
      .overlay(alignment: .trailing) { if hovering { hoverButtons } }
      .onHover { hovering = $0 }
      .padding(.horizontal, ThreadRow.fillInset - ThreadRow.sidebarPadding)
    #endif
    .accessibilityLabel(group.title)
    .accessibilityValue(Self.accessibilityValue(isCollapsed: isCollapsed, mostUrgent: group.mostUrgent))
    .accessibilityIdentifier("environment-header")
    #if os(macOS)
      // The hover buttons are out of reach of VoiceOver and the keyboard; the heading offers the same.
      .accessibilityAction(named: Self.newThreadTitle(group)) { openNewThread() }
      .accessibilityActions {
        if let id = group.environmentId {
          Button(Self.editTitle(group)) { model.openEnvironmentForm(id: id) }
        }
      }
    #else
      .contextMenu {
        Button("New thread here", systemImage: "square.and.pencil") { openNewThread() }
        .disabled(model.newThreadEntryReason != nil)
      }
    #endif
  }

  /// The pointer is over the heading (the Mac only).
  private var highlighted: Bool {
    #if os(macOS)
      hovering
    #else
      false
    #endif
  }

  /// A collapsed group's most urgent mark; quiet, or an expanded group, draws nothing and keeps the
  /// box's place.
  private var mark: some View {
    let state = isCollapsed ? group.mostUrgent ?? .quiet : .quiet
    let acknowledged = group.threads.allSatisfy { model.state(of: $0) != state || model.isAcknowledged($0) }
    return ThreadMark(state: state, acknowledged: acknowledged)
  }

  private func openNewThread() {
    Task { await model.openNewThread(in: group) }
  }

  #if os(macOS)
    /// New thread here, then (for an environment, not "No folder") edit, as in the design's mockup; each 28
    /// by 28, the last centred on the marks' column (the mark's 12 pt box ends 8 pt inside the heading).
    private var hoverButtons: some View {
      HStack(spacing: 0) {
        hoverButton(
          "square.and.pencil", label: Self.newThreadTitle(group), id: "environment-new-thread",
          disabledReason: model.newThreadEntryReason, action: openNewThread)
        if let id = group.environmentId {
          hoverButton("slider.horizontal.3", label: Self.editTitle(group), id: "environment-edit") {
            model.openEnvironmentForm(id: id)
          }
        }
      }
      .padding(.trailing, ThreadRow.contentInset + LLA.Metrics.mark / 2 - TopBarButton.side / 2)
    }

    private func hoverButton(
      _ symbol: String, label: String, id: String, disabledReason: String? = nil,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        Image(systemName: symbol)
          .foregroundStyle(LLA.Color.ink)
          .frame(width: TopBarButton.side, height: TopBarButton.side)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(disabledReason != nil)
      .help(disabledReason ?? label)
      .accessibilityLabel(label)
      .accessibilityIdentifier(id)
    }
  #endif
}

#if os(macOS)
  /// The Mac's "By environment": each group's heading, then its threads unless it is collapsed, 8 pt
  /// between groups. Plain stacks, not `List`: a List drew nothing in the macOS 26 split-view sidebar
  /// (see `SidebarView`). A heading's hover buttons and context menu open the environment form (D-212).
  struct EnvironmentGroupsView: View {
    @Bindable var model: WorkspaceModel
    let groups: [ListLayout.Group]
    @Binding var collapsed: Set<String>

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(groups) { group in
          let isCollapsed = collapsed.contains(group.id)
          VStack(alignment: .leading, spacing: 0) {
            EnvironmentHeading(model: model, group: group, isCollapsed: isCollapsed) {
              if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
            .contextMenu {
              if let id = group.environmentId {
                Button("New Thread Here", systemImage: "square.and.pencil") {
                  Task { await model.openNewThread(in: group) }
                }
                .disabled(model.newThreadEntryReason != nil)
                Button("Edit Environment\u{2026}", systemImage: "slider.horizontal.3") {
                  model.openEnvironmentForm(id: id)
                }
              }
            }
            if !isCollapsed { ThreadRows(model: model, threads: group.threads) }
          }
          .padding(.top, group.id == groups.first?.id ? 0 : EnvironmentHeading.groupGap)
        }
      }
    }
  }

#endif
