import ArgumentParser
import Coordinator
import Foundation
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

/// `coordinator status | stop | restart` (M6). The coordinator is one process per user: the app's
/// LaunchAgent, the app itself, or one this CLI started. Stop is always an orderly SIGTERM.
struct CoordinatorCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "coordinator", abstract: "Inspect, stop, or restart the coordinator process.",
    subcommands: [Status.self, Stop.self, Restart.self, Plist.self])

  struct Report: Codable {
    var running: Bool
    var pid: Int32?
    var startedAt: String?
    var socketPath: String
    var answering: Bool
    var version: String?
    var cliVersion: String
    var launchAgentLoaded: Bool
    var launchAgentState: String?
    var launchAgentLastExit: String?
    var executable: String?
  }

  static func report() async -> Report {
    let paths = PlatformPaths.resolve()
    let record = CoordinatorLauncher.runningRecord(paths: paths)
    var version: String?
    var answering = false
    if record != nil, let client = await CoordinatorLauncher.tryConnect(socketPath: paths.socketPath) {
      answering = true
      version = try? await client.request(
        DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(10))
      ).coordinator.version
      await client.close()
    }
    let job = await LaunchAgentControl.jobState()
    return Report(
      running: record != nil, pid: record?.pid, startedAt: record?.startedAt, socketPath: paths.socketPath,
      answering: answering, version: version, cliVersion: CoordinatorVersion.current,
      launchAgentLoaded: job != nil, launchAgentState: job?.state, launchAgentLastExit: job?.lastExitCode,
      executable: CoordinatorLauncher.executablePath())
  }

  static func describe(_ r: Report) -> String {
    var lines: [String] = []
    if let pid = r.pid {
      lines.append(
        "coordinator running (pid \(pid), since \(r.startedAt ?? "?"))\(r.answering ? "" : ", not answering") at \(r.socketPath)"
      )
      if let version = r.version {
        lines.append(
          "version \(version)"
            + (version == r.cliVersion ? "" : " (this CLI is \(r.cliVersion); run `coordinator restart`)"))
      }
    } else {
      lines.append("no coordinator running (socket \(r.socketPath))")
    }
    if r.launchAgentLoaded {
      var agent = "launch agent: loaded"
      if let state = r.launchAgentState { agent += ", \(state)" }
      if let exit = r.launchAgentLastExit { agent += ", last exit \(exit)" }
      if r.launchAgentState?.contains("spawn") == true {
        agent += " (launchd cannot start the bundled coordinator; relaunch the app to re-register the agent)"
      }
      lines.append(agent)
    } else {
      lines.append("launch agent: not loaded")
    }
    lines.append("executable: \(r.executable ?? "not found")")
    return lines.joined(separator: "\n")
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the running coordinator, its version, and how it is hosted.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
      let r = await CoordinatorCommand.report()
      print(global.json ? try Format.jsonOk(r) : CoordinatorCommand.describe(r))
      Foundation.exit(r.running && !r.answering ? Exit.unavailable : Exit.ok)
    }
  }

  struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Ask the coordinator to exit (SIGTERM) and wait. Owned servers keep running; local turns end."
    )
    @OptionGroup var global: GlobalOptions

    func run() async throws {
      do {
        let stopped = try await CoordinatorLauncher.stop()
        if global.json {
          print(try Format.jsonOk(["stopped": stopped.map { Int($0.pid) }]))
        } else {
          print(stopped.map { "stopped coordinator pid \($0.pid)" } ?? "no coordinator was running")
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Plist: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print the LaunchAgent property list the packaged app carries (used by Scripts/package.sh).")

    func run() throws {
      print(LaunchAgentControl.plist(), terminator: "")
    }
  }

  struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Restart the coordinator: through launchd when the app's agent hosts it, otherwise stop and start it here."
    )
    @OptionGroup var global: GlobalOptions

    func run() async throws {
      do {
        if await LaunchAgentControl.isLoaded() {
          try await LaunchAgentControl.kickstart()
        } else {
          _ = try await CoordinatorLauncher.stop()
        }
        let link = try await CoordinatorLauncher.ensure()
        await link.client.close()
        let r = await CoordinatorCommand.report()
        print(global.json ? try Format.jsonOk(r) : CoordinatorCommand.describe(r))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}
