import Darwin
import Foundation

func names(_ directory: String) throws -> [String] {
  guard let stream = opendir(directory) else { throw CocoaError(.fileReadUnknown) }
  defer { closedir(stream) }
  var names: [String] = []
  while let entry = readdir(stream) {
    let count = Int(entry.pointee.d_namlen)
    let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(count), as: UTF8.self) }
    if name != ".", name != ".." { names.append(name) }
  }
  return names
}
let path = CommandLine.arguments[1]
let clock = ContinuousClock()
for repetition in 0..<3 {
  var values: [Set<String>] = []
  for method in (repetition % 2 == 0 ? ["foundation", "namesOnly"] : ["namesOnly", "foundation"]) {
    let start = clock.now
    let entries = try method == "foundation" ? FileManager.default.contentsOfDirectory(atPath: path) : names(path)
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    values.append(Set(entries))
    let record: [String: Any] = ["method": method, "repetition": repetition, "entries": entries.count, "seconds": seconds]
    print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
  }
  precondition(values[0] == values[1], "Different directory names")
}
