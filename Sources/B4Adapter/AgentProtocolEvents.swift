import Foundation

/// Transport diagnostics contain only locally defined codes and numeric status values.
/// Neither a peer response body nor Foundation's potentially credential-bearing cause is retained.
public enum AgentProtocolTransportError: Error, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, LocalizedError
{
  case invalidBaseURL
  case invalidResourceID
  case invalidHeaderName
  case invalidHeaderValue
  case credentialUnavailable
  case invalidResponse
  case correlationMismatch
  case b4NotNegotiated
  case http(status: Int)
  case unavailable(code: Int?)

  public var description: String {
    switch self {
    case .invalidBaseURL: "agent_protocol.invalid_base_url"
    case .invalidResourceID: "agent_protocol.invalid_resource_id"
    case .invalidHeaderName: "agent_protocol.invalid_auth_header_name"
    case .invalidHeaderValue: "agent_protocol.invalid_auth_header_value"
    case .credentialUnavailable: "agent_protocol.credential_unavailable"
    case .invalidResponse: "agent_protocol.invalid_response"
    case .correlationMismatch: "agent_protocol.correlation_mismatch"
    case .b4NotNegotiated: "agent_protocol.b4_not_negotiated"
    case .http(let status): "agent_protocol.http_\(status)"
    case .unavailable(let code): "agent_protocol.unavailable\(code.map { "_\($0)" } ?? "")"
    }
  }

  public var debugDescription: String { description }
  public var errorDescription: String? { description }

  static func sanitized(_ error: any Error) -> AgentProtocolTransportError {
    if let known = error as? AgentProtocolTransportError { return known }
    return .unavailable(code: (error as? URLError)?.code.rawValue)
  }
}

/// Local classifications of the approved wire §11 diagnostics. This is separate from the closed
/// CDDL ErrorCode enum. Unknown peer strings are classified without retaining their original text.
public enum AgentProtocolDiagnostic: String, Codable, Sendable, CaseIterable {
  case malformedJSON = "malformed_json"
  case invalidArgument = "invalid_argument"
  case authRequired = "auth_required"
  case permissionDenied = "permission_denied"
  case notFound = "not_found"
  case threadExists = "thread_exists"
  case threadBusy = "thread_busy"
  case staleGeneration = "stale_generation"
  case incompleteResponses = "incomplete_responses"
  case grantInvalid = "grant_invalid"
  case grantExpired = "grant_expired"
  case approvalChanged = "approval_changed"
  case notSupported = "not_supported"
  case resyncRequired = "resync_required"
  case historyChanged = "history_changed"
  case historyExpired = "history_expired"
  case resultExpired = "result_expired"
  case submissionConflict = "submission_conflict"
  case submissionAmbiguous = "submission_ambiguous"
  case submissionTargetGone = "submission_target_gone"
  case submissionAlreadyAccepted = "submission_already_accepted"
  case receiptExpired = "receipt_expired"
  case capacityExceeded = "capacity_exceeded"
  case storageUnavailable = "storage_unavailable"
  case itemChanged = "item_changed"
  case unrecognized
}

/// Negotiated REST errors use a top-level code, unlike ASP meta.b4.code. Only validated
/// machine classification and numeric HTTP status survive; peer text and causes do not.
public struct AgentProtocolRESTFailure: Error, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, LocalizedError
{
  public let status: Int
  public let diagnostic: AgentProtocolDiagnostic

  private struct Carrier: Decodable {
    let code: String
    let message: String
    // Reuse the negotiated v1 carrier validation without retaining any raw extensions.
    let metadata: AgentProtocol.ResponseMeta?
  }

  static func decode(status: Int, data: Data) -> Self? {
    guard let carrier = try? JSONDecoder().decode(Carrier.self, from: data) else { return nil }
    return Self(status: status, diagnostic: AgentProtocolDiagnostic(rawValue: carrier.code) ?? .unrecognized)
  }

  public var description: String { "agent_protocol.rest_\(status)_\(diagnostic.rawValue)" }
  public var debugDescription: String { description }
  public var errorDescription: String? { description }
}

/// A receipt associated with a public diagnostic error, containing only validated machine facts.
/// Normal wire/application Receipt DTOs remain opaque. Native AG-UI token text, free-form reason,
/// raw JSON and unknown extensions are deliberately absent from this error representation.
public struct AgentProtocolFailureReceipt: Encodable, Sendable {
  public let submissionKind: AgentProtocol.SubmissionKind
  public let submissionID: AgentProtocol.CanonicalID?
  public let runID: AgentProtocol.CanonicalID
  public let turnID: AgentProtocol.CanonicalID
  public let inputID: AgentProtocol.CanonicalID?
  public let acceptedAt: AgentProtocol.Timestamp
  public let replayed: Bool
  public let disposition: AgentProtocol.Disposition

  private enum CodingKeys: String, CodingKey {
    case submissionKind, submissionID = "submissionId", runID = "runId", turnID = "turnId"
    case inputID = "inputId", acceptedAt, replayed, disposition
  }

  init(_ receipt: AgentProtocol.Receipt) {
    switch receipt.submission {
    case .b4(let id): submissionKind = .b4; submissionID = id
    case .agui: submissionKind = .agui; submissionID = nil
    }
    runID = receipt.runID
    turnID = receipt.turnID
    inputID = receipt.inputID
    acceptedAt = receipt.acceptedAt
    replayed = receipt.replayed
    disposition = receipt.disposition
  }
}

/// A correlated ASP failure is distinct from an HTTP failure. Only validated machine fields are
/// retained; the untrusted message, stacktrace and raw error object never become diagnostics.
public struct AgentProtocolCommandFailure: Error, Encodable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, LocalizedError
{
  public let id: AgentProtocol.JSUInt?
  public let code: AgentProtocol.ASPErrorCode
  public let diagnostic: AgentProtocolDiagnostic?
  public let appliedThroughSeq: AgentProtocol.JSUInt?
  public let receipt: AgentProtocolFailureReceipt?

  init(_ error: AgentProtocol.ASPError) {
    id = error.id
    code = error.error
    // ASPError has already validated ResponseMeta.b4's v1 carrier. Classify only its explicit
    // diagnostic field, never message/stacktrace or a similarly named application payload.
    if case .string(let code) = error.meta?.raw["b4"]?["code"] {
      diagnostic = AgentProtocolDiagnostic(rawValue: code) ?? .unrecognized
    } else {
      diagnostic = nil
    }
    appliedThroughSeq = error.meta?.appliedThroughSeq
    receipt = error.meta?.receipt.map(AgentProtocolFailureReceipt.init)
  }

  public var description: String { "agent_protocol.asp_\(code.rawValue)" }
  public var debugDescription: String { description }
  public var errorDescription: String? { description }
}

/// Selection is explicit and immutable for a transport. A7 owns negotiation before selecting B4;
/// the decoder never infers a peer profile from an optional payload or retries another policy.
public enum AgentProtocolDecodingPolicy: Sendable, Equatable {
  case generic
  case negotiatedB4V1
}

/// Ordinary event data retains every original extension. The typed view assigns only standard
/// semantics in generic mode, so an unnegotiated b4 member never supplies correlation authority.
public struct AgentProtocolDecodedEvent: Encodable, Sendable {
  public let raw: AgentProtocol.Object
  public let standard: AgentProtocol.Event
  public var method: String { standard.method }
  public var params: AgentProtocol.Object { standard.params }
  public var eventID: String? { standard.eventID }
  public var seq: AgentProtocol.JSUInt? { standard.seq }
  public var correlation: AgentProtocol.EventCorrelation? { standard.correlation }

  public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

/// The original success/ResponseMeta remains ordinary opaque application data. Only explicitly
/// negotiated B4 mode exposes validated B4 receipt semantics in the typed view.
public struct AgentProtocolDecodedSuccess: Encodable, Sendable {
  public let raw: AgentProtocol.Object
  public let standard: AgentProtocol.Success<AgentProtocol.Value>
  public var id: AgentProtocol.JSUInt { standard.id }
  public var result: AgentProtocol.Value { standard.result }
  public var meta: AgentProtocol.ResponseMeta? { standard.meta }

  public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

/// The shared wire decoder does no projection or cursor advancement. Generic event params and
/// optional extension payloads remain opaque. A7 must validate B4 reserved payloads before acting.
public enum AgentProtocolFrame: Sendable {
  case event(AgentProtocolDecodedEvent)
  case snapshot(AgentProtocol.SnapshotEvent)
  case success(AgentProtocolDecodedSuccess)
  case failure(AgentProtocolCommandFailure)
  case opaque(AgentProtocol.Value)
  case extensionEvent(name: String?, data: String)
}

public struct AgentProtocolReceivedEvent: Sendable {
  /// SSE's persistent last-event-id is a separate string from wire eventId and seq.
  public let lastEventID: String?
  public let frame: AgentProtocolFrame
}

public enum AgentProtocolDecoder {
  public static func decode(_ data: Data, policy: AgentProtocolDecodingPolicy) throws -> AgentProtocolFrame {
    do {
      let value = try JSONDecoder().decode(AgentProtocol.Value.self, from: data)
      let typedData: Data
      if policy == .generic {
        // The pinned standard Extensible contract gives these optional members no B4 meaning.
        // Preserve original ordinary payloads, but omit only b4 from the copy fed to A1's strict
        // validators. An Error never retains the original raw value after its safe projection.
        var standard = value
        switch standard["type"] {
        case .string("event"):
          standard["b4"] = nil
        case .string("success"), .string("error"):
          if case .object(var meta) = standard["meta"] {
            meta.removeValue(forKey: "b4")
            standard["meta"] = .object(meta)
          }
        default: break
        }
        typedData = try JSONEncoder().encode(standard)
      } else {
        typedData = data
      }
      switch value["type"] {
      case .string("event"):
        if policy == .negotiatedB4V1, value["b4"]?["delivery"] == .string("snapshot") {
          return .snapshot(try JSONDecoder().decode(AgentProtocol.SnapshotEvent.self, from: data))
        }
        guard case .object(let raw) = value else { throw AgentProtocolTransportError.invalidResponse }
        return .event(
          AgentProtocolDecodedEvent(
            raw: raw, standard: try JSONDecoder().decode(AgentProtocol.Event.self, from: typedData)))
      case .string("success"):
        guard case .object(let raw) = value else { throw AgentProtocolTransportError.invalidResponse }
        return .success(
          AgentProtocolDecodedSuccess(
            raw: raw,
            standard: try JSONDecoder().decode(
              AgentProtocol.Success<AgentProtocol.Value>.self, from: typedData)))
      case .string("error"):
        return .failure(
          AgentProtocolCommandFailure(try JSONDecoder().decode(AgentProtocol.ASPError.self, from: typedData)))
      default:
        return .opaque(value)
      }
    } catch {
      throw AgentProtocolTransportError.invalidResponse
    }
  }

  public static func decode(
    _ event: SSEEvent, policy: AgentProtocolDecodingPolicy
  ) throws -> AgentProtocolReceivedEvent {
    let frame: AgentProtocolFrame
    if event.event == nil || event.event == "" || event.event == "message" {
      frame = try decode(Data(event.data.utf8), policy: policy)
    } else {
      frame = .extensionEvent(name: event.event, data: event.data)
    }
    return AgentProtocolReceivedEvent(lastEventID: event.id, frame: frame)
  }
}
