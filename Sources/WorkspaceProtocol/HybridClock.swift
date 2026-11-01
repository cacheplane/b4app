import Foundation
import Synchronization

/// Wall-clock milliseconds since the Unix epoch.
public func epochMillis() -> UInt64 {
  UInt64(max(0, Date().timeIntervalSince1970 * 1000))
}

/// A hybrid logical clock stamp: 12 lowercase hex digits of epoch milliseconds, 4 of counter, then
/// the device id (`0192e0f1a2b3-0000-<device id>`). Compared as plain strings, which is the same as
/// comparing (millis, counter, device id) because the first two fields are fixed width.
public struct HLC: Comparable, Hashable, Codable, Sendable {
  /// A receiver rewrites a stamp more than this far ahead of its own wall clock.
  public static let maxAheadMillis: UInt64 = 300_000

  public let rawValue: String
  public let millis: UInt64
  public let counter: UInt16
  public let deviceId: String

  public init(millis: UInt64, counter: UInt16, deviceId: String) {
    self.millis = millis
    self.counter = counter
    self.deviceId = deviceId
    self.rawValue = Self.hex(millis, width: 12) + "-" + Self.hex(UInt64(counter), width: 4) + "-" + deviceId
  }

  /// Parses the first two `-` separated fields as millis and counter and takes the rest, which may
  /// itself contain `-` (a UUID does), as the device id. Uppercase hex, wrong widths, and an empty
  /// device id are rejected.
  public init?(rawValue: String) {
    let parts = rawValue.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 12, parts[1].count == 4, !parts[2].isEmpty,
      let millis = Self.parseHex(parts[0]), let counter = Self.parseHex(parts[1])
    else { return nil }
    self.init(millis: millis, counter: UInt16(counter), deviceId: String(parts[2]))
  }

  /// This stamp, or when it is more than five minutes ahead of `wall` the receiver's milliseconds
  /// with counter 0 and the original device id.
  public func clamped(toWall wall: UInt64) -> HLC {
    guard millis > wall, millis - wall > Self.maxAheadMillis else { return self }
    return HLC(millis: wall, counter: 0, deviceId: deviceId)
  }

  public static func < (lhs: HLC, rhs: HLC) -> Bool { lhs.rawValue < rhs.rawValue }

  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let hlc = HLC(rawValue: text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Not a hybrid logical clock: \(text)"))
    }
    self = hlc
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func hex(_ value: UInt64, width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: false)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  private static func parseHex(_ text: Substring) -> UInt64? {
    guard text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
      return nil
    }
    return UInt64(text, radix: 16)
  }
}

/// Issues strictly increasing stamps for one device, however the wall clock behaves.
public final class HybridClock: Sendable {
  private struct State {
    var millis: UInt64 = 0
    var counter: UInt16 = 0
    var deviceId: String
  }

  private let wall: @Sendable () -> UInt64
  private let state: Mutex<State>

  public init(deviceId: String, wall: @escaping @Sendable () -> UInt64 = epochMillis) {
    self.wall = wall
    self.state = Mutex(State(deviceId: deviceId))
  }

  public var deviceId: String {
    get { state.withLock { $0.deviceId } }
    set { state.withLock { $0.deviceId = newValue } }
  }

  /// The next stamp: the wall clock when it moved ahead, else the last stamp with its counter
  /// incremented (rolling into the next millisecond rather than wrapping).
  public func next() -> HLC {
    let now = wall()
    return state.withLock { s in
      if now > s.millis {
        s.millis = now
        s.counter = 0
      } else if s.counter == UInt16.max {
        s.millis += 1
        s.counter = 0
      } else {
        s.counter += 1
      }
      return HLC(millis: s.millis, counter: s.counter, deviceId: s.deviceId)
    }
  }

  /// Folds in a stamp from another device so the next local stamp sorts after it. Callers clamp a
  /// remote stamp that is far ahead first (`HLC.clamped(toWall:)`).
  public func observe(_ remote: HLC) {
    state.withLock { s in
      if (remote.millis, remote.counter) > (s.millis, s.counter) {
        s.millis = remote.millis
        s.counter = remote.counter
      }
    }
  }
}

/// Which columns the phone may write, and which are clocked for last-writer-wins merging. A table
/// or column not listed is Mac-only. Lives here, not in `WorkspaceSync`, because `WorkspaceStorage`
/// needs it and does not import `WorkspaceSync`.
public enum SyncColumns {
  public static let phoneWritable: [String: Set<String>] = [
    "threads": ["title", "pinned", "archived", "readTurnId"],
    "projects": ["name"],
    "drafts": ["threadId", "text", "updatedAt"],
  ]

  /// Phone-writable columns plus `threads.projectId`, which only the Mac writes but which merges by
  /// clock too.
  public static let clocked: [String: Set<String>] = {
    var all = phoneWritable
    all["threads", default: []].insert("projectId")
    return all
  }()

  public static func isPhoneWritable(table: String, column: String) -> Bool {
    phoneWritable[table]?.contains(column) ?? false
  }
}
