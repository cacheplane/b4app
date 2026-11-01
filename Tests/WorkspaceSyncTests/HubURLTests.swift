import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct HubURLTests {
  @Test func rejectsPlainHTTPOffLoopback() {
    #expect(throws: WorkspaceError.self) { try HubURL.validate("http://192.168.1.10:8080") }
    #expect(throws: WorkspaceError.self) { try HubURL.validate("http://hub.example.test") }
    #expect(throws: WorkspaceError.self) { try HubURL.validate("http://localhost.evil.test") }
    #expect(throws: WorkspaceError.self) { try HubURL.validate("ftp://hub.example.test") }
  }

  @Test func rejectionUsesTheProtocolInvalidCodeAndTheFixedMessage() {
    do {
      _ = try HubURL.validate("http://10.0.0.5")
      Issue.record("expected a rejection")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
      #expect(error.message == "The hub URL must use https (http is allowed only for localhost).")
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test func acceptsHTTPSAnywhereAndHTTPOnLoopback() throws {
    #expect(try HubURL.validate("https://hub.example.test").scheme == "https")
    #expect(try HubURL.validate("http://localhost:8080").host == "localhost")
    #expect(try HubURL.validate("http://127.0.0.1:8080").host == "127.0.0.1")
    #expect(try HubURL.validate("http://[::1]:8080").host == "::1")
    #expect(try HubURL.validate("  HTTPS://Hub.Example.test/base  ").host == "hub.example.test")
  }

  @Test func rejectsStringsThatAreNotURLs() {
    #expect(throws: WorkspaceError.self) { try HubURL.validate("") }
    #expect(throws: WorkspaceError.self) { try HubURL.validate("not a url") }
    #expect(throws: WorkspaceError.self) { try HubURL.validate("https://") }
  }
}
