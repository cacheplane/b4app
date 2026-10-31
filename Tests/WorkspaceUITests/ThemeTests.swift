import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import WorkspaceUI

@Suite struct ThemeTests {
  @Test func parsesIconIntoClosedPath() {
    let path = LLAMark(variant: .icon).path(in: CGRect(x: 0, y: 0, width: 120, height: 120))
    #expect(!path.isEmpty)
    let box = path.boundingRect
    #expect(abs(box.width - 120) < 1 && abs(box.height - 120) < 1)
    // The full mark is wider than tall (320 x 120) and keeps its ratio when sized by height.
    #expect(abs(LLAMark.aspect(.full) - 320.0 / 120.0) < 0.01)
    // The artwork sits inside its viewBox with clear space, so the fitted path stays inside the
    // 64 x 24 box the ratio implies and fills most of its height.
    let fitted = LLAMark(variant: .full).path(in: CGRect(x: 0, y: 0, width: 96, height: 24)).boundingRect
    #expect(CGRect(x: 16, y: 0, width: 64, height: 24).insetBy(dx: -0.5, dy: -0.5).contains(fitted))
    #expect(fitted.height > 16)
  }

  @Test func parserHandlesRelativeAndCurveCommands() {
    let path = SVGPathData.parse("M10 10 l10 0 L20 20 H10 V10 Q15 5 20 10 C 20 0, 10 0, 10 10 Z")
    #expect(!path.isEmpty)
    let box = path.boundingRect
    #expect(box.minX >= 9 && box.maxX <= 21 && box.minY >= -1 && box.maxY <= 21)
  }

  @Test func registersBundledFonts() {
    #expect(LLAFonts.register() == true)
    #expect(LLAFonts.isAvailable(LLAFonts.sansRegular))
    #expect(LLAFonts.isAvailable(LLAFonts.sansSemiBold))
    #expect(LLAFonts.isAvailable(LLAFonts.monoRegular))
  }

  @Test func fallsBackWhenMissing() throws {
    let empty = try #require(Bundle(path: NSTemporaryDirectory()))
    #expect(LLAFonts.register(bundle: empty) == false)
    #expect(LLAFonts.isAvailable("NoSuchFace-Regular") == false)
    // Sizes still resolve to a usable font either way; the system font stands in.
    _ = LLAFont.sans(15)
    _ = LLAFont.mono(13, weight: .semibold)
  }

  @Test func contrast() {
    let p = LLA.Palette.self
    for (fg, bg, floor) in [
      (p.ink, p.bg, 4.5), (p.muted, p.bg, 4.5), (p.accent, p.bg, 4.5), (p.danger, p.bg, 4.5),
      (p.ink, p.surface, 4.5), (p.muted, p.surface, 3.0), (p.bg, p.ink, 4.5), (p.codeFg, p.codeBg, 4.5),
    ] {
      #expect(
        LLA.contrast(fg.light, bg.light) >= floor,
        "light \(String(fg.light, radix: 16)) on \(String(bg.light, radix: 16))")
      #expect(
        LLA.contrast(fg.dark, bg.dark) >= floor,
        "dark \(String(fg.dark, radix: 16)) on \(String(bg.dark, radix: 16))")
    }
  }
}
