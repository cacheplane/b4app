import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

/// A scratch Claude config directory: `projects/p1/s1.jsonl`, `projects/p1/s1/sub.jsonl`,
/// `projects/p1/s2.jsonl` and `projects/p2/other.txt`.
private struct DeleteRig {
  let base: String
  let projects: String
  let adapter: ClaudeAdapter

  init() throws {
    base = NSTemporaryDirectory() + "b4claude-delete-\(UUID().uuidString.prefix(8))"
    projects = base + "/projects"
    let fm = FileManager.default
    try fm.createDirectory(atPath: projects + "/p1/s1", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: projects + "/p2", withIntermediateDirectories: true)
    for file in ["p1/s1.jsonl", "p1/s1/sub.jsonl", "p1/s2.jsonl", "p2/other.txt"] {
      try Data("{}\n".utf8).write(to: URL(fileURLWithPath: projects + "/" + file))
    }
    var env = ProcessInfo.processInfo.environment
    env["CLAUDE_CONFIG_DIR"] = base
    env["FAKE_CLAUDE_PROJECTS"] = projects
    env["ANTHROPIC_API_KEY"] = nil
    adapter = ClaudeAdapter(
      connectionId: "c1", executablePath: fakeClaudePath(), environment: env, clientVersion: "test")
  }

  func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: projects + "/" + path) }

  func ref(_ id: String) -> NativeSessionRef {
    NativeSessionRef(nativeSessionId: id, nativeScope: "owner@example.com")
  }
}

@Suite struct ClaudeDeleteTests {
  @Test func removesOnlyThatSession() async throws {
    let rig = try DeleteRig()
    #expect(try await rig.adapter.deleteSession(rig.ref("s1")) == .deleted)
    #expect(!rig.exists("p1/s1.jsonl"))
    #expect(!rig.exists("p1/s1"))
    #expect(rig.exists("p1/s2.jsonl"))
    #expect(rig.exists("p2/other.txt"))
    #expect(rig.exists("p1"))
  }

  @Test func aMissingTranscriptIsAlreadyGone() async throws {
    let rig = try DeleteRig()
    #expect(try await rig.adapter.deleteSession(rig.ref("s9")) == .alreadyGone)
    #expect(rig.exists("p1/s2.jsonl"))
  }

  @Test func removesTheSessionFromEveryProjectFolder() async throws {
    let rig = try DeleteRig()
    let fm = FileManager.default
    try fm.createDirectory(atPath: rig.projects + "/p2/s1", withIntermediateDirectories: true)
    for file in ["p2/s1.jsonl", "p2/s1/sub.jsonl"] {
      try Data("{}\n".utf8).write(to: URL(fileURLWithPath: rig.projects + "/" + file))
    }
    #expect(try await rig.adapter.deleteSession(rig.ref("s1")) == .deleted)
    for gone in ["p1/s1.jsonl", "p1/s1", "p2/s1.jsonl", "p2/s1"] { #expect(!rig.exists(gone), "\(gone)") }
    #expect(rig.exists("p1/s2.jsonl"))
    #expect(rig.exists("p2/other.txt"))
  }

  @Test func anUnreadableRootIsNotAlreadyGone() async throws {
    let rig = try DeleteRig()
    let fm = FileManager.default
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rig.projects)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.projects) }
    await #expect(throws: WorkspaceError.self) { try await rig.adapter.deleteSession(rig.ref("s9")) }
  }

  @Test func aMissingRootIsNotAlreadyGone() async throws {
    let rig = try DeleteRig()
    try FileManager.default.removeItem(atPath: rig.projects)
    await #expect(throws: WorkspaceError.self) { try await rig.adapter.deleteSession(rig.ref("s9")) }
  }

  @Test func anUnsafeSessionIdIsRefused() async throws {
    let rig = try DeleteRig()
    for id in ["../x", "a/b", "", ".", "s1.jsonl"] {
      await #expect(throws: WorkspaceError.self) { try await rig.adapter.deleteSession(rig.ref(id)) }
    }
    for file in ["p1/s1.jsonl", "p1/s1/sub.jsonl", "p1/s2.jsonl", "p2/other.txt"] {
      #expect(rig.exists(file), "\(file)")
    }
  }

  @Test func theRootFollowsTheConfigDirectory() {
    #expect(
      ClaudeAdapter.projectsRoot(environment: ["CLAUDE_CONFIG_DIR": "/c", "HOME": "/h"]) == "/c/projects")
    #expect(ClaudeAdapter.projectsRoot(environment: ["HOME": "/h"]) == "/h/.claude/projects")
  }
}
