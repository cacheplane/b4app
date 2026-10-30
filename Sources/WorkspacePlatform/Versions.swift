import Foundation

/// Semantic-version helpers for executable compatibility checks.
public enum Versions {
  /// First `major.minor.patch` found in free-form output such as "codex-cli 0.166.0".
  public static func parse(_ output: String) -> String? {
    let pattern = #"(\d+)\.(\d+)\.(\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
      let range = Range(match.range, in: output)
    else { return nil }
    return String(output[range])
  }

  /// Negative when `a` is older than `b`, zero when equal, positive when newer.
  public static func compare(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<3 {
      let diff = (index < pa.count ? pa[index] : 0) - (index < pb.count ? pb[index] : 0)
      if diff != 0 { return diff }
    }
    return 0
  }
}
