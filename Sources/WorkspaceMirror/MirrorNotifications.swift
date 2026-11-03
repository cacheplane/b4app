import Foundation
import WorkspaceProtocol

extension MirrorStore {
  /// The subset of `keys` whose notification still announces something open, so the app removes the
  /// delivered ones that are not in it (the backstop for a withdrawal push that never arrived).
  ///
  /// - `request:<id>`: the request exists and is `pending`, and its thread is not deleted.
  /// - `turn:<id>`: the turn exists, its thread is not deleted, and the thread's `readTurnId` is nil
  ///   or names a turn created before it (`createdAt`, then `id`, bytewise, as the hub compares).
  ///   A read turn the mirror does not hold cannot be compared and leaves the notification up.
  /// - Archiving a thread ends neither kind of notification (the hub withdraws only when a request is
  ///   answered or expires, when a turn is read, or when the thread or request is deleted); it only
  ///   takes the thread out of the badge and the list.
  /// - Anything else (an unknown id, another prefix, a malformed key) is not outstanding.
  public func stillOutstanding(keys: [String]) throws -> Set<String> {
    try locked {
      var outstanding = Set<String>()
      for key in Set(keys) {
        let isOutstanding: Bool
        if let id = Self.id(in: key, prefix: "request:") {
          isOutstanding = try requestIsOutstanding(id)
        } else if let id = Self.id(in: key, prefix: "turn:") {
          isOutstanding = try turnIsOutstanding(id)
        } else {
          isOutstanding = false
        }
        if isOutstanding { outstanding.insert(key) }
      }
      return outstanding
    }
  }

  /// How many threads need the owner: non-archived, non-deleted threads in the needs-input or unread
  /// band. It reads the threads the list reads, so `activity` is populated and the band is the one
  /// the list shows. This is the app icon's badge.
  public func needsYouCount() throws -> Int {
    try threads(includeArchived: false, connectionId: nil, query: nil)
      .filter { [.needsInput, .unread].contains(Attention.band(of: $0)) }
      .count
  }

  private static func id(in key: String, prefix: String) -> String? {
    guard key.hasPrefix(prefix) else { return nil }
    let id = String(key.dropFirst(prefix.count))
    return id.isEmpty ? nil : id
  }

  private func requestIsOutstanding(_ id: String) throws -> Bool {
    let rows = try query(
      """
      SELECT r."state" = 'pending' AND t."userDeletedAt" IS NULL AS "open"
      FROM "runtimeRequests" r JOIN "threads" t ON t."id" = r."threadId" WHERE r."id" = ?
      """, [.text(id)])
    return rows.first?["open"] == .integer(1)
  }

  private func turnIsOutstanding(_ id: String) throws -> Bool {
    // `isRead`: the thread's read turn exists and is this turn or a later one. Plain `>` on text is
    // SQLite's default BINARY collation, the same bytewise order the hub uses.
    let rows = try query(
      """
      SELECT t."userDeletedAt" IS NULL AS "live",
        (rt."id" IS NOT NULL AND (rt."createdAt" > u."createdAt"
          OR (rt."createdAt" = u."createdAt" AND rt."id" >= u."id"))) AS "isRead"
      FROM "turns" u JOIN "threads" t ON t."id" = u."threadId"
      LEFT JOIN "turns" rt ON rt."id" = t."readTurnId" WHERE u."id" = ?
      """, [.text(id)])
    guard let row = rows.first else { return false }
    return row["live"] == .integer(1) && row["isRead"] != .integer(1)
  }
}
