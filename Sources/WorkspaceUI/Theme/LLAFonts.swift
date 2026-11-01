import CoreText
import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// Hanken Grotesk (400, 600) and JetBrains Mono (variable), bundled under the SIL Open Font License
/// and registered with CoreText once per process. When a face is missing the system font stands in.
public enum LLAFonts {
  public static let sansRegular = "HankenGrotesk-Regular"
  public static let sansSemiBold = "HankenGrotesk-SemiBold"
  public static let monoRegular = "JetBrainsMono-Regular"
  public static let monoSemiBold = "JetBrainsMono-SemiBold"

  private static var state: Bool?

  /// Registers the bundled fonts. Idempotent; returns true when every required face resolves.
  @discardableResult public static func register() -> Bool {
    if let state { return state }
    let ok = register(bundle: .module)
    state = ok
    return ok
  }

  /// Registers every `Fonts/*.ttf` in `bundle`; false when the bundle holds none or a face is unusable.
  static func register(bundle: Bundle) -> Bool {
    let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
    for url in urls {
      var error: Unmanaged<CFError>?
      // A second registration of the same file reports "already registered"; that is success.
      _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
    return !urls.isEmpty && [sansRegular, sansSemiBold, monoRegular].allSatisfy(isAvailable)
  }

  /// True when CoreText resolves `postScriptName` to itself rather than a fallback face.
  public static func isAvailable(_ postScriptName: String) -> Bool {
    let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
    return (CTFontCopyPostScriptName(font) as String) == postScriptName
  }
}

#if os(iOS)
  /// Navigation-bar titles in Hanken Grotesk SemiBold rather than SF Pro, so a pushed title, a
  /// sheet's title, and Settings' large title carry the same face as the rest of the app (D-036). Set
  /// on the appearance proxy, which leaves the bar's own background and glass alone; `UIFontMetrics`
  /// scales the faces with Dynamic Type as the system titles do.
  @MainActor enum LLANavigationBar {
    private static var applied = false

    static func apply() {
      guard !applied, LLAFonts.register(),
        let inline = UIFont(name: LLAFonts.sansSemiBold, size: 17),
        let large = UIFont(name: LLAFonts.sansSemiBold, size: 34)
      else { return }
      applied = true
      let ink = UIColor {
        UIColor(hex: $0.userInterfaceStyle == .dark ? LLA.Palette.ink.dark : LLA.Palette.ink.light)
      }
      let bar = UINavigationBar.appearance()
      bar.titleTextAttributes = [
        .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline), .foregroundColor: ink,
      ]
      bar.largeTitleTextAttributes = [
        .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large), .foregroundColor: ink,
        .kern: -0.6,
      ]
    }
  }
#endif

/// The type scale. Sizes are points; Dynamic Type scales them on iOS through `relativeTo`.
public enum LLAFont {
  private static let heavy: Set<Font.Weight> = [.semibold, .bold, .heavy, .black]

  public static func sans(
    _ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body
  )
    -> Font
  {
    guard LLAFonts.register() else { return .system(size: size, weight: weight) }
    return .custom(
      heavy.contains(weight) || boldText ? LLAFonts.sansSemiBold : LLAFonts.sansRegular, size: size,
      relativeTo: style)
  }

  /// Bold Text is the app's to honour with a custom face (HIG, Typography): regular text takes the
  /// semibold face while it is on. Turning it on redraws the views, which read this again.
  static var boldText: Bool {
    #if os(iOS)
      UIAccessibility.isBoldTextEnabled
    #else
      false
    #endif
  }

  /// A size that Dynamic Type leaves alone, for text inside a shape that already scales (a monogram
  /// in an avatar or a runtime mark); scaling both would double the growth.
  public static func sans(fixed size: CGFloat, weight: Font.Weight = .regular) -> Font {
    guard LLAFonts.register() else { return .system(size: size, weight: weight) }
    return .custom(heavy.contains(weight) ? LLAFonts.sansSemiBold : LLAFonts.sansRegular, fixedSize: size)
  }

  public static func mono(
    _ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body
  )
    -> Font
  {
    guard LLAFonts.register() else { return .system(size: size, weight: weight, design: .monospaced) }
    let name =
      (heavy.contains(weight) || boldText) && LLAFonts.isAvailable(LLAFonts.monoSemiBold)
      ? LLAFonts.monoSemiBold : LLAFonts.monoRegular
    return .custom(name, size: size, relativeTo: style)
  }

  public static var display: Font { sans(scale.display, weight: .semibold, relativeTo: .title) }
  public static var title: Font { sans(scale.title, weight: .semibold, relativeTo: .title3) }
  public static var body: Font { sans(scale.body) }
  public static var bodyStrong: Font { sans(scale.body, weight: .semibold) }
  public static var small: Font { sans(scale.small, relativeTo: .subheadline) }
  public static var smallStrong: Font { sans(scale.small, weight: .semibold, relativeTo: .subheadline) }
  public static var caption: Font { sans(scale.caption, relativeTo: .caption) }
  public static var code: Font { mono(scale.code, relativeTo: .callout) }
  public static var codeSmall: Font { mono(scale.codeSmall, relativeTo: .footnote) }
  /// Sidebar, menu, and search rows: dense on the Mac, the size of a system list row on the phone.
  public static var row: Font { sans(scale.row, relativeTo: scale.rowStyle) }
  public static var rowStrong: Font { sans(scale.row, weight: .semibold, relativeTo: scale.rowStyle) }
  /// Pill button titles.
  public static var button: Font { sans(scale.button, weight: .semibold, relativeTo: scale.buttonStyle) }

  /// The scale this platform draws with.
  public static var scale: LLATypeScale {
    #if os(iOS)
      .phone
    #else
      .mac
    #endif
  }
}

/// Point sizes for each role at the default text size. The Mac keeps D-036's desktop scale; the phone
/// starts each role at the size of the iOS text style it scales with (body 17, subheadline 15,
/// caption 12, title3 20, title 28; Apple's Typography specifications), so a custom face reads like
/// the system's and Dynamic Type moves it in step (D-060).
public struct LLATypeScale: Sendable, Equatable {
  public var display: CGFloat
  public var title: CGFloat
  public var body: CGFloat
  public var small: CGFloat
  public var caption: CGFloat
  public var code: CGFloat
  public var codeSmall: CGFloat
  public var button: CGFloat
  public var buttonStyle: Font.TextStyle
  public var row: CGFloat
  public var rowStyle: Font.TextStyle

  public static let mac = LLATypeScale(
    display: 26, title: 19, body: 15, small: 13, caption: 12, code: 13, codeSmall: 12, button: 13,
    buttonStyle: .subheadline, row: 13, rowStyle: .subheadline)
  /// Mono runs a point or two under its sans neighbour: JetBrains Mono is wider and taller per point.
  public static let phone = LLATypeScale(
    display: 28, title: 20, body: 17, small: 15, caption: 12, code: 15, codeSmall: 13, button: 17,
    buttonStyle: .body, row: 17, rowStyle: .body)

  /// Every size, for checks against a floor.
  public var all: [CGFloat] { [display, title, body, small, caption, code, codeSmall, button, row] }
}

extension View {
  /// Thread and sheet titles: 26/600 with the site's tight tracking.
  public func llaDisplay() -> some View {
    font(LLAFont.display).tracking(-0.5).foregroundStyle(LLA.Color.ink)
  }
  /// Section heads: 19/600.
  public func llaTitle() -> some View { font(LLAFont.title).tracking(-0.2).foregroundStyle(LLA.Color.ink) }
  public func llaBody() -> some View { font(LLAFont.body).foregroundStyle(LLA.Color.ink) }
  public func llaMuted() -> some View { font(LLAFont.body).foregroundStyle(LLA.Color.muted) }
  public func llaSmall() -> some View { font(LLAFont.small).foregroundStyle(LLA.Color.ink) }
  public func llaSmallMuted() -> some View { font(LLAFont.small).foregroundStyle(LLA.Color.muted) }
  public func llaCaption() -> some View { font(LLAFont.caption).foregroundStyle(LLA.Color.muted) }
  public func llaCode() -> some View { font(LLAFont.code).foregroundStyle(LLA.Color.ink) }
  public func llaCodeMuted() -> some View { font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted) }
}
