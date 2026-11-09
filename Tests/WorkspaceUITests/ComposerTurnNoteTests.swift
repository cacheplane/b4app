import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The line above the composer while a turn holds the draft speaks in words, never a status's raw
/// value: the phone showed "A turn is waiting_for_user." during a live approval (2026-11-09).
@Suite struct ComposerTurnNoteTests {
  @Test(arguments: TurnStatus.allCases)
  func everyStatusReadsAsWords(_ status: TurnStatus) {
    let note = ComposerView.turnNote(for: status)
    #expect(!note.contains("_"), "\(status): \(note)")
    #expect(note.hasSuffix("Your draft stays here until it finishes."))
  }

  @Test func waitingSaysItIsWaitingForYou() {
    #expect(
      ComposerView.turnNote(for: .waitingForUser)
        == "The turn is waiting for you. Your draft stays here until it finishes.")
    #expect(
      ComposerView.turnNote(for: .running) == "A turn is running. Your draft stays here until it finishes.")
  }
}
