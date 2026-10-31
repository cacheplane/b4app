import Foundation
import WorkspaceProtocol

public enum HubURL {
  private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

  /// Accepts `https://` anywhere and `http://` only for `localhost`, `127.0.0.1`, and `::1`. The
  /// returned URL has a lowercase scheme and host.
  public static func validate(_ string: String) throws -> URL {
    let invalid = WorkspaceError(.protocolInvalid, "The hub URL is not a valid URL.")
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
      let rawHost = components.host?.lowercased()
    else { throw invalid }
    // URLComponents keeps the brackets of an IPv6 literal.
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !host.isEmpty else { throw invalid }
    switch scheme {
    case "https": break
    case "http" where loopbackHosts.contains(host): break
    default:
      throw WorkspaceError(
        .protocolInvalid, "The hub URL must use https (http is allowed only for localhost).")
    }
    components.scheme = scheme
    components.host = rawHost
    guard let url = components.url else { throw invalid }
    return url
  }
}
