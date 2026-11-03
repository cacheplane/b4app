import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@MainActor
@Suite struct ListSearchTests {
  private func model() -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    for (id, title, connection) in [
      ("t1", "Trip notes", "c1"), ("t2", "Release checklist", "c1"), ("t3", "", "c2"),
      ("t4", "trip budget", "c2"),
    ] {
      model.store(
        ConversationThread(
          id: id, connectionId: connection, nativeThreadId: "n-\(id)", title: title, context: "/tmp"))
    }
    return model
  }

  /// The iPhone's pull-down search narrows the list itself: the shown title, any case, "Untitled"
  /// for a thread without one, and together with the other filters.
  @Test func theListSearchMatchesShownTitles() {
    let model = model()
    #expect(Set(model.orderedThreads.map(\.id)) == ["t1", "t2", "t3", "t4"])
    model.listSearch = "TRIP"
    #expect(Set(model.orderedThreads.map(\.id)) == ["t1", "t4"])
    model.listSearch = "untitled"
    #expect(model.orderedThreads.map(\.id) == ["t3"])
    model.listSearch = "  trip "
    model.connectionFilter = "c2"
    #expect(model.orderedThreads.map(\.id) == ["t4"])
    model.listSearch = ""
    #expect(Set(model.orderedThreads.map(\.id)) == ["t3", "t4"])
  }
}
