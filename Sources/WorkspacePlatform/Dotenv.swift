import Foundation

/// A dotenv parser with no shell evaluation (spec 9.5): `KEY=value`, optional `export`, `#` comments
/// (whole-line, or from the first `#` of an unquoted value), single quotes literal, double quotes with
/// `\n`, `\"`, and `\\` escapes, no `${}` expansion, later keys win. Values go to a child
/// environment only; callers never persist or log them.
public enum Dotenv {
  public static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = Substring(rawLine)
      if line.hasSuffix("\r") { line = line.dropLast() }
      line = line.drop(while: { $0 == " " || $0 == "\t" })
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if line.hasPrefix("export ") { line = line.dropFirst(7).drop(while: { $0 == " " || $0 == "\t" }) }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
      let rest = line[line.index(after: equals)...].drop(while: { $0 == " " || $0 == "\t" })
      result[key] = value(from: rest)
    }
    return result
  }

  private static func value(from text: Substring) -> String {
    guard let first = text.first else { return "" }
    if first == "'" {
      let body = text.dropFirst()
      if let close = body.firstIndex(of: "'") { return String(body[..<close]) }
      return String(body)
    }
    if first == "\"" {
      var out = ""
      var iterator = text.dropFirst().makeIterator()
      while let character = iterator.next() {
        if character == "\"" { break }
        if character == "\\", let next = iterator.next() {
          switch next {
          case "n": out.append("\n")
          case "r": out.append("\r")
          case "t": out.append("\t")
          case "\"": out.append("\"")
          case "\\": out.append("\\")
          default:
            out.append("\\")
            out.append(next)
          }
        } else {
          out.append(character)
        }
      }
      return out
    }
    // Unquoted values end at the first `#`, as npm dotenv's `[^#\r\n]+` does.
    var unquoted = text
    if let hash = unquoted.firstIndex(of: "#") { unquoted = unquoted[..<hash] }
    return unquoted.trimmingCharacters(in: .whitespaces)
  }
}
