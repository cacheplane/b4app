import CoreGraphics
import Testing

@testable import WorkspaceUI

/// What a change of the transcript's scroll geometry says about the reader (F14, F15): the rule that
/// decides whether the stream may move the view.
@Suite struct TranscriptReadingTests {
  /// A 480 pt viewport over `height` of content, its top edge at `top`.
  private func geometry(height: CGFloat, top: CGFloat) -> TranscriptEnd {
    let below = height - (top + 480)
    return TranscriptEnd(
      height: height, top: top, reached: below <= 8, away: below > LLA.Metrics.margin + 8)
  }

  @Test func scrollingBackOverTheSameContentIsReading() {
    let end = geometry(height: 2_000, top: 1_520)
    #expect(TranscriptEnd.intent(from: end, to: geometry(height: 2_000, top: 1_220)) == .reading)
  }

  @Test func theEndInViewIsFollowing() {
    let back = geometry(height: 2_000, top: 1_220)
    #expect(TranscriptEnd.intent(from: back, to: geometry(height: 2_000, top: 1_520)) == .following)
    #expect(TranscriptEnd.intent(from: back, to: geometry(height: 2_000, top: 1_514)) == .following)
  }

  /// A reply streaming under a still viewport is not the reader's doing, and neither is being taken
  /// down towards the end.
  @Test func contentGrowingOrTheViewGoingDownChangesNothing() {
    let end = geometry(height: 2_000, top: 1_520)
    #expect(TranscriptEnd.intent(from: end, to: geometry(height: 2_400, top: 1_520)) == .unchanged)
    let back = geometry(height: 2_000, top: 600)
    #expect(TranscriptEnd.intent(from: back, to: geometry(height: 2_000, top: 900)) == .unchanged)
  }

  /// A layout pass that resizes the content moves the view with it; the reader did not scroll.
  @Test func aLayoutPassThatMovesTheViewIsNotReading() {
    let before = geometry(height: 2_000, top: 1_200)
    #expect(TranscriptEnd.intent(from: before, to: geometry(height: 1_900, top: 1_100)) == .unchanged)
  }

  /// Following rests the view with the transcript's bottom padding below it; a small settling move
  /// there is still the end.
  @Test func aMoveWithinTheBottomPaddingIsNotReading() {
    let rest = geometry(height: 2_000, top: 1_520 - LLA.Metrics.margin)
    let nudged = geometry(height: 2_000, top: 1_520 - LLA.Metrics.margin - 4)
    #expect(TranscriptEnd.intent(from: rest, to: nudged) == .unchanged)
  }
}
