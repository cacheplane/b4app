import Foundation
import WorkspaceProtocol

/// Claude's plan windows from a stream-json `rate_limit_event` (`rate_limit_info`), which Claude Code
/// emits during a turn when a window's rounded percentage or reset time moves. Verified against
/// Claude Code 2.1.282's bundled schema.
///
/// `unifiedWindows` (5-hour and weekly, each `utilization` as a fraction and `resetsAt` in epoch
/// seconds) is marked `@internal` there, so the top-level `utilization` and `resetsAt` fill the window
/// `rateLimitType` names when `unifiedWindows` lacks it, and any other stays unknown.
public enum ClaudeUsage {
  public static func reading(from info: JSONValue, observedAt: String) -> UsageReading? {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    if let windows = info["unifiedWindows"], case .object = windows {
      fiveHour = windows["five_hour"].flatMap { window($0, minutes: 300) }
      weekly = windows["seven_day"].flatMap { window($0, minutes: 10080) }
    }
    // The top-level figures describe the window closest to its limit; they fill that window when
    // `unifiedWindows` lacks it. Per-model weekly buckets (`seven_day_opus`, `seven_day_sonnet`) and the
    // overage-included one are not the plan's week, so they are not shown as "Weekly".
    switch info["rateLimitType"]?.stringValue {
    case "five_hour" where fiveHour == nil: fiveHour = window(info, minutes: 300)
    case "seven_day" where weekly == nil: weekly = window(info, minutes: 10080)
    default: break
    }
    guard fiveHour != nil || weekly != nil else { return nil }
    return UsageReading(
      fiveHour: fiveHour, weekly: weekly, blocked: info["status"]?.stringValue == "rejected",
      observedAt: observedAt)
  }

  /// `utilization` is a fraction that can pass 1 when use runs past a window's cap; kept unclamped.
  private static func window(_ value: JSONValue, minutes: Int) -> UsageWindow? {
    guard let fraction = value["utilization"]?.numberValue else { return nil }
    return UsageWindow(
      usedPercent: (fraction * 1000).rounded() / 10, windowMinutes: minutes,
      resetsAt: value["resetsAt"]?.numberValue.map { Timestamp.string(from: Date(timeIntervalSince1970: $0)) }
    )
  }
}
