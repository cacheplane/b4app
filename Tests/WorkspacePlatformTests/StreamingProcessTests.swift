import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspacePlatform

private func collect(_ stream: AsyncStream<[UInt8]>) async -> String {
  var bytes: [UInt8] = []
  for await chunk in stream { bytes += chunk }
  return String(decoding: bytes, as: UTF8.self)
}

@Suite struct StreamingProcessTests {
  @Test func echoesWrittenLinesAndEndsAtEOF() async throws {
    let child = try StreamingProcess.start(executable: "/bin/cat", arguments: [])
    try child.write(Data("one\n".utf8))
    try child.write(Data("two\n".utf8))
    child.closeInput()
    let output = await collect(child.stdout)
    #expect(output == "one\ntwo\n")
    #expect(await child.waitForExit() == .exited(0))
  }

  @Test func terminateEndsASleepingChild() async throws {
    let child = try StreamingProcess.start(executable: "/bin/sleep", arguments: ["30"])
    child.terminate()
    let status = await child.waitForExit()
    #expect(status == .signaled(SIGTERM))
    #expect(!child.isRunning)
  }

  @Test func keepsOnlyTheTailOfStderr() async throws {
    let child = try StreamingProcess.start(
      executable: "/bin/sh",
      arguments: ["-c", "i=0; while [ $i -lt 4000 ]; do printf 'line-%05d\\n' $i 1>&2; i=$((i+1)); done"])
    _ = await child.waitForExit()
    await child.waitForStderrEnd()
    let tail = child.recentStderr()
    #expect(tail.utf8.count <= 16 * 1024)
    #expect(tail.hasSuffix("line-03999\n"))
    #expect(!tail.contains("line-00000"))
  }

  /// A child that writes to stderr and exits at once: nothing it wrote may be lost to the moment
  /// between the spawn and `start` returning. The race needs a stalled thread to show, so this passes
  /// by luck without the early buffer most of the time; it pins the contract all the same.
  @Test func keepsStderrWrittenByAChildThatExitsAtOnce() async throws {
    for _ in 0..<20 {
      let child = try StreamingProcess.start(executable: "/bin/sh", arguments: ["-c", "echo early 1>&2"])
      _ = await child.waitForExit()
      await child.waitForStderrEnd()
      #expect(child.recentStderr() == "early\n")
    }
  }

  @Test func writeAfterExitFailsWithEndpointUnavailable() async throws {
    let child = try StreamingProcess.start(executable: "/usr/bin/true", arguments: [])
    _ = await child.waitForExit()
    #expect(throws: WorkspaceError.self) { try child.write(Data("x\n".utf8)) }
  }

  @Test func missingExecutableThrowsMissingExecutable() {
    do {
      _ = try StreamingProcess.start(executable: "/nonexistent/binary", arguments: [])
      Issue.record("expected throw")
    } catch let error as WorkspaceError {
      #expect(error.code == .missingExecutable)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }
}
