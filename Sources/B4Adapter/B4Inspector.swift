import Foundation
import WorkspaceProtocol

public enum B4Inspector {
  /// Check reachability and known protocol behavior without issuing inference. A healthy server
  /// does not imply valid model credentials; that is reported separately.
  public static func inspect(
    baseURL: String, authorization: String? = nil, session: URLSession? = nil
  ) async -> ConnectionInspection {
    let authStatus: AuthStatus = authorization == nil ? .notRequired : .unknown
    let client: B4HTTPClient
    do {
      client = try B4HTTPClient(baseURL: baseURL, authorization: authorization, session: session)
    } catch {
      let failure = WorkspaceError.from(error)
      return ConnectionInspection(
        status: .error, authStatus: authStatus, message: failure.message, error: failure)
    }
    do {
      let health = try await client.health()
      guard health.status == "ready" else {
        return ConnectionInspection(
          status: .incompatible, authStatus: authStatus, nativeScope: client.origin,
          message: "Unexpected healthz payload: status \(health.status)",
          error: WorkspaceError(.incompatibleVersion, "healthz did not report ready."))
      }
    } catch {
      let failure = WorkspaceError.from(error)
      return ConnectionInspection(
        status: failure.code == .endpointUnavailable ? .offline : .incompatible, authStatus: authStatus,
        nativeScope: client.origin, message: failure.message, error: failure)
    }
    let readiness = (try? await client.ready())?.status ?? "unknown"
    return ConnectionInspection(
      status: .ready, authStatus: authStatus, nativeScope: client.origin,
      message: "Server reachable (readyz: \(readiness)). Model credentials are not verified by this check.")
  }
}
