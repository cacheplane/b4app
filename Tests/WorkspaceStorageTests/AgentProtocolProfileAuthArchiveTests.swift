import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Authentication metadata only. No secret values, adapter admission, owner assumption or network.
@Suite(.serialized) struct AgentProtocolProfileAuthArchiveTests {
  private static func profile(_ id: String, mode: ConnectionAuthMode?) -> Connection {
    Connection(
      id: id, kind: .agentProtocol, label: id,
      target: mode == nil ? "" : "https://example.invalid/profile",
      authReference:
        mode == ConnectionAuthMode.bearer || mode == ConnectionAuthMode.header
        ? "secret:fixture-" + id : nil,
      nativeScope: #"["agent-protocol-v1","agentProtocol","https://example.invalid/profile"]"#,
      peerProfile: .agentProtocol, agentId: "fixture-agent", authMode: mode,
      authHeaderName: mode == ConnectionAuthMode.header ? "x-api-key" : nil,
      createdAt: "created", updatedAt: "updated")
  }

  @Test func archiveRetainsUnconfiguredAndExplicitDeviceAuthAsDifferentFacts() throws {
    let root = URL(fileURLWithPath: AgentProtocolResourceFixture.temporaryDirectory)
      .resolvingSymlinksInPath().appendingPathComponent("ap-auth-archive-" + UUID().uuidString).path
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let source = try AgentProtocolResourceFixture.database()
    defer { try? source.close() }
    let target = try AgentProtocolResourceFixture.database()
    defer { try? target.close() }
    let profiles = [
      Self.profile("public-only", mode: nil),
      Self.profile("explicit-none", mode: ConnectionAuthMode.none),
      Self.profile("explicit-bearer", mode: ConnectionAuthMode.bearer),
      Self.profile("explicit-header", mode: ConnectionAuthMode.header),
    ]
    for profile in profiles { _ = try source.insertConnection(profile) }
    let before = try source.listConnections(includeDisabled: true).sorted { $0.id < $1.id }
    #expect(before == profiles.sorted { $0.id < $1.id })
    let path = (root as NSString).appendingPathComponent("profiles.jsonl")
    _ = try source.export(to: path)
    // An independent raw-file oracle distinguishes SQL NULL from the explicit enum string "none".
    var archived: [String: [String: Any]] = [:]
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    for line in bytes.split(separator: 0x0a) {
      let entry = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      guard entry["table"] as? String == "connections" else { continue }
      let row = try #require(entry["row"] as? [String: Any])
      let id = try #require(row["id"] as? String)
      try #require(archived[id] == nil)
      archived[id] = row
    }
    #expect(Set(archived.keys) == Set(profiles.map(\.id)))
    let publicRow = try #require(archived["public-only"])
    #expect(publicRow["target"] as? String == "")
    #expect(publicRow["authMode"] is NSNull)
    #expect(publicRow["authHeaderName"] is NSNull)
    #expect(publicRow["authReference"] is NSNull)
    #expect(archived["explicit-none"]?["authMode"] as? String == "none")
    #expect(archived["explicit-bearer"]?["authMode"] as? String == "bearer")
    #expect(archived["explicit-bearer"]?["authReference"] as? String == "secret:fixture-explicit-bearer")
    #expect(archived["explicit-header"]?["authMode"] as? String == "header")
    #expect(archived["explicit-header"]?["authHeaderName"] as? String == "x-api-key")
    #expect(archived["explicit-header"]?["authReference"] as? String == "secret:fixture-explicit-header")
    _ = try target.restore(from: path)
    let restored = try target.listConnections(includeDisabled: true).sorted { $0.id < $1.id }
    #expect(restored == before)
    let publicProfile = try #require(restored.first { $0.id == "public-only" })
    #expect(publicProfile.authMode == nil)
    #expect(publicProfile.authMode != ConnectionAuthMode.none)
    #expect(restored.first { $0.id == "explicit-none" }?.authMode == ConnectionAuthMode.none)
    #expect(try source.listConnections(includeDisabled: true).sorted { $0.id < $1.id } == before)
    try target.close()
    try source.close()
  }
}
