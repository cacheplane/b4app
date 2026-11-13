import Foundation

public struct NodeExecutable: Sendable, Equatable {
  public var path: String
  public var version: String
  public var source: String
}

/// Bounded facts from the explicit Node probe after its CommandRunner operation has returned.
/// Parent elapsed time includes scheduling, capture, group cleanup and resumption, not process time.
package struct NodeVersionProbeObservation: Sendable {
  /// Classifies returned wrapper stdout independently of the resolver's trimmed version predicates.
  package enum StdoutShape: String, Sendable {
    case unavailable, empty, exactFake24, vPrefixOther, other
  }

  package let commandThrew: Bool
  package let returnedTimedOut: Bool?
  package let returnedExitCode: Int32?
  package let returnedSignal: Int32?
  package let returnedSucceeded: Bool?
  package let stdoutShape: StdoutShape
  package let versionPrefixAccepted: Bool?
  package let minimumAccepted: Bool?
  package let resolveAccepted: Bool
  package let callerCancelledAtReturn: Bool
  package let probeParentElapsedMilliseconds: UInt64
  package let selectedOutcomeOrigin: CommandRunner.SelectedOutcomeOrigin?

  /// Projects returned wrapper stdout to a closed value; stderr and error-shaped text are never retained.
  static func classifyStdout(of result: CommandResult?) -> StdoutShape {
    guard let result else { return .unavailable }
    if result.stdout.isEmpty { return .empty }
    if result.stdout == "v24.0.0\n" { return .exactFake24 }
    return result.stdout.hasPrefix("v") ? .vPrefixOther : .other
  }

  package init(
    commandThrew: Bool, returnedTimedOut: Bool?, returnedExitCode: Int32?, returnedSignal: Int32?,
    returnedSucceeded: Bool?, stdoutShape: StdoutShape, versionPrefixAccepted: Bool?,
    minimumAccepted: Bool?, resolveAccepted: Bool, callerCancelledAtReturn: Bool,
    probeParentElapsedMilliseconds: UInt64,
    selectedOutcomeOrigin: CommandRunner.SelectedOutcomeOrigin? = nil
  ) {
    self.commandThrew = commandThrew
    self.returnedTimedOut = returnedTimedOut
    self.returnedExitCode = returnedExitCode
    self.returnedSignal = returnedSignal
    self.returnedSucceeded = returnedSucceeded
    self.stdoutShape = stdoutShape
    self.versionPrefixAccepted = versionPrefixAccepted
    self.minimumAccepted = minimumAccepted
    self.resolveAccepted = resolveAccepted
    self.callerCancelledAtReturn = callerCancelledAtReturn
    self.probeParentElapsedMilliseconds = probeParentElapsedMilliseconds
    self.selectedOutcomeOrigin = selectedOutcomeOrigin
  }
}

/// Resolves a Node >= 24 executable for managed B4 servers. Order: B4APP_NODE_PATH, PATH, fallback
/// directories, then version-manager installs. Never a shell lookup.
public enum NodeLocator {
  public static let minimumMajor = 24

  static func major(of version: String) -> Int {
    let digits = version.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    return Int(digits) ?? 0
  }

  static func version(of path: String) async -> String? {
    guard
      let result = try? await CommandRunner.run(
        path, ["--version"], options: CommandOptions(timeout: .seconds(5))),
      result.succeeded
    else { return nil }
    let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.hasPrefix("v") ? version : nil
  }

  /// Observes only the SAME explicit probe, without retry, fallback or a custom child environment.
  package static func resolveObservingExplicitProbe(
    environment env: [String: String],
    observation: @Sendable (NodeVersionProbeObservation) -> Void
  ) async -> NodeExecutable? {
    guard let explicit = env["B4APP_NODE_PATH"] else { return await resolve(environment: env) }
    let started = ContinuousClock.now
    let observed = try? await CommandRunner.runObservingSelectedOutcome(
      explicit, ["--version"], options: CommandOptions(timeout: .seconds(5)))
    // Sample the parent boundary before predicates or callback work. timedOut does not identify
    // whether the existing timer or work cancellation won CommandRunner's race.
    let elapsed = started.duration(to: ContinuousClock.now)
    let callerCancelledAtReturn = Task.isCancelled
    let result = observed?.result
    var versionPrefixAccepted: Bool? = nil
    var minimumAccepted: Bool? = nil
    var executable: NodeExecutable? = nil
    if let result, result.succeeded {
      let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefixAccepted = version.hasPrefix("v")
      versionPrefixAccepted = prefixAccepted
      if prefixAccepted {
        let majorAccepted = major(of: version) >= minimumMajor
        minimumAccepted = majorAccepted
        if majorAccepted {
          executable = NodeExecutable(path: explicit, version: version, source: "explicit")
        }
      }
    }
    let shape = NodeVersionProbeObservation.classifyStdout(of: result)
    observation(
      NodeVersionProbeObservation(
        commandThrew: result == nil, returnedTimedOut: result?.timedOut,
        returnedExitCode: result?.exitCode, returnedSignal: result?.signal,
        returnedSucceeded: result?.succeeded, stdoutShape: shape,
        versionPrefixAccepted: versionPrefixAccepted, minimumAccepted: minimumAccepted,
        resolveAccepted: executable != nil, callerCancelledAtReturn: callerCancelledAtReturn,
        probeParentElapsedMilliseconds: boundedProbeMilliseconds(elapsed),
        selectedOutcomeOrigin: observed?.selectedOutcomeOrigin))
    return executable
  }

  /// Saturates rather than trapping if a parent-side duration exceeds UInt64 milliseconds.
  private static func boundedProbeMilliseconds(_ duration: Duration) -> UInt64 {
    guard duration > .zero else { return 0 }
    let components = duration.components
    let seconds = UInt64(clamping: components.seconds)
    let fractional = UInt64(clamping: components.attoseconds / 1_000_000_000_000_000)
    let whole = seconds.multipliedReportingOverflow(by: 1_000)
    guard !whole.overflow else { return .max }
    let total = whole.partialValue.addingReportingOverflow(fractional)
    return total.overflow ? .max : total.partialValue
  }

  static func versionManagerCandidates(home: String) -> [String] {
    let roots = [
      "\(home)/.nvm/versions/node",
      "\(home)/.local/share/fnm/node-versions",
      "\(home)/.local/share/mise/installs/node",
      "\(home)/.asdf/installs/nodejs",
    ]
    var candidates: [(String, Int)] = []
    for root in roots {
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
      for entry in entries where major(of: entry) >= minimumMajor {
        candidates.append(("\(root)/\(entry)/bin/node", major(of: entry)))
        candidates.append(("\(root)/\(entry)/installation/bin/node", major(of: entry)))
      }
    }
    return candidates.sorted { $0.1 > $1.1 }.map(\.0)
  }

  public static func resolve(
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) async -> NodeExecutable? {
    if let explicit = env["B4APP_NODE_PATH"] {
      if let version = await version(of: explicit), major(of: version) >= minimumMajor {
        return NodeExecutable(path: explicit, version: version, source: "explicit")
      }
      return nil
    }
    if let found = ExecutableLocator.find("node", environment: env),
      let version = await version(of: found.path), major(of: version) >= minimumMajor
    {
      return NodeExecutable(path: found.path, version: version, source: found.source.rawValue)
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    for candidate in versionManagerCandidates(home: home) {
      if let version = await version(of: candidate), major(of: version) >= minimumMajor {
        return NodeExecutable(path: candidate, version: version, source: "version-manager")
      }
    }
    return nil
  }
}
