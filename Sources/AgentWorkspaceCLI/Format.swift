import Foundation
import WorkspaceProtocol

enum Format {
  static func doctor(_ report: DiagnosticsReport) -> String {
    var lines: [String] = []
    lines.append("Coordinator")
    lines.append("  version     \(report.coordinator.version) (pid \(report.coordinator.pid))")
    lines.append("  started     \(report.coordinator.startedAt)")
    lines.append("  socket      \(report.coordinator.socketPath)")
    lines.append("  database    \(report.coordinator.databasePath)")
    lines.append("  host        \(report.host.platform) \(report.host.arch) (\(report.host.release))")
    lines.append("")
    lines.append("Runtimes")
    for runtime in report.runtimes {
      let version = runtime.version ?? "-"
      let location = runtime.executablePath ?? "(not found)"
      lines.append(
        "  \(pad(runtime.kind.rawValue, 8)) \(pad(runtime.status.rawValue, 13)) auth=\(pad(runtime.authStatus.rawValue, 14)) \(pad(version, 10)) \(location)"
      )
      if let message = runtime.message { lines.append("           \(message)") }
    }
    if !report.recentErrors.isEmpty {
      lines.append("")
      lines.append("Recent errors")
      for error in report.recentErrors {
        lines.append("  \(error.at) \(error.scope) \(error.code): \(error.message)")
      }
    }
    return lines.joined(separator: "\n")
  }

  static func connection(_ result: ConnectionAdd.Result) -> String {
    var lines = [
      "\(result.connection.label) [\(result.connection.kind.rawValue)] \(result.connection.id)",
      "  status   \(result.connection.status.rawValue)  auth=\(result.connection.authStatus.rawValue)",
      "  target   \(result.connection.target.isEmpty ? "(not found)" : result.connection.target)",
    ]
    if let route = result.connection.routeKey {
      lines.append("  route    \(route)  (\(result.connection.b4Mode?.rawValue ?? "b4"))")
    }
    if let reference = result.connection.authReference { lines.append("  auth     \(reference)") }
    if let version = result.inspection.version { lines.append("  version  \(version)") }
    if let message = result.inspection.message { lines.append("  \(message)") }
    return lines.joined(separator: "\n")
  }

  static func connections(_ connections: [Connection]) -> String {
    if connections.isEmpty {
      return "No connections. Add one with `agent-workspace connection add --kind codex`."
    }
    return connections.map {
      "\(pad($0.label, 16)) \(pad($0.kind.rawValue, 7)) \(pad($0.status.rawValue, 13)) auth=\(pad($0.authStatus.rawValue, 14)) \($0.id)"
    }.joined(separator: "\n")
  }

  static func thread(_ thread: ConversationThread, connection: Connection?) -> String {
    let isRoute =
      connection?.kind == .b4
      || (thread.context?.hasPrefix("/") == true && thread.context?.contains("#") == true)
    return
      "\(thread.id)  \(thread.title)\n  connection \(connection?.label ?? thread.connectionId)  native \(thread.nativeThreadId)  \(isRoute ? "route" : "cwd") \(thread.context ?? "-")"
  }

  static func threads(_ threads: [ConversationThread], connections: [Connection]) -> String {
    if threads.isEmpty {
      return "No threads. Start one with `agent-workspace thread new --connection codex`."
    }
    return threads.map { thread in
      let label = connections.first { $0.id == thread.connectionId }?.label ?? thread.connectionId
      return "\(thread.id)  \(pad(thread.pinned ? "*" : " ", 1)) \(pad(label, 12)) \(thread.title)"
    }.joined(separator: "\n")
  }

  static func transcript(_ result: ThreadRead.Result) -> String {
    var lines = [thread(result.thread, connection: nil)]
    for item in result.items {
      switch item.role {
      case .user: lines.append("\n> \(item.payload["text"]?.stringValue ?? "")")
      case .assistant:
        if item.type == "agentMessage" {
          lines.append("\n\(item.payload["text"]?.stringValue ?? "")")
        } else {
          lines.append("\n[\(item.type)]")
        }
      case .tool:
        var line = "\n[\(item.type) \(item.payload["status"]?.stringValue ?? "")]"
        if let command = item.payload["command"]?.stringValue { line += " \(command)" }
        lines.append(line)
      case .system: lines.append("\n[\(item.type)]")
      }
    }
    for turn in result.turns where turn.status != .terminal {
      lines.append("\n[turn \(turn.id) is \(turn.status.rawValue); submission \(turn.submission.rawValue)]")
    }
    for request in result.requests { lines.append("\n" + runtimeRequest(request)) }
    return lines.joined(separator: "\n")
  }

  static func runtimeRequest(_ request: RuntimeRequest) -> String {
    let details = request.payload["request"]
    var lines = ["[runtime request \(request.kind.rawValue)] id \(request.id)"]
    if let command = details?["command"]?.stringValue { lines.append("  command: \(command)") }
    if let cwd = details?["cwd"]?.stringValue { lines.append("  cwd: \(cwd)") }
    if let reason = details?["reason"]?.stringValue { lines.append("  reason: \(reason)") }
    for question in details?["questions"]?.arrayValue ?? [] {
      lines.append("  \(question["id"]?.stringValue ?? "?"): \(question["question"]?.stringValue ?? "")")
      let options = question["options"]?.arrayValue?.compactMap { $0["label"]?.stringValue } ?? []
      if !options.isEmpty { lines.append("    options: \(options.joined(separator: ", "))") }
    }
    if request.kind == .userQuestion {
      lines.append("  answer: agent-workspace request respond \(request.id) --answer <id>=<value>")
    } else if request.payload["answerable"]?.boolValue == true {
      lines.append(
        "  answer: agent-workspace request respond \(request.id) --accept | --accept-session | --decline")
    } else {
      lines.append("  (not answerable here; declined automatically)")
    }
    return lines.joined(separator: "\n")
  }

  static func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
  }

  static func jsonOk<T: Encodable>(_ result: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let envelope = JSONValue.object(["ok": true, "result": try JSONValue(encoding: result)])
    return String(decoding: try encoder.encode(envelope), as: UTF8.self)
  }

  static func jsonError(_ error: WorkspaceError) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let envelope = JSONValue.object(["ok": false, "error": (try? JSONValue(encoding: error)) ?? .null])
    return String(decoding: (try? encoder.encode(envelope)) ?? Data("{}".utf8), as: UTF8.self)
  }
}
