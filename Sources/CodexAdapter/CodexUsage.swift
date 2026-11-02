import Foundation
import WorkspaceProtocol

/// Codex's plan windows from `account/rateLimits/read` (or the `rateLimits` of
/// `account/rateLimits/updated`): `primary` and `secondary` windows of `usedPercent`,
/// `windowDurationMins`, and `resetsAt` (epoch seconds). Verified against codex-cli 0.166.0's
/// generated schema.
public enum CodexUsage {
  /// The windows by length: with two, the shorter is the first (`fiveHour`) and the longer the second
  /// (`weekly`); a lone window of a week or more is the second. Each keeps its length, which names it
  /// on the card ("Daily", "Weekly"). A window without a length keeps its role (primary first). Nil
  /// when neither window is present.
  public static func reading(from response: JSONValue, observedAt: String) -> UsageReading? {
    let snapshot = response["rateLimits"] ?? .null
    let windows = [snapshot["primary"], snapshot["secondary"]].enumerated().compactMap { index, value in
      value.flatMap(window).map { (index: index, window: $0) }
    }
    guard !windows.isEmpty else { return nil }
    let ordered = windows.sorted {
      ($0.window.windowMinutes ?? $0.index, $0.index) < ($1.window.windowMinutes ?? $1.index, $1.index)
    }.map(\.window)
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    if ordered.count >= 2 {
      fiveHour = ordered[0]
      weekly = ordered[1]
    } else if let only = ordered.first,
      (only.windowMinutes ?? 0) >= 10080 || (only.windowMinutes == nil && windows[0].index == 1)
    {
      weekly = only
    } else {
      fiveHour = ordered.first
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
