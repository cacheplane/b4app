import ArgumentParser
import Testing

@testable import AgentWorkspaceCLI

@Suite struct RecordingCommandTests {
  @Test func commandIsRegisteredAndAcceptsBoundedArguments() throws {
    let command = try AgentWorkspace.parseAsRoot([
      "docs-record", "--thread-id", "demo", "--output", "/tmp/private-recording.json",
    ])
    #expect(command is DocsRecord)
  }
  @Test func rejectsUnboundedDurationAndPublicDestination() {
    for args in [
      ["--thread-id", "demo", "--output", "/tmp/private.json", "--max-seconds", "0"],
      ["--thread-id", "demo", "--output", "/tmp/private.json", "--max-seconds", "901"],
      ["--thread-id", "demo", "--output", "/tmp/public/capture.json"],
      ["--thread-id", "demo", "--output", "relative.json"],
    ] {
      #expect(throws: (any Error).self) { _ = try DocsRecord.parse(args) }
    }
  }
}
