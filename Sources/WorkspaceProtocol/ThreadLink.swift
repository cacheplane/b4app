import Foundation

/// Why the hub pushed a notification (D-121, D-124). The raw values are the payload's `reason`.
public enum PushReason: String, Codable, Sendable {
  case approval
  case question
  case replied
  case failed
}

/// `<scheme>://thread/<id>`: the one link a notification tap, a widget row, and the app's own routing
/// share (D-124). The push payload carries no URL, only the thread id; the app builds the link with its
/// own scheme and sends it through `onOpenURL`. Pure parsing and building; nothing here opens anything.
public enum ThreadLink {
  public static let host = "thread"

  /// RFC 3986's unreserved characters only, so `/`, `?`, `#`, `%`, and spaces in an id are always
  /// escaped and the id stays one path segment.
  private static let unreserved: CharacterSet = {
    var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    set.insert(charactersIn: "-._~")
    return set
  }()

  /// The link for a thread, with the id percent-encoded as one path segment. `scheme` must be a valid
  /// URL scheme (the app's `B4AppURLScheme`).
  public static func url(threadId: String, scheme: String) -> URL {
    // Escaping with a fixed ASCII set cannot fail.
    let segment = threadId.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    guard let url = URL(string: "\(scheme)://\(host)/\(segment)") else {
      preconditionFailure("a thread link needs a valid URL scheme")
    }
    return url
  }

  /// The thread id a link names, or nil when it is not a thread link of this app: another scheme or
  /// host (both compared without regard to case), an empty or multi-segment path, or a query, user,
  /// password, port, or fragment.
  public static func threadId(from url: URL, scheme: String) -> String? {
    guard url.scheme?.lowercased() == scheme.lowercased(),
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.host?.lowercased() == host,
      parts.user == nil, parts.password == nil, parts.port == nil,
      parts.query == nil, parts.fragment == nil
    else { return nil }
    let path = parts.percentEncodedPath
    guard path.hasPrefix("/") else { return nil }
    let segment = path.dropFirst()
    guard !segment.isEmpty, !segment.contains("/"),
      let id = String(segment).removingPercentEncoding, !id.isEmpty
    else { return nil }
    return id
  }

  /// The thread id in a push payload's top-level `threadId`, or nil when it is missing, not a string,
  /// or empty. `userInfo` is what iOS hands a notification delegate. It does not fall back to
  /// `aps.thread-id`, which is for the system's grouping.
  public static func threadId(fromNotification userInfo: [AnyHashable: Any]) -> String? {
    guard let id = userInfo["threadId"] as? String, !id.isEmpty else { return nil }
    return id
  }

  /// The payload's top-level `reason`, or nil when it is missing or not one the app knows.
  public static func reason(fromNotification userInfo: [AnyHashable: Any]) -> PushReason? {
    (userInfo["reason"] as? String).flatMap(PushReason.init(rawValue:))
  }

  /// The notification's top-level `key` (`request:<id>` or `turn:<id>`), or nil when it is missing, not
  /// a string, or empty. The app uses it to find and withdraw a delivered notification.
  public static func key(fromNotification userInfo: [AnyHashable: Any]) -> String? {
    guard let key = userInfo["key"] as? String, !key.isEmpty else { return nil }
    return key
  }

  /// The keys a withdrawal push lists in its top-level `withdraw`: the strings in it, in order, and
  /// empty when it is missing or not an array.
  public static func withdrawKeys(fromNotification userInfo: [AnyHashable: Any]) -> [String] {
    (userInfo["withdraw"] as? [Any])?.compactMap { $0 as? String } ?? []
  }
}
