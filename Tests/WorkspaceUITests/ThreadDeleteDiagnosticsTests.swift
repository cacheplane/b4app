import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite struct ThreadDeleteDiagnosticsTests {
  @Test func countsAreNamedByRuntime() {
    #expect(DiagnosticsView.threadDeletes([]) == [])
    #expect(
      DiagnosticsView.threadDeletes([
        ThreadDeleteSummary(kind: .codex, waiting: 2, unsupported: 0),
        ThreadDeleteSummary(kind: .b4, waiting: 1, unsupported: 3),
      ])
        == [
          .init(runtime: "Codex", value: "2 waiting"),
          .init(runtime: "B4", value: "1 waiting, 3 not supported"),
        ])
  }
}
