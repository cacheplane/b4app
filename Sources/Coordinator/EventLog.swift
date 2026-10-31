import Foundation
import WorkspaceProtocol

/// In-memory event stream with a new epoch per coordinator start and a bounded replay buffer.
public actor EventLog {
  public let epoch: String
  public private(set) var sequence = 0
  private let bufferSize: Int
  private var buffer: [EventEnvelope] = []
  private var subscribers: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]

  public init(epoch: String = UUID().uuidString.lowercased(), bufferSize: Int = 1_000) {
    self.epoch = epoch
    self.bufferSize = bufferSize
  }

  @discardableResult
  public func publish(_ event: AdapterEvent) -> EventEnvelope {
    sequence += 1
    let envelope = EventEnvelope(epoch: epoch, sequence: sequence, event: event)
    buffer.append(envelope)
    if buffer.count > bufferSize { buffer.removeFirst(buffer.count - bufferSize) }
    for continuation in subscribers.values { continuation.yield(envelope) }
    return envelope
  }

  public func subscribe() -> AsyncStream<EventEnvelope> {
    let id = UUID()
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
    }
  }

  private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

  /// Events after `afterSequence` in `epoch`, or nil when a fresh snapshot is required.
  public func replay(epoch requested: String, afterSequence: Int) -> [EventEnvelope]? {
    guard requested == epoch, afterSequence <= sequence else { return nil }
    let oldest = buffer.first?.sequence ?? (sequence + 1)
    if afterSequence + 1 < oldest, afterSequence < sequence { return nil }
    return buffer.filter { $0.sequence > afterSequence }
  }

  public func finish() {
    for continuation in subscribers.values { continuation.finish() }
    subscribers = [:]
  }
}
