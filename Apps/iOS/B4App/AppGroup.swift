import Foundation

/// The App Group and URL scheme this build was made with, from the Info.plist keys `project.yml` fills
/// from the flavour's xcconfig (`B4APP_APP_GROUP`, `B4APP_URL_SCHEME`; D-125). The widget extension keeps its own copy of
/// this reader, since a target cannot share an app file without a module.
nonisolated enum AppInfo {
  /// The App Group the app and the widget share the mirror through; nil when the key is missing or empty.
  static var appGroup: String? {
    let value = (Bundle.main.object(forInfoDictionaryKey: "B4AppAppGroup") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  /// The scheme of the app's own links. Only a valid URL scheme is taken (`ThreadLink.url` traps on
  /// anything else); a missing or invalid key falls back to `b4app`.
  static var urlScheme: String {
    let value =
      (Bundle.main.object(forInfoDictionaryKey: "B4AppURLScheme") as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*/) != nil ? value : "b4app"
  }
}
