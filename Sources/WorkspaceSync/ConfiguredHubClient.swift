import Foundation

package final class HubCredentialSource: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let read: @Sendable () async throws -> String?

  package init(read: @escaping @Sendable () async throws -> String?) {
    self.read = read
  }

  package func value() async throws -> String? {
    try await read()
  }

  package var description: String { "HubCredentialSource(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<(label: String?, value: Any)>())
  }
}

// Configuration provenance only: this source is neither a receipt nor authority.
// It retains the same HTTP client and its session without sending a request.
package final class HTTPProofSource: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  fileprivate let api: HTTPHubAPI
  fileprivate let credentials: HubCredentialSource
  fileprivate let baseURL: URL

  fileprivate init(api: HTTPHubAPI, credentials: HubCredentialSource, baseURL: URL) {
    self.api = api
    self.credentials = credentials
    self.baseURL = baseURL
  }

  package var description: String { "HTTPProofSource(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<(label: String?, value: Any)>())
  }
}

package final class ConfiguredHubClient: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  package let api: any HubAPI
  private let baseURL: URL
  private let credentials: HubCredentialSource
  private let source: HTTPProofSource?

  private init(
    api: any HubAPI, baseURL: URL, credentials: HubCredentialSource, source: HTTPProofSource?
  ) {
    self.api = api
    self.baseURL = baseURL
    self.credentials = credentials
    self.source = source
  }

  package static func liveHTTP(
    baseURL: URL, credentials: HubCredentialSource, session: URLSession = .shared
  ) -> ConfiguredHubClient {
    let api = HTTPHubAPI(baseURL: baseURL, token: { try await credentials.value() }, session: session)
    let source = HTTPProofSource(api: api, credentials: credentials, baseURL: baseURL)
    return ConfiguredHubClient(api: api, baseURL: baseURL, credentials: credentials, source: source)
  }

  package static func fixtureAPI(
    _ api: any HubAPI, baseURL: URL, credentials: HubCredentialSource
  ) -> ConfiguredHubClient {
    ConfiguredHubClient(api: api, baseURL: baseURL, credentials: credentials, source: nil)
  }

  private static let unavailable = HubError(
    kind: "execution_error", code: "proof_unavailable",
    message: "The configured hub proof source is unavailable.", status: 0)

  package func requireBinding(baseURL: URL, credentials: HubCredentialSource) throws {
    guard self.credentials === credentials,
      self.baseURL.absoluteString.utf8.elementsEqual(baseURL.absoluteString.utf8)
    else { throw Self.unavailable }
  }

  package func requireHTTPProofSource(
    baseURL: URL, credentials: HubCredentialSource
  ) throws -> HTTPProofSource {
    try requireBinding(baseURL: baseURL, credentials: credentials)
    guard let source else { throw Self.unavailable }
    return source
  }

  package var description: String { "ConfiguredHubClient(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror {
    Mirror(self, children: EmptyCollection<(label: String?, value: Any)>())
  }
}
