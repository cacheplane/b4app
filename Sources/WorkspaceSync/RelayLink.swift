import Foundation

/// Where a `RelayLink` is. `stopped` is final until `start()`: the reason is `unauthorized` (no token, or
/// the hub refused it: the device has to join again), `replaced` (a newer link from this device took
/// over), `revoked`, `client_too_old` (the hub needs a newer build), or `stopped` (`stop()` was called).
public enum RelayLinkState: Sendable, Equatable {
  /// Opening the link. `attempt` counts tries since the last `hello`; `lastError` is why the previous
  /// one ended, and never carries a token.
  case connecting(attempt: Int, lastError: String?)
  /// The hub's `hello` arrived. `role` is `host` for a Mac, `client` for a phone or the CLI.
  case connected(since: Date, role: RelayRole)
  case stopped(reason: String)
}

/// The device's side of the relay link, shared by the Mac (`HubLink`) and the phone (`MirrorRelay`):
/// opens the link, reconnects with backoff, keeps the heartbeat, and keeps a clock offset to the hub.
/// Its owner passes `onMessage` and `onState`; it never logs.
///
/// - Backoff: 1 s doubling to `maxBackoff`, scaled by `jitter()` (full jitter: a random 0...1 of the
///   delay), restarting at 1 s once a link has stayed up 60 s.
/// - Heartbeat: `ping` every 10 s; 30 s without any frame ends the link and reconnects.
/// - Stops, with no retry: a 401 at the upgrade (or no token), `link_replaced`/close 4000, close 4001,
///   `client_too_old`/close 4002. A 429 at the upgrade and every other failure retry.
/// - `onMessage` gets every frame except `pong`, one at a time and in order, awaited before the next is
///   read: hand slow work to another task.
public actor RelayLink {
  /// The link protocol this build speaks, sent as `B4-Protocol`.
  public static let protocolVersion = 1

  private enum Outcome {
    case stop(String)
    case retry(String)
  }

  private let url: URL
  private let tokenProvider: @Sendable () async throws -> String?
  private let connection: any HubLinkConnection
  private let maxBackoff: Duration
  private let clock: any Clock<Duration>
  private let jitter: @Sendable () -> Double
  private let onMessage: @Sendable (RelayMessage) async -> Void
  private let onState: @Sendable (RelayLinkState) async -> Void

  /// The latest state published.
  public private(set) var state: RelayLinkState = .stopped(reason: "stopped")

  private var runTask: Task<Void, Never>?
  /// Changes on every `start` and `stop`, so work from an earlier run can tell it is stale.
  private var runID = 0
  private var socket: (any HubLinkSocket)?
  private var connected = false
  private var reachedHello = false
  private var reachedStable = false
  private var endReason: String?
  private var skipBackoff = false
  private var backoffSleeper: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var stable: Task<Void, Never>?
  /// The hub's clock minus this device's, in seconds, from the latest `hello` or `pong`.
  private var hubOffset: TimeInterval?

  /// - Parameters:
  ///   - url: the hub's base URL (as `HubURL.validate` returns it); the connection adds the path.
  ///   - token: the device token, asked for on every attempt. `nil` stops the link as `unauthorized`.
  ///   - jitter: a number in 0...1 that scales each backoff delay; tests fix it at 1.0.
  public init(
    url: URL,
    token: @escaping @Sendable () async throws -> String?,
    connection: any HubLinkConnection = URLSessionHubLinkConnection(),
    maxBackoff: Duration = .seconds(30),
    clock: any Clock<Duration> = ContinuousClock(),
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    onMessage: @escaping @Sendable (RelayMessage) async -> Void,
    onState: @escaping @Sendable (RelayLinkState) async -> Void
  ) {
    self.url = url
    self.tokenProvider = token
    self.connection = connection
    self.maxBackoff = maxBackoff
    self.clock = clock
    self.jitter = jitter
    self.onMessage = onMessage
    self.onState = onState
  }

  // MARK: - Control

  /// Starts connecting. Does nothing while already running; starts again after a stop.
  public func start() {
    guard runTask == nil else { return }
    runID += 1
    let id = runID
    runTask = Task { await self.run(id) }
  }

  /// Ends the link for good until `start()`, closing the socket.
  public func stop() async {
    guard runTask != nil else { return }
    runID += 1
    runTask?.cancel()
    runTask = nil
    backoffSleeper?.cancel()
    backoffSleeper = nil
    endReason = "stopped"
    teardown()
    state = .stopped(reason: "stopped")
    await onState(state)
  }

  /// Reconnects now: skips a backoff wait, or drops the live link and reopens it at once (after a
  /// wake or a network change). Does nothing when stopped.
  public func reconnectNow() {
    guard runTask != nil else { return }
    if let backoffSleeper {
      backoffSleeper.cancel()
    } else if let socket {
      skipBackoff = true
      endReason = "reconnecting"
      socket.close(code: 1000)
    }
  }

  /// Sends a frame. Throws `HubLinkError.notConnected` before `hello` and between links.
  public func send(_ message: RelayMessage) async throws {
    guard connected, let socket else { throw HubLinkError.notConnected }
    try await socket.send(message)
  }

  /// This device's best estimate of the hub's clock: the local time plus the offset from the latest
  /// `hello` or `pong`. Nil before the first `hello`.
  public func hubNow() -> Date? {
    hubOffset.map { Date().addingTimeInterval($0) }
  }

  // MARK: - Run loop

  private func run(_ id: Int) async {
    var attempt = 0
    var failures = 0
    await publish(.connecting(attempt: 1, lastError: nil), id)
    while !Task.isCancelled && runID == id {
      attempt += 1
      reachedHello = false
      reachedStable = false
      let outcome = await connectOnce(id)
      guard runID == id, !Task.isCancelled else { return }
      if reachedHello { attempt = 0 }
      if reachedStable { failures = 0 }
      switch outcome {
      case .stop(let reason):
        runTask = nil
        await publish(.stopped(reason: reason), id)
        return
      case .retry(let reason):
        await publish(.connecting(attempt: attempt + 1, lastError: reason), id)
        if skipBackoff {
          skipBackoff = false
        } else {
          let base = min(maxBackoff, Duration.seconds(1) * (1 << min(failures, 16)))
          failures += 1
          await wait(base * min(max(jitter(), 0), 1), id)
        }
      }
    }
  }

  private func wait(_ delay: Duration, _ id: Int) async {
    let clock = clock
    let sleeper = Task { _ = try? await clock.sleep(for: delay) }
    backoffSleeper = sleeper
    await withTaskCancellationHandler {
      await sleeper.value
    } onCancel: {
      sleeper.cancel()
    }
    if runID == id { backoffSleeper = nil }
  }

  private func publish(_ new: RelayLinkState, _ id: Int) async {
    guard runID == id else { return }
    state = new
    await onState(new)
  }

  /// One connection: token, open, then read until it ends.
  private func connectOnce(_ id: Int) async -> Outcome {
    let token: String?
    do {
      token = try await tokenProvider()
    } catch {
      return .retry("token unavailable")
    }
    guard let token, !token.isEmpty else { return .stop("unauthorized") }

    let socket: any HubLinkSocket
    do {
      socket = try await connection.open(url: url, token: token, protocolVersion: Self.protocolVersion)
    } catch HubLinkError.refused(let status) where status == 401 {
      return .stop("unauthorized")
    } catch {
      return .retry(Self.describe(error))
    }
    guard runID == id, !Task.isCancelled else {
      socket.close(code: 1000)
      return .retry("cancelled")
    }

    self.socket = socket
    endReason = nil
    armWatchdog(id)
    let outcome = await read(socket, id)
    socket.close(code: 1000)
    if runID == id { teardown() }
    return outcome
  }

  private func read(_ socket: any HubLinkSocket, _ id: Int) async -> Outcome {
    while true {
      let message: RelayMessage
      do {
        message = try await socket.receive()
      } catch HubLinkError.undecodable {
        // A frame from a newer hub: it still proves the link is alive.
        armWatchdog(id)
        continue
      } catch {
        return ended(by: error)
      }
      guard runID == id else { return .retry("cancelled") }
      armWatchdog(id)

      switch message {
      case .hello(_, _, _, let role, _, let hubTime):
        noteHubTime(hubTime)
        if !connected {
          connected = true
          reachedHello = true
          startTimers(id)
          await publish(.connected(since: Date(), role: role), id)
        }
      case .pong(let hubTime):
        noteHubTime(hubTime)
        continue
      case .error(let code, _, _):
        if code == "link_replaced" {
          await onMessage(message)
          return .stop("replaced")
        }
        if code == "client_too_old" {
          await onMessage(message)
          return .stop("client_too_old")
        }
      default:
        break
      }
      await onMessage(message)
    }
  }

  /// What a failed `receive` means: a stop for the hub's terminal close codes, a retry for the rest.
  private func ended(by error: any Error) -> Outcome {
    if let endReason { return .retry(endReason) }
    if case HubLinkError.closed(let code) = error {
      switch code {
      case 4000: return .stop("replaced")
      case 4001: return .stop("revoked")
      case 4002: return .stop("client_too_old")
      default: break
      }
    }
    return .retry(Self.describe(error))
  }

  private static func describe(_ error: any Error) -> String {
    switch error {
    case HubLinkError.refused(let status): return "refused (\(status))"
    case HubLinkError.closed(let code): return "closed (\(code))"
    case HubLinkError.failed(let message): return message
    case is CancellationError: return "cancelled"
    default: return "connection failed"
    }
  }

  // MARK: - Heartbeat and clock

  private func startTimers(_ id: Int) {
    let clock = clock
    heartbeat = Task {
      while !Task.isCancelled {
        do { try await clock.sleep(for: .seconds(RelayLimits.heartbeatSeconds)) } catch { return }
        await self.sendPing(id)
      }
    }
    stable = Task {
      do { try await clock.sleep(for: .seconds(60)) } catch { return }
      self.markStable(id)
    }
  }

  private func sendPing(_ id: Int) async {
    guard runID == id, let socket else { return }
    try? await socket.send(.ping)
  }

  private func markStable(_ id: Int) {
    guard runID == id, connected else { return }
    reachedStable = true
  }

  /// Restarts the 30 s silence timer; called for every frame.
  private func armWatchdog(_ id: Int) {
    watchdog?.cancel()
    let clock = clock
    watchdog = Task {
      do { try await clock.sleep(for: RelayLimits.deadLink) } catch { return }
      self.linkWentSilent(id)
    }
  }

  private func linkWentSilent(_ id: Int) {
    guard runID == id, !Task.isCancelled, let socket else { return }
    endReason = "silent"
    socket.close(code: 1000)
  }

  private func noteHubTime(_ hubTime: String) {
    guard let date = Self.parse(hubTime) else { return }
    hubOffset = date.timeIntervalSinceNow
  }

  private static func parse(_ string: String) -> Date? {
    if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
      return date
    }
    return try? Date(string, strategy: Date.ISO8601FormatStyle())
  }

  /// Drops the live link's state and timers.
  private func teardown() {
    heartbeat?.cancel()
    watchdog?.cancel()
    stable?.cancel()
    heartbeat = nil
    watchdog = nil
    stable = nil
    connected = false
    socket?.close(code: 1000)
    socket = nil
  }
}
