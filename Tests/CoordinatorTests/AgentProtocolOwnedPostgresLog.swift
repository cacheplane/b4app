import Darwin
import Foundation
import WorkspacePlatform

/// Test-only reader for the exact log/socket pair selected by EphemeralPostgres.
/// Configuration comes from the fixture, never from a candidate log's basename or existence.
struct AgentProtocolOwnedPostgresLog: Sendable {
  enum Failure: Error, Sendable, Equatable { case unsafeLog, oversizedLog }

  struct Configuration: Sendable {
    let persistentDirectory: String?
    let temporaryDirectory: String?
    let foundationTemporaryDirectory: String
    let nonce: String?
    let privateRoot: String?
    let processIdentifier: Int32

    static var current: Self {
      // Copy only the four fixture fields; never retain or report the process environment.
      func field(_ name: String) -> String? {
        guard let value = getenv(name) else { return nil }
        return String(validatingCString: value)
      }
      return Self(
        persistentDirectory: field("B4APP_TEST_POSTGRES_DIR"), temporaryDirectory: field("TMPDIR"),
        foundationTemporaryDirectory: NSTemporaryDirectory(), nonce: field("B4APP_A3_NONCE"),
        privateRoot: field("B4APP_A3_PRIVATE_ROOT"),
        processIdentifier: ProcessInfo.processInfo.processIdentifier)
    }
  }

  private let path: String
  private let device: dev_t
  private let inode: ino_t

  init(_ endpoint: PostgresEndpoint, configuration: Configuration = .current) throws {
    let persistent = configuration.persistentDirectory.flatMap { $0.isEmpty ? nil : $0 }
    guard configuration.processIdentifier > 0,
      configuration.nonce == nil || persistent == nil
    else { throw Failure.unsafeLog }

    let logRoot: String, socketRoot: String
    if let persistent {
      logRoot = try Self.ownedDirectory(persistent)
      socketRoot = logRoot
    } else {
      // Mirror EphemeralPostgres: an empty TMPDIR is selected (and refused), not a fallback.
      let temporary = try Self.ownedDirectory(
        configuration.temporaryDirectory ?? configuration.foundationTemporaryDirectory)
      if let nonce = configuration.nonce {
        guard nonce.count == 12, nonce.allSatisfy({ $0.isHexDigit }),
          let privateRoot = configuration.privateRoot, configuration.temporaryDirectory != nil
        else { throw Failure.unsafeLog }
        let ownedRoot = try Self.ownedDirectory(privateRoot)
        guard ownedRoot.hasSuffix("/b4a3-" + nonce), temporary == ownedRoot + "/tmp" else {
          throw Failure.unsafeLog
        }
      }
      let short = String(configuration.processIdentifier)
      let expectedLogRoot = temporary + "/b4pg-shared-" + short
      let expectedSocketRoot = temporary + "/b4pgs-" + short
      logRoot = try Self.ownedDirectory(expectedLogRoot)
      socketRoot = try Self.ownedDirectory(expectedSocketRoot)
      // Only the configured trusted base may have an alias; derived fixture leaves stay exact.
      guard logRoot == expectedLogRoot, socketRoot == expectedSocketRoot else {
        throw Failure.unsafeLog
      }
    }

    guard Self.absolutePath(endpoint.logPath), Self.absolutePath(endpoint.socketDir),
      (endpoint.logPath as NSString).lastPathComponent == "postgres.log",
      try Self.ownedDirectory((endpoint.logPath as NSString).deletingLastPathComponent) == logRoot,
      try Self.ownedDirectory(endpoint.socketDir) == socketRoot
    else { throw Failure.unsafeLog }
    // Resolve the trusted directory only. The supplied raw leaf must reach lstat/O_NOFOLLOW.
    var info = stat()
    guard lstat(endpoint.logPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid()
    else { throw Failure.unsafeLog }
    path = endpoint.logPath
    device = info.st_dev
    inode = info.st_ino
  }

  private static func absolutePath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.utf8.contains(0)
  }

  private static func ownedDirectory(_ path: String) throws -> String {
    guard absolutePath(path) else { throw Failure.unsafeLog }
    let resolved: String
    do {
      resolved = try AgentProtocolResourceFixture.physicalExistingDirectory(path)
    } catch { throw Failure.unsafeLog }
    var info = stat()
    guard lstat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid()
    else { throw Failure.unsafeLog }
    return resolved
  }

  private func opened() throws -> FileHandle {
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.unsafeLog }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode,
      info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
    else { Darwin.close(fd); throw Failure.unsafeLog }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func offset() throws -> UInt64 {
    do {
      let handle = try opened(); defer { try? handle.close() }
      return try handle.seekToEnd()
    } catch { throw Failure.unsafeLog }
  }

  func tail(_ start: UInt64) throws -> String {
    do {
      let handle = try opened(); defer { try? handle.close() }
      let end = try handle.seekToEnd()
      guard end >= start, end - start <= 4 << 20 else { throw Failure.oversizedLog }
      try handle.seek(toOffset: start)
      let length = Int(end - start)
      var data = Data()
      while data.count < length {
        guard let chunk = try handle.read(upToCount: length - data.count), !chunk.isEmpty
        else { throw Failure.unsafeLog }
        data.append(chunk)
      }
      return String(decoding: data, as: UTF8.self)
    } catch let failure as Failure {
      throw failure
    } catch { throw Failure.unsafeLog }
  }

  func observed(_ marker: String, after start: UInt64) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    repeat {
      if try tail(start).contains(marker) { return true }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { throw Failure.unsafeLog }
    } while ContinuousClock.now < deadline
    return false
  }
}
