import SwiftUI

/// How far a quiet thread's title fades with the age of its last activity, in five steps: under a day
/// full strength, then 0.9, 0.82, 0.76, and 0.72 from two weeks on. It never fades further, so an old
/// title stays readable.
public enum QuietFade {
  public static func opacity(ageInDays: Double) -> Double {
    switch ageInDays {
    case ..<1: return 1.0
    case ..<3: return 0.9
    case ..<7: return 0.82
    case ..<14: return 0.76
    default: return 0.72
    }
  }
}

extension View {
  /// A working thread's title: dimmed ink with a band of full ink sweeping across it once every 4 s.
  /// Brightness only; the text is never invisible. Off under Reduce Motion, where the title stays the
  /// colour set outside this modifier. Apply it directly to the `Text`, inside its `foregroundStyle`.
  public func workingShimmer(active: Bool) -> some View {
    modifier(WorkingShimmer(active: active))
  }
}

private struct WorkingShimmer: ViewModifier {
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var swept = false

  func body(content: Content) -> some View {
    if active && !reduceMotion {
      content
        .modifier(ShimmerSweep(phase: swept ? 1 : 0))
        // Starts from rest each time the shimmer comes on, as the mark's motion does.
        .task {
          var reset = Transaction()
          reset.disablesAnimations = true
          withTransaction(reset) { swept = false }
          try? await Task.sleep(for: .milliseconds(30))
          guard !Task.isCancelled else { return }
          withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: false)) { swept = true }
        }
    } else {
      content
    }
  }
}

/// The sweep at one phase. The gradient is twice the text's width; at phase 0 its bright centre sits
/// half a width before the text's leading edge, at phase 1 half a width past its trailing edge.
private struct ShimmerSweep: ViewModifier, Animatable {
  var phase: Double

  nonisolated var animatableData: Double {
    get { phase }
    set { phase = newValue }
  }

  /// Ink laid 78% over the sidebar's surface.
  static let dim = LLA.Palette.ink.mixed(0.78, over: LLA.Palette.surface).color

  func body(content: Content) -> some View {
    let start = -1.5 + 2 * phase
    content.foregroundStyle(
      LinearGradient(
        stops: [
          .init(color: Self.dim, location: 0),
          .init(color: Self.dim, location: 0.3),
          .init(color: LLA.Color.ink, location: 0.5),
          .init(color: Self.dim, location: 0.7),
          .init(color: Self.dim, location: 1),
        ],
        startPoint: UnitPoint(x: start, y: 0.5), endPoint: UnitPoint(x: start + 2, y: 0.5)))
  }
}

extension LLA.Dynamic {
  /// This colour laid `fraction` over `base`, channel by channel in sRGB (CSS
  /// `color-mix(in srgb, self fraction, base)`), in each appearance.
  nonisolated func mixed(_ fraction: Double, over base: LLA.Dynamic) -> LLA.Dynamic {
    func mix(_ top: UInt32, _ bottom: UInt32) -> UInt32 {
      var out: UInt32 = 0
      for shift in [16, 8, 0] as [UInt32] {
        let t = Double((top >> shift) & 0xFF)
        let b = Double((bottom >> shift) & 0xFF)
        out |= UInt32((t * fraction + b * (1 - fraction)).rounded()) << shift
      }
      return out
    }
    return LLA.Dynamic(light: mix(light, base.light), dark: mix(dark, base.dark))
  }
}
