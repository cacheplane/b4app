import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite(.serialized) struct AgentProtocolConnectionIdentityTests {
  private typealias F = AgentProtocolIdentityManagedFixture
  @Test func protocolIdentityEditsRefuseWithoutChangingRowsCatalogOrSequences() async throws {
    let edits: [(String, @Sendable (inout Connection) -> Void)] = [
      ("id", { $0.id = "different-id" }), ("kind", { $0.kind = .codex }),
      ("target", { $0.target = "https://different.invalid/base" }),
      ("peerProfile", { $0.peerProfile = .b4 }), ("agentId", { $0.agentId = "different-agent" }),
      ("nativeScope", { $0.nativeScope = "different-scope" }),
    ]
    for (field, edit) in edits {
      try await F.withStore { f in
        let before = try F.snapshot(f.raw)
        var error: WorkspaceError?
        do { _ = try f.database.updateConnection(id: "profile", edit) } catch let caught {
          error = WorkspaceError.from(caught)
        }
        #expect(error?.code == .protocolInvalid, "Identity field \(field) requires a new profile.")
        let stateUnchanged = try F.snapshot(f.raw) == before
        #expect(stateUnchanged)
        #expect(try f.database.connection(id: "profile")?.id == "profile")
      }
    }
  }
  @Test func labelsAuthSelectionStatusAndCapabilityFactsRemainMutable() async throws {
    try await F.withStore { f in
      let original = try #require(try f.database.connection(id: "profile"))
      let before = try F.snapshot(f.raw)
      let previousSequence = try #require(
        f.raw.execute(#"SELECT max("seq")::text AS n FROM "changes""#).rows.first?.text("n"))
      _ = try f.database.updateConnection(id: "profile") {
        $0.label = "Renamed"; $0.enabled = false; $0.profileRevision += 1
        $0.authMode = .bearer; $0.authReference = "secret:mutable-endpoint-reference"
        $0.status = .offline; $0.authStatus = .required; $0.capabilities = [.streaming: .supported]
      }
      let bearer = try #require(try f.database.connection(id: "profile"))
      #expect(bearer.label == "Renamed" && !bearer.enabled && bearer.profileRevision == 1)
      #expect(bearer.authMode == .bearer && bearer.authReference == "secret:mutable-endpoint-reference")
      #expect(bearer.status == .offline && bearer.authStatus == .required)
      #expect(bearer.capabilities[.streaming] == .supported)
      _ = try f.database.updateConnection(id: "profile") {
        $0.authMode = .header; $0.authHeaderName = "X-Fixture-Token"
      }
      let header = try #require(try f.database.connection(id: "profile"))
      #expect(header.authMode == .header && header.authHeaderName == "X-Fixture-Token")
      _ = try f.database.updateConnection(id: "profile") {
        $0.authMode = ConnectionAuthMode.none; $0.authHeaderName = nil; $0.authReference = nil
      }
      let updated = try #require(try f.database.connection(id: "profile"))
      #expect(
        updated.authMode == ConnectionAuthMode.none && updated.authHeaderName == nil
          && updated.authReference == nil)
      #expect(updated.id == original.id && updated.kind == original.kind && updated.target == original.target)
      #expect(
        updated.peerProfile == original.peerProfile && updated.agentId == original.agentId
          && updated.nativeScope == original.nativeScope)
      let historyUnchanged = try F.history(F.snapshot(f.raw)) == F.history(before)
      #expect(historyUnchanged)
      let allowed = Set([
        "label", "enabled", "profileRevision", "authMode", "authHeaderName", "authReference", "status",
        "authStatus", "capabilities", "updatedAt",
      ])
      let changes = try f.raw.execute(
        #"SELECT "table","rowId","column" FROM "changes" WHERE "seq">$1::bigint"#, [previousSequence]
      ).rows
      #expect(!changes.isEmpty)
      let onlyExpectedChanges = changes.allSatisfy {
        $0.text("table") == "connections" && $0.text("rowId") == "profile"
          && allowed.contains($0.text("column") ?? "")
      }
      #expect(onlyExpectedChanges)
    }
  }
  @Test func legacyConversionRefusesAndFreshIdKeepsEveryHistoricalFact() async throws {
    try await F.withStore { f in
      let before = try F.snapshot(f.raw)
      var error: WorkspaceError?
      do {
        _ = try f.database.updateConnection(id: "legacy") {
          $0.kind = .agentProtocol; $0.peerProfile = .agentProtocol; $0.agentId = "fresh-agent"
          $0.authMode = ConnectionAuthMode.none; $0.authHeaderName = nil; $0.nativeScope = "fresh-scope"
        }
      } catch let caught { error = WorkspaceError.from(caught) }
      #expect(error?.code == .protocolInvalid)
      let refusedWithoutMutation = try F.snapshot(f.raw) == before
      #expect(refusedWithoutMutation)
      _ = try f.database.insertConnection(
        Connection(
          id: "fresh-profile", kind: .agentProtocol, label: "Fresh",
          target: "https://example.invalid/base", nativeScope: "fresh-scope", peerProfile: .agentProtocol,
          agentId: "fresh-agent", authMode: ConnectionAuthMode.none))
      let after = try F.snapshot(f.raw)
      let retainedAllOldRows = before.rows.allSatisfy { table, rows in
        Set(rows).isSubset(of: Set(after.rows[table] ?? []))
      }
      #expect(retainedAllOldRows)
      #expect(try f.database.connection(id: "legacy")?.kind == .b4)
      #expect(try f.database.thread(id: "thread-legacy")?.connectionId == "legacy")
      #expect(try f.database.thread(id: "thread-legacy")?.nativeScope == "scope-legacy")
      #expect(try f.database.turn(id: "turn-legacy")?.outcome == nil)
      #expect(try f.database.runtimeRequest(id: "request-legacy")?.state == .pending)
    }
  }
  @Test func codexAndClaudeRuntimeScopeAndStatusRefreshRemainSupported() async throws {
    try await F.withStore { f in
      let before = try F.snapshot(f.raw)
      for id in ["codex", "claude"] {
        _ = try f.database.updateConnection(id: id) {
          $0.nativeScope = "refreshed-" + id; $0.label = "Current " + id
          $0.authReference = "secret:refreshed-" + id
        }
        try f.database.updateConnectionStatus(
          id: id, status: .offline, authStatus: .required, capabilities: [.streaming: .supported])
        let updated = try #require(try f.database.connection(id: id))
        #expect(
          updated.nativeScope == "refreshed-" + id && updated.status == .offline
            && updated.authStatus == .required)
        #expect(updated.authReference == "secret:refreshed-" + id)
        #expect(try f.database.thread(id: "thread-" + id)?.nativeScope == "scope-" + id)
        #expect(try f.database.turn(id: "turn-" + id)?.outcome == nil)
      }
      let historyUnchanged = try F.history(F.snapshot(f.raw)) == F.history(before)
      #expect(historyUnchanged)
    }
  }
}
