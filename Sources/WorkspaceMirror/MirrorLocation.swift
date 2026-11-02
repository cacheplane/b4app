import Foundation

/// Where the phone's mirror file lives. The app and the widget extension share it through the App Group
/// container, so the widget reads what the app wrote (D-114). Foundation only: the app and the widget
/// each pass their own App Group id, read from their Info.plist.
public enum MirrorLocation {
  public static let fileName = "mirror.sqlite"

  /// What `move(from:to:)` did.
  public enum Move: Equatable, Sendable {
    /// The old directory holds no `mirror.sqlite`; nothing changed.
    case nothingToMove
    /// The old files now live in the new directory.
    case moved
    /// The new directory already had a `mirror.sqlite`, so it wins and the old files stay where they were.
    case keptGroupCopy
  }

  /// `<group container>/b4app`, created when missing with `completeUntilFirstUserAuthentication` (the
  /// widget must read it while the phone is locked, after the first unlock). Nil when the group
  /// container is unavailable.
  public static func groupDirectory(appGroup: String) -> URL? {
    let resolved = storeDirectory(appGroup: appGroup, fallback: URL(fileURLWithPath: "/"))
    guard resolved.inGroup else { return nil }
    do {
      try FileManager.default.createDirectory(
        at: resolved.directory, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
      return resolved.directory
    } catch {
      return nil
    }
  }

  /// The directory the mirror lives in: `<resolved container>/b4app` (and `inGroup` true) when
  /// `appGroup` is set and `resolve` finds its container, else `fallback`. Creates nothing.
  public static func storeDirectory(
    appGroup: String?, fallback: URL,
    resolve: (String) -> URL? = {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }
  ) -> (directory: URL, inGroup: Bool) {
    guard let appGroup, let container = resolve(appGroup) else { return (fallback, false) }
    return (container.appendingPathComponent("b4app", isDirectory: true), true)
  }

  /// Moves `mirror.sqlite` and its `-wal` and `-shm` (each only if it exists) from `old` to `new`,
  /// creating `new` when missing. Never deletes: an old file stays when the new directory already has a
  /// `mirror.sqlite` (`.keptGroupCopy`, nothing touched), and side files without a main file are left
  /// alone (`.nothingToMove`). Each file moves by rename (the app container and the group container share a
  /// volume), one after another; call it before the store is opened. A crash between two renames can strand
  /// a `-wal` apart from its main file, which loses only what that log held, so run it once per launch.
  public static func move(from old: URL, to new: URL) throws -> Move {
    let manager = FileManager.default
    let oldMain = old.appendingPathComponent(fileName)
    guard manager.fileExists(atPath: oldMain.path) else { return .nothingToMove }
    guard !manager.fileExists(atPath: new.appendingPathComponent(fileName).path) else {
      return .keptGroupCopy
    }
    try manager.createDirectory(at: new, withIntermediateDirectories: true)
    for suffix in ["-wal", "-shm", ""] {
      let source = old.appendingPathComponent(fileName + suffix)
      guard manager.fileExists(atPath: source.path) else { continue }
      let target = new.appendingPathComponent(fileName + suffix)
      // A stray side file at the destination (no main file there) would block the move.
      if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
      try manager.moveItem(at: source, to: target)
    }
    return .moved
  }
}
