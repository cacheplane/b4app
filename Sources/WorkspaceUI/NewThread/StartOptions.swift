import Foundation
import WorkspaceProtocol

// MARK: - What a new thread can start in (M8c, "A new thread from the phone"; the new-thread composer)

extension WorkspaceModel {
  /// The projects a thread can be started in, the one with the newest thread activity first. The Mac
  /// offers every project; the phone those whose owning Mac is known.
  var startProjects: [Project] {
    relaysThroughHub ? filterProjects.filter { $0.ownerDeviceId != nil } : filterProjects
  }

  /// The connections offered for a project: ready Codex or Claude connections, and a local B4
  /// connection that serves this very project. Never a remote B4 (it has no project) or another
  /// project's B4. The phone offers only the connections of the Mac that owns the project.
  public func startConnections(for project: Project) -> [Connection] {
    let owner = project.ownerDeviceId
    if relaysThroughHub, owner == nil { return [] }
    return conversationReadyConnections.filter { connection in
      if relaysThroughHub, connection.ownerDeviceId != owner { return false }
      switch connection.kind {
      case .codex, .claude: return true
      case .b4: return connection.b4Mode != .remote && connection.projectId == project.id
      }
    }
  }

  /// The Mac's ready remote B4 connections, offered with no project. None on the phone, which has no
  /// route to them.
  public var remoteB4Connections: [Connection] {
    guard !relaysThroughHub else { return [] }
    return conversationReadyConnections.filter { $0.kind == .b4 && $0.b4Mode == .remote }
  }

  /// The connections a start with no project may use: on the Mac, a ready Codex or Claude connection
  /// (in a folder chosen outside every project, whose project the coordinator finds or makes on Send)
  /// and a remote B4. None on the phone, which always names a project.
  public var startConnectionsWithoutProject: [Connection] {
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

  /// The folders a start may run in: a Codex or Claude thread runs in one of the project's folders; a
  /// B4 thread is bound to its connection's route and has none.
  public func startFolders(for project: Project, connection: Connection) -> [ProjectFolder] {
    connection.kind == .b4 ? [] : project.folders
  }

  /// The folder step is shown only when there is more than one folder to choose from.
  public func needsFolderChoice(for project: Project, connection: Connection) -> Bool {
    startFolders(for: project, connection: connection).count > 1
  }

  /// The notice about the Mac that owns the project: left the hub, offline, or the quiet reconnecting
  /// line. Nil on the Mac and when the Mac is reachable or not known.
  public func startNotice(for project: Project) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: project.ownerDeviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: project.ownerDeviceId, fallbackName: nil)
  }

  /// Why a thread cannot be started in this project right now, in words: its own Mac is offline or has
  /// left the hub, or the phone's link is down. Nil while the Mac is reconnecting (the hub answers
  /// `device_offline` for a send in that window, as for any other) and whenever presence is unknown.
  public func startBlockedReason(for project: Project) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = startNotice(for: project), notice.kind != .reconnecting { return notice.text }
    return hubLinkNotice
  }

  /// Why New thread is off: no project can be started in. The phone checks each project's own Mac, so
  /// one Mac being offline leaves the other's projects open. The Mac's New thread is unchanged.
  public var newThreadEntryReason: String? {
    guard relaysThroughHub else {
      return conversationReadyConnections.isEmpty
        ? "Add a ready Codex connection first" : newThreadDisabledReason
    }
    let projects = startProjects
    let offered = projects.filter { !startConnections(for: $0).isEmpty }
    if offered.contains(where: { startBlockedReason(for: $0) == nil }) { return nil }
    if let reason = offered.lazy.compactMap({ self.startBlockedReason(for: $0) }).first { return reason }
    if let reason = newThreadDisabledReason { return reason }
    return projects.isEmpty
      ? "No projects yet. Start one on your Mac."
      : "Add a ready connection on your Mac first"
  }
}
