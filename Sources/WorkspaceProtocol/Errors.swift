import Foundation

/// Stable internal error codes (spec section 12 plus transport codes). Messages may change; codes never do.
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
  case missingExecutable = "missing_executable"
  case incompatibleVersion = "incompatible_version"
  case authRequired = "auth_required"
  case authModeConflict = "auth_mode_conflict"
  case allowanceExceeded = "allowance_exceeded"
  case endpointUnavailable = "endpoint_unavailable"
  case unsupportedCapability = "unsupported_capability"
  case nativeSessionMissing = "native_session_missing"
  /// The connection now presents a different native identity than the thread was created under.
  case identityChanged = "identity_changed"
  case staleRuntimeRequest = "stale_runtime_request"
  case submissionUnknown = "submission_unknown"
  case ownedProcessConflict = "owned_process_conflict"
  case cancellationUnconfirmed = "cancellation_unconfirmed"
  case protocolInvalid = "protocol_invalid"
  case methodUnknown = "method_unknown"
  case snapshotRequired = "snapshot_required"
  case notImplemented = "not_implemented"
  case notFound = "not_found"
  case internalError = "internal"
  // The relay (M8c). They travel in `error` frames and in a relayed `reply`'s `error`.
  /// The Mac that owns the thread has no open link. `details`: `deviceId`, `deviceName`, `lastSeenAt`.
  case deviceOffline = "device_offline"
  /// The command's deadline passed before the Mac ran it.
  case commandExpired = "command_expired"
  /// The Mac did not reply within the hub's reply wait.
  case relayTimeout = "relay_timeout"
  /// Over a relay rate limit. `details.retryAfterMs` says when to try again.
  case rateLimited = "rate_limited"
  /// A newer link from the same device closed this one.
  case linkReplaced = "link_replaced"
  /// The client's protocol version is below the hub's minimum.
  case clientTooOld = "client_too_old"
  /// The link already watches the most threads it may.
  case watchLimit = "watch_limit"
}

public struct WorkspaceError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
  public var code: ErrorCode
  public var message: String
  public var details: JSONValue?

  public init(_ code: ErrorCode, _ message: String, details: JSONValue? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }

  public var description: String { "[\(code.rawValue)] \(message)" }

  /// Normalize any thrown error into a WorkspaceError without losing a known code.
  public static func from(_ error: any Error) -> WorkspaceError {
    if let error = error as? WorkspaceError { return error }
    return WorkspaceError(.internalError, String(describing: error))
  }

  /// The standard error for behavior that is deliberately not implemented yet.
  public static func unsupported(_ capability: String, plannedFor milestone: String) -> WorkspaceError {
    WorkspaceError(
      .unsupportedCapability,
      "\(capability) is not implemented yet (planned for \(milestone)).",
      details: ["capability": .string(capability), "milestone": .string(milestone)])
  }
}
