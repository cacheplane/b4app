import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

struct OwnedProtocolProofWriteTests {
  @Test func losingTheCommitAcknowledgementLeavesTheWriteOutcomeUnknown() {
    let decision = ProtocolProofSettlementClassifier.classify(
      beginSent: true, rollbackAcknowledged: false, commitSent: true, commitAcknowledged: false)
    #expect(decision == .unknown)
  }

  @Test func bindVerifyAndFenceRequireTheOriginalMembershipAndCredential() throws {
    let db = try AgentProtocolResourceFixture.database()
    defer { try? db.close() }
    let link = WorkspaceDatabase.HubLink(
      url: "https://example.invalid/proof", deviceId: "device", deviceName: "Mac",
      tokenRef: "secret:original", orgSlug: "display", username: "display", joinedAt: "then")
    try db.saveHubLink(link)
    _ = try db.insertConnection(
      Connection(
        id: "modern", kind: .agentProtocol, label: "Modern", target: "https://example.invalid/agent",
        nativeScope: "opaque", peerProfile: .agentProtocol, agentId: "agent",
        authMode: ConnectionAuthMode.none))
    let binding = try ProtocolMembershipBinding(
      accountID: "account", canonicalHubBase: link.url, hubUserID: "user", hubOrgID: "org",
      deviceID: link.deviceId, databaseName: db.endpoint.database, linkJoinedAt: link.joinedAt)
    let membership = try ProtocolNativeMembership(
      canonicalHubBase: link.url, deviceID: link.deviceId, linkJoinedAt: link.joinedAt)
    let anchor = try db.captureProtocolVerification(
      accountID: binding.accountID, expectedMembership: membership)
    let admission = ProtocolProofMemoryAdmission {}
    let refused = db.prepareProtocolVerification(
      expectedSnapshot: anchor, expectedBinding: binding, expectedTokenRef: "secret:other",
      memoryAdmission: admission)
    #expect(refused.disposition == .confirmedNoncommit)
    #expect(throws: (any Error).self) {
      try refused.currentSuccessor(
        expectedSnapshot: anchor, expectedTokenRef: link.tokenRef, memoryAdmission: admission)
    }
    try db.validateProtocolVerification(expectedSnapshot: anchor)
    let bind = db.prepareProtocolVerification(
      expectedSnapshot: anchor, expectedBinding: binding, expectedTokenRef: link.tokenRef,
      memoryAdmission: admission)
    try #require(bind.disposition == .committedCurrent)
    let bound = try bind.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: link.tokenRef, memoryAdmission: admission)
    let observation = try ProtocolVerificationObservation(
      binding: binding, reportedMinimum: 2, reportedVersion: 7, healthy: true)
    let positive = db.commitObservedProtocolFact(
      expectedSnapshot: bound, expectedBindingReceipt: bind, observation: observation,
      expectedTokenRef: link.tokenRef,
      memoryAdmission: admission)
    try #require(positive.disposition == .committedCurrent)
    let verified = try positive.currentSuccessor(
      expectedSnapshot: bound, expectedTokenRef: link.tokenRef, memoryAdmission: admission)
    try db.validateProtocolVerification(expectedSnapshot: verified)
    #expect(verified.observation == observation)
    let fence = db.fenceProtocolVerification(
      expectedSnapshot: anchor, expectedBinding: binding, expectedTokenRef: link.tokenRef,
      memoryAdmission: admission)
    try #require(fence.disposition == .committedCurrent)
    #expect(throws: (any Error).self) { try db.validateProtocolVerification(expectedSnapshot: verified) }
    let cleared = try fence.currentSuccessor(
      expectedSnapshot: anchor, expectedTokenRef: link.tokenRef, memoryAdmission: admission)
    try db.validateProtocolVerification(expectedSnapshot: cleared)
    #expect(cleared.observation == nil)
    #expect(try db.hubLink() == link)
  }
}
