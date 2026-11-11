import Foundation

/// How the account's thread list is arranged: one synced row (`viewSettings`, id `view`) that every
/// device of the account reads and any of them may write. Decoding is lenient per field: a missing,
/// null, or unknown value is that field's default, so a value a newer build wrote reads as the default
/// here (and stays in the row, since a write names only the fields it changes).
public struct ViewSettings: Codable, Sendable, Equatable {
  public enum Arrangement: String, Codable, Sendable, CaseIterable { case needsYouFirst, byEnvironment }
  public enum QuietThreads: String, Codable, Sendable, CaseIterable { case small, tiny, collapsed, hidden }

  /// Default `.needsYouFirst`.
  public var arrangement: Arrangement
  /// How the threads that do not need you are drawn; default `.small`.
  public var quietThreads: QuietThreads
  /// Default false.
  public var showArchived: Bool

  /// The id of the one row.
  public static let rowId = "view"

  public enum Device: Sendable { case mac, phone }

  public init(
    arrangement: Arrangement = .needsYouFirst, quietThreads: QuietThreads = .small, showArchived: Bool = false
  ) {
    self.arrangement = arrangement
    self.quietThreads = quietThreads
    self.showArchived = showArchived
  }

  /// The stored text values read leniently: nil or unknown is the default.
  public init(arrangement: String?, quietThreads: String?, showArchived: Bool?) {
    self.init(
      arrangement: arrangement.flatMap(Arrangement.init(rawValue:)) ?? .needsYouFirst,
      quietThreads: quietThreads.flatMap(QuietThreads.init(rawValue:)) ?? .small,
      showArchived: showArchived ?? false)
  }

  /// What this device draws for the stored values (decision 5). Never written back.
  public func shown(on device: Device) -> ViewSettings {
    var shown = self
    if device == .phone, quietThreads == .tiny { shown.quietThreads = .collapsed }
    return shown
  }

  private enum CodingKeys: String, CodingKey { case arrangement, quietThreads, showArchived }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      arrangement: (try? container.decodeIfPresent(String.self, forKey: .arrangement)) ?? nil,
      quietThreads: (try? container.decodeIfPresent(String.self, forKey: .quietThreads)) ?? nil,
      showArchived: (try? container.decodeIfPresent(Bool.self, forKey: .showArchived)) ?? nil)
  }
}
