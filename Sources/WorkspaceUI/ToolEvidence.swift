import Foundation
import WorkspaceProtocol

/// What an opened tool card shows, read from the item's payload. No SwiftUI: the card only draws it.
enum ToolEvidence {
  struct Change: Equatable, Sendable {
    var path: String
    var diff: String?
  }

  /// What the item recorded as its result.
  enum Output: Equatable, Sendable {
    /// No result was recorded (the call is open, or its runtime keeps none).
    case none
    /// A result was recorded and it has no text: an empty string, or null.
    case empty
    /// The result: text as it is, any other value (`false`, `0`, a list) as JSON.
    case text(String)
  }

  struct Detail: Equatable, Sendable {
    var cwd: String?
    /// The call's arguments: text as it is, anything else as JSON with sorted keys.
    var input: String?
    var output: Output
    var exitCode: Int?
    var changes: [Change]
    /// The payload as JSON with sorted keys, cut at `rawLimit`, when nothing above was found: an unknown item type is
    /// still inspectable.
    var raw: String?
  }

  static let rawLimit = 2_000

  static func detail(of item: DisplayItem) -> Detail {
    let payload = item.payload
    let changes = (payload["changes"]?.arrayValue ?? []).map {
      Change(path: $0["path"]?.stringValue ?? "", diff: $0["diff"]?.stringValue)
    }
    var detail = Detail(
      cwd: payload["cwd"]?.stringValue, input: text(payload["input"] ?? payload["arguments"]),
      output: output(payload["aggregatedOutput"] ?? payload["output"]),
      exitCode: payload["exitCode"]?.numberValue.map { Int($0) }, changes: changes, raw: nil)
    if detail.cwd == nil, detail.input == nil, detail.output == .none, detail.exitCode == nil, changes.isEmpty
    {
      detail.raw = String((text(payload) ?? String(describing: payload)).prefix(rawLimit))
    }
    return detail
  }

  private static func output(_ value: JSONValue?) -> Output {
    guard let value else { return .none }
    if value.isNull || value.stringValue == "" { return .empty }
    return text(value).map(Output.text) ?? .empty
  }

  /// Text as it is; any other value as JSON. Nil for a missing or null value.
  private static func text(_ value: JSONValue?) -> String? {
    guard let value, !value.isNull else { return nil }
    if let string = value.stringValue { return string }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
  }
}
