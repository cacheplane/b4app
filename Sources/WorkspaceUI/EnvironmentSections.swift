import Foundation
import WorkspaceProtocol

/// Which threads the list shows: everything, one environment, the threads without an environment ("No
/// folder"), or the archive.
public enum EnvironmentFilter: Sendable, Hashable {
  case all
  case environment(String)
  case other
  case archived
}

/// One group of the Mac sidebar: an environment's threads, or "No folder" for threads without an environment.
public struct EnvironmentSection: Identifiable, Sendable, Equatable {
  /// The environment id, or `"other"`.
  public var id: String
  public var title: String
  public var threads: [ConversationThread]

  public static let otherId = "other"
  /// The heading of the threads without an environment.
  public static let noFolderTitle = "No folder"

  public init(id: String, title: String, threads: [ConversationThread]) {
    self.id = id
    self.title = title
    self.threads = threads
  }

  /// Groups `threads` (pinned ones already removed) by environment. A thread whose environment is not in
  /// `environments` (not loaded yet, or deleted) goes to "No folder". Threads inside a section keep
  /// `Attention.ordered`; environment sections are ordered by their most urgent thread's state (their
  /// first thread's), then its activity (newest first), then title, then id, so an environment with a
  /// waiting approval rises. "No folder" is always last, whatever it holds.
  static func build(threads: [ConversationThread], environments: [WorkEnvironment]) -> [EnvironmentSection] {
    let names = Dictionary(
      environments.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    var groups: [String: [ConversationThread]] = [:]
    for thread in threads {
      let key = thread.environmentId.flatMap { names[$0] == nil ? nil : $0 } ?? otherId
      groups[key, default: []].append(thread)
    }
    let sections = groups.filter { $0.key != otherId }.map { key, members in
      EnvironmentSection(id: key, title: names[key] ?? noFolderTitle, threads: Attention.ordered(members))
    }
    let other = groups[otherId].map {
      EnvironmentSection(id: otherId, title: noFolderTitle, threads: Attention.ordered($0))
    }
    func rank(_ section: EnvironmentSection) -> (state: ThreadState, at: String) {
      guard let best = section.threads.first else { return (.quiet, "") }
      return (Attention.state(of: best), best.activity?.lastActivityAt ?? best.createdAt)
    }
    let sorted = sections.sorted { lhs, rhs in
      let l = rank(lhs)
      let r = rank(rhs)
      if l.state != r.state { return l.state < r.state }
      if l.at != r.at { return l.at > r.at }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.id < rhs.id
    }
    return sorted + (other.map { [$0] } ?? [])
  }
}
