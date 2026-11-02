import Foundation
import WorkspaceProtocol

/// The words and numbers a usage meter shows. Pure, so the copy is pinned by tests.
enum UsageFormat {
  /// "62%". Use past a cap stays visible ("120%"); only the bar is clamped.
  static func percent(_ used: Double) -> String { "\(Int(used.rounded()))%" }

  /// How much of the bar to fill, 0…1.
  static func fill(_ used: Double) -> Double { min(max(used / 100, 0), 1) }

  /// A window at 90% or more draws in the danger colour.
  static func isHot(_ used: Double) -> Bool { used >= 90 }

  /// "Resets in 38m", "Resets in 2h 14m", "Resets Thu 9:00 AM" (a day or more away), or "Reset" once
  /// the time has passed (a stale reading). Nil when the runtime gave no time.
  static func resets(_ iso: String?, now: Date, calendar: Calendar = .current) -> String? {
    guard let iso, let date = Timestamp.date(from: iso) else { return nil }
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "Reset" }
    let minutes = Int((seconds / 60).rounded(.up))
    if minutes < 60 { return "Resets in \(minutes)m" }
    if minutes < 24 * 60 {
      let hours = minutes / 60
      let rest = minutes % 60
      return rest == 0 ? "Resets in \(hours)h" : "Resets in \(hours)h \(rest)m"
    }
    var style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar)
    style.timeZone = calendar.timeZone
    let day = date.formatted(style.weekday(.abbreviated))
    let time = date.formatted(style.hour().minute())
    return "Resets \(day) \(time)"
  }

  /// How old a reading is: "Just now", "As of 20 min ago", "As of 3 h ago", "As of 2 days ago".
  static func age(_ iso: String, now: Date) -> String {
    guard let date = Timestamp.date(from: iso) else { return "" }
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "Just now" }
    if minutes < 60 { return "As of \(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "As of \(hours) h ago" }
    let days = hours / 24
    return days == 1 ? "As of 1 day ago" : "As of \(days) days ago"
  }

  /// "999", "1.5k", "412k", "2.1M", "12M": one decimal only under ten.
  static func tokens(_ count: Int) -> String {
    func compact(_ value: Double, _ unit: String) -> String {
      value < 10 && value.rounded() != value
        ? String(format: "%.1f%@", value, unit) : "\(Int(value.rounded()))\(unit)"
    }
    if count >= 1_000_000 { return compact((Double(count) / 100_000).rounded() / 10, "M") }
    if count >= 1_000 { return compact((Double(count) / 100).rounded() / 10, "k") }
    return String(count)
  }
}

/// A connection's or a B4 project's state as one icon (settings connections design): the words are its
/// accessibility label and hover help, never visible text.
enum LLAStatus: Equatable {
  case ok, busy, attention, idle

  var label: String {
    switch self {
    case .ok: return "Connected"
    case .busy: return "Checking"
    case .attention: return "Needs attention"
    case .idle: return "Not checked"
    }
  }

  init(connection: Connection, checking: Bool, blocked: Bool) {
    if checking || connection.status == .connecting {
      self = .busy
    } else if blocked || [.error, .offline, .incompatible].contains(connection.status)
      || [.required, .error].contains(connection.authStatus)
    {
      self = .attention
    } else if connection.status == .ready {
      self = .ok
    } else {
      self = .idle
    }
  }

  init(health: LocalServerHealth) {
    switch health {
    case .ready: self = .ok
    case .starting: self = .busy
    case .unhealthy: self = .attention
    case .stopped, .unknown: self = .idle
    }
  }
}
