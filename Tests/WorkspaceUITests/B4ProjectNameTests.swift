import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// "B4 project" is a different feature from the environment (D-201) and keeps its name everywhere.
/// These guard against the environments rename reaching it.
@Suite struct B4ProjectNameTests {
  @Test func b4ProjectsKeepTheirName() throws {
    #expect(SettingsPage.servers.title == "B4 projects")
    #expect(B4ProjectSummary.folder("/opt/x", home: "/Users/someone") == "/opt/x")

    let server = LocalServer(
      id: "s", name: "support-bot", projectPath: "/tmp/app", nodePath: "/n", cliPath: "/c",
      launchMode: .development)
    let data = try JSONEncoder().encode(server)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["projectPath"] as? String == "/tmp/app")
    #expect(object["environmentPath"] == nil)
    let decoded = try JSONDecoder().decode(LocalServer.self, from: data)
    #expect(decoded.projectPath == "/tmp/app")
  }
}
