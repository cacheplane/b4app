import Coordinator
import Darwin
import Foundation

/// Executable entry point. Paths come from B4APP_RUNTIME_DIR / B4APP_DATA_DIR or platform defaults.
/// Exits 0 immediately when another coordinator already holds the lock.
@main
struct CoordinatorMain {
  static func main() async throws {
    // The launcher starts us detached from a terminal; a closing terminal must not take us down.
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    let outcome: StartOutcome
    do {
      outcome = try await Coordinator.start(
        options: CoordinatorOptions(legacyAdoption: LegacyAdoption.planIfExplicitLocal()))
    } catch {
      // A clear line and exit status, not a Swift trap: the launcher shows this log to the user.
      FileHandle.standardError.write(Data("coordinator failed to start: \(error)\n".utf8))
      exit(1)
    }
    switch outcome {
    case .alreadyRunning(let record, let paths):
      print("already running (pid \(record?.pid ?? -1)) at \(paths.socketPath)")
      return
    case .running(let coordinator):
      print("ready \(coordinator.paths.socketPath)")
      fflush(stdout)
      let stop = AsyncStream<Int32> { continuation in
        for sig in [SIGINT, SIGTERM] {
          signal(sig, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
          source.setEventHandler { continuation.yield(sig) }
          source.resume()
          continuation.onTermination = { _ in source.cancel() }
        }
      }
      for await sig in stop {
        FileHandle.standardError.write(Data("shutting down on signal \(sig)\n".utf8))
        await coordinator.close()
        exit(0)
      }
    }
  }
}
