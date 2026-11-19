import Foundation
import WorkspaceProtocol

/// The words a turn's line draws for time: a clock while the turn runs, a duration once it ends.
enum ActivityTime {
  /// `0:42`, `1:15`, `1:00:00`; negative reads as `0:00`.
  static func clock(_ seconds: Int) -> String {
    let total = max(seconds, 0)
    let (hours, minutes, rest) = (total / 3_600, total % 3_600 / 60, total % 60)
    let tail = String(format: "%02d", rest)
    return hours > 0 ? "\(hours):" + String(format: "%02d", minutes) + ":\(tail)" : "\(minutes):\(tail)"
  }

  /// `8s`, `1m`, `1m 12s`, `1h`, `1h 4m`; negative and 0 read as `1s`.
  static func duration(_ seconds: Int) -> String {
    guard seconds > 0 else { return "1s" }
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 {
      let (minutes, rest) = (seconds / 60, seconds % 60)
      return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
    let (hours, minutes) = (seconds / 3_600, seconds % 3_600 / 60)
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }

  /// The clock as it is spoken: "42 seconds", "1 minute 15 seconds", "1 hour 2 minutes 5 seconds".
  static func words(_ seconds: Int) -> String {
    let total = max(seconds, 0)
    func part(_ count: Int, _ unit: String) -> String? {
      count == 0 ? nil : "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
    let parts = [part(total / 3_600, "hour"), part(total % 3_600 / 60, "minute"), part(total % 60, "second")]
      .compactMap { $0 }
    return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
  }

  /// Whole seconds from one timestamp to another; nil when either does not parse.
  static func seconds(from start: String, to end: String) -> Int? {
    guard let start = Timestamp.date(from: start), let end = Timestamp.date(from: end) else { return nil }
    return Int(end.timeIntervalSince(start).rounded(.down))
  }

  /// Whole seconds since `start`; 0 when it is in the future or does not parse.
  static func seconds(since start: String, now: Date) -> Int {
    guard let start = Timestamp.date(from: start) else { return 0 }
    return max(Int(now.timeIntervalSince(start).rounded(.down)), 0)
  }
}
