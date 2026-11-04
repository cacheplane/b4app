import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

/// D-133 against the real `launchctl`: the boot-out adoption runs when `launchctl print` cannot tell
/// whether the old job is loaded. A throwaway job (`/bin/sleep`, a label of its own, never the
/// legacy label) is bootstrapped into this user's GUI domain and always booted out again; the
/// legacy plist the identity rule reads lives in a temporary home. Enabled only with
/// `B4APP_LIVE_LAUNCHCTL=1`; never run in CI.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_LIVE_LAUNCHCTL"] == "1"))
struct LegacyAdoptionLiveTests {
  /// A job of its own under `label`, and the legacy plist in a temporary home naming the same program.
  private struct Job {
    let home: URL
    let label: String
    let jobPlist: URL
    var domainTarget: String { "gui/\(getuid())/\(label)" }

    init() throws {
      label = "com.cacheplane.b4app.test.legacy-bootout.\(UUID().uuidString.prefix(8).lowercased())"
      home = FileManager.default.temporaryDirectory.appendingPathComponent("b4app-launchctl-\(UUID())")
      let agents = home.appendingPathComponent("Library/LaunchAgents")
      try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
      let program = ["/bin/sleep", "600"]
      // What the identity rule reads: the legacy label's plist, naming a program that is not ours.
      let legacy: [String: Any] = ["Label": LegacyAdoption.legacyLabel, "ProgramArguments": program]
      try (legacy as NSDictionary).write(to: LegacyAdoption.legacyPlist(home: home))
      jobPlist = home.appendingPathComponent("\(label).plist")
      let job: [String: Any] = ["Label": label, "ProgramArguments": program, "RunAtLoad": true]
      try (job as NSDictionary).write(to: jobPlist)
    }

    func bootstrap() async throws {
      let result = try await CommandRunner.run(
        "/bin/launchctl", ["bootstrap", "gui/\(getuid())", jobPlist.path],
        options: CommandOptions(timeout: .seconds(15)))
      try #require(result.exitCode == 0, "launchctl bootstrap failed: \(result.stderr)")
    }

    func isLoaded() async throws -> Bool {
      let result = try await CommandRunner.run(
        "/bin/launchctl", ["print", domainTarget], options: CommandOptions(timeout: .seconds(15)))
      return result.exitCode == 0
    }

    func remove() async {
      _ = try? await CommandRunner.run(
        "/bin/launchctl", ["bootout", domainTarget], options: CommandOptions(timeout: .seconds(15)))
      try? FileManager.default.removeItem(at: home)
    }
  }

  private static let ownProgram = "/Applications/Agent Workspace (Local).app/Contents/MacOS/b4app-coordinator"

  /// The real `launchctl`, except that `print` times out, as it did at the sign-in gate.
  private static let printTimesOut: LegacyAdoption.Launchctl = { arguments, timeout in
    if arguments.first == "print" { return CommandResult(exitCode: nil, timedOut: true) }
    return await LegacyAdoption.systemLaunchctl(arguments, timeout)
  }

  @Test func aLoadedJobIsBootedOut() async throws {
    let job = try Job()
    defer { Task { await job.remove() } }
    try await job.bootstrap()
    #expect(try await job.isLoaded())
    let bootedOut = try await LegacyAdoption.bootOutLegacyJob(
      home: job.home, ownProgram: Self.ownProgram, domainTarget: job.domainTarget,
      launchctl: LegacyAdoption.systemLaunchctl)
    #expect(bootedOut)
    #expect(try await !job.isLoaded())
  }

  /// The gate's case: `print` times out, so the job's state is unknown; it is booted out by the
  /// plist's program anyway, and is gone afterwards.
  @Test func aJobWhosePrintTimesOutIsStillBootedOut() async throws {
    let job = try Job()
    defer { Task { await job.remove() } }
    try await job.bootstrap()
    let bootedOut = try await LegacyAdoption.bootOutLegacyJob(
      home: job.home, ownProgram: Self.ownProgram, domainTarget: job.domainTarget,
      launchctl: Self.printTimesOut)
    #expect(bootedOut)
    #expect(try await !job.isLoaded())
  }

  /// Unknown and not loaded at all: the real `bootout` answers "No such process", which is read as
  /// nothing to do, not a failure that stops adoption.
  @Test func anUnknownJobThatIsNotLoadedIsNotAFailure() async throws {
    let job = try Job()
    defer { Task { await job.remove() } }
    #expect(try await !job.isLoaded())
    let bootedOut = try await LegacyAdoption.bootOutLegacyJob(
      home: job.home, ownProgram: Self.ownProgram, domainTarget: job.domainTarget,
      launchctl: Self.printTimesOut)
    #expect(!bootedOut)
  }
}
