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
  /// Nonisolated on purpose: AppKit and UIKit resolve a dynamic provider on whatever thread is
  /// drawing or snapshotting, and a main-actor closure trapped there (SIGTRAP in the iOS scene
  /// snapshot, found 2026-10-31 during the M8a click-through).
  public nonisolated struct Dynamic: Sendable, Equatable {
    public var light: UInt32
    public var dark: UInt32

    public init(light: UInt32, dark: UInt32) {
      self.light = light
      self.dark = dark
    }

    public var color: SwiftUI.Color {
      #if canImport(AppKit)
        return SwiftUI.Color(nsColor: nsColor)
      #else
        let light = self.light
        let dark = self.dark
        return SwiftUI.Color(
          uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
          })
      #endif
    }

    #if canImport(AppKit)
      /// The pair as an AppKit colour, for the AppKit views the app hosts (the Mac composer, D-219).
      public var nsColor: NSColor {
        let light = self.light
        let dark = self.dark
        return NSColor(name: nil) { appearance in
          let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          return NSColor(hex: isDark ? dark : light)
        }
      }
    #endif
  }

  public nonisolated enum Palette {
    public static let bg = Dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)
    public static let surface = Dynamic(light: 0xF7F7F8, dark: 0x161617)
    public static let surfaceRaised = Dynamic(light: 0xECECEE, dark: 0x202022)
    public static let ink = Dynamic(light: 0x0D0D0D, dark: 0xECECEC)
    public static let muted = Dynamic(light: 0x5D5D5D, dark: 0x9C9C9C)
    public static let rule = Dynamic(light: 0xE8E8E8, dark: 0x262628)
    public static let accent = Dynamic(light: 0x002FA7, dark: 0x7F98E0)
    public static let accentHover = Dynamic(light: 0x00247F, dark: 0xA3B5EA)
    public static let danger = Dynamic(light: 0x962E1F, dark: 0xE07A6A)
    /// The working mark's arc: the same lime in both modes.
    public static let working = Dynamic(light: 0xB4CE37, dark: 0xB4CE37)
    public static let codeBg = Dynamic(light: 0x0D0D0D, dark: 0x161617)
    public static let codeFg = Dynamic(light: 0xECECEC, dark: 0xECECEC)
    public static let selection = Dynamic(light: 0xD9E0F5, dark: 0x1F2A4D)
    /// Supplementary marks (the runtime logos on thread rows); below the graphics floor on purpose.
    public static let ghost = Dynamic(light: 0xB8B8BC, dark: 0x5A5A5E)
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
    public static let working = Palette.working.color
    public static let codeBg = Palette.codeBg.color
    public static let codeFg = Palette.codeFg.color
    public static let selection = Palette.selection.color
    public static let ghost = Palette.ghost.color
  }

  public enum Radius {
    public static let input: CGFloat = 8
    public static let card: CGFloat = 16
    /// Floating menus (the profile menu).
    public static let menu: CGFloat = 12
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
      /// The least height of a tappable row. The Mac draws rows at their content height.
      public static let row: CGFloat = 0
      /// A thread row: one 16 pt line in a 28 pt row, `rowGap` between rows.
      public static let threadRow: CGFloat = 28
      /// Side margin of a page, the transcript, and the composer.
      public static let margin: CGFloat = Space.xl
    #else
      /// Apple's minimum hit target on iPhone, 44 by 44 pt (HIG, Accessibility; D-060).
      public static let control: CGFloat = 44
      public static let row: CGFloat = 44
      /// A thread row's least height; Dynamic Type grows it.
      public static let threadRow: CGFloat = 44
      /// The iPhone's system layout margin, 16 pt, so pages line up with lists and the navigation bar.
      public static let margin: CGFloat = Space.l
    #endif
    /// The Mac sidebar column's fixed width.
    public static let sidebarWidth: CGFloat = 240
    /// The box a thread's state mark is drawn in, at the default text size (`ThreadMark`).
    public static let mark: CGFloat = 12
    /// A tiny thread row (the Mac's lower list under Dense): an 11 pt line in a 20 pt row.
    public static let threadRowTiny: CGFloat = 20
    /// The space between consecutive rows in the sidebar's lists: a hairline of space, not a drawn
    /// line. A section gap above a list's first row replaces it (D-208, the owner's changes).
    public static let rowGap: CGFloat = 1
    /// A tiny row's mark box.
    public static let markTiny: CGFloat = 8
    /// Reading column for transcripts and long copy.
    public static let column: CGFloat = 720
    /// The smallest window the macOS app allows; the thread detail must fit inside it at any
    /// content (`DetailMinimumSizeTests`).
    public static let minimumWindow = CGSize(width: 900, height: 600)
    /// The most height the pending-request area takes before it scrolls, so a long command or
    /// several requests never push the composer off the window or collapse the split view.
    public static let requestsMaxHeight: CGFloat = 240
    /// Expanded diagnostic text scrolls within this height instead of enlarging the app window.
    public static let diagnosticsMaxHeight: CGFloat = 120
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
    nonisolated convenience init(hex: UInt32) {
      self.init(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#else
  extension UIColor {
    nonisolated convenience init(hex: UInt32) {
      self.init(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#endif
