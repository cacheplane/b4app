import Foundation
import Observation
import WorkspaceClient
import WorkspaceProtocol

public enum LinkState: Sendable, Equatable {
  case connecting, ready, unavailable
}

public enum Surface: String, CaseIterable, Identifiable, Sendable {
  case threads, connections, servers, diagnostics

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .threads: return "Threads"
    case .connections: return "Connections"
    case .servers: return "Local servers"
    case .diagnostics: return "Diagnostics"
    }
  }

  public var systemImage: String {
    switch self {
    case .threads: return "bubble.left.and.bubble.right"
    case .connections: return "point.3.connected.trianglepath.dotted"
    case .servers: return "server.rack"
    case .diagnostics: return "stethoscope"
    }
  }
}

/// The open thread: cached rows from `thread.read` patched by live events.
public struct ThreadDetail: Sendable, Equatable {
  public var thread: ConversationThread
  public var turns: [Turn]
  public var items: [DisplayItem]
  public var requests: [RuntimeRequest]
  /// Streaming assistant text by native item id, cleared when the item completes.
  public var liveText: [String: String] = [:]

  public var activeTurn: Turn? { turns.last { $0.status != .terminal } }

  mutating func upsert(_ item: DisplayItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
      items.sort { $0.sequence < $1.sequence }
    }
  }

  mutating func upsert(_ turn: Turn) {
    if let index = turns.firstIndex(where: { $0.id == turn.id }) {
      turns[index] = turn
    } else {
      turns.append(turn)
      turns.sort { $0.createdAt < $1.createdAt }
    }
  }
}

/// Renderer-side projection of coordinator state: snapshot first, then live events, resnapshot on
/// desync. Views never talk to the client directly.
@Observable
public final class WorkspaceModel {
  public typealias TransportProvider = @Sendable () async throws -> any WorkspaceTransport

  public private(set) var link: LinkState = .connecting
  public private(set) var linkMessage: String?
  public private(set) var connections: [Connection] = []
  public private(set) var threads: [ConversationThread] = []
  public private(set) var diagnostics: DiagnosticsReport?
  public private(set) var diagnosticsError: String?
  public private(set) var diagnosticsLoading = false
  public private(set) var detail: ThreadDetail?
  public private(set) var detailLoading = false
  public private(set) var busy = false
  public var lastError: String?
  public var composerText = ""
  public var surface: Surface = .threads
  public var selectedThreadId: String?
  public var searchText = ""
  public var connectionFilter: String?
  public var showNewThread = false
  /// Set after `connection.login`; the view opens it in the system browser and clears it.
  public var pendingLoginURL: URL?

  private let transportProvider: TransportProvider
  private var client: WorkspaceClient?
  private var connectTask: Task<Void, Never>?

  public init(transportProvider: @escaping TransportProvider) {
    self.transportProvider = transportProvider
  }

  public var visibleThreads: [ConversationThread] {
    let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
    return threads.filter { !$0.archived }
      .filter { connectionFilter == nil || $0.connectionId == connectionFilter }
      .filter { query.isEmpty || $0.title.lowercased().contains(query) }
      .sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
  }

  public func connection(id: String) -> Connection? { connections.first { $0.id == id } }

  /// Connections that can start a thread right now.
  public var conversationReadyConnections: [Connection] {
    connections.filter { $0.enabled && $0.kind == .codex && $0.status == .ready }
  }

  public func connect() {
    connectTask?.cancel()
    link = .connecting
    linkMessage = nil
    connectTask = Task { [transportProvider] in
      do {
        let transport = try await transportProvider()
        let client = WorkspaceClient(transport: transport)
        self.client = client
        _ = try await client.ready()
        try await refreshSnapshot()
        link = .ready
        await observe(client)
      } catch {
        link = .unavailable
        linkMessage = Self.describe(error)
      }
    }
  }

  public func disconnect() async {
    connectTask?.cancel()
    await client?.close()
    client = nil
    link = .unavailable
  }

  public func refreshSnapshot() async throws {
    guard let client else { return }
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    connections = snapshot.connections
    threads = snapshot.threads
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    if let id = selectedThreadId, detail != nil { await loadDetail(id: id) }
  }

  public func refreshDiagnostics() async {
    guard let client else {
      diagnosticsError = "Coordinator is not connected."
      return
    }
    diagnosticsLoading = true
    defer { diagnosticsLoading = false }
    do {
      diagnostics = try await client.request(
        DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
      diagnosticsError = nil
    } catch {
      diagnosticsError = Self.describe(error)
    }
  }

  // MARK: - Connections

  @discardableResult
  public func addConnection(
    kind: ConnectionKind, label: String? = nil, executablePath: String? = nil
  ) async
    -> Connection?
  {
    await perform {
      let result = try await $0.request(
        ConnectionAdd.self, ConnectionAdd.Params(kind: kind, label: label, executablePath: executablePath),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      if result.connection.status != .ready, let message = result.inspection.message {
        self.lastError = message
      }
      return result.connection
    }
  }

  public func inspectConnection(id: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionInspect.self, ConnectionInspect.Params(connectionId: id),
        options: Self.mutation(timeout: .seconds(60)))
      self.merge(result.connection)
      return result.connection
    }
  }

  public func login(connectionId: String) async {
    _ = await perform {
      let result = try await $0.request(
        ConnectionLogin.self, ConnectionLogin.Params(connectionId: connectionId), options: Self.mutation())
      self.pendingLoginURL = URL(string: result.authUrl)
      return result
    }
  }

  // MARK: - Threads

  public func createThread(connectionId: String, directory: String, title: String?) async {
    let created: ConversationThread? = await perform {
      try await $0.request(
        ThreadCreate.self,
        ThreadCreate.Params(connectionId: connectionId, workingDirectory: directory, title: title),
        options: Self.mutation(timeout: .seconds(60))
      ).thread
    }
    if let created {
      threads.removeAll { $0.id == created.id }
      threads.insert(created, at: 0)
      await openThread(id: created.id)
    }
  }

  public func openThread(id: String) async {
    if let current = detail, current.thread.id != id { await saveDraft(threadId: current.thread.id) }
    selectedThreadId = id
    surface = .threads
    await loadDetail(id: id)
  }

  private func loadDetail(id: String) async {
    guard let client else { return }
    detailLoading = true
    defer { detailLoading = false }
    do {
      let read = try await client.request(
        ThreadRead.self, ThreadRead.Params(threadId: id), options: RequestOptions(timeout: .seconds(60)))
      detail = ThreadDetail(
        thread: read.thread, turns: read.turns, items: read.items, requests: read.requests)
      let draft = try? await client.request(DraftRead.self, DraftRead.Params(threadId: id)).draft
      composerText = draft?.text ?? ""
      lastError = nil
    } catch {
      lastError = Self.describe(error)
    }
  }

  public func saveDraft(threadId: String) async {
    guard let client else { return }
    let text = composerText
    _ = try? await client.request(
      DraftSave.self, DraftSave.Params(threadId: threadId, text: text), options: Self.mutation())
  }

  public func updateThread(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async
  {
    _ = await perform {
      try await $0.request(
        ThreadUpdate.self,
        ThreadUpdate.Params(threadId: id, title: title, pinned: pinned, archived: archived),
        options: Self.mutation()
      ).thread
    }
  }

  // MARK: - Turns and requests

  public func send() async {
    guard let detail else { return }
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    composerText = ""
    let sent: Turn? = await perform {
      try await $0.request(
        TurnSend.self, TurnSend.Params(threadId: detail.thread.id, text: text),
        options: Self.mutation(timeout: .seconds(90))
      ).turn
    }
    if sent == nil, composerText.isEmpty, self.detail?.activeTurn != nil {
      composerText = text
    }
  }

  public func stop() async {
    guard let detail else { return }
    _ = await perform {
      try await $0.request(
        TurnInterrupt.self, TurnInterrupt.Params(threadId: detail.thread.id), options: Self.mutation()
      ).turn
    }
  }

  public func respond(requestId: String, decision: RuntimeDecision) async {
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, decision: decision),
        options: Self.mutation()
      ).request
    }
  }

  public func answer(requestId: String, answers: [String: [String]]) async {
    _ = await perform {
      try await $0.request(
        RequestRespond.self, RequestRespond.Params(requestId: requestId, answers: answers),
        options: Self.mutation()
      ).request
    }
  }

  // MARK: - Internals

  private static func mutation(timeout: Duration = .seconds(30)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: timeout)
  }

  private func perform<T: Sendable>(_ body: (WorkspaceClient) async throws -> T) async -> T? {
    guard let client else {
      lastError = "Coordinator is not connected."
      return nil
    }
    busy = true
    defer { busy = false }
    do {
      let value = try await body(client)
      lastError = nil
      return value
    } catch {
      lastError = Self.describe(error)
      return nil
    }
  }

  private func merge(_ connection: Connection) {
    if let index = connections.firstIndex(where: { $0.id == connection.id }) {
      connections[index] = connection
    } else {
      connections.append(connection)
    }
  }

  private func observe(_ client: WorkspaceClient) async {
    let events = await client.events()
    let desync = await client.desync()
    let desyncTask = Task { @MainActor in
      for await _ in desync { try? await self.refreshSnapshot() }
    }
    for await envelope in events { apply(envelope.event) }
    desyncTask.cancel()
    if link == .ready {
      link = .unavailable
      linkMessage = "Coordinator connection closed."
    }
  }

  private func apply(_ event: AdapterEvent) {
    switch event.kind {
    case .threadUpdated:
      if let thread = try? event.payload["thread"]?.decode(ConversationThread.self) {
        threads.removeAll { $0.id == thread.id }
        threads.insert(thread, at: 0)
        if detail?.thread.id == thread.id { detail?.thread = thread }
      }
    case .connectionChanged:
      if let index = connections.firstIndex(where: { $0.id == event.connectionId }) {
        if let status = event.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:)) {
          connections[index].status = status
        }
        if let auth = event.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:)) {
          connections[index].authStatus = auth
        }
      }
    default:
      applyToDetail(event)
    }
  }

  private func applyToDetail(_ event: AdapterEvent) {
    guard var current = detail, event.threadId == current.thread.id else { return }
    switch event.kind {
    case .messageDelta:
      if let itemId = event.nativeIds["itemId"], let delta = event.payload["delta"]?.stringValue {
        current.liveText[itemId, default: ""] += delta
      }
    case .messageStarted, .messageCompleted, .toolStarted, .toolCompleted:
      if let item = try? event.payload["displayItem"]?.decode(DisplayItem.self) {
        current.upsert(item)
        if event.kind == .messageCompleted || event.kind == .toolCompleted, let nativeId = item.nativeItemId {
          current.liveText[nativeId] = nil
        }
      }
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      if let turn = try? event.payload["turn"]?.decode(Turn.self) { current.upsert(turn) }
      if event.kind == .turnFinished { current.liveText = [:] }
    case .runtimeRequestOpened:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self),
        request.state == .pending, !current.requests.contains(where: { $0.id == request.id })
      {
        current.requests.append(request)
      }
    case .runtimeRequestResolved, .runtimeRequestExpired:
      if let request = try? event.payload["runtimeRequest"]?.decode(RuntimeRequest.self) {
        current.requests.removeAll { $0.id == request.id }
      } else if let nativeId = event.nativeIds["requestId"] {
        current.requests.removeAll {
          $0.nativeRequestId == nativeId && $0.adapterGeneration == event.adapterGeneration
        }
      }
    case .adapterError:
      lastError = event.payload["message"]?.stringValue
    default:
      break
    }
    detail = current
  }

  static func describe(_ error: any Error) -> String {
    let failure = WorkspaceError.from(error)
    return "\(failure.message) [\(failure.code.rawValue)]"
  }
}
