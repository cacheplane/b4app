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
    guard let art = BrandArt.load(variant), art.viewBox.width > 0, art.viewBox.height > 0 else {
      return Path()
    }
    let scale = min(rect.width / art.viewBox.width, rect.height / art.viewBox.height)
    let width = art.viewBox.width * scale
    let height = art.viewBox.height * scale
    let transform = CGAffineTransform(
      translationX: rect.minX + (rect.width - width) / 2 - art.viewBox.minX * scale,
      y: rect.minY + (rect.height - height) / 2 - art.viewBox.minY * scale
    ).scaledBy(x: scale, y: scale)
    return art.path.applying(transform)
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

  private static let cache = Mutex<[LLAMark.Variant: BrandArt]>([:])

  static func load(_ variant: LLAMark.Variant) -> BrandArt? {
    if let cached = cache.withLock({ $0[variant] }) { return cached }
    guard
      let url = Bundle.module.url(forResource: variant.rawValue, withExtension: "svg", subdirectory: "Brand"),
      let text = try? String(contentsOf: url, encoding: .utf8), let art = parse(svg: text)
    else { return nil }
    cache.withLock { $0[variant] = art }
    return art
  }

  /// Reads `viewBox` and the first `<path d>` of an outlined SVG (absolute M, L, H, V, Q, C, Z only).
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

/// A minimal SVG path-data reader for the outlined brand files.
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
      default:
        return path
      }
    }
    return path
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
      } else {
        buffer.append(character)
      }
    }
    flush()
    return tokens
  }
}
