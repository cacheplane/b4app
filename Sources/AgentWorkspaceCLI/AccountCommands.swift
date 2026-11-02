import ArgumentParser
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// `account status | logout` (sign-in plan, Task 10). Signing in happens in the app, which runs the
/// passkey or Apple ceremony; the CLI only reports and logs out.
struct AccountCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "account", abstract: "Show who this Mac is signed in as, or log out.",
    subcommands: [Status.self, Logout.self])

  static func describe(_ status: AccountStatus.Result) -> String {
    var lines: [String] = []
    switch status.state {
    case .signedOut:
      lines.append("signed out")
      if let reason = status.reason, reason.kind == .rejectedByHub {
        lines.append("This Mac was signed out of \(reason.orgName).")
      }
    case .needsOnboarding, .signedIn:
      let account = status.account
      lines.append(status.state == .signedIn ? "signed in" : "signed in, onboarding not finished")
      lines.append("org        \(account?.orgName ?? "")")
      if let name = account?.displayName, !name.isEmpty { lines.append("name       \(name)") }
      lines.append("hub        \(account?.hubURL ?? "")")
      lines.append("account    \(account?.id ?? "")")
    }
    if let notice = status.notice { lines.append(notice) }
    let others = status.known.filter { $0.id != status.account?.id }
    if !others.isEmpty {
      lines.append(
        "known      " + others.map { $0.orgName.isEmpty ? $0.id : $0.orgName }.joined(separator: ", "))
    }
    return lines.joined(separator: "\n")
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the account this Mac is signed in as.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(AccountStatus.self, EmptyParams())
        await client.close()
        print(global.json ? try Format.jsonOk(status) : AccountCommand.describe(status))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract:
        "Log out: push what is left, end the session at the hub, and forget the token. Refused while work is running unless --stop-work."
    )
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Interrupt running turns and stop this account's local servers first.")
    var stopWork = false

    func run() async throws {
      do {
        let client = try await Link.open()
        let status = try await client.request(
          AccountLogout.self, AccountLogout.Params(stopWork: stopWork),
          options: Link.mutation(timeout: .seconds(60)))
        await client.close()
        print(global.json ? try Format.jsonOk(status) : "Logged out.")
      } catch {
        let failure = WorkspaceError.from(error)
        if failure.code == .workRunning, !global.json,
          let work = try? failure.details?["work"]?.decode(WorkspaceActiveWork.Result.self)
        {
          FileHandle.standardError.write(Data((Logout.refusal(failure.message, work) + "\n").utf8))
          Foundation.exit(Exit.code(for: failure))
        }
        Output.fail(error, json: global.json)
      }
    }

    static func refusal(_ message: String, _ work: WorkspaceActiveWork.Result) -> String {
      var lines = ["error [work_running]: \(message)"]
      for turn in work.turns {
        lines.append("  turn    \(turn.threadTitle) (\(turn.connectionLabel), \(turn.status.rawValue))")
      }
      for server in work.servers {
        lines.append("  server  \(server.name) (\(server.health.rawValue))")
      }
      lines.append("Run `agent-workspace account logout --stop-work` to stop them and log out.")
      return lines.joined(separator: "\n")
    }
  }
}
