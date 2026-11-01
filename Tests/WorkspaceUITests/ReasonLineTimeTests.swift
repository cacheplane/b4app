import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The unread reason line's time, which compares the Mac's clock (the reply) with this device's.
@Suite struct ReasonLineTimeTests {
  private let now = Date(timeIntervalSince1970: 1_793_000_600)

  private func replied(secondsAgo: Double) -> ConversationThread {
    ConversationThread(
      id: "t", connectionId: "c1", nativeThreadId: "n-t", title: "t",
      activity: ThreadActivity(
        latestTurnId: "u1", latestTurnStatus: .terminal, latestTurnOutcome: .completed,
        lastActivityAt: Timestamp.string(from: now.addingTimeInterval(-secondsAgo))))
  }

  @Test func aReplyFromAClockAheadOfThisOneIsJustNow() {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    model.now = { [now] in now }
    #expect(model.reasonLine(for: replied(secondsAgo: -4)) == "Replied just now")
    #expect(model.reasonLine(for: replied(secondsAgo: 0)) == "Replied just now")
    #expect(model.reasonLine(for: replied(secondsAgo: 59)) == "Replied just now")
    let older = model.reasonLine(for: replied(secondsAgo: 180))
    #expect(older.hasPrefix("Replied ") && older.contains("3") && older != "Replied just now")
  }
}
