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
  /// The Mac's lower list under "Tiny": a 20 pt row, 11 pt title, and 8 pt mark; nothing else changes.
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
/// (`HiddenWorkingRows`, pinned above the profile footer) and the list's last row on the phone.
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
      let empty = model.orderedThreads.isEmpty
      if empty {
        Text("No threads yet.").llaSmallMuted().padding(.horizontal, 10).padding(.vertical, 6)
      }
      switch layout.body {
      case .needsYouFirst(let top, let lower):
        ThreadRows(model: model, threads: top)
        if !lower.drawsNothing {
          macLower(lower).padding(.top, top.isEmpty ? 0 : Self.gap)
        }
      case .byEnvironment(let groups):
        EnvironmentGroupsView(
          model: model, groups: groups,
          collapsed: Binding(
            get: { CollapsedEnvironments.parse(collapsedRaw) },
            set: { collapsedRaw = CollapsedEnvironments.encode($0) }))
      }
      if !layout.archived.isEmpty {
        ThreadRows(model: model, threads: layout.archived)
          .padding(.top, empty || layout.body.drawsAboveArchive ? Self.gap : 0)
      }
    }

    @ViewBuilder private func macLower(_ lower: ListLayout.Lower) -> some View {
      switch lower {
      case .rows(let threads, let tiny):
        ThreadRows(model: model, threads: threads, tiny: tiny)
      case .collapsed(let count, let working, let threads):
        VStack(spacing: 0) {
          StowedThreadsRow(
            text: ListLayout.collapsedLabel(count: count, working: working), working: working > 0,
            open: showsStowed
          ) { showsStowed.toggle() }
          .accessibilityIdentifier("collapsed-threads")
          if showsStowed { ThreadRows(model: model, threads: threads) }
        }
      case .hidden:
        // The sidebar draws Hidden's row, above the profile footer.
        EmptyView()
      }
    }
  #endif
}

/// Thread rows, touching: no gap between one row's fill and the next (the Mac's stacks).
struct ThreadRows: View {
  @Bindable var model: WorkspaceModel
  let threads: [ConversationThread]
  var tiny = false

  var body: some View {
    VStack(spacing: 0) { ForEach(threads) { ThreadRow(model: model, thread: $0, tiny: tiny) } }
  }
}

/// Hidden's row, "2 working" with the orbit, while agents run; activating it shows those threads
/// beneath it. The Mac pins it above the profile footer, outside the list's scroll view.
struct HiddenWorkingRows: View {
  @Bindable var model: WorkspaceModel
  let working: [ConversationThread]
  @Binding var open: Bool

  var body: some View {
    if let text = ListLayout.hiddenLabel(working: working.count) {
      VStack(spacing: 0) {
        StowedThreadsRow(text: text, working: true, open: open) { open.toggle() }
          .accessibilityIdentifier("hidden-working")
        if open { ThreadRows(model: model, threads: working) }
      }
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
    let empty = model.orderedThreads.isEmpty && layout.archived.isEmpty
    if empty {
      Text("No threads yet.")
        .llaSmallMuted()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    let hidden: [ConversationThread] = {
      if case .needsYouFirst(_, .hidden(let working)) = layout.body { return working }
      return []
    }()
    let drawn = layout.body.drawsAboveArchive
    Group {
      switch layout.body {
      case .needsYouFirst(let top, let lower):
        rows(top, gap: 0)
        let lowerGap = top.isEmpty ? 0 : gap
        switch lower {
        case .rows(let threads, let tiny):
          rows(threads, tiny: tiny, gap: lowerGap)
        case .collapsed(let count, let working, let threads) where count > 0:
          StowedThreadsRow(
            text: ListLayout.collapsedLabel(count: count, working: working), working: working > 0,
            open: showsStowed
          ) { showsStowed.toggle() }
          .accessibilityIdentifier("collapsed-threads")
          .modifier(PhoneRowChrome(gap: lowerGap))
          if showsStowed { rows(threads, gap: 0) }
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
        if showsStowed { rows(hidden, gap: 0) }
      }
    }
    .deleteThreadAlert(model: model, thread: $deleting)
  }

  /// Rows with their swipe actions; `gap` opens above the first.
  private func rows(_ threads: [ConversationThread], tiny: Bool = false, gap: CGFloat) -> some View {
    ForEach(threads) { thread in
      ThreadRow(model: model, thread: thread, tiny: tiny)
        .modifier(PhoneRowChrome(gap: thread.id == threads.first?.id ? gap : 0))
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
/// above it, outside its button (the 24 pt between the list's parts; a list has no spacer row shorter
/// than its least row height).
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
      .overlay(alignment: .trailing) { if hovering { newThreadButton } }
      .onHover { hovering = $0 }
      .padding(.horizontal, ThreadRow.fillInset - ThreadRow.sidebarPadding)
    #endif
    .accessibilityLabel(group.title)
    .accessibilityValue(Self.accessibilityValue(isCollapsed: isCollapsed, mostUrgent: group.mostUrgent))
    .accessibilityIdentifier("environment-header")
    #if os(macOS)
      // The hover button is out of reach of VoiceOver and the keyboard; the heading offers the same.
      .accessibilityAction(named: Self.newThreadTitle(group)) { openNewThread() }
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
    /// 28 by 28, centred on the marks' column (the mark's 12 pt box ends 8 pt inside the heading).
    private var newThreadButton: some View {
      Button(action: openNewThread) {
        Image(systemName: "square.and.pencil")
          .foregroundStyle(LLA.Color.ink)
          .frame(width: TopBarButton.side, height: TopBarButton.side)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .disabled(model.newThreadEntryReason != nil)
      .help(model.newThreadEntryReason ?? Self.newThreadTitle(group))
      .accessibilityLabel(Self.newThreadTitle(group))
      .accessibilityIdentifier("environment-new-thread")
      .padding(.trailing, ThreadRow.contentInset + LLA.Metrics.mark / 2 - TopBarButton.side / 2)
    }
  #endif
}

#if os(macOS)
  /// The Mac's "By environment": each group's heading, then its threads unless it is collapsed, 8 pt
  /// between groups. Plain stacks, not `List`: a List drew nothing in the macOS 26 split-view sidebar
  /// (see `SidebarView`). A heading's context menu keeps Rename, Add Folder, and (for a manual one)
  /// Delete until the environment form gives them a home.
  struct EnvironmentGroupsView: View {
    @Bindable var model: WorkspaceModel
    let groups: [ListLayout.Group]
    @Binding var collapsed: Set<String>
    @State private var renaming: WorkEnvironment?
    @State private var deleting: WorkEnvironment?
    @State private var folderTarget: WorkEnvironment?
    @State private var choosingFolder = false

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(groups) { group in
          let isCollapsed = collapsed.contains(group.id)
          VStack(alignment: .leading, spacing: 0) {
            EnvironmentHeading(model: model, group: group, isCollapsed: isCollapsed) {
              if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
            .contextMenu { environmentActions(group) }
            if !isCollapsed { ThreadRows(model: model, threads: group.threads) }
          }
          .padding(.top, group.id == groups.first?.id ? 0 : EnvironmentHeading.groupGap)
        }
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

    @ViewBuilder private func environmentActions(_ group: ListLayout.Group) -> some View {
      if let environment = model.environments.first(where: { $0.id == group.environmentId }) {
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
#endif
