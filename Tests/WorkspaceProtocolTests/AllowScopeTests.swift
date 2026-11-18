import Foundation
import Testing

@testable import WorkspaceProtocol

@Suite struct AllowScopeTests {
  @Test func aRequestsPayloadGivesItsScope() {
    #expect(AllowScope(requestPayload: ["request": ["allowScope": "session"]]) == .session)
    #expect(AllowScope(requestPayload: ["request": ["allowScope": "always"]]) == .always)
  }

  @Test func noScopeOrAnUnknownOneIsNone() {
    #expect(AllowScope(requestPayload: ["request": ["command": "ls"]]) == nil)
    #expect(AllowScope(requestPayload: ["request": ["allowScope": "forever"]]) == nil)
    #expect(AllowScope(requestPayload: [:]) == nil)
    // Beside the request, not in it: not the adapter's field.
    #expect(AllowScope(requestPayload: ["allowScope": "session"]) == nil)
  }
}
