import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The reason line's time, which compares the Mac's clock (the reply) with this device's.
@Suite struct ReasonLineTimeTests {
  private let now = Date(timeIntervalSince1970: 1_793_000_600)

  private func replied(secondsAgo: Double, outcome: TurnOutcome = .completed) -> ConversationThread {
    ConversationThread(
      id: "t", connectionId: "c1", nativeThreadId: "n-t", title: "t",
      activity: ThreadActivity(
        latestTurnId: "u1", latestTurnStatus: .terminal, latestTurnOutcome: outcome,
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

  /// A failure keeps its word and its time once it is read: it stays failed.
  @Test func aFailureSaysFailedWithItsTimeReadOrNot() {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    model.now = { [now] in now }
    var failed = replied(secondsAgo: 180, outcome: .failed)
    let unread = model.reasonLine(for: failed)
    #expect(unread.hasPrefix("Failed ") && unread.contains("3"))
    failed.readTurnId = "u1"
    #expect(model.state(of: failed) == .failed)
    #expect(model.reasonLine(for: failed) == unread)
    #expect(model.reasonLine(for: replied(secondsAgo: 30, outcome: .cancelled)) == "Stopped just now")
  }
}
