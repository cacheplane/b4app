import Foundation
import Testing
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceStorage

@Suite(.serialized) struct AgentProtocolLegacyManagedTests {
  private typealias F = AgentProtocolIdentityManagedFixture
  @Test func enabledAndDisabledLegacyOnlyRegistrationsStayUntouchedAtStartup() async throws {
    for disabled in [false, true] {
      try await F.withServer { h in
        let server = try h.rememberedServer(references: ["legacy"], disabled: disabled)
        let before = try F.snapshot(h.store.raw)
        await h.service.startAll()
        let unchanged = try F.snapshot(h.store.raw) == before
        #expect(unchanged)
        #expect(try h.store.database.localServer(id: server.id)?.pid == h.rememberedPID)
        #expect(try h.store.database.connection(id: "legacy")?.status == .ready)
        #expect(await h.events.sequence == 0)
        #expect(!(await h.service.isReady(id: server.id)))
      }
    }
  }
  @Test func sharedServerNotificationSkipsLegacyBeforeCurrentEventBarrier() async throws {
    try await F.withServer { h in
      let server = try h.rememberedServer(references: ["legacy", "profile"])
      let ordered = try h.store.database.connections(localServerId: server.id)
      // Exact unique createdAt ordering makes receipt of profile's event a flush barrier for the
      // single reader: any legacy event from this notification pass MUST have arrived before it.
      #expect(ordered.map(\.id) == ["legacy", "profile"])
      let before = try F.snapshot(h.store.raw)
      let originalLegacy = try #require(try h.store.database.connection(id: "legacy"))
      let beforeSequence = try #require(
        h.store.raw.execute(#"SELECT max("seq")::text AS n FROM "changes""#).rows.first?.text("n"))
      await h.service.startAll()
      let currentSeen = await h.observedCurrentEvent("profile")
      #expect(currentSeen)
      let emitted = h.adapterEvents().filter { $0.kind == .connectionChanged }
      #expect(emitted.map(\.connectionId) == ["profile"])
      let legacyUnchanged = try h.store.database.connection(id: "legacy") == originalLegacy
      #expect(legacyUnchanged)
      #expect(try h.store.database.connection(id: "profile")?.status == .offline)
      #expect(try h.store.database.localServer(id: server.id)?.health == .stopped)
      let after = try F.snapshot(h.store.raw)
      #expect(F.history(after) == F.history(before))
      #expect(after.catalog == before.catalog)
      let changedOwners = try h.store.raw.execute(
        #"SELECT DISTINCT "rowId" FROM "changes" WHERE "seq">$1::bigint AND "table"='connections'"#,
        [beforeSequence]
      ).rows.compactMap { $0.text("rowId") }
      #expect(changedOwners == ["profile"])
    }
  }
  @Test func unreferencedAndCurrentHarnessRegistrationsKeepMismatchHandling() async throws {
    try await F.withServer { h in
      let server = try h.rememberedServer(references: [])
      await h.service.startAll()
      #expect(try h.store.database.localServer(id: server.id)?.pid == nil)
      #expect(try h.store.database.localServer(id: server.id)?.health == .stopped)
      #expect(await h.events.sequence == 1)
    }
    try await F.withServer { h in
      let server = try h.rememberedServer(references: ["codex", "claude"])
      await h.service.startAll()
      let lastSeen = await h.observedCurrentEvent("claude")
      #expect(lastSeen)
      let emitted = h.adapterEvents().filter { $0.kind == .connectionChanged }
      #expect(emitted.map(\.connectionId) == ["codex", "claude"])
      #expect(try h.store.database.connection(id: "codex")?.status == .offline)
      #expect(try h.store.database.connection(id: "claude")?.status == .offline)
      #expect(try h.store.database.localServer(id: server.id)?.pid == nil)
      #expect(await h.events.sequence == 1)
    }
  }
}
