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
    guard case .hello(let protocolVersion, _, _, let role, let heartbeat, _) = messages[0] else {
      Issue.record("first is not hello")
      return
    }
    #expect(protocolVersion == 1 && role == .client && heartbeat == 10)
    guard case .command(_, let method, _, let deadline, let from) = messages[6] else {
      Issue.record("seventh is not a command")
      return
    }
    #expect(method == .turnInterrupt && deadline != nil && from?.name == "Brian's iPhone")
    guard case .event(let event) = messages[13] else {
      Issue.record("not an event")
      return
    }
    #expect(event.kind == .messageDelta && event.threadId == "thread-1")
    #expect(
      Set(
        messages.compactMap { m -> RelayMethod? in
          if case .command(_, let method, _, _, _) = m { return method }
          return nil
        }) == Set(RelayMethod.allCases))
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
