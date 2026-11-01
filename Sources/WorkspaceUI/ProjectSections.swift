import Foundation
import WorkspaceProtocol

/// Which threads the list shows: everything, one project, the threads without a project, or the
/// archive.
public enum ProjectFilter: Sendable, Hashable {
  case all
  case project(String)
  case other
  case archived
}

/// One group of the Mac sidebar: a project's threads, or "Other" for threads without a project.
public struct ProjectSection: Identifiable, Sendable, Equatable {
  /// The project id, or `"other"`.
  public var id: String
  public var title: String
  public var threads: [ConversationThread]

  public static let otherId = "other"

  public init(id: String, title: String, threads: [ConversationThread]) {
    self.id = id
    self.title = title
    self.threads = threads
  }

  /// Groups `threads` (pinned ones already removed) by project. A thread whose project is not in
  /// `projects` (not loaded yet, or deleted) goes to "Other". Threads inside a section keep
  /// `Attention.ordered`; project sections are ordered by their best thread's band, then its activity
  /// (newest first), then title, then id, so a project with a waiting approval rises. "Other" is
  /// always last, whatever it holds.
  static func build(threads: [ConversationThread], projects: [Project]) -> [ProjectSection] {
    let names = Dictionary(projects.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    var groups: [String: [ConversationThread]] = [:]
    for thread in threads {
      let key = thread.projectId.flatMap { names[$0] == nil ? nil : $0 } ?? otherId
      groups[key, default: []].append(thread)
    }
    let sections = groups.filter { $0.key != otherId }.map { key, members in
      ProjectSection(id: key, title: names[key] ?? "Other", threads: Attention.ordered(members))
    }
    let other = groups[otherId].map {
      ProjectSection(id: otherId, title: "Other", threads: Attention.ordered($0))
    }
    func rank(_ section: ProjectSection) -> (band: AttentionBand, at: String) {
      guard let best = section.threads.first else { return (.quiet, "") }
      return (Attention.band(of: best), best.activity?.lastActivityAt ?? best.createdAt)
    }
    let sorted = sections.sorted { lhs, rhs in
      let l = rank(lhs)
      let r = rank(rhs)
      if l.band != r.band { return l.band < r.band }
      if l.at != r.at { return l.at > r.at }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.id < rhs.id
    }
    return sorted + (other.map { [$0] } ?? [])
  }
}
