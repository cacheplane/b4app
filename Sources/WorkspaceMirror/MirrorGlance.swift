import Foundation
import WorkspaceProtocol

/// One line on the widget: a thread, how urgent it is, and the project it belongs to.
public struct GlanceRow: Sendable, Equatable, Codable {
  public var threadId: String
  public var title: String
  public var projectName: String?
  public var band: AttentionBand
  public var pinned: Bool

  public init(threadId: String, title: String, projectName: String?, band: AttentionBand, pinned: Bool) {
    self.threadId = threadId
    self.title = title
    self.projectName = projectName
    self.band = band
    self.pinned = pinned
  }
}

/// What the widget shows: the top threads, whether this phone is linked to a hub, and how old the data
/// is (`asOf` is the link's last successful sync).
public struct Glance: Sendable, Equatable {
  public var linked: Bool
  public var rows: [GlanceRow]
  public var asOf: Date?

  /// Past this age the widget says "as of <time>".
  public static let staleAfter: TimeInterval = 300
  /// How long after a timeline is built the widget asks to be reloaded.
  public static let reloadAfter: TimeInterval = 900

  public init(linked: Bool, rows: [GlanceRow], asOf: Date?) {
    self.linked = linked
    self.rows = rows
    self.asOf = asOf
  }

  /// Data with no date (never synced, or not linked) has nothing to be old, so it is not stale.
  public func isStale(at now: Date) -> Bool {
    guard let asOf else { return false }
    return now.timeIntervalSince(asOf) > Self.staleAfter
  }

  /// "as of 3:42 PM" in the viewer's locale when stale, else nil.
  public func staleLabel(at now: Date) -> String? {
    guard isStale(at: now), let asOf else { return nil }
    return "as of " + asOf.formatted(date: .omitted, time: .shortened)
  }

  /// The timeline's entry dates: now, plus the moment the data turns stale when that is still ahead.
  public func entryDates(now: Date) -> [Date] {
    guard let asOf else { return [now] }
    let staleAt = asOf.addingTimeInterval(Self.staleAfter)
    return staleAt > now ? [now, staleAt] : [now]
  }

  public func reloadDate(now: Date) -> Date { now.addingTimeInterval(Self.reloadAfter) }
}

public enum MirrorGlance {
  /// The first `limit` non-archived threads in attention order (pinned first), with project names, and
  /// the link's state and last sync.
  public static func load(store: MirrorStore, limit: Int = 3) throws -> Glance {
    let threads = Attention.ordered(try store.threads(includeArchived: false, connectionId: nil, query: nil))
    let names = Dictionary(
      try store.projects().map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    let rows = threads.prefix(max(limit, 0)).map { thread in
      GlanceRow(
        threadId: thread.id, title: thread.title,
        projectName: thread.projectId.flatMap { names[$0] },
        band: Attention.band(of: thread), pinned: thread.pinned)
    }
    let link = try store.link()
    return Glance(
      linked: link != nil, rows: Array(rows), asOf: link?.lastSyncAt.flatMap(Timestamp.date(from:)))
  }

  /// Opens the file read-only and reads it. Any failure (no file, an older schema, a locked or damaged
  /// file) answers the unlinked, empty glance, which the widget shows as "Open Agent Workspace".
  public static func load(path: String, limit: Int = 3) -> Glance {
    let empty = Glance(linked: false, rows: [], asOf: nil)
    guard let store = try? MirrorStore.openReadOnly(path: path) else { return empty }
    return (try? load(store: store, limit: limit)) ?? empty
  }
}
