import Darwin
import Foundation

/// Owner-only publication on one anchored directory. No authority is passed to observations.
enum ArchivePublication {
  enum Stage { case contentsWritten, fileSynchronized, renamed, directorySynchronized }
  private enum Failure: Error { case unavailable }

  /// Newly made directories are0700. Existing owner directories retain their permissions; a readable
  /// parent does not make a0600 file public. Group/world-writable final directories are refused.
  /// Each component is opened relative to the previous fd without following symlinks.
  static func directory(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/"), path != "/" else { throw Failure.unavailable }
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard current >= 0 else { throw Failure.unavailable }
    do {
      for component in path.split(separator: "/") {
        let name = String(component)
        guard name != ".", name != "..", !name.utf8.contains(0) else { throw Failure.unavailable }
        var next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if next < 0, errno == ENOENT {
          guard mkdirat(current, name, mode_t(0o700)) == 0 || errno == EEXIST else {
            throw Failure.unavailable
          }
          next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard next >= 0 else { throw Failure.unavailable }
        Darwin.close(current); current = next
      }
      var info = stat()
      guard fstat(current, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
        info.st_uid == getuid(), info.st_mode & 0o022 == 0
      else { throw Failure.unavailable }
      return current
    } catch { Darwin.close(current); throw error }
  }

  /// Preserve existing overwrite behavior. Before rename every failure keeps the old file intact.
  /// After rename a directory-sync/observer failure may leave the complete new file published;
  /// callers report failure without promising impossible old-file rollback.
  static func write(
    to requestedPath: String, privateDirectory: Bool = false, observe: ((Stage) throws -> Void)? = nil,
    contents: (FileHandle) throws -> Void
  ) throws {
    guard !requestedPath.isEmpty, !requestedPath.hasSuffix("/"), !requestedPath.utf8.contains(0)
    else { throw Failure.unavailable }
    // Foundation standardization can rewrite an existing /private path through a symlink alias.
    // Keep its spelling; the anchored no-follow walk below validates the actual parent chain.
    let url = URL(fileURLWithPath: requestedPath)
    let name = url.lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { throw Failure.unavailable }
    let parent = try directory(url.deletingLastPathComponent().path)
    defer { Darwin.close(parent) }
    if privateDirectory, fchmod(parent, mode_t(0o700)) != 0 { throw Failure.unavailable }
    var old = stat()
    if fstatat(parent, name, &old, AT_SYMLINK_NOFOLLOW) == 0 {
      guard old.st_mode & S_IFMT == S_IFREG, old.st_uid == getuid() else { throw Failure.unavailable }
    } else if errno != ENOENT {
      throw Failure.unavailable
    }
    let temporary = ".\(UUID().uuidString).partial"
    let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw Failure.unavailable }
    guard fchmod(fd, mode_t(0o600)) == 0 else {
      Darwin.close(fd); _ = unlinkat(parent, temporary, 0); throw Failure.unavailable
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var renamed = false
    defer {
      try? handle.close()
      if !renamed { _ = unlinkat(parent, temporary, 0) }
    }
    try contents(handle)
    try observe?(.contentsWritten)
    try handle.synchronize()
    try handle.close()
    try observe?(.fileSynchronized)
    guard renameat(parent, temporary, parent, name) == 0 else { throw Failure.unavailable }
    renamed = true
    try observe?(.renamed)
    guard Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
    try observe?(.directorySynchronized)
  }
}
