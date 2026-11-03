import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

private func makeAdapter(_ environment: [String: String] = [:]) -> CodexAdapter {
  CodexAdapter(
    connectionId: "c1", executablePath: fakeCodexPath(),
    environment: ProcessInfo.processInfo.environment.merging(environment) { $1 }, clientVersion: "test")
}

@Suite(.serialized) struct CodexDeleteTests {
  @Test func deletesAThread() async throws {
    let adapter = makeAdapter()
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    #expect(try await adapter.deleteSession(ref) == .deleted)
    // The fake forgets a deleted thread, so a second delete finds nothing.
    #expect(try await adapter.deleteSession(ref) == .alreadyGone)
    await adapter.dispose()
  }

  @Test func aMissingThreadIsAlreadyGone() async throws {
    let adapter = makeAdapter()
    let ref = NativeSessionRef(nativeSessionId: "thr_missing", nativeScope: "owner@example.com")
    #expect(try await adapter.deleteSession(ref) == .alreadyGone)
    await adapter.dispose()
  }

  @Test func invalidParamsWithoutNotFoundAreNotAlreadyGone() async throws {
    let adapter = makeAdapter(["FAKE_CODEX_DELETE_INVALID": "1"])
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    await #expect(throws: WorkspaceError.self) { try await adapter.deleteSession(ref) }
    await adapter.dispose()
  }

  @Test func anOldCodexIsUnsupported() async throws {
    let adapter = makeAdapter(["FAKE_CODEX_NO_DELETE": "1"])
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    #expect(try await adapter.deleteSession(ref) == .unsupported)
    await adapter.dispose()
  }
}
