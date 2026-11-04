import Foundation

/// Where `WorkspaceStorage`'s resources (the migrations under `SQL/` and `SQL/registry/`) are found
/// (D-171). SwiftPM's `Bundle.module` looks only beside the main bundle (`<.app>/b4app_WorkspaceStorage.bundle`,
/// a place a signed app cannot hold files) and then at the absolute build path it was compiled in. The
/// packaged coordinator runs from `Agent Workspace.app/Contents/Helpers/B4AppCoordinator.app`, so on
/// any Mac without that build tree `Bundle.module` stopped the process the first time it was used.
/// The packaged app carries the bundle in its own `Contents/Resources`, so that is looked for first,
/// walking up from the executable through every enclosing `.app`; a development build (an executable
/// under `.build`, or a test) falls back to `Bundle.module`.
enum StorageResources {
  static let bundleName = "b4app_WorkspaceStorage.bundle"

  /// The bundle every resource lookup in this module uses.
  static let bundle: Bundle = packaged(from: Bundle.main.executableURL) ?? Bundle.module

  /// The resource bundle in the `Contents/Resources` of the nearest enclosing `.app` that has one,
  /// walking up from `executable` (symlinks resolved); `nil` outside any such app.
  static func packaged(from executable: URL?) -> Bundle? {
    var directory = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
    while let current = directory, current.pathComponents.count > 1 {
      if current.pathExtension == "app" {
        let candidate = current.appendingPathComponent("Contents/Resources/\(bundleName)", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          let found = Bundle(url: candidate)
        {
          return found
        }
      }
      directory = current.deletingLastPathComponent()
    }
    return nil
  }
}
