import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@MainActor
@Suite struct ListSearchTests {
  private func model() -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
    for (id, title) in [("t1", "Trip notes"), ("t2", "Release checklist")] {
      model.store(
        ConversationThread(
          id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: title, context: "/tmp"))
    }
    return model
  }

  /// The iPhone's search is the Search sheet (D-201): the list itself is never narrowed by a query,
  /// and an account that ends closes the sheet, so the next account's list starts without it.
  @Test func theSearchSheetResetsWithTheAccount() {
    let model = model()
    model.showSearch = true
    #expect(Set(model.orderedThreads.map(\.id)) == ["t1", "t2"])
    model.forgetWorkspace()
    #expect(!model.showSearch)
  }
}
