import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

/// launchd as seen on 2026-11-09: `bootout` returns while the old coordinator is still stopping (it
/// shuts its PostgreSQL down in order), the job stays listed until it has, and a `bootstrap` sent
/// meanwhile fails with 5 ("Input/output error"), leaving the agent unloaded.
private actor FakeLaunchd {
  /// How many more `print`s list the job after `bootout`.
  private var listedAfterBootout: Int
  private var loaded = true
  private var bootedOut = false
  private(set) var calls: [String] = []

  init(listedAfterBootout: Int) { self.listedAfterBootout = listedAfterBootout }

  func run(_ arguments: [String]) -> CommandResult {
    let verb = arguments.first ?? ""
    calls.append(verb)
    switch verb {
    case "print":
      if bootedOut {
        if listedAfterBootout > 0 {
          listedAfterBootout -= 1
        } else {
          loaded = false
        }
      }
      return result(loaded ? 0 : 113)
    case "bootout":
      bootedOut = true
      return result(0)
    case "bootstrap":
      if loaded { return result(5, stderr: "Bootstrap failed: 5: Input/output error") }
      loaded = true
      bootedOut = false
      return result(0)
    default:
      return result(1)
    }
  }

  private func result(_ code: Int32, stderr: String = "") -> CommandResult {
    CommandResult(stdout: "", stderr: stderr, exitCode: code, signal: nil, timedOut: false)
  }
}

@Suite struct LaunchAgentInstallTests {
  private func home() throws -> String {
    let path = NSTemporaryDirectory() + "agent-install-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  /// Repointing a loaded agent waits for launchd to drop the old job before loading the new plist.
  @Test func installWaitsForTheOldJobToLeaveBeforeBootstrap() async throws {
    let home = try home()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let launchd = FakeLaunchd(listedAfterBootout: 3)

    let loaded = try await LaunchAgentControl.install(
      programPath: "/Applications/New.app/b4app-coordinator", home: home,
      // This fake advances on calls, not elapsed time. The production deadline is wall-clock, and four
      // actor hops outlasted its 30 s on a CI runner whose cooperative pool was busy with parallel
      // suites (45 s, run 42766454581), so neither a sleep nor the deadline may decide this test.
      launchctl: { arguments, _ in await launchd.run(arguments) }, leaveTimeout: .seconds(3600),
      poll: .zero)

    #expect(loaded)
    #expect(await launchd.calls == ["print", "bootout", "print", "print", "print", "print", "bootstrap"])
    #expect(LaunchAgentControl.installedProgramPath(home: home) == "/Applications/New.app/b4app-coordinator")
  }

  /// A job that never leaves in time: the bootstrap is still tried, and its refusal is reported.
  @Test func aJobThatNeverLeavesReportsTheRefusal() async throws {
    let home = try home()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let launchd = FakeLaunchd(listedAfterBootout: .max)

    let error = await #expect(throws: WorkspaceError.self) {
      try await LaunchAgentControl.install(
        programPath: "/Applications/New.app/b4app-coordinator", home: home,
        launchctl: { arguments, _ in await launchd.run(arguments) }, leaveTimeout: .milliseconds(30),
        poll: .milliseconds(1))
    }
    #expect(error?.code == .endpointUnavailable)
    #expect(error?.message.contains("Input/output error") == true)
    #expect(await launchd.calls.last == "bootstrap")
  }
}
