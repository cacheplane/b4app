import Foundation

/// Where the owner left the Mac's palette: how far from where it opens by itself, in points. It
/// belongs to this device and never syncs; nothing stored means it opens at home.
enum PalettePlace {
  static let key = "palette.offset"

  private struct Stored: Codable {
    var x: Double
    var y: Double
  }

  static func offset(in preferences: any LocalPreferences) -> CGSize? {
    guard let data = preferences.data(forKey: key),
      let stored = try? JSONDecoder().decode(Stored.self, from: data),
      stored.x.isFinite, stored.y.isFinite
    else { return nil }
    return CGSize(width: stored.x, height: stored.y)
  }

  /// `nil` forgets it: the palette opens at home again.
  static func remember(_ offset: CGSize?, in preferences: any LocalPreferences) {
    let data = offset.flatMap { try? JSONEncoder().encode(Stored(x: $0.width, y: $0.height)) }
    preferences.set(data, forKey: key)
  }
}
