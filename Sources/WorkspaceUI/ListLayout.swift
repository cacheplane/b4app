import Foundation
import WorkspaceProtocol

/// What the thread list draws, from the threads and the view settings this device shows; both
/// platforms draw from it. "Needs you first" (decision 6) is the top list (approve, reply, failed,
/// finished), then the lower list (working, then quiet) drawn by `quietThreads` (decision 7); "By
/// environment" (decision 8) is one group per environment with live threads, by name, "No folder"
/// last. With "Show archived" on, the archived threads are a final block in either arrangement
/// (decision 10).
///
/// The selected thread (`Selection`) is ordered by the most urgent state it has had since it was
/// selected, so the thread being read does not move under the owner, and under Collapsed or Hidden it is
/// never stowed (the owner's changes of 2026-11-11, D-206).
struct ListLayout: Equatable {
  /// The selected thread and the hold the model keeps for it: the most urgent state it has had since it
  /// was selected (`WorkspaceModel.selectionHold`), nil while it is not in the live list. The list orders
  /// it by `min(its state now, held)`; its mark and title always show its state now.
  struct Selection: Equatable {
    var threadId: String
    var held: ThreadState?
  }

  /// One environment's live threads in state order (`Attention.ordered`), or "No folder"
  /// (`environmentId` nil, `id` `noFolderId`).
  struct Group: Equatable, Identifiable {
    /// The environment id, or `noFolderId`; also the key `CollapsedEnvironments` keeps.
    var id: String
    var title: String
    var environmentId: String?
    var threads: [ConversationThread]

    /// "No folder"'s id: threads without an environment, or with one this device does not know.
    static let noFolderId = "other"
    static let noFolderTitle = "No folder"

    /// The most urgent real state among its threads, which a collapsed heading marks; nil when empty.
    /// Not simply the first thread's: a held selected thread can lead with a quieter state.
    var mostUrgent: ThreadState? { threads.map(Attention.state(of:)).min() }
  }

  /// The threads that do not need the owner, as `quietThreads` draws them.
  enum Lower: Equatable {
    /// Small or Tiny: every row.
    case rows([ConversationThread], tiny: Bool)
    /// One row standing for the stowed threads, working ones included; it opens to show them.
    /// `selected` is the selected thread when it would otherwise be stowed: an ordinary row where the
    /// lower list starts, above the stowed row, and in neither `count`, `working`, nor `threads`.
    case collapsed(
      count: Int, working: Int, threads: [ConversationThread], selected: ConversationThread? = nil)
    /// Nothing but the working threads behind one row, while there are any; quiet threads are not shown.
    /// `selected` is the selected thread when it would otherwise be hidden or stowed, drawn as for
    /// Collapsed and not in `working`.
    case hidden(working: [ConversationThread], selected: ConversationThread? = nil)

    /// Nothing at all is drawn: no rows, nothing stowed, nothing working, no selected row.
    var drawsNothing: Bool {
      switch self {
      case .rows(let threads, _): threads.isEmpty
      case .collapsed(let count, _, _, let selected): count == 0 && selected == nil
      case .hidden(let working, let selected): working.isEmpty && selected == nil
      }
    }

    /// Something is drawn in the list's flow: a row, Collapsed's row, or the selected row. Hidden's own
    /// row sits apart from the list (above the Mac's profile footer, at the foot of the phone's list).
    var drawsInList: Bool {
      switch self {
      case .hidden(_, let selected): selected != nil
      case .rows, .collapsed: !drawsNothing
      }
    }

    /// The selected thread drawn apart from the stowed ones (Collapsed and Hidden only).
    var selected: ConversationThread? {
      switch self {
      case .rows: nil
      case .collapsed(_, _, _, let selected), .hidden(_, let selected): selected
      }
    }
  }

  enum Body: Equatable {
    case needsYouFirst(top: [ConversationThread], lower: Lower)
    case byEnvironment([Group])

    /// Nothing is drawn: the arrangement has no row, collapsed or hidden row, or group to show.
    var drawsNothing: Bool {
      switch self {
      case .needsYouFirst(let top, let lower): top.isEmpty && lower.drawsNothing
      case .byEnvironment(let groups): groups.isEmpty
      }
    }

    /// Something is drawn in the list's flow above the archived block: a row, Collapsed's row, the
    /// selected row, or a group. Hidden's row is not counted; it sits apart from the list (above the
    /// Mac's profile footer, at the foot of the phone's list).
    var drawsAboveArchive: Bool {
      switch self {
      case .needsYouFirst(let top, let lower): !top.isEmpty || lower.drawsInList
      case .byEnvironment(let groups): !groups.isEmpty
      }
    }
  }

  var body: Body
  /// Archived threads, newest first; empty unless `showArchived`.
  var archived: [ConversationThread]

  /// `threads` are every thread the list may show, archived ones included (the connection filter is
  /// applied before). Inside each state a pinned thread comes first, then newest activity
  /// (`Attention.ordered`); a pin never lifts a thread above a more urgent state. The selected thread
  /// ranks by `rank(_:selection:)` and, under Collapsed or Hidden, is never stowed.
  static func build(
    threads: [ConversationThread], environments: [WorkEnvironment], settings: ViewSettings,
    selection: Selection? = nil
  ) -> ListLayout {
    let rank = { (thread: ConversationThread) in Self.rank(thread, selection: selection) }
    let live = Attention.ordered(threads.filter { !$0.archived }, by: rank)
    let archived = settings.showArchived ? newestFirst(threads.filter(\.archived)) : []
    switch settings.arrangement {
    case .needsYouFirst:
      let top = live.filter { rank($0).isTopList }
      let rest = live.filter { !rank($0).isTopList }
      // The selected thread is drawn, not stowed: it leaves the stowed set and its counts.
      let selected = rest.first { $0.id == selection?.threadId }
      let stowed = rest.filter { $0.id != selection?.threadId }
      let working = stowed.filter { Attention.state(of: $0) == .working }
      let lower: Lower =
        switch settings.quietThreads {
        case .small: .rows(rest, tiny: false)
        case .tiny: .rows(rest, tiny: true)
        case .collapsed:
          .collapsed(count: stowed.count, working: working.count, threads: stowed, selected: selected)
        case .hidden: .hidden(working: working, selected: selected)
        }
      return ListLayout(body: .needsYouFirst(top: top, lower: lower), archived: archived)
    case .byEnvironment:
      let groups = groups(live, environments: environments)
      return ListLayout(body: .byEnvironment(groups), archived: archived)
    }
  }

  /// The state the list ranks a thread by: its real state, or for the selected thread the more urgent of
  /// that and its hold. The mark, the title, the badge, and the arrivals use the real state.
  static func rank(_ thread: ConversationThread, selection: Selection?) -> ThreadState {
    let state = Attention.state(of: thread)
    guard let selection, selection.threadId == thread.id, let held = selection.held else { return state }
    return min(state, held)
  }

  /// One group per environment that has a live thread, then "No folder" for threads without an
  /// environment or with one not in `environments` (not loaded yet, or deleted). Groups are ordered by
  /// name ignoring case, then id, so the order never moves with thread states; `live` is already in
  /// state order, which each group keeps. An environment without live threads has no group.
  private static func groups(_ live: [ConversationThread], environments: [WorkEnvironment]) -> [Group] {
    let names = Dictionary(
      environments.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    var members: [String: [ConversationThread]] = [:]
    var loose: [ConversationThread] = []
    for thread in live {
      if let id = thread.environmentId, names[id] != nil {
        members[id, default: []].append(thread)
      } else {
        loose.append(thread)
      }
    }
    let named = members.map { id, threads in
      Group(id: id, title: names[id] ?? id, environmentId: id, threads: threads)
    }
    .sorted { lhs, rhs in
      switch lhs.title.caseInsensitiveCompare(rhs.title) {
      case .orderedAscending: true
      case .orderedDescending: false
      case .orderedSame: lhs.id < rhs.id
      }
    }
    let noFolder =
      loose.isEmpty
      ? [] : [Group(id: Group.noFolderId, title: Group.noFolderTitle, environmentId: nil, threads: loose)]
    return named + noFolder
  }

  /// The mode whose row stows threads now: Collapsed with something below the top list, or Hidden while
  /// something works; nil under Small or Tiny, under "By environment", and when nothing is stowed.
  var stowing: ViewSettings.QuietThreads? {
    switch body {
    case .needsYouFirst(_, .collapsed(let count, _, _, _)) where count > 0: .collapsed
    case .needsYouFirst(_, .hidden(let working, _)) where !working.isEmpty: .hidden
    default: nil
    }
  }

  /// Whether the opened stowed rows (per window, never stored) stay open as the list goes from stowing
  /// `old` to stowing `new`: only while the same row still stows something. A change of arrangement or
  /// mode, or the stowed set emptying, closes them, so the row never comes back already open.
  static func keepsStowedOpen(
    from old: ViewSettings.QuietThreads?, to new: ViewSettings.QuietThreads?
  ) -> Bool {
    old != nil && old == new
  }

  /// Whether the list prints "No threads yet.": no live thread (`hasLiveThreads`, before Hidden leaves
  /// the quiet ones out) and no archived row drawn.
  func saysNoThreadsYet(hasLiveThreads: Bool) -> Bool { !hasLiveThreads && archived.isEmpty }

  /// The collapsed row's text: "9 more", and ", 2 working" while any of them runs.
  static func collapsedLabel(count: Int, working: Int) -> String {
    working > 0 ? "\(count) more, \(working) working" : "\(count) more"
  }

  /// The hidden row's text, "2 working"; nil when nothing is working, and the row is absent.
  static func hiddenLabel(working: Int) -> String? {
    working > 0 ? "\(working) working" : nil
  }

  /// Newest activity first (creation for a thread without any), ties by id.
  private static func newestFirst(_ threads: [ConversationThread]) -> [ConversationThread] {
    threads.sorted { lhs, rhs in
      let l = lhs.activity?.lastActivityAt ?? lhs.createdAt
      let r = rhs.activity?.lastActivityAt ?? rhs.createdAt
      return l != r ? l > r : lhs.id < rhs.id
    }
  }
}
