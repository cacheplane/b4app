import Foundation
import WorkspaceProtocol

/// Codex's plan windows from `account/rateLimits/read` (or the `rateLimits` of
/// `account/rateLimits/updated`): `primary` and `secondary` windows of `usedPercent`,
/// `windowDurationMins`, and `resetsAt` (epoch seconds). Verified against codex-cli 0.166.0's
/// generated schema.
public enum CodexUsage {
  /// The windows placed by length (5 hours or less is the short window, a week or more the long one),
  /// falling back to role (primary short, secondary long) when a window has no length. Nil when
  /// neither window is present.
  public static func reading(from response: JSONValue, observedAt: String) -> UsageReading? {
    let snapshot = response["rateLimits"] ?? .null
    let windows = [snapshot["primary"], snapshot["secondary"]].map { $0.flatMap(window) }
    guard windows.contains(where: { $0 != nil }) else { return nil }
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    for (index, window) in windows.enumerated() {
      guard let window else { continue }
      switch window.windowMinutes {
      case .some(let minutes) where minutes <= 300: fiveHour = window
      case .some(let minutes) where minutes >= 10080: weekly = window
      default:
        if index == 0 { fiveHour = fiveHour ?? window } else { weekly = weekly ?? window }
      }
    }
    // `ordinaryUsageAllowed` false, or a limit named as reached, is the runtime refusing use now. A
    // null permission is unknown, and the schema says not to infer it from the percentages.
    let refused = response["ordinaryUsageAllowed"]?.boolValue == false
    let reached = !(snapshot["rateLimitReachedType"]?.isNull ?? true)
    return UsageReading(
      fiveHour: fiveHour, weekly: weekly, blocked: refused || reached,
      planType: snapshot["planType"]?.stringValue, observedAt: observedAt)
  }

  private static func window(_ value: JSONValue) -> UsageWindow? {
    guard let used = value["usedPercent"]?.numberValue else { return nil }
    return UsageWindow(
      usedPercent: used, windowMinutes: value["windowDurationMins"]?.numberValue.map { Int($0) },
      resetsAt: value["resetsAt"]?.numberValue.map { Timestamp.string(from: Date(timeIntervalSince1970: $0)) }
    )
  }
}
