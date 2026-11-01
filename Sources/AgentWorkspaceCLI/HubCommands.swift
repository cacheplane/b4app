import ArgumentParser
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// `hub join | status | leave` (M8a). The enrollment code is read with a hidden prompt (or one line
/// of a piped stdin), never from an argument, and goes to the coordinator over the local socket.
struct HubCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hub", abstract: "Mirror this Mac's conversations to a hub, read-only (M8a).",
    subcommands: [Join.self, Status.self, Leave.self])

  static func describe(_ status: HubStatus.Result) -> String {
    guard status.joined else {
      return "not joined (\(status.unsyncedChanges) change(s) recorded locally)"
    }
    var lines = ["hub        \(status.url ?? "")"]
    lines.append("device     \(status.deviceName ?? "") (\(status.deviceId ?? ""))")
    lines.append("account    \(status.username ?? "")@\(status.orgSlug ?? "")")
    lines.append("unsynced   \(status.unsyncedChanges) change(s)")
    lines.append("last push  \(status.lastPushAt ?? "never")")
    if let error = status.lastError { lines.append("last error \(error)") }
    return lines.joined(separator: "\n")
  }

  struct Join: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Join a hub with a one-time enrollment code, then push this Mac's history.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "The hub URL (https, or http for localhost).") var url: String
    @Option(name: .long, help: "This device's name at the hub (default: the Mac's name).") var name: String?

    func run() async throws {
      do {
        let code = try HiddenPrompt.read("Enrollment code: ")
        let client = try await Link.open()
        let status = try await client.request(
          HubJoin.self, HubJoin.Params(url: url, code: code, deviceName: name),
          options: Link.mutation(timeout: .seconds(300)))
        await client.close()
        print(global.json ? try Format.jsonOk(status) : HubCommand.describe(status))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show the hub this Mac joined and how much is left to push.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(HubStatus.self, EmptyParams())
        await client.close()
        print(global.json ? try Format.jsonOk(status) : HubCommand.describe(status))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Leave: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Revoke this device at the hub and stop pushing; uploaded history stays on the hub.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(HubLeave.self, EmptyParams(), options: Link.mutation())
        await client.close()
        print(global.json ? try Format.jsonOk(status) : HubCommand.describe(status))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}
