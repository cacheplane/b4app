import Foundation
import Testing

@testable import WorkspaceMirror

private func scratchDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "mirror-location-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func write(_ text: String, to url: URL) throws {
  try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
  String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

@Suite struct MirrorLocationTests {
  @Test func movesAllThreeFiles() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old", isDirectory: true)
    let new = root.appendingPathComponent("group/b4app", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      try write("old\(suffix)", to: old.appendingPathComponent(MirrorLocation.fileName + suffix))
    }
    #expect(try MirrorLocation.move(from: old, to: new) == .moved)
    for suffix in ["", "-wal", "-shm"] {
      let name = MirrorLocation.fileName + suffix
      #expect(try read(new.appendingPathComponent(name)) == "old\(suffix)")
      #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent(name).path))
    }
  }

  @Test func movesOnlyTheFilesThatExist() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old", isDirectory: true)
    let new = root.appendingPathComponent("new", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try write("main", to: old.appendingPathComponent(MirrorLocation.fileName))
    #expect(try MirrorLocation.move(from: old, to: new) == .moved)
    #expect(try read(new.appendingPathComponent(MirrorLocation.fileName)) == "main")
    #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("mirror.sqlite-wal").path))
  }

  @Test func failedMainMovePutsTheSideFilesBack() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old", isDirectory: true)
    let new = root.appendingPathComponent("group/b4app", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      try write("old\(suffix)", to: old.appendingPathComponent(MirrorLocation.fileName + suffix))
    }
    struct RenameFailed: Error {}
    // Every rename works except the main file's into the new directory.
    #expect(throws: RenameFailed.self) {
      try MirrorLocation.move(
        from: old, to: new,
        moveItem: { source, target in
          if source.lastPathComponent == MirrorLocation.fileName, target.path.hasPrefix(new.path) {
            throw RenameFailed()
          }
          try FileManager.default.moveItem(at: source, to: target)
        })
    }
    for suffix in ["", "-wal", "-shm"] {
      let name = MirrorLocation.fileName + suffix
      #expect(try read(old.appendingPathComponent(name)) == "old\(suffix)")
      #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent(name).path))
    }
  }

  @Test func nothingToMove() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old", isDirectory: true)
    let new = root.appendingPathComponent("new", isDirectory: true)
    #expect(try MirrorLocation.move(from: old, to: new) == .nothingToMove)
    // Stray side files without a main file are left alone.
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try write("wal", to: old.appendingPathComponent("mirror.sqlite-wal"))
    #expect(try MirrorLocation.move(from: old, to: new) == .nothingToMove)
    #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("mirror.sqlite-wal").path))
    #expect(!FileManager.default.fileExists(atPath: new.path))
  }

  @Test func moveKeepsBothWhenGroupHasOne() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old", isDirectory: true)
    let new = root.appendingPathComponent("new", isDirectory: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
    try write("old", to: old.appendingPathComponent(MirrorLocation.fileName))
    try write("old-wal", to: old.appendingPathComponent("mirror.sqlite-wal"))
    try write("group", to: new.appendingPathComponent(MirrorLocation.fileName))
    #expect(try MirrorLocation.move(from: old, to: new) == .keptGroupCopy)
    #expect(try read(old.appendingPathComponent(MirrorLocation.fileName)) == "old")
    #expect(try read(old.appendingPathComponent("mirror.sqlite-wal")) == "old-wal")
    #expect(try read(new.appendingPathComponent(MirrorLocation.fileName)) == "group")
    #expect(!FileManager.default.fileExists(atPath: new.appendingPathComponent("mirror.sqlite-wal").path))
  }

  @Test func missingGroupFallsBack() throws {
    let fallback = URL(fileURLWithPath: "/tmp/fallback/b4app", isDirectory: true)
    let unresolved = MirrorLocation.storeDirectory(
      appGroup: "group.example.missing", fallback: fallback, resolve: { _ in nil })
    #expect(unresolved.directory == fallback)
    #expect(!unresolved.inGroup)
    let noGroup = MirrorLocation.storeDirectory(
      appGroup: nil, fallback: fallback, resolve: { _ in URL(fileURLWithPath: "/never/used") })
    #expect(noGroup.directory == fallback)
    #expect(!noGroup.inGroup)
  }

  @Test func groupDirectoryIsUsedWhenResolved() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fallback = root.appendingPathComponent("fallback", isDirectory: true)
    let resolved = MirrorLocation.storeDirectory(
      appGroup: "group.example.app", fallback: fallback,
      resolve: { id in
        #expect(id == "group.example.app")
        return root
      })
    #expect(resolved.directory == root.appendingPathComponent("b4app", isDirectory: true))
    #expect(resolved.inGroup)
    // Resolving creates nothing.
    #expect(!FileManager.default.fileExists(atPath: resolved.directory.path))
  }

  @Test func flavourFolderIsUsedInsideTheGroup() {
    let root = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
    let resolved = MirrorLocation.storeDirectory(
      appGroup: "group.example.app", folder: PhoneFlavor.beta.directoryName,
      fallback: URL(fileURLWithPath: "/tmp/fallback"), resolve: { _ in root })
    #expect(resolved.directory == root.appendingPathComponent("b4app-beta", isDirectory: true))
    #expect(resolved.inGroup)
  }
}
