import Foundation
import Network
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

/// Tells `HubLink` that the network path has become usable, so a link that died with the old path is
/// reopened at once instead of after its backoff. `NWPathMonitorSignal` is the real one.
public protocol NetworkPathMonitoring: Sendable {
  /// Calls `onSatisfied` on every later path change whose status is `.satisfied` (not for the path
  /// current when monitoring starts).
  func start(onSatisfied: @escaping @Sendable () async -> Void)
  func stop()
}

/// `NetworkPathMonitoring` over `NWPathMonitor`.
public final class NWPathMonitorSignal: NetworkPathMonitoring, Sendable {
  private struct State {
    var monitor: NWPathMonitor?
    /// Changes on every start, so a cancelled monitor's late update is ignored.
    var run = 0
    /// The status and interfaces last seen; nil until the first update, which is the current path.
    var last: String?
  }

  private let state = Mutex(State())
  private let queue = DispatchQueue(label: "b4app.hub-link.path")

  public init() {}

  public func start(onSatisfied: @escaping @Sendable () async -> Void) {
    let monitor = NWPathMonitor()
    let (run, replaced) = state.withLock { state -> (Int, NWPathMonitor?) in
      let replaced = state.monitor
      state.run += 1
      state.last = nil
      state.monitor = monitor
      return (state.run, replaced)
    }
    replaced?.cancel()
    monitor.pathUpdateHandler = { [weak self] update in
      guard let self else { return }
      let seen = "\(update.status) \(update.availableInterfaces.map(\.name))"
      let changedToSatisfied = self.state.withLock { state -> Bool in
        guard state.run == run else { return false }
        defer { state.last = seen }
        guard let previous = state.last else { return false }
        return previous != seen && update.status == .satisfied
      }
      if changedToSatisfied { Task { await onSatisfied() } }
    }
    monitor.start(queue: queue)
  }

  public func stop() {
    let monitor = state.withLock { state -> NWPathMonitor? in
      defer {
        state.monitor = nil
        state.run += 1
      }
      return state.monitor
    }
    monitor?.cancel()
  }
}

/// The Mac's relay link to the hub (M8c), started and stopped by `HubSync`: it holds a `RelayLink`
/// (WebSocket, heartbeat, backoff, hub clock), runs each relayed command through `RelayExecutor` in its
/// own task, and streams the live events of the threads some client watches.
///
/// - **Commands** run concurrently and never hold up the link: the reply is sent when the command ends.
///   The deadline is judged on the hub's clock (`RelayLink.hubNow()`, ruling R1); a command with no
///   readable deadline is treated as expired.
/// - **Events** come from the coordinator's `EventLog`. One is sent only when its thread is in the
///   latest `watching` set, its kind is in `RelayLimits.forwardedEventKinds` (the hub does not filter),
///   and its encoded `event` frame fits in `RelayLimits.hostFrameMax`; a larger one arrives by sync.
/// - **Catch-up.** For every active turn (watched or not) the text of each started, uncompleted message
///   item is kept from its `message.delta`s, and dropped on `message.completed` and `turn.finished`.
///   A thread that enters the watched set first gets one `message.delta` per open item carrying the
///   whole text so far, then its live events. Both are queued on this actor without suspending, and
///   one task sends the queue in order, so a live delta can neither overtake nor repeat the catch-up.
/// - A new link starts with nothing watched: the hub's `watching` after `hello` catches every watched
///   thread up again, and events queued for an earlier link are not sent on the new one.
/// - **Reconnects** at once on `reconnectNow()` (the wake signal) and on a network path change.
///   A 401 stops the link until the next join, as `HubSync` suspends its pushes.
///
/// Never logs a token, params, results, or event content.
public actor HubLink {
  /// A message item that has started and not completed, with its text so far.
  private struct OpenItem {
    var itemId: String
    /// The item's latest delta, the shape of the catch-up event.
    var template: AdapterEvent
    var text: String
  }

  /// A frame waiting for the sender. `generation` is the link an event belongs to; replies have none
  /// and go out on whichever link is up.
  private struct Outbound: Sendable {
    var message: RelayMessage
    var generation: Int?
  }

  private static let forwarded = Set(RelayLimits.forwardedEventKinds)

  private let url: URL
  private let token: @Sendable () async throws -> String?
  private let executor: RelayExecutor
  private let eventLog: EventLog
  private let connection: any HubLinkConnection
  private let clock: any Clock<Duration>
  private let jitter: @Sendable () -> Double
  private let pathMonitor: (any NetworkPathMonitoring)?
  private let logger = Log.logger("hub-link")

  private var relay: RelayLink?
  private var running = false
  /// Changes on every `start` and `stop`, so a `start` that a `stop` overtook while it was suspended
  /// leaves nothing running.
  private var epoch = 0
  private var eventTask: Task<Void, Never>?
  private var senderTask: Task<Void, Never>?
  private var outbox: AsyncStream<Outbound>.Continuation?
  /// Counts the links that reached `hello`; the current one is up while `linkUp`.
  private var generation = 0
  private var linkUp = false
  /// The threads some client watches, from the latest `watching` on the current link.
  private(set) var watchedThreads: Set<String> = []
  /// Open message items by thread, in the order they started.
  private var open: [String: [OpenItem]] = [:]
  private var current = HubLinkStatus(state: .offline)

  /// - Parameters:
  ///   - url: the hub's base URL; `token`: the device token (`HubToken`'s value), asked for on every
  ///     attempt, never read here from the Keychain.
  ///   - jitter: scales each backoff delay (0...1); tests fix it.
  ///   - pathMonitor: path changes that reconnect at once; nil for none.
  public init(
    url: URL, token: @escaping @Sendable () async throws -> String?, executor: RelayExecutor,
    eventLog: EventLog, connection: any HubLinkConnection, clock: any Clock<Duration> = ContinuousClock(),
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    pathMonitor: (any NetworkPathMonitoring)? = nil
  ) {
    self.url = url
    self.token = token
    self.executor = executor
    self.eventLog = eventLog
    self.connection = connection
    self.clock = clock
    self.jitter = jitter
    self.pathMonitor = pathMonitor
  }

  // MARK: - Control

  /// Subscribes to the event log and starts connecting. Does nothing while running.
  public func start() async {
    guard !running else { return }
    running = true
    epoch += 1
    let started = epoch
    let relay =
      self.relay
      ?? RelayLink(
        url: url, token: token, connection: connection, clock: clock, jitter: jitter,
        onMessage: { [weak self] message in await self?.received(message) },
        onState: { [weak self] state in await self?.changed(state) })
    self.relay = relay

    let (frames, outbox) = AsyncStream<Outbound>.makeStream()
    self.outbox = outbox
    senderTask = Task { [weak self] in
      for await frame in frames {
        guard let self else { return }
        await self.send(frame, via: relay)
      }
    }
    let events = await eventLog.subscribe()
    // A stop while subscribing has torn down what was set up above; dropping `events` unsubscribes.
    guard epoch == started else { return }
    eventTask = Task { [weak self] in
      for await envelope in events {
        guard let self else { return }
        await self.observe(envelope.event)
      }
    }
    pathMonitor?.start { [weak self] in await self?.reconnectNow() }
    await relay.start()
    // A stop that ran while the start was on its way to the link must not leave it running (unless a
    // later start owns it now).
    if epoch != started, !running { await relay.stop() }
  }

  /// Closes the link and ends the subscription. A relayed command still running finishes, and its
  /// reply is dropped.
  public func stop() async {
    guard running else { return }
    running = false
    epoch += 1
    // Everything but the link's own stop happens before suspending, so a `start` arriving meanwhile
    // sets up afresh instead of having its new tasks torn down here.
    pathMonitor?.stop()
    eventTask?.cancel()
    eventTask = nil
    outbox?.finish()
    outbox = nil
    senderTask?.cancel()
    senderTask = nil
    watchedThreads = []
    open = [:]
    linkUp = false
    await relay?.stop()
  }

  /// Reopens the link now (after a wake or a network change), skipping any backoff wait.
  public func reconnectNow() async {
    guard running else { return }
    logger.info("reconnecting to the hub now")
    await relay?.reconnectNow()
  }

  public func status() -> HubLinkStatus { current }

  /// The open message items' text so far, by item id (for tests).
  func openText(threadId: String) -> [String: String] {
    Dictionary((open[threadId] ?? []).map { ($0.itemId, $0.text) }, uniquingKeysWith: { $1 })
  }

  // MARK: - From the hub

  private func received(_ message: RelayMessage) async {
    switch message {
    case .command(let id, let method, let params, let deadline, _):
      let due = deadline.flatMap(Self.date(from:)) ?? .distantPast
      let executor = executor
      let relay = relay
      Task { [weak self] in
        // The hub's clock (R1: nil only before a hello), read just before running, so time spent
        // getting here counts against the deadline.
        let hubNow = await relay?.hubNow() ?? Date()
        let reply = await executor.execute(
          id: id, method: method, params: params, deadline: due, hubNow: hubNow)
        await self?.enqueue(reply, generation: nil)
      }
    case .watching(let threadIds):
      watch(threadIds)
    case .error(let code, _, _):
      logger.warning("the hub reported \(code, privacy: .public) on the link")
    default:
      break
    }
  }

  /// Takes the hub's new watched set; each newly watched thread gets its open text first.
  private func watch(_ threadIds: [String]) {
    guard linkUp else { return }
    let previous = watchedThreads
    watchedThreads = Set(threadIds)
    for threadId in threadIds where !previous.contains(threadId) {
      for item in open[threadId] ?? [] {
        var catchUp = item.template
        catchUp.payload = ["delta": .string(item.text)]
        forward(catchUp)
      }
    }
  }

  private func changed(_ state: RelayLinkState) {
    let now = Timestamp.now()
    switch state {
    case .connecting(_, let lastError):
      linkUp = false
      watchedThreads = []
      let since = current.state == .connecting ? current.since : now
      current = HubLinkStatus(state: .connecting, since: since, lastError: lastError)
    case .connected(let since, _):
      generation += 1
      linkUp = true
      watchedThreads = []
      current = HubLinkStatus(state: .connected, since: Timestamp.string(from: since))
      logger.info("linked to the hub")
    case .stopped(let reason):
      linkUp = false
      watchedThreads = []
      current = HubLinkStatus(state: .offline, since: now, lastError: Self.describe(stopped: reason))
      if reason != "stopped" { logger.warning("the hub link stopped: \(reason, privacy: .public)") }
    }
  }

  // MARK: - To the hub

  private func observe(_ event: AdapterEvent) {
    guard let threadId = event.threadId else { return }
    switch event.kind {
    case .messageDelta:
      if let itemId = event.nativeIds["itemId"], let delta = event.payload["delta"]?.stringValue {
        var items = open[threadId] ?? []
        if let index = items.firstIndex(where: { $0.itemId == itemId }) {
          items[index].text += delta
          items[index].template = event
        } else {
          items.append(OpenItem(itemId: itemId, template: event, text: delta))
        }
        open[threadId] = items
      }
    case .messageCompleted:
      let itemId =
        event.nativeIds["itemId"]
        ?? (try? event.payload["displayItem"]?.decode(DisplayItem.self))?.nativeItemId
      if let itemId, var items = open[threadId] {
        items.removeAll { $0.itemId == itemId }
        open[threadId] = items.isEmpty ? nil : items
      }
    case .turnFinished:
      open[threadId] = nil
    default:
      break
    }
    guard Self.forwarded.contains(event.kind), linkUp, watchedThreads.contains(threadId) else { return }
    forward(event)
  }

  /// Queues an event for the current link when its frame fits.
  private func forward(_ event: AdapterEvent) {
    let message = RelayMessage.event(event)
    guard let size = try? JSONEncoder().encode(message).count, size <= RelayLimits.hostFrameMax else {
      logger.debug("skipped an oversized \(event.kind.rawValue, privacy: .public) event")
      return
    }
    enqueue(message, generation: generation)
  }

  private func enqueue(_ message: RelayMessage, generation: Int?) {
    outbox?.yield(Outbound(message: message, generation: generation))
  }

  /// Sends one queued frame; an event queued for an earlier link is dropped. A frame the link cannot
  /// take (it is down) is dropped too: the phone recovers through sync and `turn.lookup`.
  private func send(_ frame: Outbound, via relay: RelayLink) async {
    if let generation = frame.generation, generation != self.generation || !linkUp { return }
    do {
      try await relay.send(frame.message)
    } catch {
      logger.debug("a frame for the hub was dropped: the link is down")
    }
  }

  // MARK: - Helpers

  private static func date(from string: String) -> Date? {
    if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
      return date
    }
    return try? Date(string, strategy: Date.ISO8601FormatStyle())
  }

  /// Why the link stopped, as `hub status` shows it; nil for a stop this Mac asked for.
  private static func describe(stopped reason: String) -> String? {
    switch reason {
    case "stopped": nil
    case "unauthorized": "The hub refused this Mac's token; leave the hub and join it again."
    case "revoked": "This Mac was removed from the hub; leave the hub and join it again."
    case "replaced": "Another link from this Mac took over."
    case "client_too_old": "The hub needs a newer version of Agent Workspace."
    default: reason
    }
  }
}
