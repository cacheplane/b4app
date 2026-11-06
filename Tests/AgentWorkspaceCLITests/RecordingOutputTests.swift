import Foundation
import Testing
import WorkspaceProtocol

@testable import AgentWorkspaceCLI
@testable import WorkspaceClient

@Suite struct RecordingOutputTests {
  @Test(arguments: ["token", "id_token", "ID-TOKEN", "session"])
  func masksStandardCredentialKeys(key: String) throws {
    let event = RecordedEvent(
      sourceSequence: 0, elapsedMs: 0, kind: .toolCompleted, turnId: "turn",
      fields: .object(["output": .object([key: .string("opaque-value")])]))
    let safe = try RecordingOutput.sanitized([event])
    #expect(safe[0].fields["output"]?[key] == "[redacted]")
  }

  @Test(arguments: ["public", ".git", "PUBLIC", ".GIT"])
  func refusesSymlinkedProtectedParents(directory: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let protected = folder.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let alias = folder.appendingPathComponent("private-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
    #expect(throws: RecordingOutputFailure.invalidPath) {
      try RecordingOutput.write(
        events: [], appVersion: "test", path: alias.appendingPathComponent("capture.json").path)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: protected.path).isEmpty)
  }

  @Test(arguments: ["PUBLIC", ".GIT"])
  func refusesCaseVariantProtectedParents(directory: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let protected = folder.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: RecordingOutputFailure.invalidPath) {
      try RecordingOutput.write(
        events: [], appVersion: "test", path: protected.appendingPathComponent("capture.json").path)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: protected.path).isEmpty)
  }

  @Test func refusesASecretSplitAcrossDeltas() throws {
    let events = [delta(1, "sk-"), delta(2, "123456789abcdef")]
    #expect(throws: RecordingOutputFailure.unsafeStream) {
      try RecordingOutput.sanitized(events, home: "/Users/demo")
    }
  }
  @Test func masksPrivatePathsAndWholeFieldSecrets() throws {
    let event = RecordedEvent(
      sourceSequence: 1, elapsedMs: 0, kind: .toolCompleted, turnId: "turn",
      fields: ["id": "item", "output": ["text": "Read /Users/demo/project; api_key=private-value"]])
    let result = try RecordingOutput.sanitized([event], home: "/Users/demo")
    let text = String(decoding: try JSONCoding.encoder.encode(result), as: UTF8.self)
    #expect(!text.contains("/Users/demo"))
    #expect(!text.contains("private-value"))
  }
  @Test func rejectsASecretSpanningInitialTextAndDelta() throws {
    let start = RecordedEvent(
      sourceSequence: 0, elapsedMs: 0, kind: .messageStarted, turnId: "turn",
      fields: ["nativeItemId": "native", "text": "sk-"])
    #expect(throws: RecordingOutputFailure.unsafeStream) {
      try RecordingOutput.sanitized([start, delta(1, "123456789abcdef")])
    }
  }
  @Test func masksStructuredSecretValues() throws {
    let event = RecordedEvent(
      sourceSequence: 0, elapsedMs: 0, kind: .toolCompleted, turnId: "turn",
      fields: ["output": ["access_token": "private-value"]])
    let safe = try RecordingOutput.sanitized([event])
    #expect(safe[0].fields["output"]?["access_token"] == "[redacted]")
  }
  @Test func createsOwnerOnlyOutputWithoutReplacingExistingBytes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("capture.json").path
    try RecordingOutput.write(events: [delta(1, "hello")], appVersion: "test", path: path)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(throws: RecordingOutputFailure.self) {
      try RecordingOutput.write(events: [], appVersion: "test", path: path)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
  }
  private func delta(_ sequence: Int, _ text: String) -> RecordedEvent {
    RecordedEvent(
      sourceSequence: sequence, elapsedMs: Double(sequence), kind: .messageDelta, turnId: "turn",
      fields: ["nativeItemId": "native", "delta": .string(text)])
  }
}
