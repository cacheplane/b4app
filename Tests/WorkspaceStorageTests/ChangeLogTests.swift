import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seed(_ db: WorkspaceDatabase) throws -> (thread: ConversationThread, turn: Turn) {
  _ = try db.insertConnection(
    Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
  let thread = try db.insertThread(
    ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "thr_1", nativeScope: "acct", title: "First",
      context: "/tmp/p"))
  let turn = try db.insertTurn(Turn(id: "u1", threadId: "t1", operationId: "op1"))
  _ = try db.upsertDisplayItem(
    threadId: "t1", turnId: "u1", nativeItemId: nil, role: .user, type: "userMessage",
    payload: ["text": "hello"],
    provenance: .live)
  _ = try db.upsertDisplayItem(
    threadId: "t1", turnId: "u1", nativeItemId: "a1", role: .assistant, type: "agentMessage",
    payload: ["text": "hi", "nested": ["ok": true, "n": 2]], provenance: .live)
  _ = try db.saveDraft(threadId: "t1", text: "unsent")
  return (thread, turn)
}

@Suite struct ChangeLogTests {
  @Test func everyWriteLeavesChangesAndTheLogReplaysIntoAnEqualStore() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, turn) = try seed(source)
    _ = try source.updateThread(id: thread.id) {
      $0.title = "Renamed"
      $0.pinned = true
    }
    _ = try source.updateTurn(id: turn.id) {
      $0.status = .terminal
      $0.outcome = .completed
    }
    try source.deleteDraft(threadId: thread.id)

    let changes = try source.changes(after: 0)
    #expect(
      changes.filter { $0.op == "insert" }.map(\.table).sorted() == [
        "connections", "displayItems", "displayItems", "drafts", "threads", "turns",
      ])
    let titleUpdates = changes.filter { $0.op == "update" && $0.table == "threads" && $0.column == "title" }
    #expect(titleUpdates.map { $0.value?.stringValue } == ["Renamed"])
    #expect(
      changes.contains {
        $0.op == "update" && $0.table == "turns" && $0.column == "status"
          && $0.value?.stringValue == "terminal"
      })
    #expect(changes.contains { $0.op == "delete" && $0.table == "drafts" && $0.rowId == thread.id })
    #expect(changes.allSatisfy { $0.deviceId == "local" && !$0.synced && $0.wall > 1_700_000_000_000 })
    #expect(try source.unsyncedChangeCount() == changes.count)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.replay(changes) == changes.count)
    #expect(try target.listConnections() == source.listConnections())
    #expect(
      try target.listThreads(ThreadFilter(includeArchived: true))
        == source.listThreads(ThreadFilter(includeArchived: true)))
    #expect(try target.turns(threadId: thread.id) == source.turns(threadId: thread.id))
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
    #expect(try target.draft(threadId: thread.id) == nil)
    // A replay records nothing of its own, and replaying twice changes nothing.
    #expect(try target.changes(after: 0).isEmpty)
    #expect(try target.replay(changes) == changes.count)
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
  }

  /// An update in the change log stores the column's new value, which can be any JSON value: a
  /// string, a boolean, a number, null, or an object. Every one must survive backup and restore.
  @Test func exportAndRestoreRoundTripKeepsScalarChangeValues() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, turn) = try seed(source)
    _ = try source.updateThread(id: thread.id) {
      $0.title = "{\"looks\": [\"like\", \"json\"]}"  // a string that must stay a string
      $0.pinned = true  // boolean
      $0.context = nil  // JSON null
    }
    _ = try source.updateTurn(id: turn.id) { $0.status = .terminal }  // "terminal"
    _ = try source.updateConnection(id: "c1") { $0.profileRevision = 7 }  // number
    _ = try source.upsertDisplayItem(
      threadId: thread.id, turnId: turn.id, nativeItemId: "a1", role: .assistant, type: "agentMessage",
      payload: ["text": "hi there", "nested": ["ok": false, "list": [1, 2.5, "x", nil]]], provenance: .live)
    let updates = try source.changes(after: 0).filter { $0.op == "update" }
    #expect(
      updates.contains {
        $0.column == "title" && $0.value?.stringValue == "{\"looks\": [\"like\", \"json\"]}"
      })
    #expect(updates.contains { $0.column == "pinned" && $0.value == .bool(true) })
    #expect(updates.contains { $0.column == "status" && $0.value?.stringValue == "terminal" })
    #expect(updates.contains { $0.column == "profileRevision" && $0.value == .number(7) })
    #expect(updates.contains { $0.column == "context" && $0.value == nil })

    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    let summary = try source.export(to: path)
    let target = try WorkspaceDatabase.temporary()
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.changes(after: 0) == source.changes(after: 0))
    #expect(try target.listThreads() == source.listThreads())
    #expect(try target.listConnections() == source.listConnections())
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
    // The JSON null is a jsonb null in both stores, not an SQL NULL.
    let nullTypes = """
      SELECT jsonb_typeof("value") AS "t" FROM "changes" WHERE "op" = 'update' AND "column" = 'context'
      """
    for db in [source, target] {
      #expect(try db.read { try $0.execute(nullTypes).rows.map { $0.text("t") } } == ["null"])
    }
  }

  /// A version 1 archive carried every jsonb cell as the parsed value, so a scalar string arrived bare
  /// and failed to restore. The reader still accepts such archives, re-encoding each value as JSON.
  @Test func restoreReadsAVersionOneArchive() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, turn) = try seed(source)
    _ = try source.updateThread(id: thread.id) {
      $0.title = "Renamed"
      $0.pinned = true
    }
    _ = try source.updateTurn(id: turn.id) { $0.status = .terminal }
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    let summary = try source.export(to: path)

    // Rewrite the archive the way the version 1 exporter wrote it: jsonb text parsed into values.
    let jsonColumns: Set<String> = ["value", "payload", "capabilities", "routes"]
    var lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    var header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
    #expect(header["version"] as? Int == 2)
    header["version"] = 1
    lines[0] = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
    for index in lines.indices.dropFirst() {
      var line = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as! [String: Any]
      var row = line["row"] as! [String: Any]
      for column in jsonColumns {
        guard let text = row[column] as? String else { continue }
        row[column] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
      }
      line["row"] = row
      lines[index] = String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.changes(after: 0) == source.changes(after: 0))
    #expect(try target.listThreads() == source.listThreads())
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
  }

  @Test func exportAndRestoreRoundTrip() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, _) = try seed(source)
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    let summary = try source.export(to: path)
    #expect(summary.rows > 6)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.listThreads() == source.listThreads())
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
    #expect(try target.draft(threadId: thread.id)?.text == "unsent")
    #expect(try target.changes(after: 0).count == source.changes(after: 0).count)
    // Not empty any more: refused without --replace, accepted with it.
    #expect(throws: (any Error).self) { try target.restore(from: path) }
    #expect(try target.restore(from: path, replace: true).rows == summary.rows)
    #expect(try target.tableCounts()["threads"] == 1)
    // Clearing and reloading record nothing: the log is exactly the archive's.
    #expect(try target.changes(after: 0).count == source.changes(after: 0).count)
  }

  @Test func restoreMarksEveryChangeUnsyncedSoALaterJoinUploadsIt() throws {
    let source = try WorkspaceDatabase.temporary()
    _ = try seed(source)
    let total = try source.changes(after: 0).count
    try source.markSynced(through: Int.max)
    #expect(try source.unsyncedChangeCount() == 0)
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    try source.export(to: path)

    let target = try WorkspaceDatabase.temporary()
    try target.restore(from: path)
    #expect(total > 0)
    #expect(try target.changes(after: 0).count == total)
    #expect(try target.unsyncedChangeCount() == total)
  }
}
