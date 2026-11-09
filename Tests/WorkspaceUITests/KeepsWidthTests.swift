import AppKit
import SwiftUI
import Testing

@testable import WorkspaceUI

/// The picker row's project label gives way first at a narrow width, but never to a sliver: it keeps
/// its ideal width up to the floor, so a long name still shows its ends and a short one is not padded.
@Suite @MainActor struct KeepsWidthTests {
  private func width(_ view: some View, proposed: CGFloat) -> CGFloat {
    NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: proposed, height: 0)).width
  }

  @Test func aLongLabelKeepsTheFloor() {
    let name = String(repeating: "A long project name ", count: 6)
    let label = Text(name).lineLimit(1).truncationMode(.middle).keepsWidth(80)
    #expect(width(label, proposed: 10) >= 80)
    // Given more, it takes up to what it is given (a truncated line may measure a little less).
    let given = width(label, proposed: 200)
    #expect(given > 180 && given <= 200)
  }

  @Test func aShortLabelIsNotPadded() {
    let ideal = width(Text("B4").fixedSize(), proposed: 0)
    #expect(ideal < 40)
    #expect(width(Text("B4").lineLimit(1).keepsWidth(80), proposed: 10) == ideal)
  }

  /// In an `HStack` beside labels with a higher priority, the label keeps the floor; without it, it
  /// would be the one cut to nothing.
  @Test func itHoldsTheFloorBesideHigherPriorityLabels() {
    let long = String(repeating: "A long label ", count: 10)
    let row = HStack(spacing: 0) {
      Text(long).lineLimit(1).keepsWidth(80)
      Text(long).lineLimit(1).layoutPriority(2)
    }
    // The row's minimum is at least the floor (the other label truncates to an ellipsis).
    #expect(width(row, proposed: 0) >= 80)
  }
}
