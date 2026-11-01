import Darwin
import Foundation

/// What the kernel says about a process: enough to tell "the server we started" from "whatever now
/// has that pid" (spec 9.4, D-025). A pid alone never establishes ownership.
public struct ProcessIdentity: Sendable, Equatable, Codable {
  public var pid: Int32
  /// Seconds since the epoch at which the process started.
  public var startedAt: Double
  public var arguments: [String]

  public init(pid: Int32, startedAt: Double, arguments: [String]) {
    self.pid = pid
    self.startedAt = startedAt
    self.arguments = arguments
  }

  /// True when `other` is plausibly the same process: same pid, start times within a second, and
  /// every expected argument present.
  public func matches(pid other: Int32, startedAt otherStart: Double, requiredArguments: [String]) -> Bool {
    pid == other && abs(startedAt - otherStart) < 1
      && requiredArguments.allSatisfy { required in arguments.contains(required) }
  }
}

public enum ProcessInspector {
  /// `KERN_PROC_PID` for the start time and `KERN_PROCARGS2` for the argv. Nil when no such process
  /// exists or it is a zombie.
  public static func identity(pid: Int32) -> ProcessIdentity? {
    guard let info = kinfo(pid: pid), Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
    let start = info.kp_proc.p_starttime
    let startedAt = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    return ProcessIdentity(pid: pid, startedAt: startedAt, arguments: arguments(pid: pid))
  }

  /// Where the process's executable is now, from `proc_pidpath`: the file's current path, so a
  /// moved bundle shows its new location. Nil when the process is gone or the path is unknown.
  public static func executablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer[..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  public static func isAlive(pid: Int32) -> Bool {
    guard pid > 0, let info = kinfo(pid: pid) else { return false }
    return Int32(info.kp_proc.p_stat) != SZOMB
  }

  private static func kinfo(pid: Int32) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let status = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    guard status == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
    return info
  }

  /// argv from `KERN_PROCARGS2`: an argc, the executable path, padding, then NUL-separated strings.
  private static func arguments(pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
      return []
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var index = MemoryLayout<Int32>.size
    // Executable path, then NUL padding up to the first argument.
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var result: [String] = []
    while index < size, result.count < argc {
      var end = index
      while end < size, buffer[end] != 0 { end += 1 }
      result.append(String(decoding: buffer[index..<end], as: UTF8.self))
      index = end + 1
    }
    return result
  }
}
