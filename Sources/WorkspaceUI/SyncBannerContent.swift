import Foundation
import WorkspaceProtocol

/// Platform-neutral copy and visibility for the phone's sync status banner.
nonisolated public struct SyncBannerContent: Sendable {
  public static let signInRequiredMessage = "Log out, then sign in to reconnect."

  public let text: String?

  public init(
    lastError: String?, lastSyncAt: String?, relayRefused: String? = nil,
    syncPaused: Bool = false, now: Date = .now,
    calendar: Calendar = .current, locale: Locale = .current
  ) {
    if syncPaused {
      text = "Sync paused. Check Diagnostics."
    } else if let relayRefused {
      text = relayRefused
    } else if lastError != nil {
      if let lastSyncAt, let date = Timestamp.date(from: lastSyncAt) {
        let time = date.formatted(
          Date.FormatStyle(
            date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated,
            time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        text = "Last synced \(time). Retrying…"
      } else {
        text = "Not synced yet. Retrying…"
      }
    } else {
      text = nil
    }
  }
}
