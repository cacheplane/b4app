import Foundation
import Synchronization
import WorkspacePlatform

/// Opt-in numeric observations of the private test cluster. Never changes its server settings.
enum EphemeralDiagnostics {
  static let enabled = ProcessInfo.processInfo.environment["B4APP_CI_DIAGNOSTICS"] == "1"

  private struct Measurement: Sendable {
    var count = 0
    var failed = 0
    var seconds = 0.0
    var maxSeconds = 0.0
  }

  private static let measurements = Mutex<[String: Measurement]>([:])

  @discardableResult
  static func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
    guard enabled else { return try body() }
    let started = ProcessInfo.processInfo.systemUptime
    var succeeded = false
    defer {
      let seconds = ProcessInfo.processInfo.systemUptime - started
      measurements.withLock {
        var value = $0[phase, default: Measurement()]
        value.count += 1
        value.failed += succeeded ? 0 : 1
        value.seconds += seconds
        value.maxSeconds = max(value.maxSeconds, seconds)
        $0[phase] = value
      }
      if phase != "createDatabase" {
        emit("CI_POSTGRES_PHASE", ["phase": phase, "seconds": seconds, "succeeded": succeeded])
      }
    }
    let value = try body()
    succeeded = true
    return value
  }

  private static func emit(_ marker: String, _ values: [String: Any]) {
    var values = values
    values["test_pid"] = ProcessInfo.processInfo.processIdentifier
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return }
    FileHandle.standardError.write(Data((marker + " " + json + "\n").utf8))
  }

  /// No database connection or SQL is issued during exit diagnostics.
  static func snapshot(_ cluster: PostgresCluster) {
    guard enabled else { return }
    let phases = measurements.withLock {
      $0.mapValues {
        [
          "count": Double($0.count), "failed": Double($0.failed), "sum_seconds": $0.seconds,
          "max_seconds": $0.maxSeconds,
        ]
      }
    }
    emit(
      "CI_POSTGRES_SUMMARY",
      [
        "phases": phases, "settings_origin": "server command options",
        "configured_shared_buffers": cluster.serverOptions.first { $0.hasPrefix("shared_buffers=") }
          ?? "unknown",
      ])
  }

  /// Read at most 16 KiB after the server stops, emitting only numeric checkpoint fields.
  static func checkpointLog(_ cluster: PostgresCluster) {
    guard enabled else { return }
    let started = ProcessInfo.processInfo.systemUptime
    var observation: [String: Any] = [:]
    do {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: cluster.logPath))
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      try handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
      let data = try handle.read(upToCount: 16_384) ?? Data()
      let text = String(decoding: data, as: UTF8.self)
      let expression = try NSRegularExpression(
        pattern:
          #"LOG:  checkpoint complete: wrote (\d+) buffers.*write=([\d.]+) s, sync=([\d.]+) s, total=([\d.]+) s; sync files=(\d+)"#
      )
      let records = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        match -> [String: Double] in
        let names = ["buffers", "write_seconds", "sync_seconds", "total_seconds", "sync_files"]
        var fields: [String: Double] = [:]
        for (index, name) in names.enumerated() {
          if let range = Range(match.range(at: index + 1), in: text), let value = Double(text[range]) {
            fields[name] = value
          }
        }
        return fields
      }
      observation = [
        "status": "read", "tail_bytes": data.count, "truncated": end > 16_384,
        "completed_checkpoints": records,
      ]
    } catch {
      observation["status"] = "unavailable"
    }
    observation["collection_seconds"] = ProcessInfo.processInfo.systemUptime - started
    emit("CI_POSTGRES_CHECKPOINTS", observation)
  }
}
