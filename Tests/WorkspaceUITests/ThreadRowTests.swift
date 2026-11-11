import Foundation
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite @MainActor struct ThreadRowTests {
  @Test func quietFadesInFiveSteps() {
    #expect(QuietFade.opacity(ageInDays: 0) == 1.0)
    #expect(QuietFade.opacity(ageInDays: 0.5) == 1.0)
    #expect(QuietFade.opacity(ageInDays: 2) == 0.9)
    #expect(QuietFade.opacity(ageInDays: 5) == 0.82)
    #expect(QuietFade.opacity(ageInDays: 10) == 0.76)
    #expect(QuietFade.opacity(ageInDays: 30) == 0.72)
    // The steps change at 1, 3, 7, and 14 days.
    #expect(QuietFade.opacity(ageInDays: 1) == 0.9)
    #expect(QuietFade.opacity(ageInDays: 3) == 0.82)
    #expect(QuietFade.opacity(ageInDays: 7) == 0.76)
    #expect(QuietFade.opacity(ageInDays: 14) == 0.72)
    // A clock running behind the Mac's gives a negative age: full strength.
    #expect(QuietFade.opacity(ageInDays: -1) == 1.0)
    for days in stride(from: 0.0, through: 3650, by: 0.25) {
      #expect(QuietFade.opacity(ageInDays: days) >= 0.72)
    }
  }

  @Test func actLevelTitlesAreMedium() {
    for state in [ThreadState.approve, .reply, .failed] {
      #expect(ThreadRow.titleWeight(for: state) == .medium, "\(state)")
    }
    for state in [ThreadState.finished, .working, .quiet] {
      #expect(ThreadRow.titleWeight(for: state) == .regular, "\(state)")
    }
  }

  @Test func theRowSpeaksWhatItNoLongerShows() async throws {
    // The pin glyph, the runtime mark, and the reason are gone from the row; its label still says them,
    // with the state the mark draws.
    let model = try await ListFixture.model(extra: [ListFixture.approving])
    for thread in model.threads {
      var pinned = thread
      pinned.pinned = true
      let label = ThreadRow.accessibilityLabel(model: model, thread: pinned)
      let connection = try #require(model.connection(id: thread.connectionId)?.label)
      #expect(label.hasPrefix("Pinned, "), "\(thread.id)")
      #expect(label.contains(connection), "\(thread.id)")
      #expect(label.contains(model.state(of: thread).spokenLabel), "\(thread.id): \(label)")
      var unpinned = thread
      unpinned.pinned = false
      let unpinnedLabel = ThreadRow.accessibilityLabel(model: model, thread: unpinned)
      #expect(!unpinnedLabel.hasPrefix("Pinned"), "\(thread.id)")
    }
  }

  @Test func macRowMetricsAreOnTheGrid() {
    #if os(macOS)
      #expect(LLA.Metrics.threadRow == 28)
      #expect(LLA.Metrics.sidebarWidth == 240)
      #expect(LLA.Metrics.mark == 12)
      // Fill 8–232, title from 16, the mark's box 212–224: every edge on the 4 pt grid.
      for edge in [ThreadRow.fillInset, ThreadRow.contentInset, LLA.Metrics.mark] {
        #expect(edge.truncatingRemainder(dividingBy: 4) == 0)
      }
      #expect(ThreadRow.fillInset == 8)
      #expect(ThreadRow.fillInset + ThreadRow.contentInset == 16)
      #expect(LLA.Metrics.sidebarWidth - ThreadRow.fillInset - ThreadRow.contentInset == 224)
    #endif
  }
}
