import Foundation
import Synchronization

/// Small choices that belong to this device and never sync: the last model, permission, and project a
/// new thread used. Values are encoded `Data`, keyed by a string, so a reader owns its own format and
/// a missing or unreadable value just means "no preference".
public protocol LocalPreferences: AnyObject, Sendable {
  func data(forKey key: String) -> Data?
  /// `nil` removes the value.
  func set(_ data: Data?, forKey key: String)
}

/// The app's per-device defaults: Foundation keeps them per app (and per flavour, since each flavour
/// is its own bundle), in the device's preferences, outside the data directory and the hub.
extension UserDefaults: LocalPreferences {
  public func set(_ data: Data?, forKey key: String) {
    set(data as Any?, forKey: key)
  }
}

/// Preferences held in memory, for tests and previews.
public final class InMemoryPreferences: LocalPreferences {
  private let values = Mutex<[String: Data]>([:])

  public init() {}

  public func data(forKey key: String) -> Data? { values.withLock { $0[key] } }

  public func set(_ data: Data?, forKey key: String) {
    values.withLock { $0[key] = data }
  }
}
