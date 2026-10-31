import ArgumentParser
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// `agent-workspace server …` (spec section 11): registration, lifecycle, status, and logs of owned
/// local B4 servers. Every command talks to the shared coordinator, so the GUI sees the same rows.
struct Server: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Register and run local B4 projects as owned servers.",
    subcommands: [
      Add.self, List.self, Start.self, Status.self, Logs.self, Restart.self, Stop.self, Inspect.self,
    ])

  /// Start, restart, add, and inspect wait for readiness or route discovery (design D-028 notes).
  static let longOperation: Duration = .seconds(150)

  static func resolve(_ client: WorkspaceClient, _ nameOrId: String) async throws -> LocalServer {
    let servers = try await client.request(ServerList.self, EmptyParams()).servers
    if let match = servers.first(where: { $0.id == nameOrId || $0.name == nameOrId }) { return match }
    throw WorkspaceError(
      .notFound,
      "No managed server named \"\(nameOrId)\". Known: \(servers.map(\.name).joined(separator: ", "))",
      details: ["server": .string(nameOrId)])
  }

  static func exitCode(for server: LocalServer) -> Int32 {
    server.health == .ready ? Exit.ok : Exit.unavailable
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Register a local B4 project. Inspecting it runs its b4.config and route modules with Node.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The project directory (the B4 app root with b4.config.ts and package.json).")
    var projectDir: String
    @Option(help: "Handle for the other server commands (default: the directory name).") var name: String?
    @Option(help: "development (b4 dev, hot reload) or source (b4 start, the default).") var mode:
      LocalServerLaunchMode?
    @Option(
      name: .customLong("env-file"), help: "Env file for the server (default: <project>/.env when present).")
    var envFile: String?
    @Option(help: "Loopback port; allocated once when omitted and kept for route connections.") var port: Int?

    func run() async throws {
      do {
        let client = try await Link.open()
        if !global.json {
          print(
            "Inspecting \(projectDir) runs its b4.config and route modules with Node; register only projects you trust."
          )
          fflush(stdout)
        }
        let result = try await client.request(
          ServerAdd.self,
          ServerAdd.Params(
            projectPath: projectDir, name: name, launchMode: mode, envFilePath: envFile, port: port),
          options: Link.mutation(timeout: Server.longOperation))
        let connections = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : Format.server(result.server, connections: connections.connections))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List registered servers.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(ServerList.self, EmptyParams())
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.servers(result.servers))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Start an owned server and wait until /healthz is ready. Idempotent.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Server.resolve(client, name)
        let result = try await client.request(
          ServerStart.self, ServerRef(serverId: target.id),
          options: Link.mutation(timeout: Server.longOperation))
        let connections = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : Format.server(result.server, connections: connections.connections))
        Foundation.exit(Server.exitCode(for: result.server))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show a server's health, pid, port, and routes.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Server.resolve(client, name)
        let result = try await client.request(ServerStatus.self, ServerRef(serverId: target.id))
        let connections = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : Format.server(result.server, connections: connections.connections))
        Foundation.exit(Server.exitCode(for: result.server))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Re-run route discovery (b4 routes --json) for a registered project.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Server.resolve(client, name)
        let result = try await client.request(
          ServerInspect.self, ServerRef(serverId: target.id),
          options: Link.mutation(timeout: Server.longOperation))
        let connections = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : Format.server(result.server, connections: connections.connections))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the redacted tail of a server's log.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Option(help: "Lines to print (default 200).") var lines: Int?
    @Flag(help: "Keep printing new lines until interrupted.") var follow = false
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Server.resolve(client, name)
        var result = try await client.request(
          ServerLogs.self, ServerLogs.Params(serverId: target.id, lines: lines))
        if global.json, !follow {
          print(try Format.jsonOk(result))
          await client.close()
          return
        }
        for line in result.lines { print(line) }
        fflush(stdout)
        while follow {
          try await Task.sleep(for: .milliseconds(500))
          result = try await client.request(
            ServerLogs.self, ServerLogs.Params(serverId: target.id, afterOffset: result.offset))
          for line in result.lines { print(line) }
          fflush(stdout)
        }
        await client.close()
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop an owned server (SIGTERM to its process group, SIGKILL after 10 s).")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Flag(help: "Stop even while a route connection has a running turn (the turn is lost).") var force = false
    func run() async throws {
      await Server.lifecycle(ServerStop.self, name: name, force: force, json: global.json)
    }
  }

  struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop, then start and wait for readiness.")
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Flag(help: "Restart even while a route connection has a running turn (the turn is lost).") var force =
      false
    func run() async throws {
      await Server.lifecycle(ServerRestart.self, name: name, force: force, json: global.json)
    }
  }

  static func lifecycle<C: WorkspaceCommand>(
    _ command: C.Type, name: String, force: Bool, json: Bool
  ) async -> Never where C.Params == ServerLifecycleParams, C.Result == ServerAdd.Result {
    do {
      let client = try await Link.open()
      let target = try await resolve(client, name)
      let result = try await client.request(
        command, ServerLifecycleParams(serverId: target.id, force: force ? true : nil),
        options: Link.mutation(timeout: longOperation))
      let connections = try await client.request(
        ConnectionList.self, ConnectionList.Params(includeDisabled: true))
      await client.close()
      print(
        json ? try Format.jsonOk(result) : Format.server(result.server, connections: connections.connections))
      if C.method == .serverRestart { Foundation.exit(exitCode(for: result.server)) }
      Foundation.exit(result.server.health == .stopped ? Exit.ok : Exit.unavailable)
    } catch {
      let failure = WorkspaceError.from(error)
      if !json, failure.details?["reason"]?.stringValue == "turn_active" {
        let threads = failure.details?["threadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        FileHandle.standardError.write(
          Data(
            "Running turns on threads: \(threads.joined(separator: ", ")). Pass --force to stop anyway.\n"
              .utf8))
      }
      Output.fail(error, json: json)
    }
  }
}

extension LocalServerLaunchMode: ExpressibleByArgument {}
