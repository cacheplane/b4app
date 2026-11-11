import Foundation
import WorkspaceProtocol

/// What the thread list draws, from the threads and the view settings this device shows; both
/// platforms draw from it. "Needs you first" (decision 6) is the top list (approve, reply, failed,
/// finished), then the lower list (working, then quiet) drawn by `quietThreads` (decision 7); "By
/// environment" is one group per environment. With "Show archived" on, the archived threads are a
/// final block in either arrangement (decision 10).
struct ListLayout: Equatable {
  /// One environment's live threads, or "No folder" (`environmentId` nil).
  struct Group: Equatable, Identifiable {
    var id: String
    var title: String
    var environmentId: String?
    var threads: [ConversationThread]
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
      // Until the by-environment arrangement is drawn as its own (the next task), its groups are the
      // Mac's environment sections.
      let groups = EnvironmentSection.build(threads: live, environments: environments).map {
        Group(
          id: $0.id, title: $0.title, environmentId: $0.id == EnvironmentSection.otherId ? nil : $0.id,
          threads: $0.threads)
      }
      return ListLayout(body: .byEnvironment(groups), archived: archived)
    }
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
