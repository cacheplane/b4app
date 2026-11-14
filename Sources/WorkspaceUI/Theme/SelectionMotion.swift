import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// How a list's selection highlight moves (D-222): one shape that glides from row to row, under the
/// arrow keys and under the pointer alike, with the same spring in every list that has one.
public enum SelectionMotion {
  /// A short spring with no bounce: it retargets cleanly when a key repeats or the pointer sweeps.
  public static let glide: Animation = .snappy(duration: 0.16, extraBounce: 0)

  /// The glide, or nothing under Reduce Motion: the highlight is then simply on the new row.
  public static func animation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : glide }

  /// The same, read from the system, for code with no view's environment to ask.
  @MainActor public static var current: Animation? {
    #if os(macOS)
      animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    #else
      animation(reduceMotion: UIAccessibility.isReduceMotionEnabled)
    #endif
  }
}

extension View {
  /// The selected row's highlight. Every row of a list carries this with the list's namespace; the
  /// one that is selected draws the shape, and a change made inside `withAnimation` slides it.
  public func selectionHighlight(_ selected: Bool, in namespace: Namespace.ID) -> some View {
    background {
      if selected {
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
          .fill(LLA.Color.surfaceRaised)
          .matchedGeometryEffect(id: "selection", in: namespace)
      }
    }
  }
}
