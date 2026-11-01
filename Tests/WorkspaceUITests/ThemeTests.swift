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

  @Test func dynamicColorsResolveOffTheMainActor() async {
    // AppKit and UIKit call a dynamic colour provider on whatever thread draws or snapshots. A
    // main-actor provider trapped in the iOS scene snapshot (2026-10-31), so every palette colour
    // must resolve from a nonisolated context; a regression crashes this test process.
    let resolved = await Task.detached { () -> Int in
      let palette: [LLA.Dynamic] = [
        LLA.Palette.bg, LLA.Palette.surface, LLA.Palette.surfaceRaised, LLA.Palette.ink,
        LLA.Palette.muted, LLA.Palette.rule, LLA.Palette.accent, LLA.Palette.accentHover,
        LLA.Palette.danger, LLA.Palette.codeBg, LLA.Palette.codeFg, LLA.Palette.selection,
        LLA.Palette.ghost,
      ]
      var count = 0
      for dynamic in palette where NSColor(dynamic.color).usingColorSpace(.sRGB) != nil {
        count += 1
      }
      return count
    }.value
    #expect(resolved == 13)
  }

  @Test func parserHandlesRelativeAndCurveCommands() {
    let path = SVGPathData.parse("M10 10 l10 0 L20 20 H10 V10 Q15 5 20 10 C 20 0, 10 0, 10 10 Z")
    #expect(!path.isEmpty)
    let box = path.boundingRect
    #expect(box.minX >= 9 && box.maxX <= 21 && box.minY >= -1 && box.maxY <= 21)
  }

  @Test func parserHandlesArcsAndPackedNumbers() {
    // Simple Icons paths use relative arcs and run decimals together (".07.07" is two numbers).
    let arc = SVGPathData.parse("M0 10a10 10 0 0 0 20 0z")
    let box = arc.boundingRect
    #expect(abs(box.width - 20) < 0.5 && abs(box.maxY - 20) < 0.5 && abs(box.minY - 10) < 0.5)
    let packed = SVGPathData.parse("M0 0l.5.5L1 0z")
    #expect(abs(packed.boundingRect.maxY - 0.5) < 0.01)
  }

  @Test func runtimeMarksLoad() throws {
    for name in ["openai", "anthropic"] {
      let art = try #require(BrandArt.load(named: name), "\(name).svg did not parse")
      #expect(!art.path.isEmpty)
      #expect(art.viewBox.width > 0 && art.viewBox.height > 0)
      // The whole mark is drawn: a parser that stops early leaves a fraction of the viewBox.
      #expect(art.path.boundingRect.width > art.viewBox.width * 0.8)
    }
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

  @Test func phoneTypeScaleMeetsTheHIG() {
    // D-060: the phone starts each role at its iOS text style's default size, never under Apple's
    // 11 pt floor, with body at the system's 17 pt; the Mac keeps D-036's desktop scale.
    let phone = LLATypeScale.phone
    #expect(phone.body == 17 && phone.row == 17 && phone.button == 17)
    #expect(phone.small == 15 && phone.caption == 12 && phone.title == 20 && phone.display == 28)
    #expect(phone.all.allSatisfy { $0 >= 11 })
    #expect(LLATypeScale.mac.body == 15 && LLATypeScale.mac.row == 13 && LLATypeScale.mac.button == 13)
    // Each phone role is at least the Mac's: the phone never reads smaller than the desktop.
    #expect(zip(phone.all, LLATypeScale.mac.all).allSatisfy { $0 >= $1 })
    // This test target runs on the Mac, so the desktop scale and metrics are the ones in use.
    #expect(LLAFont.scale == .mac)
    #expect(LLA.Metrics.row == 0 && LLA.Metrics.margin == LLA.Space.xl && LLA.Metrics.control == 30)
  }

  @Test func composerChoosesLineOrBox() {
    // D-061: one line only on a wide screen, for a draft that fits beside the 32 pt button with no
    // line break, and never at an accessibility size. A 400 pt field leaves 400 - 16 - 8 - 32 - 6.
    let room: CGFloat = 400 - 16 - 8 - 32 - 6
    func shape(
      wide: Bool = true, ax: Bool = false, draft: String = "Ship it", width: CGFloat
    ) -> ComposerView.Shape {
      ComposerView.shape(wide: wide, accessibilitySize: ax, draft: draft, draftWidth: width, fieldWidth: 400)
    }
    #expect(shape(width: room) == .line)
    #expect(shape(width: room + 1) == .box)
    #expect(shape(wide: false, width: 10) == .box)
    #expect(shape(ax: true, width: 10) == .box)
    #expect(shape(draft: "two\nlines", width: 10) == .box)
    #expect(
      ComposerView.shape(wide: true, accessibilitySize: false, draft: "", draftWidth: 50, fieldWidth: 0)
        == .line)
    // The button is concentric with the 44 pt line's corner: equal gaps on every side it touches.
    #expect(ComposerView.inset * 2 + ComposerView.control == ComposerView.line)
  }

  @Test func contrast() {
    // `ghost` is exempt from the 3:1 graphics floor: the runtime marks it draws are supplementary,
    // and the row's accessibility label names the runtime.
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
