import SwiftUI
import WorkspaceProtocol

extension ThreadState {
  /// What the mark says to VoiceOver: the shape carries the state, so it needs a name.
  public var spokenLabel: String {
    switch self {
    case .approve: return "Needs your approval"
    case .reply: return "Needs your reply"
    case .failed: return "Failed"
    case .finished: return "Finished"
    case .working: return "Working"
    case .quiet: return "Quiet"
    }
  }
}

/// A thread's state as one mark in a 12 pt box that grows with the text. The shape carries the state
/// and colour only reinforces it: approve is a dot in a ring, pulsing until the thread is opened
/// (`acknowledged`); reply a large dot; failed a cross in danger; finished a small dot; working a
/// faint ring with a lime arc that orbits; quiet nothing (the box keeps its place). Under Reduce
/// Motion, or with `animated` off (the widget), nothing moves: the working mark is a still ring and arc.
public struct ThreadMark: View {
  let state: ThreadState
  let acknowledged: Bool
  let animated: Bool
  let tiny: Bool

  /// `tiny` draws in the 8 pt box of a tiny row (`LLA.Metrics.markTiny`); the shapes keep their
  /// proportions.
  public init(state: ThreadState, acknowledged: Bool = false, animated: Bool = true, tiny: Bool = false) {
    self.state = state
    self.acknowledged = acknowledged
    self.animated = animated
    self.tiny = tiny
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The phase of the one motion this mark has: the pulse ring spread out, or the arc turned once.
  @State private var moved = false
  /// 12 pt at the default size (8 when tiny); every measurement below is in a 12 by 12 box scaled to it.
  @ScaledMetric(relativeTo: .body) private var regularSize: CGFloat = LLA.Metrics.mark
  @ScaledMetric(relativeTo: .body) private var tinySize: CGFloat = LLA.Metrics.markTiny
  private var size: CGFloat { tiny ? tinySize : regularSize }

  /// When the mark moves: the pulse and the orbit are its only motion.
  public enum Motion {
    /// An approve mark pulses until its thread is opened since its latest activity.
    public static func pulses(state: ThreadState, acknowledged: Bool, reduceMotion: Bool) -> Bool {
      state == .approve && !acknowledged && !reduceMotion
    }

    /// A working mark's arc turns.
    public static func orbits(state: ThreadState, reduceMotion: Bool) -> Bool {
      state == .working && !reduceMotion
    }
  }

  private enum Movement: Equatable { case none, pulse, orbit }

  private var movement: Movement {
    let still = reduceMotion || !animated
    if Motion.pulses(state: state, acknowledged: acknowledged, reduceMotion: still) { return .pulse }
    if Motion.orbits(state: state, reduceMotion: still) { return .orbit }
    return .none
  }

  public var body: some View {
    let u = size / 12
    ZStack {
      switch state {
      case .approve:
        if movement == .pulse {
          Circle().stroke(LLA.Color.ink, lineWidth: 1.5 * u)
            .frame(width: 9.5 * u, height: 9.5 * u)
            .scaleEffect(moved ? 1.3 : 0.5)
            .opacity(moved ? 0 : 1)
        }
        Circle().stroke(LLA.Color.ink, lineWidth: 1.5 * u).frame(width: 9.5 * u, height: 9.5 * u)
        Circle().fill(LLA.Color.ink).frame(width: 4.5 * u, height: 4.5 * u)
      case .reply:
        Circle().fill(LLA.Color.ink).frame(width: 8 * u, height: 8 * u)
      case .failed:
        Cross()
          .stroke(LLA.Color.danger, style: StrokeStyle(lineWidth: 1.8 * u, lineCap: .round))
      case .finished:
        Circle().fill(LLA.Color.ink).frame(width: 5 * u, height: 5 * u)
      case .working:
        Circle().stroke(LLA.Color.ink.opacity(0.22), lineWidth: 1.5 * u)
          .frame(width: 6.5 * u, height: 6.5 * u)
        Circle()
          .stroke(
            LLA.Color.working,
            style: StrokeStyle(lineWidth: 1.75 * u, lineCap: .round, dash: [6.4 * u, 14 * u])
          )
          .frame(width: 6.5 * u, height: 6.5 * u)
          // The dash starts at three o'clock; a still arc starts at twelve.
          .rotationEffect(.degrees(movement == .orbit && moved ? 270 : -90))
      case .quiet:
        Color.clear
      }
    }
    .frame(width: size, height: size)
    // Keyed by the motion, not by the state: a row keeps its identity when its state changes in place,
    // and Reduce Motion can change while it is on screen. Each change resets the phase first, so a mark
    // that stops and starts again begins from rest.
    .task(id: movement) {
      var reset = Transaction()
      reset.disablesAnimations = true
      withTransaction(reset) { moved = false }
      guard movement != .none else { return }
      try? await Task.sleep(for: .milliseconds(30))
      guard !Task.isCancelled else { return }
      let animation: Animation =
        movement == .pulse
        ? .easeOut(duration: 1.25).repeatForever(autoreverses: false)
        : .linear(duration: 1.4).repeatForever(autoreverses: false)
      withAnimation(animation) { moved = true }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(state.spokenLabel)
    .accessibilityHidden(state == .quiet)
  }

  /// The failed cross, from (2.6, 2.6) to (9.4, 9.4) and (9.4, 2.6) to (2.6, 9.4) in the 12 pt box.
  private struct Cross: Shape {
    func path(in rect: CGRect) -> Path {
      let u = rect.width / 12
      func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * u, y: rect.minY + y * u)
      }
      var path = Path()
      path.move(to: point(2.6, 2.6))
      path.addLine(to: point(9.4, 9.4))
      path.move(to: point(9.4, 2.6))
      path.addLine(to: point(2.6, 9.4))
      return path
    }
  }
}
