import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

@Suite struct LauncherTests {
  @Test func coordinatorCandidatesCoverOverrideSiblingAndInstalledApp() {
    let env = ["B4APP_COORDINATOR_PATH": "/x/b4app-coordinator", "HOME": "/Users/me"]
    let cli = URL(fileURLWithPath: "/Applications/Agent Workspace.app/Contents/Helpers/agent-workspace")
    let candidates = CoordinatorLauncher.candidatePaths(environment: env, executableURL: cli)
    #expect(candidates.first == "/x/b4app-coordinator")
    #expect(candidates.contains("/Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator"))
    #expect(
      candidates.contains("/Users/me/Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator"))
  }

  @Test func symlinkedCliFindsTheBundledCoordinator() throws {
    let base = NSTemporaryDirectory() + "b4launch-\(UUID().uuidString.prefix(8))"
    let helpers = base + "/Agent Workspace.app/Contents/Helpers"
    try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: base + "/bin", withIntermediateDirectories: true)
    for name in ["agent-workspace", "b4app-coordinator"] {
      FileManager.default.createFile(
        atPath: "\(helpers)/\(name)", contents: Data("#!/bin/sh\n".utf8),
        attributes: [.posixPermissions: 0o755])
    }
    try FileManager.default.createSymbolicLink(
      atPath: base + "/bin/agent-workspace", withDestinationPath: helpers + "/agent-workspace")
    let found = CoordinatorLauncher.executablePath(
      environment: ["PATH": "/nonexistent", "HOME": base, ExecutableLocator.fallbackOverrideVariable: ""],
      executableURL: URL(fileURLWithPath: base + "/bin/agent-workspace"))
    #expect(
      found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        == URL(fileURLWithPath: helpers + "/b4app-coordinator").resolvingSymlinksInPath().path)
  }

  @Test func stopIsANoOpWithoutACoordinatorAndThePlistNamesTheHelper() async throws {
    let paths = PlatformPaths(
      runtimeDir: NSTemporaryDirectory() + "b4none-\(UUID().uuidString.prefix(6))", dataDir: "/tmp")
    #expect(try await CoordinatorLauncher.stop(paths: paths) == nil)
    let plist = LaunchAgentControl.plist(logPath: "/tmp/log")
    #expect(plist.contains("<string>Contents/Helpers/b4app-coordinator</string>"))
    #expect(plist.contains("<string>com.cacheplane.b4app.coordinator</string>"))
    #expect(plist.contains("<key>LimitLoadToSessionType</key><string>Aqua</string>"))
    let parsed =
      try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
    #expect(parsed?["RunAtLoad"] as? Bool == true)
  }
}
