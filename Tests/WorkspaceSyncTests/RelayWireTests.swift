import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct RelayWireTests {
  /// The fixture the hub's Rust tests read too, read in place (see `WireTests`).
  private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/\(name)")
  }

  @Test func relayFixtureRoundTrips() throws {
    let data = try Data(contentsOf: fixtureURL("relay.json"))
    let elements = try JSONCoding.decoder.decode([JSONValue].self, from: data)
    #expect(elements.count == 17)
    for element in elements {
      let elementData = try JSONCoding.encoder.encode(element)
      let message = try JSONCoding.decoder.decode(RelayMessage.self, from: elementData)
      let encoded = try JSONCoding.decoder.decode(
        JSONValue.self, from: JSONCoding.encoder.encode(message))
      #expect(encoded == element)
    }
  }

  @Test func decodesTheShapes() throws {
    let data = try Data(contentsOf: fixtureURL("relay.json"))
    let messages = try JSONCoding.decoder.decode([RelayMessage].self, from: data)
    let hello = messages.first { if case .hello = $0 { true } else { false } }
    guard case .hello(let protocolVersion, _, _, let role, let heartbeat, _)? = hello else {
      Issue.record("no hello")
      return
    }
    #expect(protocolVersion == 1 && role == .client && heartbeat == 10)
    let stamped = messages.compactMap { m -> (RelayMethod, String?, RelayFrom?)? in
      if case .command(_, let method, _, let deadline, let from) = m, deadline != nil {
        return (method, deadline, from)
      }
      return nil
    }
    #expect(stamped.map(\.0) == [.turnInterrupt, .requestRespond])
    #expect(stamped.allSatisfy { $0.2?.name == "Brian's iPhone" })
    let event = messages.compactMap { m -> AdapterEvent? in
      if case .event(let event) = m { return event }
      return nil
    }.first
    #expect(event?.kind == .messageDelta && event?.threadId == "thread-1")
    let methods = Set(
      messages.compactMap { m -> RelayMethod? in
        if case .command(_, let method, _, _, _) = m { return method }
        return nil
      })
    #expect(methods == Set(RelayMethod.allCases))
  }

  @Test func unknownErrorCodesStillDecodeAndRoundTrip() throws {
    let frames = [
      #"{"type":"error","code":"invalid_request","message":"Bad frame."}"#,
      #"{"type":"error","code":"payload_too_large","message":"Too big.","details":{"limit":65536}}"#,
      #"{"type":"reply","id":"c1","error":{"code":"invalid_request","message":"No.","details":{"a":1}}}"#,
    ]
    for frame in frames {
      let message = try JSONCoding.decoder.decode(RelayMessage.self, from: Data(frame.utf8))
      let original = try JSONCoding.decoder.decode(JSONValue.self, from: Data(frame.utf8))
      let encoded = try JSONCoding.decoder.decode(
        JSONValue.self, from: JSONCoding.encoder.encode(message))
      #expect(encoded == original)
    }
    let message = try JSONCoding.decoder.decode(RelayMessage.self, from: Data(frames[0].utf8))
    guard case .error(let code, _, _) = message else {
      Issue.record("not an error frame")
      return
    }
    #expect(code == "invalid_request" && ErrorCode(rawValue: code) == nil)

    let reply = try JSONCoding.decoder.decode(RelayMessage.self, from: Data(frames[2].utf8))
    guard case .reply(_, _, let error?) = reply else {
      Issue.record("not a reply error")
      return
    }
    #expect(error.errorCode == nil)
    #expect(error.workspaceError.code == .protocolInvalid)
    #expect(error.workspaceError.details?["relayCode"]?.stringValue == "invalid_request")
    #expect(RelayWireError(.deviceOffline, "x").workspaceError.code == .deviceOffline)
  }

  @Test func anUnknownTypeIsRefused() {
    let data = Data(#"{"type":"teleport"}"#.utf8)
    #expect(throws: (any Error).self) { try JSONCoding.decoder.decode(RelayMessage.self, from: data) }
  }

  @Test func methodsAndRolesUseTheirWireStrings() {
    #expect(
      RelayMethod.allCases.map(\.rawValue)
        == ["turn.send", "turn.interrupt", "request.respond", "thread.start", "turn.lookup"])
    #expect(RelayRole.host.rawValue == "host" && RelayRole.client.rawValue == "client")
  }

  @Test func everyErrorCodeHasItsWireString() {
    let expected: [ErrorCode: String] = [
      .deviceOffline: "device_offline", .commandExpired: "command_expired",
      .relayTimeout: "relay_timeout", .rateLimited: "rate_limited",
      .linkReplaced: "link_replaced", .clientTooOld: "client_too_old",
      .watchLimit: "watch_limit",
    ]
    for (code, wire) in expected { #expect(code.rawValue == wire) }
    #expect(ErrorCode(rawValue: "stale_runtime_request") == .staleRuntimeRequest)
  }

  @Test func limitsMatchTheHub() {
    #expect(RelayLimits.heartbeatSeconds == 10)
    #expect(RelayLimits.deadLink == .seconds(30) && RelayLimits.commandDeadline == .seconds(10))
    #expect(RelayLimits.replyWaitStart == .seconds(30) && RelayLimits.replyWaitOther == .seconds(15))
    #expect(RelayLimits.holdWindow == .seconds(60) && RelayLimits.pendingThreadTTL == .seconds(300))
    #expect(RelayLimits.clientFrameMax == 65_536 && RelayLimits.hostFrameMax == 262_144)
    #expect(RelayLimits.watchMax == 4 && RelayLimits.heldMax == 32 && RelayLimits.linkQueue == 256)
    #expect(RelayLimits.forwardedEventKinds.count == 10)
  }
}
