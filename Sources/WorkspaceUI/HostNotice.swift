import Foundation
import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

/// Whether one Mac can be reached, as the phone sees it (M8c spec, "When the Mac is unreachable").
public enum HostPhase: Sendable, Equatable {
  /// Online, and the phone's link is up. Everything works.
  case connected
  /// Offline for less than 60 s since it was last heard (`lastSeenAt` on the phone's clock).
  case reconnecting(until: Date)
  /// Offline for 60 s or more: threads stay browsable, the controls that need the Mac do not.
  case disconnected(lastSeen: Date?)
  /// Not known: the Mac, whose coordinator never reports presence; the phone before the hub has said;
  /// the phone while its own link is down.
  case unknown

  /// The grace period, the same window D-045 uses for holding interrupts and answers.
  public static let grace: TimeInterval = 60

  static func of(_ presence: HostPresence?, link: HubLinkStatus.State?, now: Date) -> HostPhase {
    guard link == .connected, let presence else { return .unknown }
    if presence.online { return .connected }
    guard let seen = presence.lastSeenAt.flatMap(Timestamp.date(from:)) else {
      return .disconnected(lastSeen: nil)
    }
    let until = seen.addingTimeInterval(grace)
    return now < until ? .reconnecting(until: until) : .disconnected(lastSeen: seen)
  }
}

/// A notice about the Mac: one quiet line while reconnecting, a persistent one while it is offline or
/// has left the hub.
public struct HostNoticeMessage: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case reconnecting, offline, leftHub }
  public var kind: Kind
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }

  /// "<Mac name> is offline · last seen <time>".
  static func offline(name: String, lastSeen: Date, now: Date) -> String {
    "\(name) is offline · last seen \(Self.lastSeen(lastSeen, now: now))"
  }

  /// The time alone today ("14:02"), the date with it on another day.
  static func lastSeen(_ date: Date, now: Date) -> String {
    Calendar.current.isDate(date, inSameDayAs: now)
      ? date.formatted(date: .omitted, time: .shortened)
      : date.formatted(date: .abbreviated, time: .shortened)
  }
}

// MARK: - Presence in the model

extension WorkspaceModel {
  /// One Mac's phase. Always `.unknown` on the Mac, whose model never takes presence into account.
  public func hostPhase(deviceId: String?) -> HostPhase {
    _ = presenceRevision
    guard relaysThroughHub, let deviceId else { return .unknown }
    return HostPhase.of(hostPresence[deviceId], link: hubLinkPhase, now: now())
  }

  /// The phase of the Mac a thread belongs to: its own owner, else the primary Mac.
  public func hostPhase(for thread: ConversationThread) -> HostPhase {
    hostPhase(deviceId: thread.ownerDeviceId ?? primaryHostId)
  }

  /// The Mac the thread list speaks for: the owner of the thread with the latest activity, else the
  /// most recently seen host. A stale second Mac that owns nothing recent raises no list notice.
  public var primaryHostId: String? {
    let latest = threads.filter { $0.ownerDeviceId != nil }.max {
      ($0.activity?.lastActivityAt ?? $0.updatedAt) < ($1.activity?.lastActivityAt ?? $1.updatedAt)
    }
    if let owner = latest?.ownerDeviceId { return owner }
    return hostPresence.values.max { Self.seenRank($0) < Self.seenRank($1) }?.deviceId
  }

  /// Online first, then the latest `lastSeenAt`.
  private static func seenRank(_ host: HostPresence) -> (Int, Date) {
    (host.online ? 1 : 0, host.lastSeenAt.flatMap(Timestamp.date(from:)) ?? .distantPast)
  }

  /// The notice above the thread list: the Mac left the hub, or the primary Mac is offline.
  public var listNotice: HostNoticeMessage? {
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    return offlineNotice(deviceId: primaryHostId, fallbackName: nil)
  }

  /// The notice at the top of a thread: left the hub, offline, or the quiet reconnecting line.
  public func threadNotice(for thread: ConversationThread) -> HostNoticeMessage? {
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    let deviceId = thread.ownerDeviceId ?? primaryHostId
    if case .reconnecting = hostPhase(deviceId: deviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: deviceId, fallbackName: thread.ownerDeviceName)
  }

  private func offlineNotice(deviceId: String?, fallbackName: String?) -> HostNoticeMessage? {
    guard case .disconnected(let seen) = hostPhase(deviceId: deviceId) else { return nil }
    let named = deviceId.flatMap { hostPresence[$0]?.name }.flatMap { $0.isEmpty ? nil : $0 }
    let name = named ?? fallbackName ?? "Your Mac"
    let text =
      seen.map { HostNoticeMessage.offline(name: name, lastSeen: $0, now: now()) } ?? "\(name) is offline"
    return HostNoticeMessage(kind: .offline, text: text)
  }

  /// Why the composer, Stop, and approvals are off for this thread: its Mac is offline or left the
  /// hub. The notice is the reason. Nil while reconnecting, on the Mac, and whenever presence is unknown.
  public func controlsDisabledReason(for thread: ConversationThread) -> String? {
    guard let notice = threadNotice(for: thread), notice.kind != .reconnecting else { return nil }
    return notice.text
  }

  /// Why New thread is off: the primary Mac is offline or has left the hub.
  public var newThreadDisabledReason: String? { listNotice?.text }

  /// "Not confirmed while your Mac is offline" for a turn the mirror still shows as active on a Mac
  /// that is offline, instead of a working spinner. Its band stays as synced.
  public func activeTurnLabel(for thread: ConversationThread) -> String? {
    guard
      activeTurns[thread.id] != nil || (detail?.thread.id == thread.id && detail?.activeTurn != nil)
        || thread.activity?.latestTurnStatus.map({ $0 != .terminal }) == true,
      controlsDisabledReason(for: thread) != nil
    else { return nil }
    return RelayCopy.offlineTurn
  }

  /// "Connecting to the hub…" while the phone's own link is down; presence is then unknown.
  public var hubLinkNotice: String? {
    guard relaysThroughHub, let link = hubLinkPhase, link != .connected else { return nil }
    return RelayCopy.connecting
  }

  /// A `host.presence` event. Kept on any model, but only the phone's reads it (`hostPhase`). While
  /// the phone's link is down every host is unknown, so the last frame's hosts are forgotten.
  func applyPresence(_ event: AdapterEvent) {
    let wasConnected = hubLinkPhase == .connected
    if let link = event.presenceLink {
      hubLinkPhase = link
      if link != .connected { hostPresence = [:] }
    }
    if let host = event.presenceHost, hubLinkPhase == .connected { hostPresence[host.deviceId] = host }
    presenceChanged(wasConnected: wasConnected)
  }

  /// Presence as a snapshot carries it: it replaces what the model held.
  func applyPresence(_ snapshot: PresenceSnapshot) {
    let wasConnected = hubLinkPhase == .connected
    hubLinkPhase = snapshot.link
    hostPresence =
      snapshot.link == .connected
      ? Dictionary(snapshot.hosts.map { ($0.deviceId, $0) }, uniquingKeysWith: { _, new in new }) : [:]
    presenceChanged(wasConnected: wasConnected)
  }

  private func presenceChanged(wasConnected: Bool) {
    if !wasConnected, hubLinkPhase == .connected { linkGeneration += 1 }
    presenceRevision += 1
    schedulePhaseTimer()
    guard relaysThroughHub else { return }
    if !wasConnected, hubLinkPhase == .connected { retryLostSends() }
    advancePendingSends()
  }

  /// Redraw when the first reconnecting Mac's grace runs out, on the model's clock.
  func schedulePhaseTimer() {
    phaseTimer?.cancel()
    phaseTimer = nil
    guard relaysThroughHub else { return }
    let current = now()
    let next = hostPresence.keys.compactMap { id -> Date? in
      if case .reconnecting(let until) = hostPhase(deviceId: id) { return until }
      return nil
    }.min()
    guard let next else { return }
    let sleep = sleeper(Duration.seconds(max(next.timeIntervalSince(current), 0)))
    phaseTimer = Task { [weak self] in
      guard (try? await sleep()) != nil, !Task.isCancelled, let self else { return }
      self.presenceRevision += 1
      self.schedulePhaseTimer()
    }
  }
}

// MARK: - The view

/// A notice about the Mac, at the top of the thread list and of a thread. Reconnecting is one quiet
/// muted line with a small spinner; offline and left-the-hub are a persistent line on the raised
/// surface with a danger dot, like the sync banner. Never interactive: it explains why controls are off.
struct HostNotice: View {
  let message: HostNoticeMessage

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      if message.kind == .reconnecting {
        ProgressView().controlSize(.mini).accessibilityHidden(true)
      } else {
        Circle().fill(LLA.Color.danger).frame(width: 8, height: 8).accessibilityHidden(true)
      }
      Text(message.text)
        .font(LLAFont.small)
        .foregroundStyle(message.kind == .reconnecting ? LLA.Color.muted : LLA.Color.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, LLA.Metrics.margin)
    .padding(.vertical, LLA.Space.s)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(message.kind == .reconnecting ? Color.clear : LLA.Color.surfaceRaised)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("host-notice")
  }
}
