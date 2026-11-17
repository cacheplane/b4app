import Foundation
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceStorage

/// Historical rows are cache facts, inserted only into this test host's owned account database.
/// No legacy endpoint, provider, Node process or Agent Protocol client is started by this seed.
enum B4SmokeSeed {
  static let threadId = "smoke-historical-b4"
  static let connectionId = "smoke-historical-connection"
  static let draft = "  Keep this historical draft exactly.  "

  static func create(
    root: URL, client: WorkspaceClient, database: WorkspaceDatabase, fake: String
  )
    async throws -> String
  {
    let current = try await client.request(
      ConnectionAdd.self, .init(kind: .codex, label: "Current fixture runtime", executablePath: fake),
      options: .init(operationId: UUID().uuidString)
    ).connection
    let thread = try await client.request(
      ThreadCreate.self,
      .init(
        connectionId: current.id, workingDirectory: root.appendingPathComponent("work").path,
        title: "Current native fixture"),
      options: .init(operationId: UUID().uuidString)
    ).thread
    _ = try await client.request(
      DraftSave.self, .init(threadId: thread.id, text: "partial"),
      options: .init(operationId: UUID().uuidString))

    let at = "2026-11-01T00:00:00.000Z"
    let scope = "opaque/old-scope#b4"
    let connection = try database.insertConnection(
      Connection(
        id: connectionId, kind: .b4, label: "Historical cached B4", target: "https://example.invalid/old",
        routeKey: "/cached#agent", b4Mode: .remote, nativeScope: scope,
        capabilities: Dictionary(uniqueKeysWithValues: CapabilityKey.allCases.map { ($0, .supported) }),
        status: .ready, authStatus: .notRequired, createdAt: at, updatedAt: at))
    _ = try database.insertThread(
      ConversationThread(
        id: threadId, connectionId: connection.id, nativeThreadId: "opaque/native/thread#old",
        nativeScope: scope, title: "Historical B4 cache fixture", context: "/cached#agent",
        createdAt: at, updatedAt: at))
    let turn = try database.insertTurn(
      Turn(
        id: "smoke-historical-turn", threadId: threadId, operationId: "opaque/old-operation",
        nativeTurnId: "opaque/native/turn#old", status: .reconciling, submission: .unknown,
        createdAt: at, updatedAt: at))
    let payloads: [(String, DisplayItemRole, String, JSONValue)] = [
      ("text", .assistant, "agentMessage", ["text": "Historical cached text remains readable."]),
      (
        "tool", .tool, "commandExecution",
        [
          "command": "cached lookup", "status": "completed", "aggregatedOutput": "cached-output",
          "opaque": ["namespace": ["old", "tool"], "retained": true],
        ]
      ),
      (
        "task", .tool, "taskList",
        [
          "type": "taskList", "status": "completed",
          "steps": [["text": "Historical task remains unresolved", "status": "inProgress"]],
          "opaque": ["namespace": ["old", "task"], "retained": true],
        ]
      ),
    ]
    for (index, entry) in payloads.enumerated() {
      _ = try database.insertDisplayItem(
        DisplayItem(
          id: "smoke-historical-\(entry.0)", threadId: threadId, turnId: turn.id,
          nativeItemId: "opaque/native/item#\(entry.0)", role: entry.1, type: entry.2, payload: entry.3,
          sequence: index, provenance: .cache, createdAt: at))
    }
    let requests: [(RuntimeRequestKind, JSONValue)] = [
      (
        .commandApproval,
        [
          "answerable": true, "request": ["command": "cached approval", "cwd": "/old"],
          "opaque": ["keep": true],
        ]
      ),
      (
        .userQuestion,
        [
          "answerable": true,
          "request": [
            "questions": [
              [
                "id": "old-choice", "header": "Historical choice",
                "question": "Keep the old choice?", "options": [], "isOther": true,
                "isSecret": false,
              ]
            ]
          ], "opaque": ["keep": true],
        ]
      ),
    ]
    for (kind, payload) in requests {
      // The database orders pending requests only by createdAt. Distinct fixed timestamps make
      // full seed/API/final snapshot array comparisons deterministic without touching payloads.
      let requestAt =
        kind == .commandApproval ? "2026-11-01T00:00:01.000Z" : "2026-11-01T00:00:02.000Z"
      _ = try database.insertRuntimeRequest(
        RuntimeRequest(
          id: "smoke-historical-\(kind.rawValue)", nativeRequestId: "opaque/native/request#\(kind.rawValue)",
          threadId: threadId, turnId: turn.id, adapterGeneration: 17, kind: kind, payload: payload,
          createdAt: requestAt, updatedAt: requestAt))
    }
    _ = try database.saveDraft(threadId: threadId, text: draft)
    try snapshot(database, root: root, name: "historical-database-seed.json")
    return thread.id
  }

  static func snapshot(_ database: WorkspaceDatabase, root: URL, name: String) throws {
    guard let thread = try database.thread(id: threadId),
      let connection = try database.connection(id: connectionId)
    else { throw WorkspaceError(.internalError, "Historical fixture rows disappeared.") }
    let read = ThreadRead.Result(
      thread: thread, turns: try database.turns(threadId: threadId),
      items: try database.displayItems(threadId: threadId),
      requests: try database.pendingRuntimeRequests(threadId: threadId))
    let state: JSONValue = [
      "connection": try JSONValue(encoding: connection), "read": try JSONValue(encoding: read),
      "draft": try JSONValue(encoding: DraftRead.Result(draft: database.draft(threadId: threadId))),
    ]
    try JSONEncoder().encode(state).write(to: root.appendingPathComponent(name), options: .atomic)
  }
}
