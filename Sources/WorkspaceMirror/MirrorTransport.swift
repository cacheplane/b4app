import Foundation
import Synchronization
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

/// An in-process `WorkspaceTransport` that answers the read commands from a `MirrorStore`, so the
/// shared `WorkspaceModel` runs over the mirror exactly as it runs over the coordinator's socket.
///
/// Single use: it delivers one `HelloEnvelope` (a fresh epoch, sequence 0) and serves one
/// `WorkspaceClient`; a reconnect makes a new transport over the same store. `publish(_:)` turns an
/// applied batch into events in this transport's epoch, numbered one after another.
///
/// The phone's own edits (M8b: `thread.update`, `thread.markRead`, `draft.save`, `project.rename`) go to
/// the store, which applies them at once and queues them for the hub; each announces itself with an
/// event like the Mac's coordinator does, then `onLocalWrite` is called so the host can wake the
/// uploader. Everything else the phone cannot do answers `unsupported_capability` "… is done on the Mac."
///
/// With a `MirrorRelay` (M8c), `turn.send`, `turn.interrupt`, `request.respond`, `thread.start`, and
/// `turn.lookup` go to the Mac through the hub: `turn.send` and `thread.start` use the envelope's
/// `operationId` as the relay id (the Mac's idempotency key), the others a fresh one. The transport
/// watches the thread read last, and only that one. Relayed events are re-emitted in this transport's
/// epoch and change only the on-screen model, never the mirror:
/// - a `message.delta` for an item the mirror holds as final, or that a relayed completion already
///   ended, is dropped;
/// - a gap (`stream_gap`, or the link dropping) ends the live text of the thread's open messages with a
///   `message.completed` carrying the item as last known, and their later deltas are dropped until the
///   item completes (the phone waits for sync);
/// - what the relayed events said about the open thread (items, turns, pending requests) is kept in
///   memory and merged into `thread.read` until the synced rows catch up, so a re-read never loses an
///   item still streaming;
/// - a synced row of a message still streaming is announced as `message.started`, so its live text
///   keeps going until the relayed completion arrives.
///
/// A started thread whose row has not reached the mirror is answered by a placeholder held in memory:
/// the thread from the Mac's reply, with what its relayed events said. Until the first read, its events
/// are held (up to 256), and its streamed text is handed over with the next delta. The synced row
/// replaces it; with no row after 2 minutes it is dropped and the read answers `not_found`.
///
/// Presence and the phone's own link reach the model as `host.presence` events (see
/// `AdapterEvent.hostPresence`): one per Mac on every presence frame, and one with no host whenever the
/// link's phase changes.
public final class MirrorTransport: WorkspaceTransport {
  public let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let store: MirrorStore
  private let version: String
  private let onLocalWrite: (@Sendable () -> Void)?
  private let unavailable: String?
  private let relay: MirrorRelay?
  private let now: @Sendable () -> ContinuousClock.Instant
  /// The thread to watch, in the order threads are read; one task sends them to the relay.
  private let watchTargets: AsyncStream<String>.Continuation?
  private let tasks = Mutex<[Task<Void, Never>]>([])
  private let epoch = UUID().uuidString
  private let startedAt = Timestamp.now()
  /// Sequence, the last thread read, and closure. Responses and events are yielded while it is held,
  /// so the stream's order is the sequence order and a snapshot's sequence matches what preceded it.
  private let state = Mutex(State())

  private struct State {
    var sequence = 0
    var lastReadThreadId: String?
    var closed = false
    /// Set by a command that changed the store, read once the command has been answered.
    var wrote = false
    /// What relayed events said about the open thread and about started threads, by thread id.
    var overlays: [String: Overlay] = [:]
    /// Started threads whose row is not in the mirror yet, by thread id.
    var placeholders: [String: Placeholder] = [:]
    /// The phone's hub link as last announced.
    var link: HubLinkStatus.State = .offline
  }

  /// Relayed state of one thread, kept in memory until the synced rows catch up.
  struct Overlay {
    var connectionId = ""
    /// Items by id, and whether a relayed completion carried them.
    var items: [String: (item: DisplayItem, completed: Bool)] = [:]
    var turns: [String: Turn] = [:]
    /// Pending requests a relayed `runtime_request.opened` announced.
    var requests: [String: RuntimeRequest] = [:]
    /// Requests a relayed event resolved or expired.
    var resolved: Set<String> = []
    /// Native item ids whose deltas reached the model since their item last completed.
    var open: Set<String> = []
    /// Native item ids whose live text a gap ended; their deltas are dropped until they complete.
    var muted: Set<String> = []
    /// Native item ids a relayed `message.completed` or `tool.completed` ended.
    var completed: Set<String> = []
    /// Text streamed before the thread was first read, handed over with the item's next delta.
    var owed: [String: String] = [:]
  }

  struct Placeholder {
    /// The thread from the Mac's reply; nil until `thread.start` is accepted.
    var thread: ConversationThread?
    var expires: ContinuousClock.Instant
    /// Whether the thread has been read; until then its events are held.
    var read = false
    var held = 0
  }

  /// How long a started thread's placeholder waits for its row.
  static let placeholderLifetime = Duration.seconds(120)
  /// The most events held for a started thread before its first read.
  static let placeholderEvents = 256

  /// The phone's commands the relay carries to the Mac.
  static let relayed: [WorkspaceProtocol.Method: RelayMethod] = [
    .turnSend: .turnSend, .turnInterrupt: .turnInterrupt, .requestRespond: .requestRespond,
    .threadStart: .threadStart, .turnLookup: .turnLookup,
  ]

  /// The methods the mirror answers; every other one is refused.
  static let served: Set<WorkspaceProtocol.Method> = [
    .systemPing, .eventsSnapshot, .eventsReplay, .connectionList, .threadList, .threadRead, .draftRead,
    .serverList, .workspaceActiveWork, .diagnosticsRead, .projectList, .projectRename, .threadUpdate,
    .threadMarkRead, .draftSave,
  ]

  /// The methods the phone leaves to the Mac, whose projects it only reads and renames.
  static let macOnly: Set<WorkspaceProtocol.Method> = [.projectCreate, .projectUpdate, .projectDelete]

  static let macRefusal = "Creating, editing folders of, and deleting projects is done on the Mac."

  /// Why the phone does not do `method`: "… is done on the Mac."
  static func refusal(for method: WorkspaceProtocol.Method) -> String {
    switch method {
    case .projectCreate, .projectUpdate, .projectDelete:
      return macRefusal
    case .turnSend, .turnInterrupt, .requestRespond, .threadStart, .turnLookup:
      return "Chatting before this iPhone is linked to the hub is done on the Mac."
    case .threadCreate:
      return "Starting a thread outside a project is done on the Mac."
    case .turnAbandon, .threadReconcile, .workspaceReconcile, .workspaceStopLocalWork:
      return "Recovering and stopping local work is done on the Mac."
    case .connectionAdd, .connectionInspect, .connectionLogin, .credentialAdd:
      return "Setting up connections is done on the Mac."
    case .serverAdd, .serverStart, .serverStatus, .serverLogs, .serverRestart, .serverStop, .serverInspect:
      return "Running local servers is done on the Mac."
    case .databaseStatus, .databaseBackup, .databaseRestore, .databaseImportSQLite:
      return "Managing the workspace database is done on the Mac."
    case .hubJoin, .hubStatus, .hubLeave, .hubPair, .hubPairStatus, .settingsRead, .settingsUpdate:
      return "Managing the hub and the Mac's settings is done on the Mac."
    default:
      return "This is done on the Mac."
    }
  }

  /// `onLocalWrite` is called (outside the transport's lock, so it must only hand off) after each
  /// command that wrote to the store; the host uses it to wake the uploader.
  ///
  /// `unavailable` is for a host whose real mirror cannot be used (it holds unsent edits in a schema
  /// this build cannot read): the transport answers reads from `store`, refuses every write with the
  /// reason, and lists the reason in Diagnostics.
  ///
  /// `relay` carries the phone's commands and live events (M8c); without one, those commands are
  /// refused. `now` is the monotonic clock of the placeholder's lifetime.
  public init(
    store: MirrorStore, version: String, onLocalWrite: (@Sendable () -> Void)? = nil,
    unavailable: String? = nil, relay: MirrorRelay? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    (incoming, continuation) = AsyncStream.makeStream(of: Data.self)
    self.store = store
    self.version = version
    self.onLocalWrite = onLocalWrite
    self.unavailable = unavailable
    self.relay = relay
    self.now = now
    let targets: AsyncStream<String>?
    if relay != nil {
      let (stream, targetContinuation) = AsyncStream.makeStream(of: String.self)
      targets = stream
      watchTargets = targetContinuation
    } else {
      targets = nil
      watchTargets = nil
    }
    let hello = HelloEnvelope(epoch: epoch, sequence: 0, coordinator: identity)
    if let line = try? NDJSON.encodeLine(hello) { continuation.yield(line) }
    guard let relay, let targets else { return }
    let watcher = Task {
      for await threadId in targets { await relay.watchOnly(threadId) }
    }
    let listener = Task { [weak self] in
      for await update in await relay.updates() {
        guard let self else { return }
        self.receive(update)
      }
    }
    tasks.withLock { $0 = [watcher, listener] }
  }

  public func send(_ line: Data) async throws {
    // Diagnostics read the store (link, cursor, the undecodable count) without holding the lock, so
    // they never hold up other commands or `publish`; only the sequence is read under it.
    if let command = try? parseCommand(line), command.method == .diagnosticsRead {
      let sequence = try state.withLock { state in
        guard !state.closed else { throw Self.closedError }
        return state.sequence
      }
      let response: ResponseEnvelope
      do {
        response = .success(
          command.envelope.requestId, result: try JSONValue(encoding: try diagnostics(sequence: sequence)))
      } catch {
        response = .failure(command.envelope.requestId, error: WorkspaceError.from(error))
      }
      try state.withLock { state in
        guard !state.closed else { throw Self.closedError }
        continuation.yield(try NDJSON.encodeLine(response))
      }
      return
    }
    if let relay, let command = try? parseCommand(line), let method = Self.relayed[command.method] {
      try await relayCommand(command, method: method, relay: relay)
      return
    }
    let wrote = try state.withLock { state in
      guard !state.closed else { throw Self.closedError }
      state.wrote = false
      let response = respond(to: line, state: &state)
      continuation.yield(try NDJSON.encodeLine(response))
      return state.wrote
    }
    if wrote { onLocalWrite?() }
  }

  private static var closedError: WorkspaceError {
    WorkspaceError(.endpointUnavailable, "The mirror transport is closed.")
  }

  public func close() async {
    state.withLock { state in
      state.closed = true
      continuation.finish()
    }
    watchTargets?.finish()
    for task in tasks.withLock({ $0 }) { task.cancel() }
  }

  /// Emits `connection.changed` per touched connection (its status and sign-in from the row),
  /// `project.changed` per touched project, `thread.updated` per touched thread (with the row), and `message.completed` carrying the
  /// `displayItem` for each touched item of the thread last read. Does nothing once closed.
  public func publish(_ batch: AppliedBatch) {
    var events: [AdapterEvent] = []
    let connections = (try? store.connections()) ?? []
    for connection in connections where batch.touchedConnectionIds.contains(connection.id) {
      // The phone holds no runtime connection of its own, so the transport field says so.
      events.append(
        .connectionChanged(
          connectionId: connection.id, status: connection.status, authStatus: connection.authStatus,
          transport: .disconnected))
    }
    for id in batch.touchedProjectIds.sorted() { events.append(.projectChanged(projectId: id)) }
    for id in batch.touchedThreadIds.sorted() {
      if let thread = try? store.thread(id: id), let event = try? AdapterEvent.threadUpdated(thread) {
        events.append(event)
      }
    }
    var owners: [String: String] = [:]
    for item in batch.touchedItems where owners[item.threadId] == nil {
      owners[item.threadId] = (try? store.thread(id: item.threadId))?.connectionId ?? ""
    }
    state.withLock { state in
      guard !state.closed else { return }
      // The row replaces a started thread's placeholder.
      for id in batch.touchedThreadIds where state.placeholders[id] != nil {
        if (try? store.thread(id: id)) != nil { state.placeholders[id] = nil }
      }
      var open: [AdapterEvent] = []
      for item in batch.touchedItems where item.threadId == state.lastReadThreadId {
        guard let payload = try? JSONValue(encoding: item) else { continue }
        var kind = EventKind.messageCompleted
        if let native = item.nativeItemId, state.overlays[item.threadId]?.open.contains(native) == true {
          // Still streaming: announcing it complete would end its live text early.
          if (try? store.item(threadId: item.threadId, nativeItemId: native))?.final == true {
            state.overlays[item.threadId]?.open.remove(native)
          } else {
            kind = .messageStarted
          }
        }
        open.append(
          AdapterEvent(
            kind: kind, connectionId: owners[item.threadId] ?? "", threadId: item.threadId,
            turnId: item.turnId,
            nativeIds: item.nativeItemId.map { ["itemId": $0] } ?? [:], payload: ["displayItem": payload]))
      }
      catchUp(batch, state: &state)
      emit(events + open, state: &state)
    }
  }

  /// Forgets what relayed events said once the synced rows say as much: an item the mirror holds as
  /// final (or one a relayed completion never improved on), a turn the mirror holds as new, and a
  /// request the mirror holds.
  private func catchUp(_ batch: AppliedBatch, state: inout State) {
    let threads = Set(batch.touchedItems.map(\.threadId)).union(batch.touchedThreadIds)
    for threadId in threads {
      guard var overlay = state.overlays[threadId] else { continue }
      for item in batch.touchedItems where item.threadId == threadId {
        guard let relayed = overlay.items[item.id] else { continue }
        let final = item.nativeItemId.flatMap { try? store.item(threadId: threadId, nativeItemId: $0) }?.final
        if !relayed.completed || final == true || item.nativeItemId == nil { overlay.items[item.id] = nil }
      }
      if !overlay.turns.isEmpty, let turns = try? store.turns(threadId: threadId) {
        for turn in turns {
          if let relayed = overlay.turns[turn.id], relayed.updatedAt <= turn.updatedAt {
            overlay.turns[turn.id] = nil
          }
        }
      }
      if !overlay.requests.isEmpty || !overlay.resolved.isEmpty,
        let requests = try? store.requests(threadId: threadId)
      {
        for request in requests {
          overlay.requests[request.id] = nil
          if request.state != .pending { overlay.resolved.remove(request.id) }
        }
      }
      state.overlays[threadId] = overlay
    }
  }

  // MARK: - Commands

  private var identity: CoordinatorIdentity {
    CoordinatorIdentity(version: version, pid: ProcessInfo.processInfo.processIdentifier)
  }

  private func respond(to line: Data, state: inout State) -> ResponseEnvelope {
    let requestId =
      (try? JSONCoding.decoder.decode(JSONValue.self, from: line))?["requestId"]?.stringValue ?? "unknown"
    do {
      // A write the phone cannot make is refused before `parseCommand` would ask it for an operationId.
      if let envelope = try? JSONCoding.decoder.decode(CommandEnvelope.self, from: line),
        envelope.protocolVersion == protocolVersion, envelope.kind == "command",
        let method = WorkspaceProtocol.Method(rawValue: envelope.method), !Self.served.contains(method),
        relay == nil || Self.relayed[method] == nil
      {
        throw Self.refused(method)
      }
      let command = try parseCommand(line)
      return .success(command.envelope.requestId, result: try handle(command, state: &state))
    } catch {
      return .failure(requestId, error: WorkspaceError.from(error))
    }
  }

  private func handle(_ command: ParsedCommand, state: inout State) throws -> JSONValue {
    switch command.method {
    case .systemPing:
      return try JSONValue(
        encoding: SystemPing.Result(
          epoch: epoch, sequence: state.sequence, coordinator: identity, startedAt: startedAt))
    case .eventsSnapshot:
      return try JSONValue(
        encoding: EventsSnapshot.Result(
          epoch: epoch, sequence: state.sequence, connections: try store.connections(),
          threads: try store.threads(includeArchived: true, connectionId: nil, query: nil), activeTurns: []))
    case .eventsReplay:
      // Events are never buffered: within this epoch there is nothing the client missed (each
      // client gets every event this transport emits); any other epoch needs a snapshot.
      let params = try command.params(for: EventsReplay.self)
      guard params.epoch == epoch else {
        throw WorkspaceError(
          .snapshotRequired, "Event position is no longer replayable; fetch a snapshot.",
          details: ["epoch": .string(epoch), "sequence": .number(Double(state.sequence))])
      }
      return try JSONValue(encoding: EventsReplay.Result(events: []))
    case .connectionList:
      let params = try command.params(for: ConnectionList.self)
      let all = try store.connections()
      return try JSONValue(
        encoding: ConnectionList.Result(
          connections: params.includeDisabled == true ? all : all.filter(\.enabled)))
    case .threadList:
      let params = try command.params(for: ThreadList.self)
      return try JSONValue(
        encoding: ThreadList.Result(
          threads: try store.threads(
            includeArchived: params.includeArchived ?? false, connectionId: params.connectionId,
            query: params.query)))
    case .threadRead:
      let params = try command.params(for: ThreadRead.self)
      expirePlaceholders(state: &state)
      let thread: ConversationThread
      if let stored = try store.thread(id: params.threadId) {
        thread = stored
        state.placeholders[stored.id] = nil
      } else if let placeholder = state.placeholders[params.threadId], let started = placeholder.thread {
        thread = started
        state.placeholders[started.id]?.read = true
      } else {
        throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
      }
      focus(thread.id, state: &state)
      return try JSONValue(encoding: try read(thread, overlay: state.overlays[thread.id]))
    case .draftRead:
      let params = try command.params(for: DraftRead.self)
      return try JSONValue(encoding: DraftRead.Result(draft: try store.draft(threadId: params.threadId)))
    case .serverList:
      return try JSONValue(encoding: ServerList.Result(servers: []))
    case .workspaceActiveWork:
      return try JSONValue(encoding: WorkspaceActiveWork.Result(turns: [], servers: []))
    case .projectList:
      return try JSONValue(encoding: ProjectList.Result(projects: try store.projects()))
    case .projectRename:
      try refuseWhileUnavailable()
      let params = try command.params(for: ProjectRename.self)
      guard let project = try store.renameProject(id: params.projectId, name: params.name) else {
        throw WorkspaceError(.notFound, "Project \(params.projectId) does not exist.")
      }
      state.wrote = true
      emit([.projectChanged(projectId: project.id)], state: &state)
      return try JSONValue(encoding: ProjectRename.Result(project: project))
    case .threadUpdate:
      try refuseWhileUnavailable()
      let params = try command.params(for: ThreadUpdate.self)
      guard
        let thread = try store.updateThread(
          id: params.threadId, title: params.title, pinned: params.pinned, archived: params.archived)
      else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
      state.wrote = true
      emit([try AdapterEvent.threadUpdated(thread)], state: &state)
      return try JSONValue(encoding: ThreadUpdate.Result(thread: thread))
    case .threadMarkRead:
      try refuseWhileUnavailable()
      let params = try command.params(for: ThreadMarkRead.self)
      guard let before = try store.thread(id: params.threadId),
        let after = try store.markRead(threadId: params.threadId, turnId: params.turnId)
      else { throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.") }
      state.wrote = true
      // Viewers hear about a change only, as they do from the Mac.
      if before.readTurnId != after.readTurnId {
        emit([try AdapterEvent.threadUpdated(after)], state: &state)
      }
      return try JSONValue(encoding: ThreadMarkRead.Result(thread: after))
    case .draftSave:
      try refuseWhileUnavailable()
      let params = try command.params(for: DraftSave.self)
      let draft = try store.saveDraft(threadId: params.threadId, text: params.text)
      state.wrote = true
      return try JSONValue(encoding: DraftSave.Result(draft: draft))
    default:
      // `diagnostics.read` is answered in `send`, outside the lock.
      throw Self.refused(command.method)
    }
  }

  /// The thread as the mirror holds it, with what relayed events said that the rows do not say yet.
  private func read(_ thread: ConversationThread, overlay: Overlay?) throws -> ThreadRead.Result {
    var turns = try store.turns(threadId: thread.id)
    var items = try store.items(threadId: thread.id)
    var requests = try store.requests(threadId: thread.id)
    guard let overlay else {
      return ThreadRead.Result(
        thread: thread, turns: turns, items: items, requests: requests.filter { $0.state == .pending })
    }
    let finished = Set(turns.filter { $0.status == .terminal }.map(\.id))
    for turn in overlay.turns.values {
      if let index = turns.firstIndex(where: { $0.id == turn.id }) {
        if turns[index].updatedAt < turn.updatedAt { turns[index] = turn }
      } else {
        turns.append(turn)
      }
    }
    for (item, completed) in overlay.items.values {
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        let final = items[index].turnId.map(finished.contains) ?? true
        if completed, !final { items[index] = item }
      } else {
        items.append(item)
      }
    }
    for request in overlay.requests.values where !requests.contains(where: { $0.id == request.id }) {
      requests.append(request)
    }
    turns.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    items.sort { ($0.sequence, $0.id) < ($1.sequence, $1.id) }
    requests.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    return ThreadRead.Result(
      thread: thread, turns: turns, items: items,
      requests: requests.filter { $0.state == .pending && !overlay.resolved.contains($0.id) })
  }

  /// Makes `threadId` the open thread: the one whose items are published and the one watched. The
  /// previous thread's relayed state is forgotten, unless it is a started thread still waiting for
  /// its row.
  private func focus(_ threadId: String, state: inout State) {
    guard state.lastReadThreadId != threadId else { return }
    if let previous = state.lastReadThreadId, state.placeholders[previous] == nil {
      state.overlays[previous] = nil
    }
    state.lastReadThreadId = threadId
    if state.overlays[threadId] == nil { state.overlays[threadId] = Overlay() }
    watchTargets?.yield(threadId)
  }

  private func expirePlaceholders(state: inout State) {
    let now = now()
    for (id, placeholder) in state.placeholders where placeholder.expires <= now {
      state.placeholders[id] = nil
      if (try? store.thread(id: id)) == nil { state.overlays[id] = nil }
    }
  }

  // MARK: - The relay

  /// Sends one of the phone's commands to the Mac and answers with the Mac's reply, outside the lock.
  private func relayCommand(_ command: ParsedCommand, method: RelayMethod, relay: MirrorRelay) async throws {
    let requestId = command.envelope.requestId
    try state.withLock { if $0.closed { throw Self.closedError } }
    let operationId = command.envelope.operationId.flatMap { $0.isEmpty ? nil : $0 }
    let id =
      (method == .turnSend || method == .threadStart ? operationId : nil) ?? UUID().uuidString.lowercased()
    var started: ThreadStart.Params?
    if method == .threadStart {
      do {
        started = try command.params(for: ThreadStart.self)
      } catch {
        try answer(.failure(requestId, error: WorkspaceError.from(error)))
        return
      }
    }
    if let started {
      state.withLock { state in
        guard (try? store.thread(id: started.threadId)) == nil else { return }
        if state.placeholders[started.threadId] == nil {
          state.placeholders[started.threadId] = Placeholder(
            expires: now().advanced(by: Self.placeholderLifetime))
        }
        if state.overlays[started.threadId] == nil { state.overlays[started.threadId] = Overlay() }
      }
    }
    let result = await relay.command(id: id, method: method, params: command.params)
    if let started { settle(started.threadId, result) }
    switch result {
    case .success(let value): try answer(.success(requestId, result: value))
    case .failure(let error): try answer(.failure(requestId, error: error))
    }
  }

  private func answer(_ response: ResponseEnvelope) throws {
    try state.withLock { state in
      guard !state.closed else { throw Self.closedError }
      continuation.yield(try NDJSON.encodeLine(response))
    }
  }

  /// After `thread.start`'s reply: an accepted start gives the placeholder its thread and turn; a
  /// refusal (no turn was made) removes it. A start that is not confirmed, or whose turn exists but
  /// failed, keeps waiting for its row.
  private func settle(_ threadId: String, _ result: MirrorRelay.Reply) {
    state.withLock { state in
      guard state.placeholders[threadId] != nil else { return }
      switch result {
      case .success(let value):
        guard let started = try? value.decode(ThreadStart.Result.self) else { return }
        state.placeholders[threadId]?.thread = started.thread
        state.placeholders[threadId]?.expires = now().advanced(by: Self.placeholderLifetime)
        state.overlays[threadId, default: Overlay()].turns[started.turn.id] = started.turn
        state.overlays[threadId]?.connectionId = started.thread.connectionId
      case .failure(let error):
        if error.code == MirrorRelay.notConfirmedCode || error.details?["turnId"] != nil { return }
        state.placeholders[threadId] = nil
        if state.lastReadThreadId != threadId { state.overlays[threadId] = nil }
      }
    }
  }

  /// One update from the relay, in order.
  private func receive(_ update: MirrorRelay.Update) {
    state.withLock { state in
      guard !state.closed else { return }
      switch update {
      case .link(let link):
        let phase: HubLinkStatus.State
        switch link {
        case .connected: phase = .connected
        case .connecting: phase = .connecting
        case .stopped: phase = .offline
        }
        guard phase != state.link else { return }
        let dropped = state.link == .connected
        state.link = phase
        if let event = try? AdapterEvent.hostPresence(nil, link: phase) { emit([event], state: &state) }
        // The relay reports the watched thread's gap; a started thread the hub watched on its own
        // (not read yet) lost its events too.
        if dropped {
          for id in state.placeholders.keys.sorted() where id != state.lastReadThreadId {
            gap(id, state: &state)
          }
        }
      case .presence(let hosts):
        let events = hosts.compactMap {
          try? AdapterEvent.hostPresence(
            HostPresence(deviceId: $0.deviceId, name: $0.name, online: $0.online, lastSeenAt: $0.lastSeenAt),
            link: state.link)
        }
        emit(events, state: &state)
      case .event(let event):
        relayed(event, state: &state)
      case .gap(let threadId):
        gap(threadId, state: &state)
      }
    }
  }

  /// Re-emits one relayed event, keeping what it says about the open or a started thread.
  private func relayed(_ event: AdapterEvent, state: inout State) {
    expirePlaceholders(state: &state)
    guard let threadId = event.threadId, var overlay = state.overlays[threadId] else {
      emit([event], state: &state)
      return
    }
    // Before a started thread's first read, its events are held, not shown.
    let holding = state.placeholders[threadId].map { !$0.read } ?? false
    if holding {
      guard (state.placeholders[threadId]?.held ?? 0) < Self.placeholderEvents else {
        if let native = event.nativeIds["itemId"], event.kind == .messageDelta {
          overlay.owed[native] = nil
          overlay.muted.insert(native)
          state.overlays[threadId] = overlay
        }
        return
      }
      state.placeholders[threadId]?.held += 1
    }
    overlay.connectionId = event.connectionId
    var out = event
    switch event.kind {
    case .messageDelta:
      guard let native = event.nativeIds["itemId"], let text = event.payload["delta"]?.stringValue else {
        break
      }
      if overlay.completed.contains(native) || overlay.muted.contains(native)
        || (try? store.item(threadId: threadId, nativeItemId: native))?.final == true
      {
        state.overlays[threadId] = overlay
        return
      }
      if holding {
        overlay.owed[native, default: ""] += text
      } else {
        if let owed = overlay.owed.removeValue(forKey: native) {
          out.payload = Self.merged(event.payload, ["delta": .string(owed + text)])
        }
        overlay.open.insert(native)
      }
    case .messageStarted, .toolStarted, .messageCompleted, .toolCompleted:
      guard let item = try? event.payload["displayItem"]?.decode(DisplayItem.self) else { break }
      let completed = event.kind == .messageCompleted || event.kind == .toolCompleted
      if let known = overlay.items[item.id], known.completed, !completed {
        // A late start never undoes a completion.
      } else {
        overlay.items[item.id] = (item, completed)
      }
      if completed, let native = item.nativeItemId {
        overlay.completed.insert(native)
        overlay.open.remove(native)
        overlay.muted.remove(native)
        overlay.owed[native] = nil
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let turn = try? event.payload["turn"]?.decode(Turn.self) { overlay.turns[turn.id] = turn }
      // The model drops every live text of the thread when a turn finishes.
      if event.kind == .turnFinished { overlay.open = [] }
    case .runtimeRequestOpened:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self),
        request.state == .pending
      {
        overlay.requests[request.id] = request
        overlay.resolved.remove(request.id)
      }
    case .runtimeRequestResolved, .runtimeRequestExpired:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self) {
        overlay.requests[request.id] = nil
        overlay.resolved.insert(request.id)
      }
    default:
      break
    }
    state.overlays[threadId] = overlay
    if !holding { emit([out], state: &state) }
  }

  /// Events for `threadId` may have been lost: each open message's live text ends with its item as last
  /// known, and its later deltas wait for its completion or for sync.
  private func gap(_ threadId: String, state: inout State) {
    guard var overlay = state.overlays[threadId] else { return }
    var events: [AdapterEvent] = []
    for native in overlay.open.sorted() {
      overlay.muted.insert(native)
      let known =
        overlay.items.values.first { $0.item.nativeItemId == native }?.item
        ?? (try? store.item(threadId: threadId, nativeItemId: native))?.item
      guard let known, let payload = try? JSONValue(encoding: known) else { continue }
      events.append(
        AdapterEvent(
          kind: .messageCompleted, connectionId: overlay.connectionId, threadId: threadId,
          turnId: known.turnId,
          nativeIds: ["itemId": native], payload: ["displayItem": payload]))
    }
    for native in overlay.owed.keys { overlay.muted.insert(native) }
    overlay.owed = [:]
    overlay.open = []
    state.overlays[threadId] = overlay
    emit(events, state: &state)
  }

  private static func merged(_ payload: JSONValue, _ fields: [String: JSONValue]) -> JSONValue {
    guard case .object(var object) = payload else { return .object(fields) }
    for (key, value) in fields { object[key] = value }
    return .object(object)
  }

  private func refuseWhileUnavailable() throws {
    if let unavailable { throw WorkspaceError(.endpointUnavailable, unavailable) }
  }

  private static func refused(_ method: WorkspaceProtocol.Method) -> WorkspaceError {
    WorkspaceError(
      .unsupportedCapability, refusal(for: method), details: ["method": .string(method.rawValue)])
  }

  /// Numbers and sends events while the lock is held, so they precede the command's response.
  private func emit(_ events: [AdapterEvent], state: inout State) {
    for event in events {
      state.sequence += 1
      let envelope = EventEnvelope(epoch: epoch, sequence: state.sequence, event: event)
      if let line = try? NDJSON.encodeLine(envelope) { continuation.yield(line) }
    }
  }

  private func diagnostics(sequence: Int) throws -> DiagnosticsReport {
    let link = try store.link()
    let directory = (store.path as NSString).deletingLastPathComponent
    let coordinator = CoordinatorInfo(
      version: version, pid: ProcessInfo.processInfo.processIdentifier, startedAt: startedAt, epoch: epoch,
      sequence: sequence, runtimeDir: directory, dataDir: directory, socketPath: "mirror",
      databasePath: store.path, host: link?.deviceName ?? "iPhone")
    let undecodable = try store.undecodableRowCount()
    let sync = link.map {
      SyncDiagnostic(
        hubURL: $0.hubURL, deviceName: $0.deviceName, cursor: store.cursor, lastSyncAt: $0.lastSyncAt,
        lastError: $0.lastError, undecodableRows: undecodable, pendingUploads: store.outboxCount,
        refusedUploads: (try? store.refusedUploads) ?? 0)
    }
    var errors = link?.lastError.map { [RecentError(scope: "sync", code: "sync_failed", message: $0)] } ?? []
    if let unavailable {
      errors.insert(RecentError(scope: "mirror", code: "mirror_unreadable", message: unavailable), at: 0)
    }
    return DiagnosticsReport(
      coordinator: coordinator, host: Self.host, runtimes: [], recentErrors: errors, sync: sync)
  }

  private static var host: HostInfo {
    #if os(iOS)
      let platform = "iOS"
    #else
      let platform = "macOS"
    #endif
    #if arch(arm64)
      let arch = "arm64"
    #else
      let arch = "x86_64"
    #endif
    return HostInfo(
      platform: platform, arch: arch, release: ProcessInfo.processInfo.operatingSystemVersionString)
  }
}
