import Darwin
import Foundation
import Testing

@testable import WorkspaceStorage

/// Test fixture selection follows a trusted existing base once. The publisher itself must still
/// reject aliases, including an explicitly created alias on machines whose TMPDIR is already real.
@Suite struct ArchivePublicationPathTests {
  private func root() throws -> String {
    let root =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "publication-path-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return root
  }

  @Test func rawPhysicalBasePublishesIntoAFreshPrivateParent() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let directory = root + "/fresh/parent"
    let path = directory + "/archive.jsonl"
    let bytes = Data("fixed publication control\n".utf8)
    #expect(!FileManager.default.fileExists(atPath: directory))
    var stages: [Int] = []
    try ArchivePublication.write(
      to: path, privateDirectory: true,
      observe: { stage in
        switch stage {
        case .contentsWritten: stages.append(1)
        case .fileSynchronized: stages.append(2)
        case .renamed: stages.append(3)
        case .directorySynchronized: stages.append(4)
        }
      }
    ) { try $0.write(contentsOf: bytes) }
    #expect(stages == [1, 2, 3, 4])
    let complete = try Data(contentsOf: URL(fileURLWithPath: path)) == bytes
    #expect(complete)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["archive.jsonl"])
    var parent = stat(), file = stat()
    try #require(lstat(directory, &parent) == 0 && lstat(path, &file) == 0)
    #expect(
      parent.st_mode & S_IFMT == S_IFDIR && parent.st_uid == getuid() && parent.st_mode & 0o777 == 0o700)
    #expect(file.st_mode & S_IFMT == S_IFREG && file.st_uid == getuid() && file.st_mode & 0o777 == 0o600)
  }

  @Test func explicitAliasRemainsARefusedInputAndCannotReplaceTheRealCanary() throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let real = root + "/real", alias = root + "/alias"
    try FileManager.default.createDirectory(
      atPath: real, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let canary = real + "/archive.jsonl", bytes = Data("retain the original canary\n".utf8)
    try bytes.write(to: URL(fileURLWithPath: canary))
    try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: real)
    var original = stat(), originalAlias = stat()
    try #require(lstat(canary, &original) == 0 && lstat(alias, &originalAlias) == 0)
    try #require(originalAlias.st_mode & S_IFMT == S_IFLNK)
    // Never canonicalize this adversarial input. Close any unexpectedly returned FD before failing.
    var directoryRefused = false
    do {
      let fd = try ArchivePublication.directory(alias + "/should-not-exist")
      let closed = Darwin.close(fd)
      #expect(closed == 0)
    } catch { directoryRefused = true }
    #expect(directoryRefused)
    #expect(!FileManager.default.fileExists(atPath: real + "/should-not-exist"))
    var writeRefused = false, contentsReached = false
    do {
      try ArchivePublication.write(to: alias + "/archive.jsonl") { handle in
        contentsReached = true
        try handle.write(contentsOf: Data("replacement must not be written".utf8))
      }
    } catch { writeRefused = true }
    #expect(writeRefused && !contentsReached)
    let unchanged = try Data(contentsOf: URL(fileURLWithPath: canary)) == bytes
    #expect(unchanged)
    var current = stat(), currentAlias = stat()
    try #require(lstat(canary, &current) == 0 && lstat(alias, &currentAlias) == 0)
    #expect(current.st_dev == original.st_dev && current.st_ino == original.st_ino)
    #expect(
      currentAlias.st_mode & S_IFMT == S_IFLNK && currentAlias.st_dev == originalAlias.st_dev
        && currentAlias.st_ino == originalAlias.st_ino)
    #expect(try FileManager.default.contentsOfDirectory(atPath: real) == ["archive.jsonl"])
  }
}
