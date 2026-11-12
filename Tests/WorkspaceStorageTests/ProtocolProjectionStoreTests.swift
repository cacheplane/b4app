import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Dormant storage controls only. No adapter, account activation, event publication or network.
@Suite(.serialized) struct ProtocolProjectionStoreTests {
  private static let generation = "11111111-1111-4111-8111-111111111111"
  private static let scope = #"["agent-protocol-v1","b4","https://example.invalid"]"#
  private static let privateFacts =
    #"{"opaque":{"integer":9007199254740993,"large":1e400,"small":1e-400},"private":"projection-private-sentinel"}"#

  private func fixture(local: Bool = false) throws -> WorkspaceDatabase {
    let db = try AgentProtocolResourceFixture.database()
    do {
      _ = try db.insertConnection(
        Connection(
          id: "c", kind: .agentProtocol, label: "Projection", profileRevision: 1,
          target: "https://example.invalid", nativeScope: Self.scope,
          peerProfile: local ? .agentProtocol : .b4, agentId: "fixture", authMode: ConnectionAuthMode.none))
      _ = try db.insertThread(
        ConversationThread(
          id: "t", connectionId: "c", nativeThreadId: "native-thread", nativeScope: Self.scope))
      return db
    } catch { try? db.close(); throw error }
  }

  private func coverage(_ channels: [String] = ["messages"]) throws -> ProtocolProjectionCoverage {
    ProtocolProjectionCoverage(
      channels: channels, namespaces: [[]],
      descriptor: try ProtocolProjectionJSON(utf8: Data(#"{"mode":"full"}"#.utf8)))
  }

  private func prepare(_ db: WorkspaceDatabase, local: Bool = false) throws -> ProtocolProjectionPrecondition
  {
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    return try db.prepareProtocolProjection(
      owner: owner, epoch: local ? .local("local-observation") : .b4(Self.generation), coverage: coverage())
  }

  private func segment(
    namespace: [String] = [], text: String = "safe partial", root: String = "root"
  ) throws -> ProtocolProjectionSegment {
    ProtocolProjectionSegment(
      namespace: namespace, nativeRunId: "run", rootRunId: root,
      facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [
        ProtocolProjectionPresentation(nativeItemId: "message", role: .assistant, content: .text(text))
      ])
  }

  private func batch(
    _ state: ProtocolProjectionPrecondition, seq: UInt64, segments: [ProtocolProjectionSegment]
  ) -> ProtocolProjectionBatch {
    ProtocolProjectionBatch(
      precondition: state, position: .b4(eventId: "b4e1.\(Self.generation).\(seq)", sequence: seq),
      segments: segments)
  }

  private func snapshot(_ db: WorkspaceDatabase) throws -> [Data] {
    try db.write { c in
      try ProtocolGrantProtection.establish(c)
      var result: [Data] = []
      for table in [
        "connections", "threads", "protocolSubscriptions", "protocolRunSegments", "protocolOperations",
        "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
        "displayItems", "turns", "changes", "columnClocks",
      ] {
        result += try c.execute(
          "SELECT $1 || ':' || to_jsonb(r)::text AS value FROM public.\(Rows.quote(table)) r", [table]
        )
        .rows.compactMap { $0.text("value").map { Data($0.utf8) } }
      }
      return result.sorted { $0.lexicographicallyPrecedes($1) }
    }
  }

  private func expectSafeRefusal(_ body: () throws -> Void) {
    do { try body(); Issue.record("An invalid projection was accepted.") } catch {
      let error = error as? WorkspaceError
      let safe =
        error?.code == .protocolInvalid
        && error?.message == "The protocol projection could not be committed."
        && error?.details == nil
      #expect(safe)
    }
  }

  @Test func nativeImagesCursorAndSafePresentationCommitTogetherWithoutNumberCoercion() throws {
    let db = try fixture(); defer { try? db.close() }
    let state = try prepare(db)
    let first = try db.applyProtocolProjection(
      batch(state, seq: 1, segments: [segment(namespace: ["a/b"]), segment(namespace: ["a", "b"])]))
    #expect(first.changedItemIds.count == 2 && Set(first.changedItemIds).count == 2)
    let firstID = try #require(first.changedItemIds.first)
    // Independent literal byte framing, not the production identity helper as the oracle.
    let framed = "19:protocol-message-v11:c1:t13:native-thread2:b436:\(Self.generation)1:13:a/b7:message"
    #expect(firstID == "protocol.v1." + Data(framed.utf8).base64EncodedString())
    #expect(first.appliedSequence == 1)
    #expect(Timestamp.date(from: first.revision) != nil)
    let factsAreExact = try db.write { c in
      try ProtocolGrantProtection.establish(c)
      return try c.execute(
        #"SELECT count(*)::text AS n FROM "protocolRunSegments" WHERE facts=$1::jsonb AND "localTurnId" IS NULL AND "submissionId" IS NULL"#,
        [Self.privateFacts]
      ).rows.first?.text("n") == "2"
    }
    #expect(factsAreExact)
    let privateNotSynced = try db.read { c in
      try c.execute("SELECT 1 FROM changes WHERE value::text LIKE '%projection-private-sentinel%'").rows
        .isEmpty
    }
    #expect(privateNotSynced)
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let second = try db.applyProtocolProjection(
      batch(current, seq: 3, segments: [segment(namespace: ["a/b"], text: "safe final")]))
    #expect(second.changedItemIds == [firstID])
    let rows = try db.read {
      try $0.execute(
        #"SELECT "sequence"::text AS seq,payload->>'text' AS text,type FROM "displayItems" ORDER BY "sequence""#
      ).rows
    }
    #expect(rows.map { $0.text("seq") } == ["0", "1"])
    #expect(rows.map { $0.text("type") } == ["agentMessage", "agentMessage"])
    #expect(rows.map { $0.text("text") } == ["safe final", "safe partial"])
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(
        batch(current, seq: 3, segments: [segment(text: "contradictory replay")]))
    }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func localNilCursorUsesStrictTimestampCASWhenThePriorStampIsAheadOfTheClock() throws {
    let db = try fixture(local: true); defer { try? db.close() }
    _ = try prepare(db, local: true)
    // A canonical future stamp forces the monotonic branch regardless of wall-clock resolution.
    try db.write {
      try $0.execute(#"UPDATE "protocolSubscriptions" SET "updatedAt"='2099-01-01T00:00:00.000000Z'"#)
    }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .local("local-observation"), coverage: coverage())
    let request = ProtocolProjectionBatch(
      precondition: current, position: .genericImage, segments: [try segment()])
    let committed = try db.applyProtocolProjection(request)
    #expect(committed.revision == "2099-01-01T00:00:00.000001Z")
    #expect(committed.appliedSequence == nil)
    let before = try snapshot(db)
    expectSafeRefusal { _ = try db.applyProtocolProjection(request) }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
    let next = try db.protocolProjectionState(
      owner: owner, epoch: .local("local-observation"), coverage: coverage())
    let again = try db.applyProtocolProjection(
      ProtocolProjectionBatch(
        precondition: next, position: .genericImage, segments: [try segment(text: "replacement")]))
    #expect(
      again.revision == "2099-01-01T00:00:00.000002Z" && again.changedItemIds == committed.changedItemIds)
  }

  @Test(arguments: [ProtocolProjectionStage.segments, .presentation, .cursor])
  func faultsRollBackPrivateImagesPresentationAndCursor(stage: ProtocolProjectionStage) throws {
    let db = try fixture(); defer { try? db.close() }
    let state = try prepare(db), before = try snapshot(db)
    var witnessed = false
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(
        batch(state, seq: 1, segments: [segment()]),
        observe: { reached in
          if reached == stage { witnessed = true; throw ProjectionFault.privateSentinel }
        })
    }
    #expect(witnessed)
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func deferredCommitFailureIsSanitizedAndRollsBackTheWholeProjection() throws {
    let db = try fixture(); defer { try? db.close() }
    let state = try prepare(db)
    try db.write { c in
      try c.execute(
        """
        CREATE SCHEMA projection_test;
        CREATE SEQUENCE projection_test.commit_probe;
        CREATE FUNCTION projection_test.refuse() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
          PERFORM nextval('projection_test.commit_probe');
          RAISE EXCEPTION 'projection-private-sentinel' USING ERRCODE='23514';
        END $$;
        CREATE CONSTRAINT TRIGGER projection_commit AFTER UPDATE ON public."protocolSubscriptions"
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION projection_test.refuse();
        """)
    }
    let before = try snapshot(db)
    expectSafeRefusal { _ = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment()])) }
    let probed = try db.read {
      try $0.execute(
        "SELECT last_value::text AS n,is_called::text AS called FROM projection_test.commit_probe"
      ).rows.first
    }
    #expect(probed?.text("n") == "1" && probed?.text("called") == "true")
    let unchanged = try snapshot(db) == before; #expect(unchanged)
    try db.write { try $0.execute(#"DROP TRIGGER projection_commit ON public."protocolSubscriptions""#) }
    let recovery = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment()]))
    #expect(recovery.appliedSequence == 1)
  }

  @Test func changedProfileCoverageEpochDeletedThreadAndForeignStoreRefuseWithoutMutation() throws {
    let db = try fixture(); defer { try? db.close() }
    let state = try prepare(db)
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.prepareProtocolProjection(
        owner: owner, epoch: .b4(Self.generation), coverage: coverage(["messages", "tools"]))
    }
    expectSafeRefusal {
      _ = try db.prepareProtocolProjection(
        owner: owner, epoch: .b4("22222222-2222-4222-8222-222222222222"), coverage: coverage())
    }
    let other = try fixture(); defer { try? other.close() }
    let otherBefore = try snapshot(other)
    expectSafeRefusal { _ = try other.applyProtocolProjection(batch(state, seq: 1, segments: [segment()])) }
    let otherUnchanged = try snapshot(other) == otherBefore; #expect(otherUnchanged)
    let unchanged = try snapshot(db) == before; #expect(unchanged)
    try db.write { try $0.execute(#"UPDATE connections SET "profileRevision"=2 WHERE id='c'"#) }
    let changed = try snapshot(db)
    expectSafeRefusal { _ = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment()])) }
    let profileUnchanged = try snapshot(db) == changed; #expect(profileUnchanged)
    // A newly captured owner cannot reuse a subscription bound to the old profile revision.
    let replacement = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    expectSafeRefusal {
      _ = try db.prepareProtocolProjection(
        owner: replacement, epoch: .b4(Self.generation), coverage: coverage())
    }
    try db.write { try $0.execute(#"UPDATE threads SET "userDeletedAt"='deleted' WHERE id='t'"#) }
    expectSafeRefusal { _ = try db.protocolProjectionOwner(connectionId: "c", threadId: "t") }
  }

  @Test func conflictingSegmentCorrelationAndMalformedJSONCannotAdvanceCursor() throws {
    let db = try fixture(); defer { try? db.close() }
    let state = try prepare(db)
    _ = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment()]))
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(batch(current, seq: 2, segments: [segment(root: "unrelated-root")]))
    }
    for invalidJSON in ["{malformed", "[]", #"{"private":"\u0000"}"#] {
      let invalid = ProtocolProjectionSegment(
        namespace: [], nativeRunId: "new-run", facts: try ProtocolProjectionJSON(utf8: Data(invalidJSON.utf8))
      )
      expectSafeRefusal { _ = try db.applyProtocolProjection(batch(current, seq: 2, segments: [invalid])) }
    }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func retainedGenerationAndNamespaceIdentitiesCannotAliasNewImages() throws {
    let db = try fixture(); defer { try? db.close() }
    let original = try prepare(db)
    let first = try db.applyProtocolProjection(
      batch(original, seq: 1, segments: [segment(namespace: ["a/b"])]))
    let generation = "22222222-2222-4222-8222-222222222222"
    // A test-only A7 reset witness: no public API in this slice can switch epochs or coverage.
    try db.write { c in
      try c.execute(
        #"UPDATE "protocolSubscriptions" SET generation=$1,"appliedEventId"=NULL,"appliedSeq"=NULL"#,
        [generation])
    }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let replacement = try db.protocolProjectionState(
      owner: owner, epoch: .b4(generation), coverage: coverage())
    let committed = try db.applyProtocolProjection(
      ProtocolProjectionBatch(
        precondition: replacement, position: .b4(eventId: "b4e1.\(generation).1", sequence: 1),
        segments: [
          try segment(namespace: ["a/b"], text: "new epoch"),
          try segment(namespace: ["a", "b"], text: "other namespace"),
        ]))
    #expect(Set(first.changedItemIds + committed.changedItemIds).count == 3)
    let count = try db.read {
      try $0.execute(#"SELECT count(*)::text AS n FROM "protocolRunSegments""#).rows.first?.text("n")
    }
    #expect(count == "3")
    let before = try snapshot(db)
    expectSafeRefusal { _ = try db.applyProtocolProjection(batch(original, seq: 2, segments: [segment()])) }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func namespacePrefixesAndRootTokensUseExactUTF8RatherThanUnicodeEquivalence() throws {
    let db = try fixture(); defer { try? db.close() }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let selected = ProtocolProjectionCoverage(
      channels: ["messages"], namespaces: [["é"]],
      descriptor: try ProtocolProjectionJSON(utf8: Data("{}".utf8)))
    let state = try db.prepareProtocolProjection(
      owner: owner, epoch: .b4(Self.generation), coverage: selected)
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment(namespace: ["e\u{301}"])]))
    }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
    _ = try db.applyProtocolProjection(batch(state, seq: 1, segments: [segment(namespace: ["é"], root: "é")]))
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: selected)
    let committed = try snapshot(db)
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(
        batch(current, seq: 2, segments: [segment(namespace: ["é"], root: "e\u{301}")]))
    }
    let rootUnchanged = try snapshot(db) == committed; #expect(rootUnchanged)
    _ = try db.insertThread(
      ConversationThread(
        id: "unicode", connectionId: "c", nativeThreadId: "unicode-native", nativeScope: Self.scope))
    let otherOwner = try db.protocolProjectionOwner(connectionId: "c", threadId: "unicode")
    let both = ProtocolProjectionCoverage(
      channels: ["messages"], namespaces: [["é"], ["e\u{301}"]],
      descriptor: try ProtocolProjectionJSON(utf8: Data("{}".utf8)))
    let bothState = try db.prepareProtocolProjection(
      owner: otherOwner, epoch: .b4(Self.generation), coverage: both)
    let distinct = try db.applyProtocolProjection(
      batch(
        bothState, seq: 1,
        segments: [segment(namespace: ["é"]), segment(namespace: ["e\u{301}"])]))
    #expect(distinct.changedItemIds.count == 2 && Set(distinct.changedItemIds).count == 2)
    let nativeBytes = try db.write { c in
      try ProtocolGrantProtection.establish(c)
      return try c.execute(
        #"SELECT encode(convert_to(namespace->>0,'UTF8'),'hex') AS bytes FROM "protocolRunSegments" WHERE "threadId"='unicode' ORDER BY bytes"#
      )
      .rows.compactMap { $0.text("bytes") }
    }
    #expect(nativeBytes == ["65cc81", "c3a9"])
  }

  @Test func existingAuthorizedLinksSurviveWholeImageReplacementWithoutAcknowledgingATurn() throws {
    let db = try fixture(); defer { try? db.close() }
    let initial = try prepare(db)
    let first = try db.applyProtocolProjection(batch(initial, seq: 1, segments: [segment()]))
    _ = try db.insertTurn(Turn(id: "optimistic", threadId: "t", operationId: "local-operation"))
    // Only a separate future A6 boundary may authorize these links; the event API has no setters.
    try db.write { c in
      try c.execute(
        #"UPDATE "protocolRunSegments" SET "localTurnId"='optimistic',"submissionId"='local-submission'"#)
    }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let next = try db.applyProtocolProjection(batch(current, seq: 2, segments: [segment(text: "reconciled")]))
    #expect(next.changedItemIds == first.changedItemIds)
    let firstID = try #require(first.changedItemIds.first)
    let links = try db.write { c in
      try ProtocolGrantProtection.establish(c)
      return try c.execute(
        #"SELECT "localTurnId"='optimistic' AND "submissionId"='local-submission' AS exact FROM "protocolRunSegments""#
      ).rows.first?.text("exact") == "t"
    }
    #expect(links)
    let presentation = try db.read {
      try $0.execute(#"SELECT "turnId" FROM "displayItems" WHERE id=$1"#, [firstID]).rows.first?.text(
        "turnId")
    }
    #expect(presentation == "optimistic")
    let turn = try #require(try db.turn(id: "optimistic"))
    #expect(turn.status == .submitting && turn.submission == .prepared && turn.nativeTurnId == nil)
  }

  @Test func invalidPriorTimestampRefusesInsteadOfInventingACASRevision() throws {
    let db = try fixture(local: true); defer { try? db.close() }
    _ = try prepare(db, local: true)
    try db.write {
      try $0.execute(#"UPDATE "protocolSubscriptions" SET "updatedAt"='2099-02-31T00:00:00.000000Z'"#)
    }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.protocolProjectionState(
        owner: owner, epoch: .local("local-observation"), coverage: coverage())
    }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func continuationReferencesTheSameCanonicalMessageAndPreservesAnUnresolvedSegmentsTrustedTurn() throws
  {
    let db = try fixture(); defer { try? db.close() }
    let initial = try prepare(db)
    let first = try db.applyProtocolProjection(batch(initial, seq: 1, segments: [segment()]))
    let itemId = try #require(first.changedItemIds.first)
    _ = try db.insertTurn(Turn(id: "original-turn", threadId: "t", operationId: "original-operation"))
    try db.write {
      try $0.execute(
        #"UPDATE "protocolRunSegments" SET "localTurnId"='original-turn',"submissionId"='original-submission'"#
      )
    }
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let second = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    _ = try db.applyProtocolProjection(batch(second, seq: 2, segments: [segment(text: "linked image")]))
    let continued = ProtocolProjectionSegment(
      namespace: [], nativeRunId: "continued-run", rootRunId: "root",
      predecessorRunId: "run", facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [
        ProtocolProjectionPresentation(
          nativeItemId: "message", role: .assistant, content: .text("continued final"))
      ])
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let alsoReferences = ProtocolProjectionSegment(
      namespace: [], nativeRunId: "another-reference", rootRunId: "root",
      facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [
        ProtocolProjectionPresentation(
          nativeItemId: "message", role: .assistant, content: .text("continued final"))
      ])
    let committed = try db.applyProtocolProjection(
      batch(current, seq: 3, segments: [continued, alsoReferences]))
    #expect(committed.changedItemIds == [itemId])
    let rows = try db.read {
      try $0.execute(#"SELECT "turnId",payload->>'text' AS text FROM "displayItems""#).rows
    }
    #expect(
      rows.count == 1 && rows.first?.text("turnId") == "original-turn"
        && rows.first?.text("text") == "continued final")
    let unresolved = try db.write { c in
      try ProtocolGrantProtection.establish(c)
      return try c.execute(
        #"SELECT "localTurnId" IS NULL AND "submissionId" IS NULL AND "predecessorRunId"='run' AS exact FROM "protocolRunSegments" WHERE "nativeRunId"='continued-run'"#
      ).rows.first?.text("exact") == "t"
    }
    #expect(unresolved)
    let turn = try #require(try db.turn(id: "original-turn"))
    #expect(turn.status == .submitting && turn.submission == .prepared && turn.nativeTurnId == nil)
    _ = try db.insertTurn(
      Turn(
        id: "other-turn", threadId: "t", operationId: "other-operation", status: .terminal,
        submission: .acknowledged, outcome: .completed))
    try db.write {
      try $0.execute(
        #"UPDATE "protocolRunSegments" SET "localTurnId"='other-turn' WHERE "nativeRunId"='continued-run'"#)
    }
    let next = try db.protocolProjectionState(owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let before = try snapshot(db)
    expectSafeRefusal { _ = try db.applyProtocolProjection(batch(next, seq: 4, segments: [continued])) }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func unknownContentBecomesKnownTextOnTheSameMessageButAnEstablishedRoleCannotChange() throws {
    let db = try fixture(); defer { try? db.close() }
    let initial = try prepare(db)
    let unknown = ProtocolProjectionSegment(
      namespace: [], nativeRunId: "run",
      facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [ProtocolProjectionPresentation(nativeItemId: "message", role: .user, content: .unknown)])
    let first = try db.applyProtocolProjection(batch(initial, seq: 1, segments: [unknown]))
    let owner = try db.protocolProjectionOwner(connectionId: "c", threadId: "t")
    let current = try db.protocolProjectionState(
      owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let known = ProtocolProjectionSegment(
      namespace: [], nativeRunId: "run",
      facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [
        ProtocolProjectionPresentation(nativeItemId: "message", role: .user, content: .text("known text"))
      ])
    let updated = try db.applyProtocolProjection(batch(current, seq: 2, segments: [known]))
    #expect(updated.changedItemIds == first.changedItemIds)
    let rows = try db.read {
      try $0.execute("SELECT role,type,payload->>'text' AS text FROM \"displayItems\"").rows
    }
    #expect(
      rows.count == 1 && rows.first?.text("role") == "user" && rows.first?.text("type") == "userMessage"
        && rows.first?.text("text") == "known text")
    let next = try db.protocolProjectionState(owner: owner, epoch: .b4(Self.generation), coverage: coverage())
    let before = try snapshot(db)
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(
        batch(next, seq: 3, segments: [segment(text: "wrong assistant role")]))
    }
    let contradiction = ProtocolProjectionSegment(
      namespace: [], nativeRunId: "other-reference",
      facts: try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8)),
      presentation: [
        ProtocolProjectionPresentation(
          nativeItemId: "message", role: .user, content: .text("contradictory whole image"))
      ])
    expectSafeRefusal {
      _ = try db.applyProtocolProjection(batch(next, seq: 3, segments: [known, contradiction]))
    }
    let unchanged = try snapshot(db) == before; #expect(unchanged)
  }

  @Test func opaqueBoundaryRefusesInvalidUTF8AndCStringNULWithoutReflectingMaterial() throws {
    expectSafeRefusal { _ = try ProtocolProjectionJSON(utf8: Data([0xff])) }
    expectSafeRefusal { _ = try ProtocolProjectionJSON(utf8: Data([0])) }
    let value = try ProtocolProjectionJSON(utf8: Data(Self.privateFacts.utf8))
    let hidden =
      !String(reflecting: value).contains("projection-private-sentinel")
      && Mirror(reflecting: value).children.isEmpty
    #expect(hidden)
  }
}

private enum ProjectionFault: Error { case privateSentinel }
