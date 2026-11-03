import Foundation
import Synchronization
import WorkspaceProtocol
import WorkspaceSync

/// The phone's side of the relay (M8c): its own `RelayLink` to the hub, the commands the phone sends
/// through it, the threads it watches, and what the hub sends back, fanned out to subscribers.
///
/// - Commands: `command(id:method:params:)` sends one frame and waits for its reply up to the phone's
///   wait for that method (`wait(for:)`). A frame larger than a client may send is refused before
///   anything is sent. A command that was sent but never answered (no reply in time, or the link
///   dropped first) is `relay_timeout` "Not confirmed…", never retried here: a caller may resend the
///   same id while the Mac's idempotency covers it.
/// - Watching: the watched set survives reconnects and `stop()`/`start()`; every new link sends it again
///   (the hub forgets a link's watches when it closes). A watch the hub refuses (an `error` frame naming
///   its `threadId`) is a gap for that thread; one refused for a reason that may pass is sent again after
///   a pause, a few times.
/// - Updates: link changes, presence (with `lastSeenAt` moved onto this device's clock), relayed events,
///   and gaps (a `stream_gap`, or the link dropping while threads were watched), in the order they
///   happened. Each subscriber first gets the current link state and, while connected, the latest
///   presence. `updates()` subscribes synchronously, so a subscriber made before an update is never
///   too late for it.
///
/// Never logs: params, results, and event content stay out of every log line. Call `stop()` when done.
public actor MirrorRelay {
  public enum Update: Sendable, Equatable {
    case link(RelayLinkState)
    case presence([RelayHostPresence])
    case event(AdapterEvent)
    /// Events for this thread may have been lost.
    case gap(threadId: String)
  }

  /// A command's outcome: the Mac's result, or why there is none.
  public typealias Reply = Result<JSONValue, WorkspaceError>

  /// The largest encoded `command` frame the phone sends: a client frame, less room for the hub's
  /// framing.
  public static let maxCommandBytes = RelayLimits.clientFrameMax - 1_024
  public static let tooLong = "This message is too long to send from the phone."
  public static let notConfirmed = "Not confirmed: your Mac may not have received this."
  public static let notConnected = "Connecting to the hub…"
  /// The code of a command sent but not answered (the same as the hub's own reply timeout).
  public static let notConfirmedCode = ErrorCode.relayTimeout

  /// How long the phone waits for a reply: stop and answer may be held by the hub for an offline Mac
  /// (60 s) and then wait for the reply (15 s), so 90 s; a send or start is never held, so 30 s.
  public static func wait(for method: RelayMethod) -> Duration {
    switch method {
    case .turnInterrupt, .requestRespond: .seconds(90)
    case .turnSend, .threadStart, .turnLookup: .seconds(30)
    }
  }

  private enum Inbound: Sendable {
    case message(RelayMessage)
    case state(RelayLinkState)
  }

  private struct Waiter {
    var token: Int
    var continuation: CheckedContinuation<Reply, Never>
    var timer: Task<Void, Never>?
  }

  private let link: RelayLink
  private let clock: any Clock<Duration>
  private let inbound: AsyncStream<Inbound>
  private var pump: Task<Void, Never>?
  private var pending: [String: [Waiter]] = [:]
  private var nextToken = 0
  /// How many times each watched thread has been watched again after a refusal, since it was last
  /// watched afresh.
  private var watchRetries: [String: Int] = [:]
  /// The subscribers, with the link state and presence a new one starts from, behind a lock so that
  /// `updates()` can subscribe without suspending.
  private struct Fanout {
    var subscribers: [UUID: AsyncStream<Update>.Continuation] = [:]
    var linkState: RelayLinkState = .stopped(reason: "stopped")
    var hosts: [RelayHostPresence] = []
  }
  private let fanout = Mutex(Fanout())

  /// The link as this relay last heard it.
  public private(set) var linkState: RelayLinkState = .stopped(reason: "stopped")
  /// The threads every link watches, in the order they were asked for.
  public private(set) var watched: [String] = []
  /// The latest presence, on this device's clock; empty until the hub sends it.
  public private(set) var hosts: [RelayHostPresence] = []

  /// - Parameters:
  ///   - url: the hub's base URL; `token`: the device token, asked for on every attempt (nil stops the
  ///     link as `unauthorized`).
  ///   - clock: drives the link's backoff and heartbeat and the command waits.
  ///   - maxBackoff: the phone's reconnect cap, 15 s.
  public init(
    url: URL,
    token: @escaping @Sendable () async throws -> String?,
    connection: any HubLinkConnection = URLSessionHubLinkConnection(),
    clock: any Clock<Duration> = ContinuousClock(),
    maxBackoff: Duration = .seconds(15),
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    let (stream, continuation) = AsyncStream.makeStream(of: Inbound.self)
    inbound = stream
    self.clock = clock
    link = RelayLink(
      url: url, token: token, connection: connection, maxBackoff: maxBackoff, clock: clock, jitter: jitter,
      onMessage: { continuation.yield(.message($0)) }, onState: { continuation.yield(.state($0)) })
  }

  // MARK: - Control

  /// Opens the link (and keeps reopening it). Does nothing while running.
  public func start() async {
    if pump == nil {
      let inbound = inbound
      pump = Task { [weak self] in
        for await item in inbound {
          guard let self else { return }
          await self.handle(item)
        }
      }
    }
    await link.start()
  }

  /// Closes the link until the next `start()`. Pending commands become "not confirmed"; the watched
  /// set is kept for the next link.
  public func stop() async {
    await link.stop()
  }

  /// Skips a backoff wait, or reopens a live link at once.
  public func reconnectNow() async {
    await link.reconnectNow()
  }

  public var isConnected: Bool {
    if case .connected = linkState { return true }
    return false
  }

  /// Commands waiting for a reply.
  var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }

  // MARK: - Updates

  /// A new stream of updates, starting with the current link state and, while connected, the latest
  /// presence. Subscribed when this returns (it does not suspend), so every later update reaches it.
  /// It ends when the caller stops iterating.
  public nonisolated func updates() -> AsyncStream<Update> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
    continuation.onTermination = { [weak self] _ in
      _ = self?.fanout.withLock { $0.subscribers.removeValue(forKey: id) }
    }
    fanout.withLock { fanout in
      continuation.yield(.link(fanout.linkState))
      if case .connected = fanout.linkState, !fanout.hosts.isEmpty {
        continuation.yield(.presence(fanout.hosts))
      }
      fanout.subscribers[id] = continuation
    }
    return stream
  }

  /// Sends `update` to every subscriber, recording the link state and presence it carries for the
  /// next subscriber in the same step.
  private func broadcast(_ update: Update) {
    fanout.withLock { fanout in
      switch update {
      case .link(let state): fanout.linkState = state
      case .presence(let hosts): fanout.hosts = hosts
      case .event, .gap: break
      }
      for continuation in fanout.subscribers.values { continuation.yield(update) }
    }
  }

  // MARK: - Watching

  public func watch(_ threadId: String) async {
    guard !watched.contains(threadId) else { return }
    watched.append(threadId)
    watchRetries[threadId] = nil
    try? await sendIfConnected(.watch(threadId: threadId))
  }

  public func unwatch(_ threadId: String) async {
    guard watched.contains(threadId) else { return }
    watched.removeAll { $0 == threadId }
    try? await sendIfConnected(.unwatch(threadId: threadId))
  }

  /// Gives back the watch the hub took for this link when it routed a `thread.start` for `threadId`
  /// (its auto-watch), after the Mac refused that start: no thread was made, and the watch would keep
  /// one of the link's four. A thread this relay watches itself is left alone.
  public func releaseAutoWatch(_ threadId: String) async {
    guard !watched.contains(threadId) else { return }
    try? await sendIfConnected(.unwatch(threadId: threadId))
  }

  /// Watches `threadId` and nothing else (the phone shows one thread at a time). Unwatches first, so
  /// the hub's limit of four is never reached on the way.
  public func watchOnly(_ threadId: String?) async {
    for other in watched where other != threadId { await unwatch(other) }
    if let threadId { await watch(threadId) }
  }

  private func sendIfConnected(_ message: RelayMessage) async throws {
    guard isConnected else { return }
    try await link.send(message)
  }

  // MARK: - Commands

  /// Sends one command and waits for its reply, up to `wait(for: method)`. Never throws: every outcome
  /// is a result, and the hub's or the Mac's error keeps its code and details.
  public func command(id: String, method: RelayMethod, params: JSONValue) async -> Reply {
    let frame = RelayMessage.command(id: id, method: method, params: params)
    guard let encoded = try? JSONEncoder().encode(frame) else {
      return .failure(WorkspaceError(.protocolInvalid, "This message could not be encoded."))
    }
    guard encoded.count <= Self.maxCommandBytes else {
      return .failure(
        WorkspaceError(
          .protocolInvalid, Self.tooLong,
          details: ["reason": "too_long", "maxBytes": .number(Double(Self.maxCommandBytes))]))
    }
    guard isConnected else { return .failure(Self.notSent) }
    nextToken += 1
    let token = nextToken
    let wait = Self.wait(for: method)
    return await withCheckedContinuation { continuation in
      let clock = clock
      let timer = Task { [weak self] in
        do { try await clock.sleep(for: wait) } catch { return }
        await self?.resolve(id: id, token: token, with: .failure(Self.unconfirmed("timeout")))
      }
      pending[id, default: []].append(Waiter(token: token, continuation: continuation, timer: timer))
      Task { await self.transmit(frame, id: id, token: token) }
    }
  }

  private func transmit(_ frame: RelayMessage, id: String, token: Int) async {
    do {
      try await link.send(frame)
    } catch HubLinkError.notConnected {
      resolve(id: id, token: token, with: .failure(Self.notSent))
    } catch {
      resolve(id: id, token: token, with: .failure(Self.unconfirmed("send_failed")))
    }
  }

  /// Answers one waiter (`token`), or every waiter for `id` when `token` is nil.
  private func resolve(id: String, token: Int?, with result: Reply) {
    guard var waiters = pending[id] else { return }
    let answered = waiters.filter { token == nil || $0.token == token }
    waiters.removeAll { token == nil || $0.token == token }
    pending[id] = waiters.isEmpty ? nil : waiters
    for waiter in answered {
      waiter.timer?.cancel()
      waiter.continuation.resume(returning: result)
    }
  }

  private static var notSent: WorkspaceError {
    WorkspaceError(
      .endpointUnavailable, notConnected, details: ["reason": "not_connected", "sent": false])
  }

  private static func unconfirmed(_ reason: String) -> WorkspaceError {
    WorkspaceError(notConfirmedCode, notConfirmed, details: ["reason": .string(reason), "local": true])
  }

  // MARK: - Inbound

  private func handle(_ item: Inbound) async {
    switch item {
    case .state(let state): await linkChanged(state)
    case .message(let message): await receive(message)
    }
  }

  private func linkChanged(_ state: RelayLinkState) async {
    let wasConnected = isConnected
    linkState = state
    broadcast(.link(state))
    if case .connected = state {
      watchRetries = [:]
      for threadId in watched { try? await link.send(.watch(threadId: threadId)) }
    } else if wasConnected {
      for id in Array(pending.keys) {
        resolve(id: id, token: nil, with: .failure(Self.unconfirmed("link_dropped")))
      }
      for threadId in watched { broadcast(.gap(threadId: threadId)) }
    }
  }

  private func receive(_ message: RelayMessage) async {
    switch message {
    case .reply(let id, let result, let error):
      if let error {
        resolve(id: id, token: nil, with: .failure(error.workspaceError))
      } else if let result {
        resolve(id: id, token: nil, with: .success(result))
      } else {
        resolve(
          id: id, token: nil, with: .failure(WorkspaceError(.protocolInvalid, "The hub sent an empty reply."))
        )
      }
    case .event(let event):
      broadcast(.event(event))
    case .streamGap(let threadId):
      broadcast(.gap(threadId: threadId))
    case .presence(let presence):
      let offset = (await link.hubNow()).map { $0.timeIntervalSinceNow } ?? 0
      hosts = presence.map { host in
        var local = host
        if let seen = host.lastSeenAt.flatMap(Self.parse) {
          local.lastSeenAt = Timestamp.string(from: seen.addingTimeInterval(-offset))
        }
        return local
      }
      broadcast(.presence(hosts))
    case .error(let code, _, let details):
      // A refused watch names its thread; the other `error` frames concern the link, which handles
      // the ones that end it.
      guard case .object(let object)? = details, case .string(let threadId)? = object["threadId"],
        watched.contains(threadId)
      else { break }
      watchRefused(threadId, code: code)
    case .hello, .ping, .pong, .command, .watch, .unwatch, .watching:
      break
    }
  }

  /// The refusals a later watch may get past: a passing failure, or a thread the hub has not seen yet
  /// (just started on the Mac, not yet synced).
  private static let retriedWatchRefusals: Set<String> = ["internal_error", ErrorCode.notFound.rawValue]
  private static let watchRetryLimit = 3
  private static let watchRetryPause: Duration = .seconds(2)

  /// The hub refused the watch of `threadId`: its live events are not coming, so subscribers hear a gap
  /// (and wait for sync); a refusal that may pass is retried after `watchRetryPause` times the attempt.
  private func watchRefused(_ threadId: String, code: String) {
    broadcast(.gap(threadId: threadId))
    guard Self.retriedWatchRefusals.contains(code) else { return }
    let attempt = watchRetries[threadId, default: 0] + 1
    guard attempt <= Self.watchRetryLimit else { return }
    watchRetries[threadId] = attempt
    let clock = clock
    Task { [weak self] in
      do { try await clock.sleep(for: Self.watchRetryPause * attempt) } catch { return }
      await self?.watchAgain(threadId)
    }
  }

  private func watchAgain(_ threadId: String) async {
    guard watched.contains(threadId) else { return }
    try? await sendIfConnected(.watch(threadId: threadId))
  }

  private static func parse(_ text: String) -> Date? {
    if let date = Timestamp.date(from: text) { return date }
    return try? Date(text, strategy: Date.ISO8601FormatStyle())
  }
}
