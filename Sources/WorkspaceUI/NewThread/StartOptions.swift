import Foundation
import WorkspaceProtocol

// MARK: - What a new thread can start in (M8c, "A new thread from the phone"; the new-thread composer)

extension WorkspaceModel {
  /// The environments a thread can be started in, the one with the newest thread activity first. The Mac
  /// offers every environment; the phone those whose owning Mac is known.
  var startEnvironments: [WorkEnvironment] {
    relaysThroughHub ? filterEnvironments.filter { $0.ownerDeviceId != nil } : filterEnvironments
  }

  /// The connections offered for an environment: ready Codex or Claude connections, and a local B4
  /// connection that serves this very environment. Never a remote B4 (it has no environment) or another
  /// environment's B4. The phone offers only the connections of the Mac that owns the environment.
  public func startConnections(for environment: WorkEnvironment) -> [Connection] {
    let owner = environment.ownerDeviceId
    if relaysThroughHub, owner == nil { return [] }
    return conversationReadyConnections.filter { connection in
      if relaysThroughHub, connection.ownerDeviceId != owner { return false }
      switch connection.kind {
      case .codex, .claude: return true
      case .b4: return connection.b4Mode != .remote && connection.environmentId == environment.id
      }
    }
  }

  /// The Mac's ready remote B4 connections, offered with no environment. None on the phone, which has no
  /// route to them.
  public var remoteB4Connections: [Connection] {
    guard !relaysThroughHub else { return [] }
    return conversationReadyConnections.filter { $0.kind == .b4 && $0.b4Mode == .remote }
  }

  /// The connections a start with no environment may use: on the Mac, a ready Codex or Claude connection
  /// (in a folder chosen outside every environment, whose environment the coordinator finds or makes on Send)
  /// and a remote B4. None on the phone, which always names an environment.
  public var startConnectionsWithoutEnvironment: [Connection] {
    guard !relaysThroughHub else { return [] }
    return conversationReadyConnections.filter { $0.kind != .b4 } + remoteB4Connections
  }

  /// How a connection reads in the sheet: a B4 connection by its route's name, as the Mac titles its
  /// threads (`/research#agent` is "research"); the others by their label.
  public func startLabel(for connection: Connection) -> String {
    guard connection.kind == .b4, let key = connection.routeKey else { return connection.label }
    let route = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(
      String.init)
    let name = route.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
    return name.isEmpty ? connection.label : name
  }

  /// The folders a start may run in: a Codex or Claude thread runs in one of the environment's folders; a
  /// B4 thread is bound to its connection's route and has none.
  public func startFolders(for environment: WorkEnvironment, connection: Connection) -> [EnvironmentFolder] {
    connection.kind == .b4 ? [] : environment.folders
  }

  /// The folder step is shown only when there is more than one folder to choose from.
  public func needsFolderChoice(for environment: WorkEnvironment, connection: Connection) -> Bool {
    startFolders(for: environment, connection: connection).count > 1
  }

  /// The notice about the Mac that owns the environment: left the hub, offline, or the quiet reconnecting
  /// line. Nil on the Mac and when the Mac is reachable or not known.
  public func startNotice(for environment: WorkEnvironment) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: environment.ownerDeviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: environment.ownerDeviceId, fallbackName: nil)
  }

  /// Why a thread cannot be started in this environment right now, in words: its own Mac is offline or has
  /// left the hub, or the phone's link is down. Nil while the Mac is reconnecting (the hub answers
  /// `device_offline` for a send in that window, as for any other) and whenever presence is unknown.
  public func startBlockedReason(for environment: WorkEnvironment) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = startNotice(for: environment), notice.kind != .reconnecting { return notice.text }
    return hubLinkNotice
  }

  /// Why New thread is off: no environment can be started in. The phone checks each environment's own Mac, so
  /// one Mac being offline leaves the other's environments open. The Mac's New thread is unchanged.
  public var newThreadEntryReason: String? {
    guard relaysThroughHub else {
      return conversationReadyConnections.isEmpty
        ? "Add a ready Codex connection first" : newThreadDisabledReason
    }
    let environments = startEnvironments
    let offered = environments.filter { !startConnections(for: $0).isEmpty }
    if offered.contains(where: { startBlockedReason(for: $0) == nil }) { return nil }
    if let reason = offered.lazy.compactMap({ self.startBlockedReason(for: $0) }).first { return reason }
    if let reason = newThreadDisabledReason { return reason }
    return environments.isEmpty
      ? RelayCopy.noEnvironments
      : "Add a ready connection on your Mac first"
  }
}
