import Foundation
import Testing

@testable import B4Adapter

/// The corpus is copied byte for byte from the pinned, unpublished SDK package.
/// Loading through #filePath keeps the existing test target's fixture exclusions intact.
@Suite struct AgentProtocolTypesTests {
  private struct Fixture: Decodable {
    let name: String
    let schema: String
    let value: AgentProtocol.Value
    let valid: Bool?
    let correctedValid: Bool?
  }

  private struct Corpus: Decodable {
    let upstream: [Fixture]
    let b4: [Fixture]
  }

  private func corpus() throws -> Corpus {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/agent-protocol", isDirectory: true)
    return try JSONDecoder().decode(
      Corpus.self, from: Data(contentsOf: directory.appendingPathComponent("agent-protocol.fixtures.json")))
  }

  private func fixture(_ name: String) throws -> AgentProtocol.Value {
    let corpus = try corpus()
    return try #require((corpus.upstream + corpus.b4).first { $0.name == name }).value
  }

  private func decode<T: Decodable>(_ type: T.Type, fixture name: String) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(fixture(name)))
  }

  private func roundTrip<T: Codable>(_ value: T, equals expected: AgentProtocol.Value) throws {
    let encoded = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(AgentProtocol.Value.self, from: encoded) == expected)
  }

  private func expectFailure<T: Decodable>(
    _ type: T.Type, value: AgentProtocol.Value, path: [String]
  ) throws {
    do {
      _ = try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
      Issue.record("Expected decoding failure at \(path.joined(separator: "."))")
    } catch let DecodingError.dataCorrupted(context) {
      #expect(context.codingPath.map(\.stringValue) == path)
    } catch let DecodingError.keyNotFound(key, context) {
      #expect(context.codingPath.map(\.stringValue) + [key.stringValue] == path)
    } catch let DecodingError.typeMismatch(_, context) {
      #expect(context.codingPath.map(\.stringValue) == path)
    } catch let DecodingError.valueNotFound(_, context) {
      #expect(context.codingPath.map(\.stringValue) == path)
    }
  }

  @Test func outgoingBuildersKeepThreadTokenAndCommandIdentitiesSeparate() throws {
    let thread = try #require(UUID(uuidString: "871e7ea2-7a46-4678-bcac-3a912de1b008"))
    let tokenUUID = try #require(UUID(uuidString: "018f2c16-5edb-7c3b-8c80-35f79a173d42"))
    let targetUUID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000003"))
    let token = AgentProtocol.CanonicalID(tokenUUID)
    let create = AgentProtocol.ThreadCreateRequest(threadID: thread, metadata: ["label": .string("original")])
    #expect(
      create.body
        == .object([
          "thread_id": .string(thread.uuidString.lowercased()), "if_exists": .string("do_nothing"),
          "metadata": .object(["label": .string("original")]),
        ]))
    let lookup = AgentProtocol.OperationLookupRequest(
      submissionID: token, operationThreadID: .init(thread), targetRunID: .init(targetUUID))
    #expect(
      lookup.body
        == .object([
          "metadata": .object([
            "b4.submissionId": .string(tokenUUID.uuidString.lowercased()), "b4.submissionKind": .string("b4"),
            "b4.operationThreadId": .string(thread.uuidString.lowercased()),
            "b4.targetRunId": .string(targetUUID.uuidString.lowercased()),
          ]), "limit": .integer(1), "offset": .integer(0),
        ]))
    let initial = AgentProtocol.OperationLookupRequest(submissionID: token, operationThreadID: .init(thread))
    #expect(initial.body["metadata"]?["b4.targetRunId"] == nil)
    #expect(initial.body["thread_id"] == nil)  // a fork's destination can differ from its original target
    let id = try JSONDecoder().decode(AgentProtocol.JSUInt.self, from: Data("42".utf8))
    let request = AgentProtocol.RunStartRequest(
      assistantID: "route/child#agent", input: .object(["text": .string("hello")]),
      config: ["model": .string("selected")],
      metadata: [
        "b4": .object(["v": .integer(1), "submissionId": .string(tokenUUID.uuidString.lowercased())])
      ])
    let command = AgentProtocol.Command(id: id, start: request)
    #expect(command.method == .runStart && command.id.rawValue == 42)
    #expect(command.params == request.params)
    #expect(command.params["metadata"]?["b4"]?["submissionId"] == .string(tokenUUID.uuidString.lowercased()))
    #expect(command.params["assistantId"] == .string("route/child#agent"))
    #expect(command.params["config"] == .object(["model": .string("selected")]))
    #expect(command.raw["b4"] == nil)
    #expect(AgentProtocol.CommandMethod(rawValue: "run.stop") == nil)
    #expect(AgentProtocol.CommandMethod(rawValue: "run.resume") == nil)
  }

  @Test func decodesStandardRunAndPreservesWireDateSpelling() throws {
    let run = try decode(AgentProtocol.Run.self, fixture: "complete Run response")
    #expect(run.runID.uuidString.lowercased() == "018f2c16-5edb-7c3b-8c80-35f79a173d42")
    #expect(run.status == .pending)
    #expect(run.createdAt.rawValue == "2026-11-05T00:00:00Z")
    try roundTrip(run, equals: fixture("complete Run response"))
  }

  @Test func rejectsInvalidStandardRunDatesAndMissingRequiredFields() throws {
    try expectFailure(
      AgentProtocol.Run.self, value: fixture("invalid Run timestamp"), path: ["created_at"])
    for field in ["run_id", "created_at", "updated_at", "status", "metadata"] {
      try expectFailure(
        AgentProtocol.Run.self, value: fixture("Run response missing \(field)"), path: [field])
    }
  }

  @Test func preservesUnknownRESTContentBlocksAndMessageExtensions() throws {
    let value = try fixture("unknown REST block preserved")
    let message = try decode(AgentProtocol.Message.self, fixture: "unknown REST block preserved")
    #expect(message.role == "assistant")
    if case .blocks(let blocks) = message.content {
      #expect(blocks.count == 1)
      #expect(blocks[0]["type"] == .string("future"))
      #expect(blocks[0]["provider"]?["unknown"] == .array([.integer(1), .integer(2)]))
    } else {
      Issue.record("Expected opaque future content block")
    }
    try roundTrip(message, equals: value)
  }

  @Test func keepsRESTAndASPRolesDistinct() throws {
    #expect(AgentProtocol.PublicRole(rawValue: "assistant") == .assistant)
    #expect(AgentProtocol.PublicRole(rawValue: "ai") == nil)
    #expect(AgentProtocol.ASPRole(rawValue: "ai") == .ai)
    #expect(AgentProtocol.ASPRole(rawValue: "assistant") == nil)
    #expect(AgentProtocol.InputRole(rawValue: "user") == .user)
    #expect(AgentProtocol.InputRole(rawValue: "assistant") == nil)
    try expectFailure(
      AgentProtocol.B4Message.self, value: fixture("B4 public message rejects ASP role"), path: ["role"])
    let message = try decode(AgentProtocol.B4Message.self, fixture: "B4 public message role")
    #expect(message.role == .tool)
  }

  @Test func canonicalB4UUIDIsLowercaseButStandardUUIDNeedNotBe() throws {
    let canonical = try decode(AgentProtocol.CanonicalID.self, fixture: "canonical UUID")
    #expect(canonical.rawValue.uuidString.lowercased() == "871e7ea2-7a46-4678-bcac-3a912de1b008")
    try expectFailure(
      AgentProtocol.CanonicalID.self, value: fixture("uppercase UUID rejected"), path: [])
    var value = try fixture("complete Run response")
    value["run_id"] = .string("018F2C16-5EDB-7C3B-8C80-35F79A173D42")
    _ = try JSONDecoder().decode(AgentProtocol.Run.self, from: JSONEncoder().encode(value))
  }

  @Test func nativeSubmissionTokenIsNotCanonicalRunIdentity() throws {
    let receipt = try decode(AgentProtocol.Receipt.self, fixture: "native receipt")
    #expect(receipt.submission == .agui("native-run/arbitrary"))
    #expect(receipt.runID.rawValue.uuidString.lowercased() == "871e7ea2-7a46-4678-bcac-3a912de1b008")
    try roundTrip(receipt, equals: fixture("native receipt"))
    try expectFailure(
      AgentProtocol.RequestMetadata.self,
      value: fixture("request metadata native token forbidden"), path: ["submissionId"])
  }

  @Test func commandCorrelationIsSeparateFromSubmissionToken() throws {
    let command = try decode(AgentProtocol.Command.self, fixture: "B4 command carrier run.start")
    #expect(command.id.rawValue == 1)
    #expect(command.method == .runStart)
    let metadata = try #require(command.params["metadata"]?["b4"])
    let request = try JSONDecoder().decode(
      AgentProtocol.RequestMetadata.self, from: JSONEncoder().encode(metadata))
    #expect(request.submissionID?.rawValue.uuidString.lowercased() == "871e7ea2-7a46-4678-bcac-3a912de1b008")
    try roundTrip(command, equals: fixture("B4 command carrier run.start"))
  }

  @Test func closedResultsKeepReceiptsInResponseMetadata() throws {
    let result = try decode(AgentProtocol.RunStartResult.self, fixture: "run.start closed result")
    #expect(result.runID == "871e7ea2-7a46-4678-bcac-3a912de1b008")
    #expect(
      try decode(AgentProtocol.RunStartResult.self, fixture: "run.start CDDL optional runId").runID == nil)
    try expectFailure(
      AgentProtocol.RunStartResult.self, value: fixture("run.start receipt cannot enter result"), path: ["b4"]
    )
    try expectFailure(
      AgentProtocol.ForkResult.self, value: fixture("state.fork receipt cannot enter result"), path: ["b4"])
    let response = try decode(
      AgentProtocol.Success<AgentProtocol.B4RunStartResult>.self,
      fixture: "response closed RunStartResponse")
    #expect(response.id.rawValue == 1)
    #expect(response.meta?.receipt?.disposition == .accepted)
    try roundTrip(response, equals: fixture("response closed RunStartResponse"))
    try expectFailure(
      AgentProtocol.Success<AgentProtocol.B4RunStartResult>.self,
      value: fixture("response rejects result extension RunStartResponse"), path: ["result", "b4"])
  }

  @Test func decodesTypedRunAndTurnSettlementWithoutFabricatingEffects() throws {
    let run = try decode(AgentProtocol.RunSummary.self, fixture: "run summary")
    #expect(run.status == .interrupted)
    #expect(run.phase == .settled)
    #expect(run.continuation == .waiting)
    #expect(run.reason == .permission)
    #expect(run.effectsUncertain)
    #expect(
      try decode(AgentProtocol.RunSummary.self, fixture: "run summary optional reason absent").reason == nil)
    let turn = try decode(AgentProtocol.TurnSummary.self, fixture: "turn summary")
    #expect(turn.state == .waiting)
    #expect(turn.continuation == .waiting)
    try roundTrip(run, equals: fixture("run summary"))
  }

  @Test func decodesAuthorizedRecoveryAndRetainsOpaquePendingPayload() throws {
    let thread = try decode(AgentProtocol.B4Thread.self, fixture: "authorized Thread recovery envelope")
    let recovery = thread.recovery
    #expect(thread.thread.status == .interrupted)
    #expect(recovery.throughSeq.rawValue == 2)
    #expect(recovery.pending.count == 1)
    #expect(recovery.pending[0].data.interruptID == "permission-1")
    #expect(recovery.pending[0].data.payload["type"] == .string("b4.permission"))
    #expect(recovery.run?.effectsUncertain == true)
    #expect(recovery.history.complete)
    try roundTrip(thread, equals: fixture("authorized Thread recovery envelope"))
    let empty = try decode(AgentProtocol.Recovery.self, fixture: "empty recovery boundary")
    #expect(empty.throughSeq.rawValue == 0)
    #expect(empty.eventID == nil)
    #expect(empty.turn?.state == .waiting)
    try roundTrip(empty, equals: fixture("empty recovery boundary"))
  }

  @Test func historyAndRunResourcesDecodeTheirB4Envelopes() throws {
    let history = try decode(AgentProtocol.B4ThreadState.self, fixture: "history fragment resource envelope")
    #expect(history.history.lineage.fragmentIndex.rawValue == 1)
    #expect(history.history.history.nextBefore == "b4h1.opaque")
    try roundTrip(history, equals: fixture("history fragment resource envelope"))
    let run = try decode(AgentProtocol.B4Run.self, fixture: "B4 Run public messages UTC envelope")
    #expect(run.metadata.submission == .agui("arbitrary"))
    #expect(run.run.messages?.first?.role == "assistant")
    try roundTrip(run, equals: fixture("B4 Run public messages UTC envelope"))
  }

  @Test func unknownOptionalActivityAndInterruptRemainOpaque() throws {
    let activity = try decode(AgentProtocol.Activity.self, fixture: "future activity payload preserved")
    #expect(activity.type == "future.optional")
    #expect(activity.payload["arbitrary"] == .array([.object(["unknown": .bool(true)])]))
    #expect(activity.effectsUncertain)
    try roundTrip(activity, equals: fixture("future activity payload preserved"))
    let input = try decode(AgentProtocol.InputRequested.self, fixture: "opaque interrupt payload")
    #expect(input.payload == .array([.null, .object(["application": .bool(true)])]))
  }

  @Test func unsupportedB4MajorFailsAtNestedVersionKey() throws {
    try expectFailure(
      AgentProtocol.RequestMetadata.self, value: fixture("request metadata unsupported version"), path: ["v"])
    var thread = try fixture("authorized Thread recovery envelope")
    thread["metadata"]?["b4"]?["v"] = .integer(2)
    try expectFailure(AgentProtocol.B4Thread.self, value: thread, path: ["metadata", "b4", "v"])
    var metadata = try fixture("agent metadata")
    metadata["v"] = .integer(2)
    try expectFailure(AgentProtocol.AgentMetadata.self, value: metadata, path: ["v"])
  }

  @Test func futureOptionalCapabilitiesStayOpaqueAndDoNotBecomeFalse() throws {
    // Derive the resource from the imported valid B4 fixture; the future block is synthetic.
    let corpus = try corpus()
    var agent = try #require(corpus.b4.first { $0.schema == "B4Agent" && $0.valid == true }).value
    agent["capabilities"]?["com.example.future"] = .object(["nested": .array([.null, .integer(9)])])
    let resource = try JSONDecoder().decode(AgentProtocol.Agent.self, from: JSONEncoder().encode(agent))
    #expect(resource.capabilities["com.example.future"] == .object(["nested": .array([.null, .integer(9)])]))
    #expect(resource.capabilities["com.example.absent"] == nil)
    try roundTrip(resource, equals: agent)
  }

  @Test func b4AgentNegotiationChecksMetadataVersionAndKeepsUnknownCapabilities() throws {
    let corpus = try corpus()
    let source = try #require(corpus.b4.first { $0.schema == "B4Agent" && $0.valid == true }).value
    let agent = try JSONDecoder().decode(AgentProtocol.B4Agent.self, from: JSONEncoder().encode(source))
    #expect(agent.metadata.kind == .agent)
    try roundTrip(agent, equals: source)
    var unsupported = source
    unsupported["metadata"]?["b4"]?["v"] = .integer(2)
    try expectFailure(AgentProtocol.B4Agent.self, value: unsupported, path: ["metadata", "b4", "v"])
  }

  @Test func sequenceLimitsStayExactAndErrorsNameTheField() throws {
    let meta = try decode(AgentProtocol.ResponseMeta.self, fixture: "safe seq limit")
    #expect(meta.appliedThroughSeq?.rawValue == 9_007_199_254_740_991)
    try roundTrip(meta, equals: fixture("safe seq limit"))
    for name in ["unsafe seq overflow", "negative seq rejected"] {
      try expectFailure(AgentProtocol.ResponseMeta.self, value: fixture(name), path: ["appliedThroughSeq"])
    }
  }

  @Test func aspAndHTTPFailuresKeepDistinctCorrelationAndMetadata() throws {
    let corpus = try corpus()
    for fixture in corpus.b4 where fixture.schema == "AspErrorResponse" && fixture.valid == true {
      let error = try JSONDecoder().decode(
        AgentProtocol.ASPError.self, from: JSONEncoder().encode(fixture.value))
      #expect(error.id?.rawValue == 1)
      #expect(error.message == "failure")
      try roundTrip(error, equals: fixture.value)
    }
    let error = try decode(AgentProtocol.HTTPError.self, fixture: "diagnostic submission_target_gone")
    #expect(error.code == "submission_target_gone")
    #expect(error.metadata?["b4"]?["code"] == .string("submission_target_gone"))
    try roundTrip(error, equals: fixture("diagnostic submission_target_gone"))
    let meta = try decode(AgentProtocol.ResponseMeta.self, fixture: "response meta extensible")
    #expect(meta.raw["future"] == .object(["opaque": .bool(true)]))
    try roundTrip(meta, equals: fixture("response meta extensible"))
  }

  @Test func opaqueJSONDoesNotRoundLargeIntegersThroughDouble() throws {
    let source = Data("{\"n\":9007199254740993,\"u\":18446744073709551615,\"d\":0.1234567890123456789}".utf8)
    let value = try JSONDecoder().decode(AgentProtocol.Value.self, from: source)
    #expect(value["n"] == .integer(9_007_199_254_740_993))
    #expect(value["u"] == .unsignedInteger(UInt64.max))
    let encoded = try JSONEncoder().encode(value)
    #expect(String(decoding: encoded, as: UTF8.self).contains("9007199254740993"))
    #expect(String(decoding: encoded, as: UTF8.self).contains("18446744073709551615"))
    #expect(String(decoding: encoded, as: UTF8.self).contains("0.1234567890123456789"))
    #expect(try JSONDecoder().decode(AgentProtocol.Value.self, from: encoded) == value)
  }

  @Test func eventSnapshotHasNoInventedJournalIdentity() throws {
    let event = try decode(AgentProtocol.Event.self, fixture: "B4 event")
    #expect(event.seq?.rawValue == 2)
    #expect(event.method == "lifecycle")
    #expect(event.correlation?.runID != nil)
    try roundTrip(event, equals: fixture("B4 event"))
    let snapshot = try decode(AgentProtocol.SnapshotEvent.self, fixture: "hydration no invented sequence")
    #expect(snapshot.delivery.throughSeq.rawValue == 5)
    #expect(snapshot.event.seq == nil)
    #expect(snapshot.event.eventID == nil)
    try expectFailure(
      AgentProtocol.SnapshotEvent.self, value: fixture("snapshot rejects invented journal sequence"),
      path: ["seq"])
  }

  @Test func importedReceiptAndSummaryFixturesRejectMissingAndMalformedRequiredData() throws {
    let corpus = try corpus()
    let selected: [String: (AgentProtocol.Value) throws -> Void] = [
      "ReceiptV1": {
        _ = try JSONDecoder().decode(AgentProtocol.Receipt.self, from: JSONEncoder().encode($0))
      },
      "RunSummary": {
        _ = try JSONDecoder().decode(AgentProtocol.RunSummary.self, from: JSONEncoder().encode($0))
      },
      "TurnSummary": {
        _ = try JSONDecoder().decode(AgentProtocol.TurnSummary.self, from: JSONEncoder().encode($0))
      },
      "OperationLookupV1": {
        _ = try JSONDecoder().decode(AgentProtocol.OperationLookup.self, from: JSONEncoder().encode($0))
      },
      "RecoveryV1": {
        _ = try JSONDecoder().decode(AgentProtocol.Recovery.self, from: JSONEncoder().encode($0))
      },
      "Activity": {
        _ = try JSONDecoder().decode(AgentProtocol.Activity.self, from: JSONEncoder().encode($0))
      },
      "AgentMetadataV1": {
        _ = try JSONDecoder().decode(AgentProtocol.AgentMetadata.self, from: JSONEncoder().encode($0))
      },
    ]
    for fixture in corpus.b4 {
      guard let decode = selected[fixture.schema], let valid = fixture.valid else { continue }
      if valid {
        try decode(fixture.value)
      } else {
        do {
          try decode(fixture.value)
          Issue.record("Accepted invalid pinned corpus case: \(fixture.name)")
        } catch is DecodingError {
          // This corpus check supplements the explicit coding-path tests above.
        }
      }
    }
  }
  private func agentWithCapabilities(_ capabilities: AgentProtocol.Object) throws -> AgentProtocol.Value {
    var agent = try fixture("supported injection advertises schema and limits")
    agent["capabilities"] = .object(capabilities)
    agent["metadata"]?["b4"]?["schemas"] = try fixture("all named agent schemas")
    agent["metadata"]?["b4"]?["limits"] = try fixture("all named agent limits")
    return agent
  }

  private func requiredCapabilityKeys(_ schemaName: String) throws -> [String] {
    let schemaPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/agent-protocol/agent-protocol.schema.json")
    let schema = try JSONDecoder().decode(AgentProtocol.Value.self, from: Data(contentsOf: schemaPath))
    guard case .array(let fields) = schema["$defs"]?[schemaName]?["required"] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return try fields.map { field in
      guard case .string(let key) = field else { throw CocoaError(.fileReadCorruptFile) }
      return key
    }
  }

  @Test func b4AgentsEnforceEveryImportedAdvertisedSchemaAndLimitRequirement() throws {
    let expectedMissingFields: [String: [String]] = [
      "injection support requires injectionInput": ["schemas", "injectionInput"],
      "injection support requires inbox": ["limits", "inbox"],
      "supported control missing schema stateEdit": ["schemas", "stateEdit"],
      "supported control missing schema update": ["schemas", "resumeUpdate"],
      "supported control missing schema goto": ["schemas", "resumeGoto"],
      "supported control missing schema config": ["schemas", "resumeConfig"],
      "supported feature missing group viewer": ["limits", "viewer"],
      "supported feature missing group inspection": ["limits", "inspection"],
      "supported feature missing group staging": ["limits", "staging"],
      "supported feature missing group recovery": ["schemas", "recovery"],
    ]
    let cases = try corpus().b4.filter { $0.schema == "B4Agent" }
    #expect(cases.filter { $0.valid == false }.count == expectedMissingFields.count)
    for fixture in cases {
      if fixture.valid == true {
        let agent = try JSONDecoder().decode(
          AgentProtocol.B4Agent.self, from: JSONEncoder().encode(fixture.value))
        try roundTrip(agent, equals: fixture.value)
      } else {
        let missing = try #require(expectedMissingFields[fixture.name])
        try expectFailure(
          AgentProtocol.B4Agent.self, value: fixture.value, path: ["metadata", "b4"] + missing)
      }
    }
  }

  @Test func knownB4CapabilitiesRejectUnsupportedMajorsAndMalformedRequiredFields() throws {
    let names: [String: String] = [
      "CapabilityProtocolV1": "run.b4.protocol",
      "CapabilityRecoveryV1": "run.b4.recovery",
      "CapabilityPermissionsV1": "run.b4.permissions",
      "CapabilityControlsV1": "run.b4.controls",
      "CapabilityAguiV1": "run.b4.agui",
      "CapabilityWorkspaceV1": "run.b4.workspace",
      "CapabilityStoreV1": "run.b4.store",
    ]
    let cases = try corpus().b4.filter { names[$0.schema] != nil && $0.valid == true }
    #expect(cases.count == names.count)
    for fixture in cases {
      let name = try #require(names[fixture.schema])
      let valid = try agentWithCapabilities([name: fixture.value])
      let decoded = try JSONDecoder().decode(AgentProtocol.B4Agent.self, from: JSONEncoder().encode(valid))
      try roundTrip(decoded, equals: valid)
      var unsupported = valid
      unsupported["capabilities"]?[name]?["v"] = .integer(2)
      try expectFailure(AgentProtocol.B4Agent.self, value: unsupported, path: ["capabilities", name, "v"])
      for key in try requiredCapabilityKeys(fixture.schema) {
        var missing = valid
        missing["capabilities"]?[name]?[key] = nil
        try expectFailure(AgentProtocol.B4Agent.self, value: missing, path: ["capabilities", name, key])
        var malformed = valid
        malformed["capabilities"]?[name]?[key] = .null
        try expectFailure(AgentProtocol.B4Agent.self, value: malformed, path: ["capabilities", name, key])
      }
    }
  }

  @Test func knownB4CapabilitiesEnforceFrozenConstantsAndEnums() throws {
    let mutations: [(String, String, AgentProtocol.Value)] = [
      ("capability protocol", "openapi", .string("unsupported")),
      ("capability protocol", "cddl", .string("unsupported")),
      ("capability protocol", "profile", .string("unsupported")),
      ("capability recovery", "threadMetadata", .string("unsupported")),
      ("capability recovery", "historyMetadata", .string("unsupported")),
      ("capability recovery", "eventEnvelope", .string("unsupported")),
      ("capability permissions", "completeSet", .bool(false)),
      ("capability permissions", "decisions", .array([.string("once")])),
      ("capability permissions", "grants", .string("unsupported")),
      ("capability controls", "forkNamespaces", .string("unsupported")),
      ("capability store", "conditionalWrites", .bool(false)),
    ]
    for (fixtureName, field, value) in mutations {
      let suffix = String(fixtureName.dropFirst("capability ".count))
      let name = "run.b4." + suffix
      var capability = try fixture(fixtureName)
      capability[field] = value
      let agent = try agentWithCapabilities([name: capability])
      try expectFailure(AgentProtocol.B4Agent.self, value: agent, path: ["capabilities", name, field])
    }
  }

  @Test func knownAgentSchemasAndLimitsEnforceAllImportedShapes() throws {
    let cases = try corpus().b4.filter { $0.schema == "AgentSchemasV1" || $0.schema == "AgentLimitsV1" }
    for fixture in cases {
      var metadata = try self.fixture("agent metadata")
      metadata[fixture.schema == "AgentSchemasV1" ? "schemas" : "limits"] = fixture.value
      if fixture.valid == true {
        let decoded = try JSONDecoder().decode(
          AgentProtocol.AgentMetadata.self, from: JSONEncoder().encode(metadata))
        try roundTrip(decoded, equals: metadata)
      } else {
        do {
          _ = try JSONDecoder().decode(AgentProtocol.AgentMetadata.self, from: JSONEncoder().encode(metadata))
          Issue.record("Accepted invalid known schema/limit corpus case: \(fixture.name)")
        } catch is DecodingError {}
      }
    }
    var schemas = try fixture("agent metadata")
    schemas["schemas"] = try fixture("agent custom schema must be an object")
    try expectFailure(
      AgentProtocol.AgentMetadata.self, value: schemas, path: ["schemas", "custom", "b4.input"])
    var limits = try fixture("agent metadata")
    limits["limits"] = try fixture("agent limits partial inspection.defaults")
    try expectFailure(
      AgentProtocol.AgentMetadata.self, value: limits, path: ["limits", "inspection", "defaults"])
  }

  @Test func knownAguiCapabilityUsesFrozenNativeCapabilitiesShape() throws {
    let cases = try corpus().b4.filter { $0.schema == "NativeAgentCapabilities" }
    for fixture in cases {
      var agui = try self.fixture("capability agui")
      agui["capabilities"] = fixture.value
      let agent = try agentWithCapabilities(["run.b4.agui": agui])
      if fixture.valid == true {
        let decoded = try JSONDecoder().decode(AgentProtocol.B4Agent.self, from: JSONEncoder().encode(agent))
        try roundTrip(decoded, equals: agent)
      } else {
        do {
          _ = try JSONDecoder().decode(AgentProtocol.B4Agent.self, from: JSONEncoder().encode(agent))
          Issue.record("Accepted invalid known native-capability corpus case: \(fixture.name)")
        } catch is DecodingError {}
      }
    }
  }

  @Test func unknownOptionalCapabilitiesAndFieldsStayOpaqueForBothProfiles() throws {
    var recovery = try fixture("capability recovery")
    recovery["future"] = .array([.null, .object(["opaque": .integer(9)])])
    var agent = try agentWithCapabilities([
      "run.b4.recovery": recovery,
      "run.b4.future": .object(["v": .integer(99), "opaque": .array([.null])]),
      "com.example.future": .array([.string("unknown"), .bool(true)]),
    ])
    let b4 = try JSONDecoder().decode(AgentProtocol.B4Agent.self, from: JSONEncoder().encode(agent))
    try roundTrip(b4, equals: agent)
    agent["capabilities"]?["run.b4.recovery"]?["v"] = .integer(2)
    let generic = try JSONDecoder().decode(AgentProtocol.Agent.self, from: JSONEncoder().encode(agent))
    try roundTrip(generic, equals: agent)
    try expectFailure(
      AgentProtocol.B4Agent.self, value: agent, path: ["capabilities", "run.b4.recovery", "v"])
  }
  @Test func snapshotMethodIsValuesWhileUnknownEventJSONIsPreserved() throws {
    let source = try fixture("hydration no invented sequence")
    for method in ["lifecycle", "custom"] {
      var invalid = source
      invalid["method"] = .string(method)
      try expectFailure(AgentProtocol.SnapshotEvent.self, value: invalid, path: ["method"])
    }
    var snapshot = source
    snapshot["future"] = .string("retained")
    snapshot["params"]?["data"] = .array([.object(["opaque": .null])])
    let decoded = try JSONDecoder().decode(
      AgentProtocol.SnapshotEvent.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded.event.method == "values")
    try roundTrip(decoded, equals: snapshot)

    var ordinary = try fixture("extensible event")
    ordinary["params"]?["future"] = .object(["unknown": .array([.null, .integer(9)])])
    let event = try JSONDecoder().decode(AgentProtocol.Event.self, from: JSONEncoder().encode(ordinary))
    try roundTrip(event, equals: ordinary)
  }

  @Test func snapshotParamsEnforceTheClosedCarrierWithoutNarrowingTimestampOrData() throws {
    let source = try fixture("hydration no invented sequence")
    for key in ["namespace", "timestamp", "data"] {
      var missing = source
      missing["params"]?[key] = nil
      try expectFailure(AgentProtocol.SnapshotEvent.self, value: missing, path: ["params", key])
    }
    for namespace in [AgentProtocol.Value.null, .string("not-an-array"), .bool(false)] {
      var invalid = source
      invalid["params"]?["namespace"] = namespace
      try expectFailure(AgentProtocol.SnapshotEvent.self, value: invalid, path: ["params", "namespace"])
    }
    var invalidEntry = source
    invalidEntry["params"]?["namespace"] = .array([.integer(9)])
    try expectFailure(
      AgentProtocol.SnapshotEvent.self, value: invalidEntry, path: ["params", "namespace", "Index 0"])
    for timestamp in [AgentProtocol.Value.integer(-1), .decimal(Decimal(0.5)), .string("0"), .null] {
      var invalid = source
      invalid["params"]?["timestamp"] = timestamp
      try expectFailure(AgentProtocol.SnapshotEvent.self, value: invalid, path: ["params", "timestamp"])
    }
    var extra = source
    extra["params"]?["future"] = .object(["opaque": .null])
    try expectFailure(AgentProtocol.SnapshotEvent.self, value: extra, path: ["params", "future"])

    let timestamps: [AgentProtocol.Value] = [
      .integer(9_007_199_254_740_992), .unsignedInteger(UInt64.max),
      .decimal(Decimal(sign: .plus, exponent: 40, significand: 1)), .real(1e200),
    ]
    for timestamp in timestamps {
      var snapshot = source
      snapshot["params"]?["timestamp"] = timestamp
      let decoded = try JSONDecoder().decode(
        AgentProtocol.SnapshotEvent.self, from: JSONEncoder().encode(snapshot))
      try roundTrip(decoded, equals: snapshot)
    }
    let values: [AgentProtocol.Value] = [
      .null, .bool(false), .integer(9), .decimal(Decimal(0.5)), .string("opaque"),
      .array([.null, .object(["future": .bool(true)])]), .object(["unknown": .array([.null])]),
    ]
    for value in values {
      var snapshot = source
      snapshot["params"]?["data"] = value
      snapshot["future"] = .object(["retained": .bool(true)])
      let decoded = try JSONDecoder().decode(
        AgentProtocol.SnapshotEvent.self, from: JSONEncoder().encode(snapshot))
      try roundTrip(decoded, equals: snapshot)
    }
  }
}
