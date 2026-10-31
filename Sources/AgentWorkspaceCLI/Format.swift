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
