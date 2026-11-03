import Foundation
import Testing

@testable import WorkspaceStorage

/// D-171, found at the step-up live check: the packaged coordinator found its migrations only at the
/// build tree it was compiled in. It now finds the bundle the app carries, from where it runs.
@Suite struct StorageResourcesTests {
  /// `Agent Workspace.app` as `package.sh` assembles it: the resource bundle (Xcode's format, with
  /// `Contents/Info.plist` and `Contents/Resources`) in the app's own `Contents/Resources`, and the
  /// coordinator in `Contents/Helpers/B4AppCoordinator.app`. Answers the coordinator's executable.
  private func packagedApp(in root: URL) throws -> URL {
    let app = root.appendingPathComponent("Agent Workspace (Local).app")
    let bundle = app.appendingPathComponent("Contents/Resources/\(StorageResources.bundleName)/Contents")
    let sql = bundle.appendingPathComponent("Resources/SQL")
    try FileManager.default.createDirectory(
      at: sql.appendingPathComponent("registry"), withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "b4app.WorkspaceStorage.resources", "CFBundlePackageType": "BNDL",
    ]
    try (info as NSDictionary).write(to: bundle.appendingPathComponent("Info.plist"))
    try "SELECT 1;".write(to: sql.appendingPathComponent("0001_init.sql"), atomically: true, encoding: .utf8)
    try "SELECT 2;".write(
      to: sql.appendingPathComponent("registry/0001_registry.sql"), atomically: true, encoding: .utf8)
    let macOS = app.appendingPathComponent("Contents/Helpers/B4AppCoordinator.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("b4app-coordinator")
    try Data().write(to: executable)
    return executable
  }

  @Test func theCoordinatorFindsTheBundleItsAppCarries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-resources-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try packagedApp(in: root)

    let bundle = try #require(StorageResources.packaged(from: executable))
    let migrations = try #require(bundle.urls(forResourcesWithExtension: "sql", subdirectory: "SQL"))
    #expect(migrations.map(\.lastPathComponent) == ["0001_init.sql"])
    let registry = try #require(bundle.urls(forResourcesWithExtension: "sql", subdirectory: "SQL/registry"))
    #expect(registry.map(\.lastPathComponent) == ["0001_registry.sql"])
    #expect(bundle.bundleURL.path.hasPrefix(root.resolvingSymlinksInPath().path))
  }

  /// A development build or a test runs outside any app, so SwiftPM's own bundle is used.
  @Test func outsideAnAppThereIsNoPackagedBundle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-resources-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent(".build/release/b4app-coordinator")
    try FileManager.default.createDirectory(
      at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: tool)
    #expect(StorageResources.packaged(from: tool) == nil)
    #expect(StorageResources.packaged(from: nil) == nil)
    // And this test process (not in an app) uses the module bundle, which holds the migrations.
    #expect(try Migrator.files().isEmpty == false)
  }
}
