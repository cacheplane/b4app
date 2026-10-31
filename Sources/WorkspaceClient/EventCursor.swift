import Foundation

/// Tracks the client's position in the coordinator event stream (spec section 6.2).
/// A gap, a changed epoch, or an expired replay buffer requires a fresh snapshot.
public enum CursorAdvance: Sendable, Equatable {
  case ok, duplicate, gap, epochChanged
}

public struct EventCursor: Sendable, Equatable {
  public private(set) var epoch: String?
  public private(set) var sequence: Int = -1

  public init() {}

  /// Position the cursor after a snapshot.
  public mutating func reset(epoch: String, sequence: Int) {
    self.epoch = epoch
    self.sequence = sequence
  }

  /// Observe an incoming event; the cursor moves forward only on `.ok`.
  public mutating func advance(epoch next: String, sequence nextSequence: Int) -> CursorAdvance {
    guard let current = epoch else {
      epoch = next
      sequence = nextSequence
      return .ok
    }
    if next != current { return .epochChanged }
    if nextSequence <= sequence { return .duplicate }
    if nextSequence != sequence + 1 { return .gap }
    sequence = nextSequence
    return .ok
  }
}
