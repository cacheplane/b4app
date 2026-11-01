import Foundation
import SwiftUI
import Synchronization

/// The LiveLoveApp mark (two Ls and a snow-capped A) drawn from the vendored outlined SVGs, never
/// typed in a font. Fill it even-odd: the snow and the icon's A are cut out of the shape.
public nonisolated struct LLAMark: Shape {
  public enum Variant: String, Sendable, Hashable {
    case full = "lla-mark"
    case icon = "lla-icon"
    case iconSmall = "lla-icon-small"
  }

  public var variant: Variant

  public init(variant: Variant = .full) { self.variant = variant }

  public func path(in rect: CGRect) -> Path {
    BrandShape(name: variant.rawValue).path(in: rect)
  }

  /// Natural width divided by height, for sizing by height.
  public static func aspect(_ variant: Variant) -> CGFloat {
    guard let art = BrandArt.load(variant), art.viewBox.height > 0 else { return 1 }
    return art.viewBox.width / art.viewBox.height
  }
}

/// The mark at a given height in a colour; the brand allows ink, white, or cobalt alone.
public struct LLAMarkView: View {
  public var variant: LLAMark.Variant
  public var height: CGFloat
  public var color: Color

  public init(variant: LLAMark.Variant = .full, height: CGFloat = 24, color: Color = LLA.Color.ink) {
    self.variant = variant
    self.height = height
    self.color = color
  }

  public var body: some View {
    LLAMark(variant: variant)
      .fill(color, style: FillStyle(eoFill: true))
      .frame(width: height * LLAMark.aspect(variant), height: height)
      .accessibilityLabel("LiveLoveApp")
  }
}

nonisolated struct BrandArt: Sendable {
  var viewBox: CGRect
  var path: Path

  private static let cache = Mutex<[String: BrandArt]>([:])

  static func load(_ variant: LLAMark.Variant) -> BrandArt? { load(named: variant.rawValue) }

  /// A vendored SVG in `Resources/Brand` by file name, without the extension.
  static func load(named name: String) -> BrandArt? {
    if let cached = cache.withLock({ $0[name] }) { return cached }
    guard
      let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Brand"),
      let text = try? String(contentsOf: url, encoding: .utf8), let art = parse(svg: text)
    else { return nil }
    cache.withLock { $0[name] = art }
    return art
  }

  /// Reads `viewBox` and the first `<path d>` of an outlined SVG.
  static func parse(svg: String) -> BrandArt? {
    guard let box = capture(#"viewBox="([^"]+)""#, in: svg), let d = capture(#"\sd="([^"]+)""#, in: svg)
    else {
      return nil
    }
    let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    guard numbers.count == 4 else { return nil }
    return BrandArt(
      viewBox: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
      path: SVGPathData.parse(d))
  }

  private static func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}

/// A minimal SVG path-data reader for the outlined brand files: M, L, H, V, Q, C, A, and Z, absolute
/// or relative.
nonisolated enum SVGPathData {
  private enum Token { case command(Character), number(CGFloat) }

  static func parse(_ d: String) -> Path {
    let tokens = tokenize(d)
    var path = Path()
    var index = 0
    var command: Character = "M"
    var current = CGPoint.zero
    var start = CGPoint.zero

    func number() -> CGFloat? {
      guard index < tokens.count, case .number(let value) = tokens[index] else { return nil }
      index += 1
      return value
    }
    func point(relative: Bool) -> CGPoint? {
      guard let x = number(), let y = number() else { return nil }
      return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    while index < tokens.count {
      if case .command(let c) = tokens[index] {
        command = c
        index += 1
        if c == "Z" || c == "z" {
          path.closeSubpath()
          current = start
        }
        continue
      }
      let relative = command.isLowercase
      switch command.uppercased() {
      case "M":
        guard let p = point(relative: relative) else { return path }
        path.move(to: p)
        current = p
        start = p
        command = relative ? "l" : "L"
      case "L":
        guard let p = point(relative: relative) else { return path }
        path.addLine(to: p)
        current = p
      case "H":
        guard let x = number() else { return path }
        current = CGPoint(x: relative ? current.x + x : x, y: current.y)
        path.addLine(to: current)
      case "V":
        guard let y = number() else { return path }
        current = CGPoint(x: current.x, y: relative ? current.y + y : y)
        path.addLine(to: current)
      case "Q":
        guard let control = point(relative: relative), let p = point(relative: relative) else { return path }
        path.addQuadCurve(to: p, control: control)
        current = p
      case "C":
        guard let c1 = point(relative: relative), let c2 = point(relative: relative),
          let p = point(relative: relative)
        else { return path }
        path.addCurve(to: p, control1: c1, control2: c2)
        current = p
      case "A":
        guard let rx = number(), let ry = number(), let rotation = number(), let large = number(),
          let sweep = number(), let p = point(relative: relative)
        else { return path }
        addArc(
          to: &path, from: current, to: p, radii: CGSize(width: rx, height: ry), rotation: rotation,
          large: large != 0, sweep: sweep != 0)
        current = p
      default:
        return path
      }
    }
    return path
  }

  /// An elliptical arc as cubic curves, from the endpoint form (SVG 1.1, appendix F.6.5 and F.6.6).
  private static func addArc(
    to path: inout Path, from start: CGPoint, to end: CGPoint, radii: CGSize, rotation: CGFloat,
    large: Bool, sweep: Bool
  ) {
    var rx = abs(radii.width)
    var ry = abs(radii.height)
    guard rx > 0, ry > 0, start != end else {
      path.addLine(to: end)
      return
    }
    let phi = rotation * .pi / 180
    let (cosPhi, sinPhi) = (cos(phi), sin(phi))
    let dx = (start.x - end.x) / 2
    let dy = (start.y - end.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = (max(0, numerator) / denominator).squareRoot()
    if large == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry
    let cy1 = -factor * ry * x1 / rx
    let center = CGPoint(
      x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
      y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    // One cubic per quarter turn or less keeps the error far below a pixel at icon sizes.
    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    func onEllipse(_ t: CGFloat) -> (point: CGPoint, derivative: CGPoint) {
      let (cosT, sinT) = (cos(t), sin(t))
      let point = CGPoint(
        x: center.x + rx * cosT * cosPhi - ry * sinT * sinPhi,
        y: center.y + rx * cosT * sinPhi + ry * sinT * cosPhi)
      let derivative = CGPoint(
        x: -rx * sinT * cosPhi - ry * cosT * sinPhi,
        y: -rx * sinT * sinPhi + ry * cosT * cosPhi)
      return (point, derivative)
    }
    var t = theta1
    for index in 0..<segments {
      let a = onEllipse(t)
      let b = onEllipse(t + step)
      let target = index == segments - 1 ? end : b.point
      path.addCurve(
        to: target,
        control1: CGPoint(x: a.point.x + k * a.derivative.x, y: a.point.y + k * a.derivative.y),
        control2: CGPoint(x: b.point.x - k * b.derivative.x, y: b.point.y - k * b.derivative.y))
      t += step
    }
  }

  private static func tokenize(_ d: String) -> [Token] {
    var tokens: [Token] = []
    var buffer = ""
    func flush() {
      if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
      buffer = ""
    }
    for character in d {
      if character.isLetter {
        flush()
        tokens.append(.command(character))
      } else if character == " " || character == "," || character == "\n" || character == "\t" {
        flush()
      } else if character == "-", !buffer.isEmpty, !buffer.hasSuffix("e") {
        flush()
        buffer = "-"
      } else if character == ".", buffer.contains("."), !buffer.contains("e") {
        // A second decimal point starts the next number: ".07.07" is 0.07 then 0.07.
        flush()
        buffer = "."
      } else {
        buffer.append(character)
      }
    }
    flush()
    return tokens
  }
}
