import Foundation

private let fixturesDirectory =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("B4AdapterTests/Fixtures")

/// The fake Node executable that runs the fake `b4` CLI (python) in place of `dist/index.js`.
func fakeNodePath() -> String { fixturesDirectory.appendingPathComponent("fake-node.sh").path }

/// Builds a scratch B4 project laid out like a real one: `package.json`, `b4.config.ts`, routes under
/// `src/app/<name>/index.ts`, and a project-installed `@b4run/cli` whose `dist/index.js` is the fake CLI.
enum FakeB4Project {
  @discardableResult
  static func make(
    root: String, cliVersion: String? = "0.15.8",
    routes: [(name: String, kind: String)] = [("chat", "agent"), ("dispatch", "workflow")],
    withConfig: Bool = true
  ) throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    try #"{"name": "fake-project", "private": true, "type": "module"}"#.write(
      toFile: root + "/package.json", atomically: true, encoding: .utf8)
    if withConfig {
      try "export default { appDir: \"src/app\" }\n".write(
        toFile: root + "/b4.config.ts", atomically: true, encoding: .utf8)
    }
    for route in routes {
      let dir = root + "/src/app/" + route.name
      try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
      try "export default \(route.kind)({})\n".write(
        toFile: dir + "/index.ts", atomically: true, encoding: .utf8)
    }
    if let cliVersion {
      let cli = root + "/node_modules/@b4run/cli"
      try fm.createDirectory(atPath: cli + "/dist", withIntermediateDirectories: true)
      try
        #"{"name": "@b4run/cli", "version": "\#(cliVersion)", "type": "module", "bin": {"b4": "dist/index.js"}}"#
        .write(toFile: cli + "/package.json", atomically: true, encoding: .utf8)
      try fm.copyItem(
        atPath: fixturesDirectory.appendingPathComponent("fake-b4-cli.py").path,
        toPath: cli + "/dist/index.js")
      try fm.copyItem(
        atPath: fixturesDirectory.appendingPathComponent("fake-b4.py").path, toPath: cli + "/dist/fake_b4.py")
    }
    return root
  }
}
