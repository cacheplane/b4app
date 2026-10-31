import Foundation
import Subprocess
import System
import WorkspaceProtocol

public struct CommandResult: Sendable, Equatable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32?
  public var signal: Int32?
  public var timedOut: Bool
  public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public struct CommandOptions: Sendable {
  public var timeout: Duration
  /// Replaces the inherited environment when set. Build it from `ProcessInfo.processInfo.environment`
  /// minus the keys you want gone; the child never sees anything else.
  public var environment: [String: String]?
  public var workingDirectory: String?
  public var input: String?
  public var maxOutputBytes: Int

  public init(
    timeout: Duration = .seconds(10), environment: [String: String]? = nil, workingDirectory: String? = nil,
    input: String? = nil, maxOutputBytes: Int = 1_048_576
  ) {
    self.timeout = timeout
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.input = input
    self.maxOutputBytes = maxOutputBytes
  }
}

/// Runs an executable with an argument array (never a shell string), bounded output, and a timeout.
/// Resolves even on nonzero exit; throws `missing_executable` only when the process cannot start.
public enum CommandRunner {
  public static func run(
    _ executable: String, _ arguments: [String], options: CommandOptions = CommandOptions()
  ) async throws -> CommandResult {
    let environment: Subprocess.Environment
    if let custom = options.environment {
      environment = .custom(
        Dictionary(
          uniqueKeysWithValues: custom.map { (Subprocess.Environment.Key(stringLiteral: $0.key), $0.value) }))
    } else {
      environment = .inherit
    }
    let workingDirectory = options.workingDirectory.map { FilePath($0) }
    let limit = options.maxOutputBytes
    let input = options.input
    let timeout = options.timeout

    enum Outcome: Sendable {
      case finished(CommandResult)
      case timedOut
    }

    return try await withThrowingTaskGroup(of: Outcome.self) { group in
      group.addTask {
        do {
          if let input {
            let result = try await Subprocess.run(
              .path(FilePath(executable)), arguments: Arguments(arguments), environment: environment,
              workingDirectory: workingDirectory, input: .string(input),
              output: .string(limit: limit), error: .string(limit: limit))
            return .finished(Self.map(result))
          }
          let result = try await Subprocess.run(
            .path(FilePath(executable)), arguments: Arguments(arguments), environment: environment,
            workingDirectory: workingDirectory, output: .string(limit: limit), error: .string(limit: limit))
          return .finished(Self.map(result))
        } catch is CancellationError {
          return .timedOut
        } catch let error as SubprocessError {
          throw WorkspaceError(.missingExecutable, "Could not run \(executable): \(error.description)")
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        return .timedOut
      }
      guard let first = try await group.next() else {
        return CommandResult(stdout: "", stderr: "", exitCode: nil, signal: nil, timedOut: true)
      }
      group.cancelAll()
      switch first {
      case .finished(let result): return result
      case .timedOut: return CommandResult(stdout: "", stderr: "", exitCode: nil, signal: nil, timedOut: true)
      }
    }
  }

  private static func map(
    _ result: borrowing ExecutionResult<Void, StringOutput<UTF8>, StringOutput<UTF8>>
  ) -> CommandResult {
    var exitCode: Int32?
    var signal: Int32?
    switch result.terminationStatus {
    case .exited(let code): exitCode = code
    case .signaled(let code): signal = code
    }
    return CommandResult(
      stdout: result.standardOutput, stderr: result.standardError, exitCode: exitCode, signal: signal,
      timedOut: false)
  }
}
