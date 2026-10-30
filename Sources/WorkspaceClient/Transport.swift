import Foundation
import WorkspaceProtocol

/// A bidirectional line-oriented channel to the coordinator. Implementations live outside this
/// module (NIO on macOS, a relay on iOS later) so this module stays Foundation-only.
public protocol WorkspaceTransport: Sendable {
  /// Complete inbound lines (one JSON document each), ending when the connection closes.
  var incoming: AsyncStream<Data> { get }
  /// Why this transport cannot deliver, when known up front (nil for live connections).
  var unavailableReason: String? { get }
  /// Write one line (the trailing newline is added by the transport if missing).
  func send(_ line: Data) async throws
  func close() async
}

/// A transport that cannot connect, used where no coordinator is reachable (for example iOS until a
/// relay exists). Every send fails with `endpoint_unavailable` and the inbound stream is already finished.
extension WorkspaceTransport {
  public var unavailableReason: String? { nil }
}

public struct UnavailableTransport: WorkspaceTransport {
  public let reason: String
  public let incoming: AsyncStream<Data>
  public var unavailableReason: String? { reason }

  public init(reason: String) {
    self.reason = reason
    self.incoming = AsyncStream { continuation in continuation.finish() }
  }

  public func send(_ line: Data) async throws {
    throw WorkspaceErrorBox.unavailable(reason)
  }

  public func close() async {}
}

/// Keeps this module free of a dependency cycle while surfacing protocol errors.
enum WorkspaceErrorBox {
  static func unavailable(_ reason: String) -> any Error {
    WorkspaceProtocol.WorkspaceError(.endpointUnavailable, reason)
  }
}
