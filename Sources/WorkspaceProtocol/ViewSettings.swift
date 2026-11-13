import Foundation

/// How the account's thread list is arranged: one synced row (`viewSettings`, id `view`) that every
/// device of the account reads and any of them may write. Decoding is lenient per field: a missing,
/// null, or unknown value is that field's default, so a value a newer build wrote reads as the default
/// here (and stays in the row, since a write names only the fields it changes).
public struct ViewSettings: Codable, Sendable, Equatable {
  public enum Arrangement: String, Codable, Sendable, CaseIterable { case needsYouFirst, byEnvironment }
  /// How tall the list's rows are.
  public enum Density: String, Codable, Sendable, CaseIterable { case normal, dense }
  /// Where the threads that do not need you go.
  public enum QuietThreads: String, Codable, Sendable, CaseIterable { case shown, collapsed, hidden }

  /// Default `.needsYouFirst`.
  public var arrangement: Arrangement
  /// Where the threads that do not need you go; default `.shown`.
  public var quietThreads: QuietThreads
  /// Default false.
  public var showArchived: Bool
  /// Default `.normal`.
  public var density: Density

  /// The id of the one row.
  public static let rowId = "view"

  public init(
    arrangement: Arrangement = .needsYouFirst, quietThreads: QuietThreads = .shown,
    showArchived: Bool = false, density: Density = .normal
  ) {
    self.arrangement = arrangement
    self.quietThreads = quietThreads
    self.showArchived = showArchived
    self.density = density
  }

  /// The stored text values read leniently: nil or unknown is the default. The old `quietThreads`
  /// values `small` and `tiny` read as `.shown`; `tiny` also reads as `.dense` unless a valid density
  /// is stored, which always wins.
  public init(arrangement: String?, quietThreads: String?, showArchived: Bool?, density: String? = nil) {
    self.init(
      arrangement: arrangement.flatMap(Arrangement.init(rawValue:)) ?? .needsYouFirst,
      quietThreads: quietThreads.flatMap(QuietThreads.init(rawValue:)) ?? .shown,
      showArchived: showArchived ?? false,
      density: density.flatMap(Density.init(rawValue:))
        ?? Self.impliedDensity(storedQuietThreads: quietThreads, storedDensity: density) ?? .normal)
  }

  /// The density an old stored `quietThreads` implies: `.dense` for `tiny` when no valid density is
  /// stored; otherwise nil.
  public static func impliedDensity(storedQuietThreads: String?, storedDensity: String?) -> Density? {
    guard storedDensity.flatMap(Density.init(rawValue:)) == nil, storedQuietThreads == "tiny" else {
      return nil
    }
    return .dense
  }

  private enum CodingKeys: String, CodingKey { case arrangement, quietThreads, showArchived, density }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      arrangement: (try? container.decodeIfPresent(String.self, forKey: .arrangement)) ?? nil,
      quietThreads: (try? container.decodeIfPresent(String.self, forKey: .quietThreads)) ?? nil,
      showArchived: (try? container.decodeIfPresent(Bool.self, forKey: .showArchived)) ?? nil,
      density: (try? container.decodeIfPresent(String.self, forKey: .density)) ?? nil)
  }
}
