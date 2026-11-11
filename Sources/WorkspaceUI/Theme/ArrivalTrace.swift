import SwiftUI

extension View {
  /// A thread's arrival in the top list, drawn on its row's fill shape (the rounded rectangle of radius
  /// 8): the row slides up 12 pt into place over 0.5 s, a 0.5 pt inset hairline at 30% ink appears, a
  /// point of light laps the edge twice in 3.5 s at constant speed, and the hairline has faded out by 10 s. Without
  /// `laps` there is no lap; under Reduce Motion no slide and no lap, the hairline only. Nothing here
  /// changes the row's layout, and the text never blinks. Apply it to the view that draws the fill.
  public func arrivalTrace(_ arrival: Arrival?, reduceMotion: Bool) -> some View {
    modifier(ArrivalTraceModifier(arrival: arrival, reduceMotion: reduceMotion))
  }
}

/// The trace at one moment: a pure function of the time since the arrival, so a row that comes on
/// screen part-way through (a section expanded, the list scrolled) joins it where it is.
struct ArrivalTraceFrame: Equatable {
  /// How far below its place the row is drawn, in points.
  var offset: CGFloat
  /// The hairline's strength, 0–1 (of its 30% ink).
  var hairline: Double
  /// The point of light's strength, 0–1.
  var light: Double
  /// How far the light's leading end has travelled along the edge, in laps (0–2): a fraction of the
  /// perimeter, so it moves at one speed along the long edges and round the ends alike.
  var head: Double

  /// No trace: what a row without an arrival draws.
  static let rest = ArrivalTraceFrame(offset: 0, hairline: 0, light: 0, head: 0)

  /// The light's length: 12% of the perimeter, brightest at its leading end and fading to nothing at
  /// its tail.
  static let segment = 0.12

  static let slide: CGFloat = 12
  static let slideDuration: TimeInterval = 0.5
  static let hairlineIn: TimeInterval = 0.5
  /// The hairline fades out over the last 1.5 s of the arrival's 10.
  static let hairlineOut: TimeInterval = 1.5
  /// The light fades in over its first 0.45 s and out over its last.
  static let lightFade: TimeInterval = 0.45

  init(offset: CGFloat, hairline: Double, light: Double, head: Double) {
    self.offset = offset
    self.hairline = hairline
    self.light = light
    self.head = head
  }

  init(elapsed: TimeInterval, laps: Bool, reduceMotion: Bool) {
    guard elapsed < Arrival.lifetime else {
      self = .rest
      return
    }
    let t = max(elapsed, 0)
    let slid = min(t / Self.slideDuration, 1)
    offset = reduceMotion ? 0 : Self.slide * CGFloat(pow(1 - slid, 3))  // cubic ease-out
    hairline = min(min(t / Self.hairlineIn, 1), (Arrival.lifetime - t) / Self.hairlineOut, 1)
    if laps && !reduceMotion {
      // Two laps at constant speed along the perimeter, then still (and dark).
      head = 2 * min(t, Arrival.lapDuration) / Arrival.lapDuration
      light =
        t < Arrival.lapDuration ? min(t / Self.lightFade, (Arrival.lapDuration - t) / Self.lightFade, 1) : 0
    } else {
      light = 0
      head = 0
    }
  }

  /// A stretch of the edge, as fractions of its perimeter from the path's start (0–1).
  struct Piece: Equatable {
    var from: Double
    var to: Double
  }

  /// The stretch lit by a segment of `length` (a fraction of the perimeter) whose leading end has
  /// travelled `head` laps: one piece, or two where it crosses the path's start (its tail up to the
  /// path's end, then the start up to the head), together `length` long. Before the light has
  /// travelled `length` it reaches back only to the start.
  static func pieces(head: Double, length: Double) -> [Piece] {
    let tail = max(head - length, 0)
    let lap = tail.rounded(.down)
    let (from, to) = (tail - lap, head - lap)
    guard to > 1 else { return [Piece(from: from, to: to)] }
    return [Piece(from: from, to: 1), Piece(from: 0, to: to - 1)]
  }
}

private struct ArrivalTraceModifier: ViewModifier {
  let arrival: Arrival?
  let reduceMotion: Bool
  /// The arrival whose 10 s have run out; the row stops drawing it before the model is asked again.
  @State private var ended: Arrival?

  func body(content: Content) -> some View {
    let live = arrival == ended ? nil : arrival
    // Always the same timeline, paused when nothing is arriving, so a trace starting or ending does
    // not rebuild the row (and restart its mark's motion).
    TimelineView(.animation(minimumInterval: nil, paused: live == nil)) { context in
      let frame =
        live.map {
          ArrivalTraceFrame(
            elapsed: context.date.timeIntervalSince($0.at), laps: $0.laps, reduceMotion: reduceMotion)
        } ?? .rest
      content
        .overlay { ArrivalTraceEdge(frame: frame) }
        .offset(y: frame.offset)
    }
    // Wakes once, when the arrival ends, so the row redraws without it; no timer while none is live.
    .task(id: arrival) {
      guard let arrival else { return }
      let remaining = arrival.at.addingTimeInterval(Arrival.lifetime).timeIntervalSinceNow
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      guard !Task.isCancelled else { return }
      ended = arrival
    }
  }
}

/// The hairline and the point of light on the row's fill shape.
struct ArrivalTraceEdge: View {
  let frame: ArrivalTraceFrame
  /// How many steps the light's fade is drawn in.
  static let slices = 16

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
    ZStack {
      if frame.hairline > 0 {
        shape.strokeBorder(LLA.Color.ink.opacity(0.3 * frame.hairline), lineWidth: 0.5)
      }
      if frame.light > 0 {
        // A short stroke travelling along the edge: `slices` abutting stretches (trimmed by length, so
        // the speed is constant), from nearly clear at the tail to full ink at the head. Each stretch
        // is split where it crosses the path's start, so the segment wraps without a jump or a gap.
        let edge = shape.inset(by: 0.5)
        let slice = ArrivalTraceFrame.segment / Double(Self.slices)
        ZStack {
          ForEach(0..<Self.slices, id: \.self) { index in
            let end = frame.head - slice * Double(Self.slices - 1 - index)
            let pieces = end > 0 ? ArrivalTraceFrame.pieces(head: end, length: slice) : []
            ForEach(pieces.indices, id: \.self) { piece in
              edge.trim(from: pieces[piece].from, to: pieces[piece].to)
                .stroke(LLA.Color.ink.opacity(Double(index + 1) / Double(Self.slices)), lineWidth: 1)
            }
          }
        }
        .opacity(frame.light)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
