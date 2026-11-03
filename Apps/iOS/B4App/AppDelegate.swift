import UIKit
import UserNotifications
import WorkspaceProtocol
import os

/// The UIKit side of attention (M8f): the APNs token, the background wake a `content-available` push
/// makes, and the notification delegate. Everything it learns goes to `MirrorHost`; a tap becomes the
/// thread link the app opens like any other (D-124).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "attention")

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    MirrorHost.shared.received(pushToken: deviceToken)
  }

  func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
  ) {
    Self.logger.error(
      "remote notification registration failed: \(MirrorHost.describe(error), privacy: .public)")
  }

  /// A push woke the app (in the background or not): remove the notifications a withdrawal push names
  /// (a request answered, a reply read), then pull what changed before the owner looks.
  func application(
    _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    refresh(withdrawing: ThreadLink.withdrawKeys(fromNotification: userInfo), then: completionHandler)
  }

  /// A background-fetch wake: how the Simulator's `simctl push` delivers a content-available payload.
  /// Only Debug builds declare the `fetch` mode, and the app sets no fetch interval, so on a device
  /// this is never called; the same refresh as a push.
  func application(
    _ application: UIApplication,
    performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    refresh(then: completionHandler)
  }

  /// Removes the delivered notifications `withdrawing` names, refreshes the mirror, the widget, and the
  /// badge, then calls `completion` once, on the main actor, after the sync loop is idle again
  /// (`MirrorHost.backgroundRefresh`).
  private func refresh(
    withdrawing keys: [String] = [], then completion: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    Task { @MainActor in
      if !keys.isEmpty { await MirrorHost.shared.withdraw(keys: keys) }
      completion(await MirrorHost.shared.backgroundRefresh() ? .newData : .noData)
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// In the foreground a notification shows unless its thread is open and on screen.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
  ) {
    let threadId = ThreadLink.threadId(fromNotification: notification.request.content.userInfo)
    Task { @MainActor in
      let onScreen = threadId.map { MirrorHost.shared.isOnScreen(threadId: $0) } ?? false
      completionHandler(onScreen ? [] : [.banner, .list, .sound])
    }
  }

  /// A tap opens its thread through the same link a widget row uses.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    let threadId = ThreadLink.threadId(fromNotification: response.notification.request.content.userInfo)
    Task { @MainActor in
      if let threadId {
        _ = MirrorHost.shared.handle(url: ThreadLink.url(threadId: threadId, scheme: AppInfo.urlScheme))
      }
      completionHandler()
    }
  }
}
