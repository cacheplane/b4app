import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// Locates a project's installed `@b4run/cli`, builds the child environment, and runs
/// `b4 routes --json` (spec 9.1, D-026). Inspection executes the project's config and route modules,
/// so it runs only for registered (trusted) projects.
enum B4ProjectInspector {
  static let minimumCLIVersion = "0.15.7"
  static let cliRelativePath = "node_modules/@b4run/cli/dist/index.js"

  struct Project: Sendable, Equatable {
    var root: String
    var cliPath: String
    var cliVersion: String
  }

  /// The app root must hold `package.json` and `b4.config.*`; the CLI must be project-installed.
  static func locate(projectPath: String) throws -> Project {
    let root = ((projectPath as NSString).expandingTildeInPath as NSString).standardizingPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw WorkspaceError(
        .protocolInvalid, "\(projectPath) is not a directory.", details: ["projectPath": .string(projectPath)]
      )
    }
    let hasConfig =
      ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).contains {
        $0.hasPrefix("b4.config.")
      }
    guard hasConfig, FileManager.default.fileExists(atPath: root + "/package.json") else {
      throw WorkspaceError(
        .protocolInvalid,
        "\(root) is not a B4 app root: it needs both b4.config.ts and package.json.",
        details: ["projectPath": .string(root)])
    }
    let cliPath = root + "/" + cliRelativePath
    guard FileManager.default.fileExists(atPath: cliPath) else {
      throw WorkspaceError(
        .missingExecutable,
        "\(root) has no project-installed @b4run/cli (expected \(cliRelativePath)). Install it in the project with `npm install @b4run/cli` or `pnpm add @b4run/cli`; nothing is downloaded by the app.",
        details: ["projectPath": .string(root), "cliPath": .string(cliPath)])
    }
    let packagePath = root + "/node_modules/@b4run/cli/package.json"
    let version =
      (try? JSONCoding.decoder.decode(
        JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: packagePath))))?[
        "version"]?.stringValue
    guard let version, Versions.parse(version) != nil else {
      throw WorkspaceError(
        .incompatibleVersion, "Could not read the @b4run/cli version from \(packagePath).",
        details: ["cliPath": .string(cliPath)])
    }
    guard Versions.compare(version, minimumCLIVersion) >= 0 else {
      throw WorkspaceError(
        .incompatibleVersion,
        "@b4run/cli \(version) in \(root) is older than the minimum \(minimumCLIVersion). Upgrade the project's dependency.",
        details: ["cliVersion": .string(version), "minimum": .string(minimumCLIVersion)])
    }
    return Project(root: root, cliPath: cliPath, cliVersion: version)
  }

  /// The child environment (design "Child environment"): never the coordinator's own. Env-file
  /// values live only in the returned dictionary; callers pass it to a spawn and drop it.
  static func childEnvironment(
    node: String, envFilePath: String?, base: [String: String]
  ) throws -> [String: String] {
    var env: [String: String] = [:]
    let nodeDirectory = (node as NSString).deletingLastPathComponent
    env["PATH"] = "\(nodeDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
    for key in ["HOME", "TMPDIR", "LANG", "USER", "SHELL"] {
      if let value = base[key] { env[key] = value }
    }
    if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
    if let envFilePath {
      guard let text = try? String(contentsOfFile: envFilePath, encoding: .utf8) else {
        throw WorkspaceError(
          .protocolInvalid, "Env file \(envFilePath) does not exist or is not readable.",
          details: ["envFilePath": .string(envFilePath)])
      }
      for (key, value) in Dotenv.parse(text) { env[key] = value }
    }
    return env
  }

  /// `node <cli> routes --json --cwd <root>` from the project directory with a 60 s budget.
  static func routes(
    project: Project, node: String, environment: [String: String]
  ) async throws -> [LocalServerRoute] {
    let result = try await CommandRunner.run(
      node, [project.cliPath, "routes", "--json", "--cwd", project.root],
      options: CommandOptions(timeout: .seconds(60), environment: environment, workingDirectory: project.root)
    )
    if result.timedOut {
      throw WorkspaceError(
        .endpointUnavailable, "`b4 routes` in \(project.root) did not finish within 60 seconds.")
    }
    guard result.succeeded else {
      // The project's modules ran with the env-file values in their environment and may have
      // printed them; redact before the text reaches a result.
      let output = String(result.stderr.suffix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n").map { LogRedactor.redact(String($0)) }.joined(separator: "\n")
      throw WorkspaceError(
        .incompatibleVersion,
        "`b4 routes` in \(project.root) failed (exit \(result.exitCode.map(String.init) ?? "signal")): \(output)",
        details: ["exitCode": result.exitCode.map { .number(Double($0)) } ?? .null])
    }
    guard let manifest = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(result.stdout.utf8)),
      let entries = manifest["routes"]?.arrayValue
    else {
      throw WorkspaceError(
        .protocolInvalid, "`b4 routes --json` in \(project.root) did not print a route manifest.")
    }
    return entries.compactMap { entry in
      guard let id = entry["id"]?.stringValue ?? entry["pathname"]?.stringValue,
        let kind = entry["kind"]?.stringValue
      else { return nil }
      return LocalServerRoute(id: id, kind: kind, entryFile: entry["entryFile"]?.stringValue ?? "")
    }
  }
}
