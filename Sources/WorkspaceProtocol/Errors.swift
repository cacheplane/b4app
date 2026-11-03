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
  // Signing in and the account (the hub's refusals, and two the app raises itself).
  /// The hub is not taking new accounts.
  case signupClosed = "signup_closed"
  /// A sign-in ceremony is unknown, expired, or already finished.
  case ceremonyExpired = "ceremony_expired"
  /// The hub could not verify the passkey or Apple credential.
  case credentialRejected = "credential_rejected"
  /// Unlinking this sign-in method would leave the account unable to sign in.
  case lastIdentity = "last_identity"
  /// The phone's account cannot be merged into the one the pairing code belongs to.
  case mergeRefused = "merge_refused"
  /// The account already has an Apple ID; it links at most one.
  case appleLinked = "apple_linked"
  /// The account belongs to a shared org, which cannot be deleted from here.
  case sharedOrg = "shared_org"
  /// The change needs a fresh passkey or Apple confirmation first (D-150). `details.methods` lists
  /// what the account can confirm with.
  case stepUpRequired = "step_up_required"
  /// An enrollment code is unknown, expired, already used, a pairing code, or another account's
  /// (D-151: a code offered to confirm it's you).
  case invalidCode = "invalid_code"
  /// The device's session ended, so it has to sign in again.
  case signedOut = "signed_out"
  /// Signing out would interrupt work that is still running.
  case workRunning = "work_running"
  // The relay (M8c). They travel in `error` frames and in a relayed `reply`'s `error`.
  /// The Mac that owns the thread has no open link. `details`: `deviceId`, `deviceName`, `lastSeenAt`.
  case deviceOffline = "device_offline"
  /// The command's deadline passed before the Mac ran it.
  case commandExpired = "command_expired"
  /// The Mac did not reply within the hub's reply wait.
  case relayTimeout = "relay_timeout"
  /// Over a relay or sign-in rate limit. `details.retryAfterMs` says when to try again.
  case rateLimited = "rate_limited"
  /// A newer link from the same device closed this one.
  case linkReplaced = "link_replaced"
  /// The client's protocol version is below the hub's minimum.
  case clientTooOld = "client_too_old"
  /// The link already watches the most threads it may.
  case watchLimit = "watch_limit"
  /// The link upgrade reached a hub instance other than the one serving this user's links (`409` at
  /// the upgrade). `details.instanceId` names the owner. The device retries at once, at most three
  /// times, then with its backoff.
  case relocated = "relocated"
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
