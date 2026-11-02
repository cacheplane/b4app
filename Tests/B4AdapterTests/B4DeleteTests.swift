import Foundation
import Testing
import WorkspaceProtocol

@testable import B4Adapter

private func adapter(_ server: FakeB4Server) -> B4Adapter {
  B4Adapter(
    connectionId: "b4-1", baseURL: server.baseURL, routeKey: "/chat#agent", authorization: { nil },
    authConfigured: false, clientVersion: "test")
}

@Suite struct B4DeleteTests {
  @Test func deletesAThread() async throws {
    let server = try await FakeB4Server.start()
    let b4 = adapter(server)
    let ref = try await b4.createSession(NewSessionInput())
    #expect(try await b4.deleteSession(ref) == .deleted)
    // The server no longer has it.
    #expect(try await b4.deleteSession(ref) == .alreadyGone)
    await b4.dispose()
    await server.stop()
  }

  @Test func aMissingThreadIsAlreadyGone() async throws {
    let server = try await FakeB4Server.start()
    let b4 = adapter(server)
    #expect(
      try await b4.deleteSession(NativeSessionRef(nativeSessionId: "nope", nativeScope: server.baseURL))
        == .alreadyGone)
    await b4.dispose()
    await server.stop()
  }

  @Test func aServerWithoutTheRouteIsUnsupported() async throws {
    let server = try await FakeB4Server.start(environment: ["FAKE_B4_NO_DELETE": "1"])
    let b4 = adapter(server)
    let ref = try await b4.createSession(NewSessionInput())
    #expect(try await b4.deleteSession(ref) == .unsupported)
    await b4.dispose()
    await server.stop()
  }
}
