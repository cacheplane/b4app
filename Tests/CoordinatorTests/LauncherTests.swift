import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

@Suite struct LauncherTests {
  /// `LockRecord` has no public initializer; the coordinator writes it as JSON.
  func record(pid: Int32) -> LockRecord {
    try! JSONDecoder().decode(
      LockRecord.self, from: Data(#"{"pid":\#(pid),"startedAt":"t","socketPath":"/tmp/s"}"#.utf8))
  }

  @Test func coordinatorCandidatesCoverOverrideSiblingAndInstalledApp() {
    let env = ["B4APP_COORDINATOR_PATH": "/x/b4app-coordinator", "HOME": "/Users/me"]
    let cli = URL(fileURLWithPath: "/Applications/Agent Workspace.app/Contents/Helpers/agent-workspace")
    let candidates = CoordinatorLauncher.candidatePaths(environment: env, executableURL: cli)
    #expect(candidates.first == "/x/b4app-coordinator")
    let wrapped = "Agent Workspace.app/Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator"
    #expect(candidates[1] == "/Applications/\(wrapped)")
    #expect(candidates.contains("/Users/me/Applications/\(wrapped)"))
  }

  @Test func symlinkedCliFindsTheBundledCoordinator() throws {
    let base = NSTemporaryDirectory() + "b4launch-\(UUID().uuidString.prefix(8))"
    let helpers = base + "/Agent Workspace.app/Contents/Helpers"
    try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: base + "/bin", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: helpers + "/B4AppCoordinator.app/Contents/MacOS", withIntermediateDirectories: true)
    for name in ["agent-workspace", CoordinatorLauncher.helperWrapper] {
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
        == URL(fileURLWithPath: helpers + "/" + CoordinatorLauncher.helperWrapper).resolvingSymlinksInPath()
        .path)
  }

  @Test func stopIsANoOpWithoutACoordinatorAndThePlistNamesTheHelper() async throws {
    let paths = PlatformPaths(
      runtimeDir: NSTemporaryDirectory() + "b4none-\(UUID().uuidString.prefix(6))", dataDir: "/tmp")
    #expect(try await CoordinatorLauncher.stop(paths: paths) == nil)
    let plist = LaunchAgentControl.plist(logPath: "/tmp/log")
    #expect(
      plist.contains(
        "<string>Contents/Helpers/B4AppCoordinator.app/Contents/MacOS/b4app-coordinator</string>"))
    #expect(plist.contains("<string>\(LaunchAgentControl.label)</string>"))
    #expect(LaunchAgentControl.label == "com.cacheplane.b4app\(Flavor.current.idSuffix).coordinator")
    #expect(plist.contains("<key>LimitLoadToSessionType</key><string>Aqua</string>"))
    let parsed =
      try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
    #expect(parsed?["RunAtLoad"] as? Bool == true)
  }

  @Test func userAgentPlistCarriesTheAbsoluteProgramAndReadsBack() throws {
    let home = NSTemporaryDirectory() + "b4agent-\(UUID().uuidString.prefix(6))"
    let program = "/Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator"
    let path = LaunchAgentControl.userPlistPath(home: home)
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try LaunchAgentControl.userPlist(programPath: program).write(
      toFile: path, atomically: true, encoding: .utf8)
    #expect(LaunchAgentControl.installedProgramPath(home: home) == program)
    let parsed =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any]
    #expect(parsed?["Label"] as? String == LaunchAgentControl.label)
    #expect(parsed?["RunAtLoad"] as? Bool == true)
    #expect((parsed?["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
    #expect(LaunchAgentControl.installedProgramPath(home: home + "/nowhere") == nil)
  }

  @Test func jobStateReadsTheTopLevelPidAndState() {
    let output = """
      gui/501/com.cacheplane.b4app.coordinator = {
      \tactive count = 1
      \tstate = running
      \tprogram = /Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator
      \truns = 3
      \tpid = 4242
      \tlast exit code = 0
      \tendpoints = {
      \t\tstate = active
      \t}
      }
      """
    let job = LaunchAgentControl.parseJobState(output)
    #expect(job == .init(state: "running", lastExitCode: "0", runs: 3, pid: 4242))
    let idle = LaunchAgentControl.parseJobState("\tstate = not running\n\tlast exit code = 0\n")
    #expect(idle.state == "not running")
    #expect(idle.pid == nil)
  }

  @Test func restartStopsACoordinatorLaunchdDoesNotOwn() {
    let cliStarted = record(pid: 100)
    let notRunning = LaunchAgentControl.JobState(state: "not running", lastExitCode: "0")
    let running = LaunchAgentControl.JobState(state: "running", pid: 100)
    let other = LaunchAgentControl.JobState(state: "running", pid: 200)
    // The 2026-11-01 case: the CLI's coordinator holds the lock and launchd's job is idle.
    #expect(LaunchAgentControl.mustStopBeforeKickstart(running: cliStarted, job: notRunning))
    #expect(LaunchAgentControl.mustStopBeforeKickstart(running: cliStarted, job: other))
    #expect(!LaunchAgentControl.mustStopBeforeKickstart(running: cliStarted, job: running))
    #expect(!LaunchAgentControl.mustStopBeforeKickstart(running: nil, job: notRunning))
  }

  @Test func confirmReplacedFailsOnlyWhenTheSamePidSurvives() throws {
    let old = record(pid: 100)
    let new = record(pid: 101)
    #expect(throws: WorkspaceError.self) {
      try CoordinatorLauncher.confirmReplaced(previous: old, current: old)
    }
    try CoordinatorLauncher.confirmReplaced(previous: old, current: new)
    try CoordinatorLauncher.confirmReplaced(previous: nil, current: new)
    try CoordinatorLauncher.confirmReplaced(previous: old, current: nil)
  }

  @Test func waitForReplacementGivesUpWhenNothingTakesTheLock() async throws {
    let paths = PlatformPaths(
      runtimeDir: NSTemporaryDirectory() + "b4none-\(UUID().uuidString.prefix(6))", dataDir: "/tmp")
    let old = record(pid: 100)
    #expect(
      try await CoordinatorLauncher.waitForReplacement(of: old, paths: paths, timeout: .milliseconds(300))
        == nil)
  }
}
