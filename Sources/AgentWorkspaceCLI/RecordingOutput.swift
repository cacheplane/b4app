import Darwin
import Foundation
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

enum RecordingOutputFailure: String, Error {
  case unsafeStream, invalidPath, alreadyExists, writeFailed, limitExceeded
}

/// Private intermediate format. Publication requires separate normalization and review.
struct RecordingFile: Codable {
  var format = "b4app-docs-private-v1"
  var complete = true
  var appVersion: String
  var recordedAt = Timestamp.now()
  var epochAlias = "epoch-1"
  var events: [RecordedEvent]
}

enum RecordingOutput {
  static func sanitized(_ events: [RecordedEvent], home: String = NSHomeDirectory()) throws -> [RecordedEvent]
  {
    var streamed: [String: String] = [:]
    var result: [RecordedEvent] = []
    for var event in events {
      if event.kind == .messageStarted || event.kind == .toolStarted,
        let native = event.fields["nativeItemId"]?.stringValue,
        let text = event.fields["text"]?.stringValue
      {
        let key = "\(event.turnId ?? ""):\(native)"
        guard cleanText(text, home: home) == text else { throw RecordingOutputFailure.unsafeStream }
        streamed[key] = text
      }
      if event.kind == .messageDelta,
        let native = event.fields["nativeItemId"]?.stringValue,
        let delta = event.fields["delta"]?.stringValue
      {
        let key = "\(event.turnId ?? ""):\(native)"
        streamed[key, default: ""] += delta
        let assembled = streamed[key] ?? ""
        // A mask spanning deltas would manufacture chunk boundaries/timing. Abort
        // without writing anything; the author must make a fresh clean recording.
        guard cleanText(assembled, home: home) == assembled else { throw RecordingOutputFailure.unsafeStream }
      }
      event.fields = cleanValue(event.fields, home: home)
      result.append(event)
    }
    return result
  }

  private static func cleanText(_ text: String, home: String) -> String {
    var value = LogRedactor.redact(text)
    if !home.isEmpty, home != "/" { value = value.replacingOccurrences(of: home, with: "[home]") }
    value = value.replacingOccurrences(
      of: #"/(?:Users|home)/[^/\s\"']+"#, with: "[home]", options: .regularExpression)
    return value
  }

  private static func cleanValue(_ value: JSONValue, home: String) -> JSONValue {
    switch value {
    case .string(let text): return .string(cleanText(text, home: home))
    case .array(let values): return .array(values.map { cleanValue($0, home: home) })
    case .object(let values):
      var safe: [String: JSONValue] = [:]
      for (key, child) in values {
        let sensitive =
          key.range(
            of:
              #"(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization|grant)"#,
            options: .regularExpression) != nil
        safe[key] = sensitive ? .string("[redacted]") : cleanValue(child, home: home)
      }
      return .object(safe)
    default: return value
    }
  }

  static func write(events: [RecordedEvent], appVersion: String, path: String) throws {
    guard path.hasPrefix("/"), !path.split(separator: "/").contains("public"),
      !path.split(separator: "/").contains(".git")
    else { throw RecordingOutputFailure.invalidPath }
    let safe = try sanitized(events)
    let data = try JSONCoding.encoder.encode(RecordingFile(appVersion: appVersion, events: safe))
    guard data.count <= 20 * 1024 * 1024 else { throw RecordingOutputFailure.limitExceeded }
    let destination = URL(fileURLWithPath: path)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".docs-record-\(UUID().uuidString)"
    ).path
    let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw RecordingOutputFailure.writeFailed }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close(); unlink(temporary) }
    do { try handle.write(contentsOf: data); try handle.synchronize() } catch {
      throw RecordingOutputFailure.writeFailed
    }
    // link is atomic and refuses every existing destination, including symlinks.
    guard Darwin.link(temporary, path) == 0 else {
      throw errno == EEXIST ? RecordingOutputFailure.alreadyExists : RecordingOutputFailure.writeFailed
    }
  }
}
