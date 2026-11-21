import Darwin
import Foundation
import Synchronization
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

  /// Test-only scheduling seam; real consumers retain the continuous-clock defaults.
  struct PollSchedule: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let pause: @Sendable (Duration) async throws -> Void

    static let continuous = Self(
      now: { ContinuousClock.now }, pause: { try await Task.sleep(for: $0) })
  }

  func observed(
    _ marker: String, after start: UInt64, observation: OwnedLogWitnessTiming? = nil,
    schedule: PollSchedule = .continuous
  ) async throws -> Bool {
    let deadline = schedule.now() + .seconds(2)
    observation?.started(deadline: deadline)
    defer { observation?.returned() }
    repeat {
      observation?.readStarted()
      let matched = try tail(start).contains(marker)
      observation?.readReturned()
      if matched { return true }
      do { try await schedule.pause(.milliseconds(10)) } catch { throw Failure.unsafeLog }
    } while schedule.now() < deadline
    return false
  }
}

/// One positive scratch witness only. Reads update bounded scalars; no per-poll output.
final class OwnedLogWitnessTiming: Sendable {
  enum Stage: String, Hashable, Sendable { case issued, observerStarted, appendReturned, observerReturned }
  private struct State {
    var emitted: Set<Stage> = []
    var deadline: UInt64?
    var firstReadStarted: UInt64?
    var lastReadStarted: UInt64?
    var lastReadReturned: UInt64?
    var readCount: UInt16 = 0
    var countSaturated = false
  }
  private let origin = ContinuousClock.now
  private let state = Mutex(State())
  private let dropped = Atomic<Bool>(false)

  private func elapsed(_ instant: ContinuousClock.Instant = ContinuousClock.now) -> UInt64 {
    InspectionObservation.elapsedNanoseconds(origin.duration(to: instant))
  }
  func issued() { emit(.issued) }
  func appendReturned() { emit(.appendReturned) }
  func started(deadline: ContinuousClock.Instant) {
    let value = elapsed(deadline)
    if state.withLockIfAvailable({
      $0.deadline = value; return true
    }) == nil {
      dropped.store(true, ordering: .relaxed)
    }
    emit(.observerStarted)
  }
  func readStarted() {
    let value = elapsed()
    if state.withLockIfAvailable({ state in
      if state.firstReadStarted == nil { state.firstReadStarted = value }
      state.lastReadStarted = value
      if state.readCount < 4096 { state.readCount += 1 } else { state.countSaturated = true }
      return true
    }) == nil {
      dropped.store(true, ordering: .relaxed)
    }
  }
  func readReturned() {
    let value = elapsed()
    if state.withLockIfAvailable({
      $0.lastReadReturned = value; return true
    }) == nil {
      dropped.store(true, ordering: .relaxed)
    }
  }
  func returned() { emit(.observerReturned) }
  private func emit(_ stage: Stage) {
    let value = elapsed()
    let snapshot = state.withLockIfAvailable { state -> State? in
      guard state.emitted.insert(stage).inserted else { return nil }
      return state
    }
    guard let available = snapshot else { dropped.store(true, ordering: .relaxed); return }
    guard let sample = available else { return }
    let deadline = sample.deadline.map { String($0) } ?? "unavailable"
    let first = sample.firstReadStarted.map { String($0) } ?? "unavailable"
    let last = sample.lastReadStarted.map { String($0) } ?? "unavailable"
    let returned = sample.lastReadReturned.map { String($0) } ?? "unavailable"
    let drop = dropped.load(ordering: .relaxed)
    print(
      "OWNED_LOG_TIMING role=positiveScratch stage=\(stage.rawValue) elapsedNanoseconds=\(value) deadlineNanoseconds=\(deadline) firstReadStartedNanoseconds=\(first) lastReadStartedNanoseconds=\(last) lastReadReturnedNanoseconds=\(returned) readCount=\(sample.readCount) countSaturated=\(sample.countSaturated) partial=true joined=false lateCallbacks=unknown contentionDropAdvisory=\(drop)"
    )
  }
}
