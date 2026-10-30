import Foundation
import Testing

@testable import WorkspaceProtocol

private func command(_ json: String) -> Data { Data(json.utf8) }

private func failure(_ json: String) -> WorkspaceError? {
  do {
    _ = try parseCommand(command(json))
    return nil
  } catch {
    return WorkspaceError.from(error)
  }
}

@Suite struct ParseCommandTests {
  @Test func acceptsReadOnlyCommandWithoutOperationId() throws {
    let parsed = try parseCommand(
      command(#"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"system.ping","params":{}}"#))
    #expect(parsed.method == .systemPing)
    #expect(try parsed.params(for: SystemPing.self) == EmptyParams())
  }

  @Test func treatsMissingParamsAsEmpty() throws {
    let parsed = try parseCommand(
      command(#"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"diagnostics.read"}"#))
    #expect(parsed.params == .object([:]))
  }

  @Test func rejectsMutationWithoutOperationId() {
    let error = failure(
      #"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"draft.save","params":{"threadId":"t","text":"x"}}"#
    )
    #expect(error?.code == .protocolInvalid)
    #expect(error?.message.contains("operationId") == true)
  }

  @Test func acceptsMutationWithOperationId() throws {
    let parsed = try parseCommand(
      command(
        #"{"protocolVersion":1,"kind":"command","requestId":"r1","operationId":"op1","method":"draft.save","params":{"threadId":"t","text":"hello"}}"#
      ))
    let params = try parsed.params(for: DraftSave.self)
    #expect(params == DraftSave.Params(threadId: "t", text: "hello"))
  }

  @Test func rejectsUnknownProtocolVersion() {
    #expect(
      failure(#"{"protocolVersion":2,"kind":"command","requestId":"r1","method":"system.ping"}"#)?.code
        == .protocolInvalid)
  }

  @Test func rejectsUnknownMethod() {
    let error = failure(
      #"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"process.kill","params":{}}"#)
    #expect(error?.code == .methodUnknown)
  }

  @Test func rejectsMalformedParamsForTypedCommand() throws {
    let parsed = try parseCommand(
      command(
        #"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"draft.read","params":{"nope":1}}"#)
    )
    #expect(throws: WorkspaceError.self) { try parsed.params(for: DraftRead.self) }
  }

  @Test func rejectsNonObjectParams() {
    #expect(
      failure(
        #"{"protocolVersion":1,"kind":"command","requestId":"r1","method":"system.ping","params":[1]}"#)?.code
        == .protocolInvalid)
  }

  @Test func rejectsGarbage() {
    #expect(failure("not json")?.code == .protocolInvalid)
  }
}

@Suite struct EnvelopeTests {
  @Test func roundTripsServerEnvelopes() throws {
    let hello = HelloEnvelope(
      epoch: "e1", sequence: 0, coordinator: CoordinatorIdentity(version: "0.0.0", pid: 1))
    let response = ResponseEnvelope.failure("r", error: WorkspaceError(.notImplemented, "later"))
    let event = EventEnvelope(
      epoch: "e1", sequence: 3,
      event: .connectionChanged(
        connectionId: "c1", status: .ready, authStatus: .authenticated, transport: .connected))
    for envelope in [ServerEnvelope.hello(hello), .response(response), .event(event)] {
      let decoded = ServerEnvelope.decode(try envelope.encoded())
      #expect(decoded == envelope)
    }
  }

  @Test func ignoresUnknownKindsAndVersions() {
    #expect(ServerEnvelope.decode(Data(#"{"protocolVersion":1,"kind":"mystery"}"#.utf8)) == nil)
    #expect(ServerEnvelope.decode(Data(#"{"protocolVersion":9,"kind":"hello"}"#.utf8)) == nil)
    #expect(ServerEnvelope.decode(Data("garbage".utf8)) == nil)
  }

  @Test func capabilitiesEncodeAsObject() throws {
    let data = try JSONCoding.encoder.encode(Capabilities.unverified)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"streaming\":\"unverified\""))
    let decoded = try JSONCoding.decoder.decode(Capabilities.self, from: data)
    #expect(decoded[.streaming] == .unverified)
  }

  @Test func errorsRoundTripWithDetails() throws {
    let error = WorkspaceError.unsupported("codex.sendTurn", plannedFor: "M1")
    let data = try JSONCoding.encoder.encode(error)
    let decoded = try JSONCoding.decoder.decode(WorkspaceError.self, from: data)
    #expect(decoded == error)
    #expect(decoded.details?["milestone"]?.stringValue == "M1")
  }
}

@Suite struct NDJSONTests {
  @Test func yieldsCompleteLinesAcrossChunkBoundaries() {
    var decoder = LineDecoder()
    #expect(decoder.push(#"{"a":"#) == [])
    #expect(decoder.push("1}\n{\"b\":2}\n{\"c\"") == [#"{"a":1}"#, #"{"b":2}"#])
    #expect(decoder.push(":3}\r\n") == [#"{"c":3}"#])
    #expect(decoder.flush() == nil)
  }

  @Test func skipsBlankLinesAndFlushesTrailingPartial() {
    var decoder = LineDecoder()
    #expect(decoder.push("\n\nx\n\ny") == ["x"])
    #expect(decoder.flush() == "y")
  }

  @Test func encodesOneValuePerLine() throws {
    let line = try NDJSON.encodeLine(["a": 1])
    #expect(String(decoding: line, as: UTF8.self) == "{\"a\":1}\n")
  }
}
