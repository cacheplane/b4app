import Foundation
import WorkspaceProtocol

/// What the thread list draws, from the threads and the view settings this device shows; both
/// platforms draw from it. "Needs you first" (decision 6) is the top list (approve, reply, failed,
/// finished), then the lower list (working, then quiet) drawn by `quietThreads` (decision 7); "By
/// environment" (decision 8) is one group per environment with live threads, by name, "No folder"
/// last. With "Show archived" on, the archived threads are a final block in either arrangement
/// (decision 10).
struct ListLayout: Equatable {
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

    /// The state of its most urgent thread (the first), which a collapsed heading marks; nil when empty.
    var mostUrgent: ThreadState? { threads.first.map(Attention.state(of:)) }
  }

  /// The threads that do not need the owner, as `quietThreads` draws them.
  enum Lower: Equatable {
    /// Small or Tiny: every row.
    case rows([ConversationThread], tiny: Bool)
    /// One row standing for the stowed threads, working ones included; it opens to show them.
    case collapsed(count: Int, working: Int, threads: [ConversationThread])
    /// Nothing but the working threads behind one row, while there are any; quiet threads are not shown.
    case hidden(working: [ConversationThread])

    /// Nothing at all is drawn: no rows, nothing stowed, nothing working.
    var drawsNothing: Bool {
      switch self {
      case .rows(let threads, _): threads.isEmpty
      case .collapsed(let count, _, _): count == 0
      case .hidden(let working): working.isEmpty
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

    /// Something is drawn in the list's flow above the archived block: a row, Collapsed's row, or a
    /// group. Hidden's row is not counted; it sits apart from the list (above the Mac's profile
    /// footer, at the foot of the phone's list).
    var drawsAboveArchive: Bool {
      switch self {
      case .needsYouFirst(let top, .hidden): !top.isEmpty
      case .needsYouFirst(let top, let lower): !top.isEmpty || !lower.drawsNothing
      case .byEnvironment(let groups): !groups.isEmpty
      }
    }
  }

  var body: Body
  /// Archived threads, newest first; empty unless `showArchived`.
  var archived: [ConversationThread]

  /// `threads` are every thread the list may show, archived ones included (the connection filter is
  /// applied before). Inside each state a pinned thread comes first, then newest activity
  /// (`Attention.ordered`); a pin never lifts a thread above a more urgent state.
  static func build(
    threads: [ConversationThread], environments: [WorkEnvironment], settings: ViewSettings
  ) -> ListLayout {
    let live = Attention.ordered(threads.filter { !$0.archived })
    let archived = settings.showArchived ? newestFirst(threads.filter(\.archived)) : []
    switch settings.arrangement {
    case .needsYouFirst:
      let top = live.filter { Attention.state(of: $0).isTopList }
      let rest = live.filter { !Attention.state(of: $0).isTopList }
      let working = rest.filter { Attention.state(of: $0) == .working }
      let lower: Lower =
        switch settings.quietThreads {
        case .small: .rows(rest, tiny: false)
        case .tiny: .rows(rest, tiny: true)
        case .collapsed: .collapsed(count: rest.count, working: working.count, threads: rest)
        case .hidden: .hidden(working: working)
        }
      return ListLayout(body: .needsYouFirst(top: top, lower: lower), archived: archived)
    case .byEnvironment:
      let groups = groups(live, environments: environments)
      return ListLayout(body: .byEnvironment(groups), archived: archived)
    }
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
