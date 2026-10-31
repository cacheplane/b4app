import ArgumentParser
import Coordinator
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// Stable exit codes (spec section 11). Machine output always carries the error code too.
enum Exit {
  static let ok: Int32 = 0
  static let failure: Int32 = 1
  static let unavailable: Int32 = 2
  static let notImplemented: Int32 = 3
  static let invalid: Int32 = 4

  static func code(for error: WorkspaceError) -> Int32 {
    switch error.code {
    case .notImplemented: return notImplemented
    case .endpointUnavailable, .missingExecutable: return unavailable
    case .protocolInvalid, .methodUnknown: return invalid
    default: return failure
    }
  }
}

struct GlobalOptions: ParsableArguments {
  @Flag(name: .long, help: "Machine-readable output.")
  var json = false
}

enum Output {
  static func fail(_ error: any Error, json: Bool) -> Never {
    let failure = WorkspaceError.from(error)
    if json {
      print(Format.jsonError(failure))
    } else {
      FileHandle.standardError.write(Data("error [\(failure.code.rawValue)]: \(failure.message)\n".utf8))
    }
    Foundation.exit(Exit.code(for: failure))
  }

  static func notImplemented(_ command: String, milestone: String, json: Bool) -> Never {
    fail(
      WorkspaceError(
        .notImplemented, "`agent-workspace \(command)` is planned for \(milestone) and is not available yet.",
        details: ["command": .string(command), "milestone": .string(milestone)]),
      json: json)
  }
}

@main
struct AgentWorkspace: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent-workspace",
    abstract: "Manage the Personal Agent Workspace coordinator, local B4 servers, and connections.",
    version: CoordinatorVersion.current,
    subcommands: [
      Doctor.self, ConnectionCommand.self, ThreadCommand.self, TurnCommand.self, RequestCommand.self,
      Server.self, Credential.self,
    ])
}

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check the coordinator, runtimes, and authentication state.")

  @OptionGroup var global: GlobalOptions

  func run() async throws {
    do {
      let link = try await CoordinatorLauncher.ensure()
      let report = try await link.client.request(
        DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
      await link.client.close()
      print(global.json ? try Format.jsonOk(report) : Format.doctor(report))
      Foundation.exit(Exit.ok)
    } catch {
      Output.fail(error, json: global.json)
    }
  }
}

struct Server: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Manage owned local B4 servers (M4).",
    subcommands: [Add.self, List.self, Start.self, Status.self, Logs.self, Restart.self, Stop.self])

  struct Add: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var projectDir: String
    @Option var name: String?
    func run() async throws { Output.notImplemented("server add", milestone: "M4", json: global.json) }
  }
  struct List: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    func run() async throws { Output.notImplemented("server list", milestone: "M4", json: global.json) }
  }
  struct Start: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws { Output.notImplemented("server start", milestone: "M4", json: global.json) }
  }
  struct Status: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws { Output.notImplemented("server status", milestone: "M4", json: global.json) }
  }
  struct Logs: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    @Flag var follow = false
    func run() async throws { Output.notImplemented("server logs", milestone: "M4", json: global.json) }
  }
  struct Restart: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws { Output.notImplemented("server restart", milestone: "M4", json: global.json) }
  }
  struct Stop: AsyncParsableCommand {
    @OptionGroup var global: GlobalOptions
    @Argument var name: String
    func run() async throws { Output.notImplemented("server stop", milestone: "M4", json: global.json) }
  }
}

struct ConnectionCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "connection", abstract: "Manage connections.",
    subcommands: [AddHarness.self, List.self, Inspect.self, Login.self])
}

struct Credential: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Store endpoint secrets in the coordinator's credential store.", subcommands: [Add.self])

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Read a secret with a hidden prompt, store it, and print its reference for `connection add --auth-ref`."
    )
    @OptionGroup var global: GlobalOptions
    @Argument(help: "A label for the credential, for example research-endpoint.") var label: String

    func run() async throws {
      do {
        let value = try HiddenPrompt.read("Secret for \(label): ")
        let client = try await Link.open()
        let result = try await client.request(
          CredentialAdd.self, CredentialAdd.Params(label: label, value: value), options: Link.mutation())
        await client.close()
        if global.json {
          print(try Format.jsonOk(result))
        } else {
          print("Stored \"\(result.label)\" as \(result.reference)")
          print(
            "Use it with: agent-workspace connection add --kind b4 --url <url> --route <route> --auth-ref \(result.reference)"
          )
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}

/// Reads a secret without echo. On a terminal it uses `readpassphrase`; when stdin is a pipe it reads
/// one line, so scripts can pass the value without putting it in an argument or the environment.
enum HiddenPrompt {
  static func read(_ prompt: String) throws -> String {
    let value: String
    if isatty(STDIN_FILENO) == 1 {
      var buffer = [CChar](repeating: 0, count: 4096)
      guard let entered = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
        throw WorkspaceError(.protocolInvalid, "Could not read the secret from the terminal.")
      }
      value = String(cString: entered)
      buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    } else {
      guard let line = readLine(strippingNewline: true) else {
        throw WorkspaceError(.protocolInvalid, "No secret was provided on stdin.")
      }
      value = line
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WorkspaceError(.protocolInvalid, "The secret is empty; nothing stored.")
    }
    return trimmed
  }
}
