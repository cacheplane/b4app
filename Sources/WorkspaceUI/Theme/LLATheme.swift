import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// LiveLoveApp tokens (design: `docs/superpowers/specs/2026-10-31-lla-visual-system-design.md`).
/// Views compose these; no literal colours, radii, or font names live outside this folder.
public enum LLA {
  /// A light/dark pair of sRGB hex values that resolves with the window's appearance.
  public struct Dynamic: Sendable, Equatable {
    public var light: UInt32
    public var dark: UInt32

    public init(light: UInt32, dark: UInt32) {
      self.light = light
      self.dark = dark
    }

    public var color: SwiftUI.Color {
      #if canImport(AppKit)
        let light = self.light
        let dark = self.dark
        return SwiftUI.Color(
          nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
          })
      #else
        let light = self.light
        let dark = self.dark
        return SwiftUI.Color(
          uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
          })
      #endif
    }
  }

  public enum Palette {
    public static let bg = Dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)
    public static let surface = Dynamic(light: 0xF7F7F8, dark: 0x161617)
    public static let surfaceRaised = Dynamic(light: 0xECECEE, dark: 0x202022)
    public static let ink = Dynamic(light: 0x0D0D0D, dark: 0xECECEC)
    public static let muted = Dynamic(light: 0x5D5D5D, dark: 0x9C9C9C)
    public static let rule = Dynamic(light: 0xE8E8E8, dark: 0x262628)
    public static let accent = Dynamic(light: 0x002FA7, dark: 0x7F98E0)
    public static let accentHover = Dynamic(light: 0x00247F, dark: 0xA3B5EA)
    public static let danger = Dynamic(light: 0x962E1F, dark: 0xE07A6A)
    public static let codeBg = Dynamic(light: 0x0D0D0D, dark: 0x161617)
    public static let codeFg = Dynamic(light: 0xECECEC, dark: 0xECECEC)
    public static let selection = Dynamic(light: 0xD9E0F5, dark: 0x1F2A4D)
  }

  public enum Color {
    public static let bg = Palette.bg.color
    public static let surface = Palette.surface.color
    public static let surfaceRaised = Palette.surfaceRaised.color
    public static let ink = Palette.ink.color
    public static let muted = Palette.muted.color
    public static let rule = Palette.rule.color
    public static let accent = Palette.accent.color
    public static let accentHover = Palette.accentHover.color
    public static let danger = Palette.danger.color
    public static let codeBg = Palette.codeBg.color
    public static let codeFg = Palette.codeFg.color
    public static let selection = Palette.selection.color
  }

  public enum Radius {
    public static let input: CGFloat = 8
    public static let card: CGFloat = 16
    public static let pill: CGFloat = 999
  }

  public enum Space {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 40
  }

  public enum Metrics {
    #if os(macOS)
      public static let control: CGFloat = 30
    #else
      public static let control: CGFloat = 44
    #endif
    /// Reading column for transcripts and long copy.
    public static let column: CGFloat = 720
  }

  /// WCAG 2 contrast ratio between two sRGB hex colours; the theme tests pin the palette with it.
  public nonisolated static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
    let la = luminance(a)
    let lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  nonisolated static func luminance(_ hex: UInt32) -> Double {
    func channel(_ value: UInt32) -> Double {
      let c = Double(value & 0xFF) / 255
      return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
  }
}

#if canImport(AppKit)
  extension NSColor {
    convenience init(hex: UInt32) {
      self.init(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#else
  extension UIColor {
    convenience init(hex: UInt32) {
      self.init(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#endif
