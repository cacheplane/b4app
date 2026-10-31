import ArgumentParser
import Coordinator
import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// Shared plumbing for commands that talk to the coordinator.
enum Link {
  static func open() async throws -> WorkspaceClient {
    try await CoordinatorLauncher.ensure().client
  }

  static func mutation(timeout: Duration = .seconds(60)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: timeout)
  }

  /// Resolve a connection by id, label, or kind (`codex`), or the only connection when unambiguous.
  static func connection(_ client: WorkspaceClient, matching text: String?) async throws -> Connection {
    let all = try await client.request(ConnectionList.self, ConnectionList.Params()).connections
    if let text {
      if let exact = all.first(where: { $0.id == text || $0.label == text }) { return exact }
      let byKind = all.filter { $0.kind.rawValue == text }
      if byKind.count == 1 { return byKind[0] }
      throw WorkspaceError(
        .notFound,
        "No connection matches \"\(text)\". Known: \(all.map { "\($0.label) (\($0.id))" }.joined(separator: ", "))"
      )
    }
    if all.count == 1 { return all[0] }
    throw WorkspaceError(
      .protocolInvalid,
      all.isEmpty
        ? "No connections yet. Run `agent-workspace connection add --kind codex`."
        : "Several connections exist; pass --connection.")
  }
}

extension ConnectionCommand {
  struct AddHarness: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract:
        "Register an installed harness (codex, claude) or attach a B4 endpoint (b4 with --url and --route).")
    @OptionGroup var global: GlobalOptions
    @Option(help: "codex, claude, or b4.") var kind: ConnectionKind = .codex
    @Option var name: String?
    @Option(help: "Explicit executable path; otherwise PATH and common install directories are searched.")
    var path: String?
    @Option(help: "B4 endpoint base URL: https://…, or http://127.0.0.1:<port> for a local server.") var url:
      String?
    @Option(help: "B4 route key, for example /chat#agent.") var route: String?
    @Option(
      name: .customLong("auth-ref"),
      help: "Credential reference from `credential add` (secret:…), sent as a bearer."
    )
    var authRef: String?
    @Option(help: "A managed server (name or id) from `server add`; the route runs on that server.")
    var server: String?

    func run() async throws {
      do {
        if kind == .b4, server != nil, url != nil || authRef != nil {
          throw WorkspaceError(
            .protocolInvalid, "--server takes --route only; --url and --auth-ref do not apply.")
        }
        if kind == .b4, server == nil, url == nil || route == nil {
          throw WorkspaceError(
            .protocolInvalid,
            "A B4 connection needs --url and --route (for example /chat#agent), or --server and --route.")
        }
        if kind == .b4, server != nil, route == nil {
          throw WorkspaceError(
            .protocolInvalid, "A managed route connection needs --route (for example /chat#agent).")
        }
        if kind != .b4, url != nil || route != nil || authRef != nil || server != nil {
          throw WorkspaceError(
            .protocolInvalid, "--url, --route, --auth-ref, and --server apply to --kind b4 only.")
        }
        let client = try await Link.open()
        var serverId: String?
        if let server { serverId = try await Server.resolve(client, server).id }
        let result = try await client.request(
          ConnectionAdd.self,
          ConnectionAdd.Params(
            kind: kind, label: name, executablePath: path, url: url, route: route, authReference: authRef,
            serverId: serverId),
          options: Link.mutation())
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.connection(result))
        Foundation.exit(result.connection.status == .ready ? Exit.ok : Exit.unavailable)
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List connections.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.connections(result.connections))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Inspect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Re-check a connection's executable, version, and account.")
    @OptionGroup var global: GlobalOptions
    @Argument var connection: String?
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Link.connection(client, matching: connection)
        let result = try await client.request(
          ConnectionInspect.self, ConnectionInspect.Params(connectionId: target.id), options: Link.mutation())
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.connection(result))
        Foundation.exit(result.connection.status == .ready ? Exit.ok : Exit.unavailable)
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Start the runtime's official sign-in and print the URL to open.")
    @OptionGroup var global: GlobalOptions
    @Argument var connection: String?
    @Flag(help: "Open the sign-in URL in the default browser.") var open = false
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Link.connection(client, matching: connection)
        let result = try await client.request(
          ConnectionLogin.self, ConnectionLogin.Params(connectionId: target.id), options: Link.mutation())
        await client.close()
        if global.json {
          print(try Format.jsonOk(result))
        } else {
          print("Open this URL to sign in (login \(result.loginId)):\n\(result.authUrl)")
        }
        if open, let url = URL(string: result.authUrl) {
          let opener = Process()
          opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          opener.arguments = [url.absoluteString]
          try opener.run()
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}

struct ThreadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "thread", abstract: "Create, list, and read conversation threads.",
    subcommands: [New.self, List.self, Show.self])

  struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a new native thread on a connection.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Connection id, label, or kind.") var connection: String?
    @Option(help: "Working directory for the agent (default: current directory; ignored for B4 routes).")
    var cwd: String?
    @Option var title: String?
    func run() async throws {
      do {
        let client = try await Link.open()
        let target = try await Link.connection(client, matching: connection)
        let directory: String? = target.kind == .b4 ? nil : (cwd ?? FileManager.default.currentDirectoryPath)
        let result = try await client.request(
          ThreadCreate.self,
          ThreadCreate.Params(connectionId: target.id, workingDirectory: directory, title: title),
          options: Link.mutation())
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.thread(result.thread, connection: target))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List threads.")
    @OptionGroup var global: GlobalOptions
    @Option var connection: String?
    @Flag var archived = false
    func run() async throws {
      do {
        let client = try await Link.open()
        var connectionId: String?
        if let connection { connectionId = try await Link.connection(client, matching: connection).id }
        let result = try await client.request(
          ThreadList.self, ThreadList.Params(connectionId: connectionId, includeArchived: archived))
        let connections = try await client.request(
          ConnectionList.self, ConnectionList.Params(includeDisabled: true))
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : Format.threads(result.threads, connections: connections.connections)
        )
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a thread's cached transcript and state.")
    @OptionGroup var global: GlobalOptions
    @Argument var threadId: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          ThreadRead.self, ThreadRead.Params(threadId: threadId),
          options: RequestOptions(timeout: .seconds(60)))
        await client.close()
        print(global.json ? try Format.jsonOk(result) : Format.transcript(result))
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}

struct TurnCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "turn", abstract: "Send a message to a thread or stop its active turn.",
    subcommands: [Send.self, Interrupt.self])

  struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Send one user message and stream the reply until the turn finishes.")
    @OptionGroup var global: GlobalOptions
    @Argument var threadId: String
    @Argument(parsing: .captureForPassthrough, help: "Message text.") var text: [String]
    @Flag(name: .customLong("no-wait"), help: "Return as soon as the turn is acknowledged.") var noWait =
      false
    @Option(help: "Seconds to wait for the turn to finish (default 600).") var timeout: Int = 600

    func run() async throws {
      let message = text.joined(separator: " ")
      do {
        let client = try await Link.open()
        let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
        await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
        let events = await client.events()
        let operationId = UUID().uuidString.lowercased()
        let sent = try await client.request(
          TurnSend.self, TurnSend.Params(threadId: threadId, text: message),
          options: RequestOptions(operationId: operationId, timeout: .seconds(60)))
        if noWait {
          await client.close()
          print(global.json ? try Format.jsonOk(sent) : "turn \(sent.turn.id) \(sent.turn.status.rawValue)")
          Foundation.exit(Exit.ok)
        }
        let printer = EventPrinter(threadId: threadId, turnId: sent.turn.id, json: global.json)
        let outcome = try await printer.follow(events, timeout: .seconds(timeout))
        await client.close()
        if global.json {
          let final = try await Link.open()
          let read = try await final.request(ThreadRead.self, ThreadRead.Params(threadId: threadId))
          await final.close()
          print(
            try Format.jsonOk(
              [
                "turn": try JSONValue(encoding: read.turns.first { $0.id == sent.turn.id }),
                "requests": try JSONValue(encoding: read.requests),
              ] as [String: JSONValue]))
        }
        switch outcome {
        case .completed: Foundation.exit(Exit.ok)
        case .cancelled: Foundation.exit(130)
        case .failed: Foundation.exit(Exit.failure)
        case .none: Foundation.exit(Exit.unavailable)
        }
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }

  struct Interrupt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the active turn on a thread.")
    @OptionGroup var global: GlobalOptions
    @Argument var threadId: String
    func run() async throws {
      do {
        let client = try await Link.open()
        let result = try await client.request(
          TurnInterrupt.self, TurnInterrupt.Params(threadId: threadId), options: Link.mutation())
        await client.close()
        print(
          global.json ? try Format.jsonOk(result) : "turn \(result.turn.id) \(result.turn.status.rawValue)")
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}

struct RequestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "request", abstract: "Answer runtime requests (approvals and questions).",
    subcommands: [Respond.self])

  struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Answer one pending runtime request.")
    @OptionGroup var global: GlobalOptions
    @Argument var requestId: String
    @Flag(help: "Allow once.") var accept = false
    @Flag(name: .customLong("accept-session"), help: "Allow for the rest of the session.") var acceptSession =
      false
    @Flag(help: "Decline.") var decline = false
    @Option(name: .customLong("answer"), parsing: .upToNextOption, help: "questionId=value (repeatable).")
    var answers: [String] = []

    func run() async throws {
      do {
        var params = RequestRespond.Params(requestId: requestId)
        if accept { params.decision = .allowOnce }
        if acceptSession { params.decision = .allowAlways }
        if decline { params.decline = true }
        if !answers.isEmpty {
          var map: [String: [String]] = [:]
          for pair in answers {
            guard let equals = pair.firstIndex(of: "=") else {
              throw WorkspaceError(.protocolInvalid, "--answer expects questionId=value, got \"\(pair)\".")
            }
            map[String(pair[..<equals]), default: []].append(String(pair[pair.index(after: equals)...]))
          }
          params.answers = map
        }
        if params.decision == nil, params.answers == nil, params.decline != true {
          throw WorkspaceError(.protocolInvalid, "Pass --accept, --accept-session, --decline, or --answer.")
        }
        let client = try await Link.open()
        let result = try await client.request(RequestRespond.self, params, options: Link.mutation())
        await client.close()
        print(
          global.json
            ? try Format.jsonOk(result) : "request \(result.request.id) \(result.request.state.rawValue)")
      } catch {
        Output.fail(error, json: global.json)
      }
    }
  }
}

extension ConnectionKind: ExpressibleByArgument {}

/// Streams one turn's events to the terminal: assistant text as it arrives, tool cards, and pending
/// runtime requests with the command that answers them.
struct EventPrinter {
  let threadId: String
  let turnId: String
  let json: Bool

  func follow(_ events: AsyncStream<EventEnvelope>, timeout: Duration) async throws -> TurnOutcome? {
    let deadline = ContinuousClock.now + timeout
    var streaming = false
    for await envelope in events {
      if ContinuousClock.now > deadline { break }
      let event = envelope.event
      guard event.threadId == threadId else { continue }
      if json {
        if event.kind != .messageDelta {
          print(String(decoding: try JSONCoding.encoder.encode(event), as: UTF8.self))
        }
      } else {
        switch event.kind {
        case .messageDelta:
          if let delta = event.payload["delta"]?.stringValue {
            print(delta, terminator: "")
            fflush(stdout)
            streaming = true
          }
        case .messageCompleted:
          if streaming {
            print()
            streaming = false
          } else if event.payload["role"]?.stringValue == "assistant",
            let text = event.payload["item"]?["text"]?.stringValue
          {
            print(text)
          }
        case .toolStarted:
          print("[\(event.payload["type"]?.stringValue ?? "tool") started]")
        case .toolCompleted:
          let item = event.payload["item"]
          let status = item?["status"]?.stringValue ?? "done"
          var line = "[\(event.payload["type"]?.stringValue ?? "tool") \(status)]"
          if let command = item?["command"]?.stringValue { line += " \(command)" }
          print(line)
          if let output = item?["aggregatedOutput"]?.stringValue, !output.isEmpty {
            print(output.split(separator: "\n").prefix(20).map { "  | \($0)" }.joined(separator: "\n"))
          }
        case .runtimeRequestOpened:
          if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self) {
            print(Format.runtimeRequest(request))
          }
        case .runtimeRequestExpired:
          print("[request expired: the runtime exited]")
        case .adapterError:
          print("[error] \(event.payload["message"]?.stringValue ?? "")")
        case .turnStateChanged where event.turnId == turnId:
          if let status = event.payload["status"]?.stringValue, status == "reconciling" {
            print("[turn outcome unknown: the runtime exited; reopen the thread to reconcile]")
          }
        default:
          break
        }
      }
      if event.kind == .turnFinished, event.turnId == turnId {
        let outcome = event.payload["outcome"]?.stringValue.flatMap(TurnOutcome.init(rawValue:))
        if !json {
          if streaming { print() }
          var line = "[turn \(outcome?.rawValue ?? "unresolved")]"
          if let message = event.payload["error"]?["message"]?.stringValue { line += " \(message)" }
          print(line)
        }
        return outcome
      }
      if event.kind == .turnStateChanged, event.turnId == turnId,
        event.payload["status"]?.stringValue == "reconciling"
      {
        return nil
      }
    }
    return nil
  }
}
