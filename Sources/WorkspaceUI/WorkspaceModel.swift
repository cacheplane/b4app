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
  public var surface: Surface = .threads
  public var selectedThreadId: String?
  public var searchText = ""
  public var connectionFilter: String?

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
      }
    case .connectionChanged:
      if let index = connections.firstIndex(where: { $0.id == event.connectionId }),
        let status = event.payload["status"]?.stringValue.flatMap(ConnectionStatus.init(rawValue:)),
        let auth = event.payload["authStatus"]?.stringValue.flatMap(AuthStatus.init(rawValue:))
      {
        connections[index].status = status
        connections[index].authStatus = auth
      }
    default:
      break
    }
  }

  static func describe(_ error: any Error) -> String {
    let failure = WorkspaceError.from(error)
    return "\(failure.message) [\(failure.code.rawValue)]"
  }
}
