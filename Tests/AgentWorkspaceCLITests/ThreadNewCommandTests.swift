import ArgumentParser
import Foundation
import Testing
import WorkspaceProtocol

@testable import AgentWorkspaceCLI

@Suite struct ThreadNewCommandTests {
  private let codex = Connection(id: "c-codex", kind: .codex, label: "Codex", target: "/usr/bin/codex")

  @Test func noFolderSendsNoWorkingDirectory() throws {
    let command = try ThreadCommand.New.parse(["--connection", "codex", "--no-folder"])
    let params = command.createParams(for: codex)
    #expect(params.connectionId == codex.id)
    #expect(params.workingDirectory == nil)
  }

  @Test func cwdIsSentAndDefaultsToTheCurrentDirectory() throws {
    #expect(
      try ThreadCommand.New.parse(["--cwd", "/tmp/app"]).createParams(for: codex).workingDirectory
        == "/tmp/app")
    #expect(
      try ThreadCommand.New.parse([]).createParams(for: codex).workingDirectory
        == FileManager.default.currentDirectoryPath)
  }

  @Test func cwdAndNoFolderTogetherAreRefused() {
    #expect(throws: (any Error).self) {
      _ = try ThreadCommand.New.parse(["--cwd", "/tmp/app", "--no-folder"])
    }
  }
}
