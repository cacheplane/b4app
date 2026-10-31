import Foundation
import Synchronization
import WorkspaceProtocol

public enum ExitStatus: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}

/// A long-lived child with a writable stdin, a chunked stdout stream, bounded stderr capture, and an
/// awaitable exit. Used for protocol servers such as `codex app-server`; one-shot commands use
/// `CommandRunner`. Arguments are always an array, never a shell string.
public final class StreamingProcess: Sendable {
  private struct State {
    var process: Process
    var stdin: FileHandle?
    var stderrTail: [UInt8] = []
    var exit: ExitStatus?
    var exitWaiters: [CheckedContinuation<ExitStatus, Never>] = []
  }

  public let processIdentifier: Int32
  /// Raw stdout bytes as they arrive. Single consumer; finishes at EOF.
  public let stdout: AsyncStream<[UInt8]>
  private let state: Mutex<State>
  private static let stderrLimit = 16 * 1024

  private init(process: Process, stdin: FileHandle, stdout: AsyncStream<[UInt8]>) {
    self.processIdentifier = process.processIdentifier
    self.stdout = stdout
    self.state = Mutex(State(process: process, stdin: stdin))
  }

  /// Spawn the child. Throws `missing_executable` when it cannot start. Ignores SIGPIPE process-wide
  /// so a write to a dead child surfaces as an error instead of killing the coordinator.
  public static func start(
    executable: String, arguments: [String], environment: [String: String]? = nil,
    workingDirectory: String? = nil
  ) throws -> StreamingProcess {
    signal(SIGPIPE, SIG_IGN)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
      } else {
        continuation.yield(Array(data))
      }
    }
    let holder = Mutex<StreamingProcess?>(nil)
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      holder.withLock { $0 }?.appendStderr(Array(data))
    }
    process.terminationHandler = { finished in
      let status: ExitStatus =
        finished.terminationReason == .uncaughtSignal
        ? .signaled(finished.terminationStatus) : .exited(finished.terminationStatus)
      holder.withLock { $0 }?.recordExit(status)
    }
    do {
      try process.run()
    } catch {
      continuation.finish()
      throw WorkspaceError(.missingExecutable, "Could not start \(executable): \(error.localizedDescription)")
    }
    let instance = StreamingProcess(process: process, stdin: stdinPipe.fileHandleForWriting, stdout: stream)
    holder.withLock { $0 = instance }
    // The handlers above may have fired before the holder was set; nothing is lost for exit because
    // `isRunning` is consulted in `recordExit` callers, but re-check termination here.
    if !process.isRunning {
      let status: ExitStatus =
        process.terminationReason == .uncaughtSignal
        ? .signaled(process.terminationStatus) : .exited(process.terminationStatus)
      instance.recordExit(status)
    }
    return instance
  }

  public var isRunning: Bool { state.withLock { $0.exit == nil && $0.process.isRunning } }

  /// Write bytes to the child's stdin. Throws `endpoint_unavailable` once stdin is closed or the child
  /// has exited.
  public func write(_ data: Data) throws {
    let handle = state.withLock { $0.exit == nil ? $0.stdin : nil }
    guard let handle else {
      throw WorkspaceError(.endpointUnavailable, "Child process \(processIdentifier) is not accepting input.")
    }
    do {
      try handle.write(contentsOf: data)
    } catch {
      throw WorkspaceError(.endpointUnavailable, "Write to child \(processIdentifier) failed: \(error)")
    }
  }

  /// Close stdin (EOF for the child). Idempotent.
  public func closeInput() {
    let handle = state.withLock { state -> FileHandle? in
      let handle = state.stdin
      state.stdin = nil
      return handle
    }
    try? handle?.close()
  }

  public func terminate() {
    state.withLock { if $0.exit == nil { $0.process.terminate() } }
  }

  public func kill() {
    state.withLock { if $0.exit == nil { Foundation.kill($0.process.processIdentifier, SIGKILL) } }
  }

  public func waitForExit() async -> ExitStatus {
    await withCheckedContinuation { continuation in
      let immediate: ExitStatus? = state.withLock { state in
        if let exit = state.exit { return exit }
        state.exitWaiters.append(continuation)
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }

  /// The last 16 KiB of stderr, for diagnostics messages. Never logged automatically.
  public func recentStderr() -> String {
    String(decoding: state.withLock { $0.stderrTail }, as: UTF8.self)
  }

  private func appendStderr(_ bytes: [UInt8]) {
    state.withLock { state in
      state.stderrTail.append(contentsOf: bytes)
      if state.stderrTail.count > Self.stderrLimit {
        state.stderrTail.removeFirst(state.stderrTail.count - Self.stderrLimit)
      }
    }
  }

  private func recordExit(_ status: ExitStatus) {
    let waiters: [CheckedContinuation<ExitStatus, Never>] = state.withLock { state in
      guard state.exit == nil else { return [] }
      state.exit = status
      let waiters = state.exitWaiters
      state.exitWaiters = []
      try? state.stdin?.close()
      state.stdin = nil
      return waiters
    }
    for waiter in waiters { waiter.resume(returning: status) }
  }
}
