import Foundation
import WorkspaceProtocol

// MARK: - What a new thread can start in (M8c, "A new thread from the phone"; the new-thread composer)

extension WorkspaceModel {
  /// The environments a thread can be started in, the one with the newest thread activity first. The Mac
  /// offers every environment; the phone those whose owning Mac is known.
  var startEnvironments: [WorkEnvironment] {
    relaysThroughHub ? filterEnvironments.filter { $0.ownerDeviceId != nil } : filterEnvironments
  }

  /// Ready harness connections for an environment. Historical B4 and staged protocol profiles cannot
  /// start conversations. The phone offers only the connections of the Mac that owns the environment.
  public func startConnections(for environment: WorkEnvironment) -> [Connection] {
    let owner = environment.ownerDeviceId
    if relaysThroughHub, owner == nil { return [] }
    return conversationReadyConnections.filter { connection in
      if relaysThroughHub, connection.ownerDeviceId != owner { return false }
      switch connection.kind {
      case .codex, .claude: return true
      case .b4, .agentProtocol: return false
      }
    }
  }

  /// Kept for existing composer callers. Historical B4 connections are never new-thread choices.
  public var remoteB4Connections: [Connection] {
    []
  }

  /// The connections a start with no environment may use. On the Mac, a ready Codex or Claude connection
  /// (with no folder, in one the coordinator makes, or in a folder chosen outside every environment, whose
  /// environment the coordinator finds or makes on Send). On the phone, the ready Codex and
  /// Claude connections of the primary Mac, which makes the folder; none when no Mac is known.
  public var startConnectionsWithoutEnvironment: [Connection] {
    let harness = conversationReadyConnections.filter { $0.kind == .codex || $0.kind == .claude }
    guard relaysThroughHub else { return harness }
    guard let primary = primaryHostId else { return [] }
    return harness.filter { $0.ownerDeviceId == primary }
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

  /// Only harness runtimes may choose an environment's folders for a new thread.
  public func startFolders(for environment: WorkEnvironment, connection: Connection) -> [EnvironmentFolder] {
    switch connection.kind {
    case .codex, .claude: return environment.folders
    case .b4, .agentProtocol: return []
    }
  }

  /// The folder step is shown only when there is more than one folder to choose from.
  public func needsFolderChoice(for environment: WorkEnvironment, connection: Connection) -> Bool {
    startFolders(for: environment, connection: connection).count > 1
  }

  /// The notice about the Mac that owns the environment: left the hub, offline, or the quiet reconnecting
  /// line. Nil on the Mac and when the Mac is reachable or not known.
  public func startNotice(for environment: WorkEnvironment) -> HostNoticeMessage? {
    startNotice(forDevice: environment.ownerDeviceId)
  }

  /// The notice about one Mac a start would go to (the rule above).
  private func startNotice(forDevice deviceId: String?) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: deviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: deviceId, fallbackName: nil)
  }

  /// Why a thread cannot be started in this environment right now: `startBlockedReason(forDevice:)` for
  /// the Mac that owns it.
  public func startBlockedReason(for environment: WorkEnvironment) -> String? {
    startBlockedReason(forDevice: environment.ownerDeviceId)
  }

  /// Why a thread cannot be started on this Mac right now, in words: it is offline or has left the hub,
  /// or the phone's link is down. Nil on the Mac, while the Mac is reconnecting (the hub answers
  /// `device_offline` for a send in that window, as for any other), and whenever presence is unknown.
  public func startBlockedReason(forDevice deviceId: String?) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = startNotice(forDevice: deviceId), notice.kind != .reconnecting { return notice.text }
    return hubLinkNotice
  }

  /// Why New thread is off: nothing can be started, with no folder or in any environment. The phone checks
  /// each Mac on its own, so one Mac being offline leaves the other's environments open. The Mac's New thread
  /// is unchanged.
  public var newThreadEntryReason: String? {
    guard relaysThroughHub else {
      return startConnectionsWithoutEnvironment.isEmpty
        ? "Add a ready Codex connection first" : newThreadDisabledReason
    }
    // "No folder" goes to the primary Mac.
    let noFolderOffered = !startConnectionsWithoutEnvironment.isEmpty
    let noFolder = noFolderOffered ? startBlockedReason(forDevice: primaryHostId) : nil
    if noFolderOffered, noFolder == nil { return nil }
    let environments = startEnvironments
    let offered = environments.filter { !startConnections(for: $0).isEmpty }
    if offered.contains(where: { startBlockedReason(for: $0) == nil }) { return nil }
    if let noFolder { return noFolder }
    if let reason = offered.lazy.compactMap({ self.startBlockedReason(for: $0) }).first { return reason }
    if let reason = newThreadDisabledReason { return reason }
    return environments.isEmpty
      ? RelayCopy.noEnvironments
      : "Add a ready connection on your Mac first"
  }
}
