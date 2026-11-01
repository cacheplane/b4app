import Foundation
import Synchronization
import WorkspaceClient
import WorkspaceProtocol

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
/// uploader. Creating, editing, and deleting projects stays on the Mac, and turns and new threads wait
/// for M8c: those answer `unsupported_capability`.
public final class MirrorTransport: WorkspaceTransport {
  public let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let store: MirrorStore
  private let version: String
  private let onLocalWrite: (@Sendable () -> Void)?
  private let unavailable: String?
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
  }

  /// The methods the mirror answers; every other one is refused.
  static let served: Set<WorkspaceProtocol.Method> = [
    .systemPing, .eventsSnapshot, .eventsReplay, .connectionList, .threadList, .threadRead, .draftRead,
    .serverList, .workspaceActiveWork, .diagnosticsRead, .projectList, .projectRename, .threadUpdate,
    .threadMarkRead, .draftSave,
  ]

  /// The methods the phone leaves to the Mac, whose projects it only reads and renames.
  static let macOnly: Set<WorkspaceProtocol.Method> = [.projectCreate, .projectUpdate, .projectDelete]

  static let macRefusal = "Creating, editing folders of, and deleting projects is done on the Mac."
  static let refusal = "Sending turns and starting threads from this device arrives in M8c."

  /// `onLocalWrite` is called (outside the transport's lock, so it must only hand off) after each
  /// command that wrote to the store; the host uses it to wake the uploader.
  ///
  /// `unavailable` is for a host whose real mirror cannot be used (it holds unsent edits in a schema
  /// this build cannot read): the transport answers reads from `store`, refuses every write with the
  /// reason, and lists the reason in Diagnostics.
  public init(
    store: MirrorStore, version: String, onLocalWrite: (@Sendable () -> Void)? = nil,
    unavailable: String? = nil
  ) {
    (incoming, continuation) = AsyncStream.makeStream(of: Data.self)
    self.store = store
    self.version = version
    self.onLocalWrite = onLocalWrite
    self.unavailable = unavailable
    let hello = HelloEnvelope(epoch: epoch, sequence: 0, coordinator: identity)
    if let line = try? NDJSON.encodeLine(hello) { continuation.yield(line) }
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
    let items: [(threadId: String, event: AdapterEvent)] = batch.touchedItems.compactMap { item in
      if owners[item.threadId] == nil {
        owners[item.threadId] = (try? store.thread(id: item.threadId))?.connectionId ?? ""
      }
      guard let payload = try? JSONValue(encoding: item) else { return nil }
      let event = AdapterEvent(
        kind: .messageCompleted, connectionId: owners[item.threadId] ?? "", threadId: item.threadId,
        turnId: item.turnId, nativeIds: item.nativeItemId.map { ["itemId": $0] } ?? [:],
        payload: ["displayItem": payload])
      return (item.threadId, event)
    }
    state.withLock { state in
      guard !state.closed else { return }
      let open = items.filter { $0.threadId == state.lastReadThreadId }.map(\.event)
      for event in events + open {
        state.sequence += 1
        let envelope = EventEnvelope(epoch: epoch, sequence: state.sequence, event: event)
        if let line = try? NDJSON.encodeLine(envelope) { continuation.yield(line) }
      }
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
        let method = WorkspaceProtocol.Method(rawValue: envelope.method), !Self.served.contains(method)
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
      guard let thread = try store.thread(id: params.threadId) else {
        throw WorkspaceError(.notFound, "Thread \(params.threadId) does not exist.")
      }
      state.lastReadThreadId = thread.id
      return try JSONValue(
        encoding: ThreadRead.Result(
          thread: thread, turns: try store.turns(threadId: thread.id),
          items: try store.items(threadId: thread.id),
          requests: try store.requests(threadId: thread.id).filter { $0.state == .pending }))
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

  private func refuseWhileUnavailable() throws {
    if let unavailable { throw WorkspaceError(.endpointUnavailable, unavailable) }
  }

  private static func refused(_ method: WorkspaceProtocol.Method) -> WorkspaceError {
    WorkspaceError(
      .unsupportedCapability, macOnly.contains(method) ? macRefusal : refusal,
      details: ["method": .string(method.rawValue)])
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
