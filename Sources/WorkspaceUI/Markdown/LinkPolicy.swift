import Foundation

/// Which links in a reply open. An agent's reply is text it chose: a web or mail link opens through
/// the environment's `openURL`; any other scheme (a file, a script, the app's own) draws as its words.
enum LinkPolicy {
  /// The scheme is http, https or mailto, in any case.
  static func opens(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https" || scheme == "mailto"
  }

  /// `text` with the link taken off every run whose link does not open, and every image URL taken off:
  /// an image (`![alt](url)`) draws as its alt text and nothing is loaded.
  static func filtered(_ text: AttributedString) -> AttributedString {
    var result = text
    for run in text.runs {
      if let link = run.link, !opens(link) { result[run.range].link = nil }
      if run.imageURL != nil { result[run.range].imageURL = nil }
    }
    return result
  }
}
