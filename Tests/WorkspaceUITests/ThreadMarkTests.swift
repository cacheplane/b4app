import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite @MainActor struct ThreadMarkTests {
  @Test func onlyApprovePulsesAndOnlyUntilAcknowledged() {
    #expect(ThreadMark.Motion.pulses(state: .approve, acknowledged: false, reduceMotion: false))
    #expect(!ThreadMark.Motion.pulses(state: .approve, acknowledged: true, reduceMotion: false))
    for state in ThreadState.allCases where state != .approve {
      #expect(!ThreadMark.Motion.pulses(state: state, acknowledged: false, reduceMotion: false), "\(state)")
    }
  }

  @Test func nothingMovesUnderReduceMotion() {
    for state in ThreadState.allCases {
      for acknowledged in [false, true] {
        #expect(!ThreadMark.Motion.pulses(state: state, acknowledged: acknowledged, reduceMotion: true))
      }
      #expect(!ThreadMark.Motion.orbits(state: state, reduceMotion: true), "\(state)")
    }
  }

  @Test func onlyWorkingOrbits() {
    for state in ThreadState.allCases {
      #expect(ThreadMark.Motion.orbits(state: state, reduceMotion: false) == (state == .working), "\(state)")
    }
  }

  @Test func everyStateHasItsOwnSpokenLabel() {
    let labels = ThreadState.allCases.map(\.spokenLabel)
    #expect(labels == ["Needs your approval", "Needs your reply", "Failed", "Finished", "Working", "Quiet"])
    #expect(Set(labels).count == ThreadState.allCases.count)
    #expect(labels.allSatisfy { !$0.isEmpty })
  }

  @Test func openingAThreadAcknowledgesIt() async throws {
    let (model, thread) = try await Self.approvingModel()
    #expect(!model.isAcknowledged(thread))
    await model.openThread(id: thread.id)
    #expect(model.isAcknowledged(try #require(model.threads.first { $0.id == thread.id })))
  }

  @Test func newActivityClearsTheAcknowledgement() async throws {
    let (model, thread) = try await Self.approvingModel()
    await model.openThread(id: thread.id)
    var later = try #require(model.threads.first { $0.id == thread.id })
    #expect(model.isAcknowledged(later))
    later.activity?.lastActivityAt = ListFixture.stamp(59)
    #expect(!model.isAcknowledged(later))
  }

  /// The list fixture with one more thread, waiting on an approval, whose read the transport serves.
  private static func approvingModel() async throws -> (WorkspaceModel, ConversationThread) {
    let approving = ListFixture.approving
    let transport = ScriptedTransport()
    let model = try await ListFixture.model(transport, extra: [approving])
    transport.setRead(ThreadRead.Result(thread: approving, turns: [], items: [], requests: []))
    #expect(model.state(of: approving) == .approve)
    return (model, approving)
  }
}
