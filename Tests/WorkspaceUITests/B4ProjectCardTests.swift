import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

private func server(
  _ health: LocalServerHealth, pid: Int32? = nil, port: Int? = 3000, message: String? = nil,
  path: String = "/Users/someone/repos/support-bot"
) -> LocalServer {
  LocalServer(
    id: "s", name: "support-bot", projectPath: path, nodePath: "/n", cliPath: "/c", launchMode: .development,
    requestedPort: port, actualPort: pid == nil ? nil : port, pid: pid, health: health, statusMessage: message
  )
}

@Suite struct B4ProjectCardTests {
  @Test func folderAbbreviatesTheHomeDirectory() {
    #expect(B4ProjectSummary.folder("/Users/someone/repos/x", home: "/Users/someone") == "~/repos/x")
    #expect(B4ProjectSummary.folder("/opt/x", home: "/Users/someone") == "/opt/x")
    #expect(B4ProjectSummary.folder("/Users/someone2/x", home: "/Users/someone") == "/Users/someone2/x")
  }

  @Test func stateIsThePortWhileRunningOrAWord() {
    #expect(B4ProjectSummary.state(server(.ready, pid: 42)) == ":3000")
    #expect(B4ProjectSummary.state(server(.starting, pid: 42)) == "Starting…")
    #expect(B4ProjectSummary.state(server(.stopped)) == "Stopped")
    #expect(B4ProjectSummary.state(server(.unhealthy, pid: 42)) == "Not responding")
    #expect(B4ProjectSummary.state(server(.unknown)) == "Not checked")
  }

  @Test func modeNamesAreShort() {
    #expect(B4ProjectSummary.mode(.development) == "Dev")
    #expect(B4ProjectSummary.mode(.source) == "Source")
  }
}
