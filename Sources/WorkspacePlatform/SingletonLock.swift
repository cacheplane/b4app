import Darwin
import Foundation

public struct LockRecord: Codable, Sendable, Equatable {
  public var pid: Int32
  public var startedAt: String
  public var socketPath: String
}

public enum LockOutcome: Sendable {
  case acquired(SingletonLock)
  case held(LockRecord?)
}

/// Advisory `flock` on a lock file. The lock is released automatically when the process exits,
/// so a crashed coordinator never leaves a live lock behind. The record inside names the holder.
public final class SingletonLock: Sendable {
  public let path: String
  private let descriptor: Int32

  private init(path: String, descriptor: Int32) {
    self.path = path
    self.descriptor = descriptor
  }

  public static func acquire(path: String, socketPath: String) throws -> LockOutcome {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let holder = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
        try? JSONDecoder().decode(LockRecord.self, from: $0)
      }
      close(fd)
      return .held(holder)
    }
    let record = LockRecord(
      pid: ProcessInfo.processInfo.processIdentifier, startedAt: ISO8601DateFormatter().string(from: Date()),
      socketPath: socketPath)
    let data = try JSONEncoder().encode(record)
    ftruncate(fd, 0)
    lseek(fd, 0, SEEK_SET)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return .acquired(SingletonLock(path: path, descriptor: fd))
  }

  /// Release and remove the lock file. Safe to call once; the descriptor is closed.
  public func release() {
    flock(descriptor, LOCK_UN)
    close(descriptor)
    try? FileManager.default.removeItem(atPath: path)
  }
}
