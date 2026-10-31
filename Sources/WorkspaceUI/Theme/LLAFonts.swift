import CoreText
import SwiftUI

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
      heavy.contains(weight) ? LLAFonts.sansSemiBold : LLAFonts.sansRegular, size: size, relativeTo: style)
  }

  public static func mono(
    _ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body
  )
    -> Font
  {
    guard LLAFonts.register() else { return .system(size: size, weight: weight, design: .monospaced) }
    let name =
      heavy.contains(weight) && LLAFonts.isAvailable(LLAFonts.monoSemiBold)
      ? LLAFonts.monoSemiBold : LLAFonts.monoRegular
    return .custom(name, size: size, relativeTo: style)
  }

  public static var display: Font { sans(26, weight: .semibold, relativeTo: .title) }
  public static var title: Font { sans(19, weight: .semibold, relativeTo: .title3) }
  public static var body: Font { sans(15) }
  public static var bodyStrong: Font { sans(15, weight: .semibold) }
  public static var small: Font { sans(13, relativeTo: .subheadline) }
  public static var smallStrong: Font { sans(13, weight: .semibold, relativeTo: .subheadline) }
  public static var caption: Font { sans(12, relativeTo: .caption) }
  public static var code: Font { mono(13, relativeTo: .callout) }
  public static var codeSmall: Font { mono(12, relativeTo: .caption) }
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
