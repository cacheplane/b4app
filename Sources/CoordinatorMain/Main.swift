import Coordinator
import Darwin
import Foundation
import WorkspacePlatform

/// Executable entry point. Paths come from B4APP_RUNTIME_DIR / B4APP_DATA_DIR or platform defaults.
/// Exits 0 immediately when another coordinator already holds the lock.
@main
struct CoordinatorMain {
  static func main() async throws {
    // The launcher starts us detached from a terminal; a closing terminal must not take us down.
    signal(SIGHUP, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    do {
      try await adoptPreFlavourInstall()
    } catch {
      // `b4app` was left as it was; starting now would create `b4app-local` empty and so end the
      // adoption for good, so the coordinator stays down until the cause is fixed.
      FileHandle.standardError.write(
        Data("coordinator failed to adopt the previous install's data: \(error)\n".utf8))
      exit(1)
    }
    let outcome: StartOutcome
    do {
      outcome = try await Coordinator.start()
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

  /// A local-flavour build takes over the owner's pre-flavour data directory (sign-in plan, Task 3).
  /// An explicit data directory or external cluster means a test or an experiment, which never
  /// adopts anything.
  private static func adoptPreFlavourInstall() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard Flavor.current == .local, environment["B4APP_DATA_DIR"] == nil,
      environment["B4APP_POSTGRES_SOCKET_DIR"] == nil
    else { return }
    let production = LegacyAdoption.Production(environment: environment)
    let moved = try await LegacyAdoption.moveDataIfNeeded(
      flavor: .local, home: production.home, readHubURL: production.readHubURL,
      bootOutLegacy: production.bootOutLegacy)
    if moved {
      FileHandle.standardError.write(
        Data("adopted the previous install's data directory b4app as b4app-local\n".utf8))
    }
  }
}
