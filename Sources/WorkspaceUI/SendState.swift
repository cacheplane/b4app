import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// Where one of the phone's sends stands (M8c spec, "Sending and its states"). Only the phone keeps
/// these: the Mac sends over its own socket and shows the turn as it always has.
public enum SendState: Sendable, Equatable {
  /// Sent, no answer yet. The draft stays.
  case sending
  /// The Mac made the turn; the draft is cleared (the Mac clears it everywhere, M8b).
  case accepted(turnId: String)
  /// The Mac made the turn, then failed it (its error carries `details.turnId`). Shown as the turn.
  case acceptedWithError(turnId: String, WorkspaceError)
  /// Nothing was made (`device_offline`, `rate_limited`, a Mac error without a `turnId`): the
  /// message is removed, the reason shown, the draft kept.
  case refused(WorkspaceError)
  /// The Mac may have it (`relay_timeout`, the link dropped, no answer in time). Settled only by a
  /// synced turn with this send's id or by `turn.lookup`.
  case notConfirmed
  /// `turn.lookup` answered `none`: the Mac never ran it. The draft is there to send again.
  case didNotReach

  /// Still open: the Mac may yet run it, so no second send is offered.
  public var isUnsettled: Bool {
    switch self {
    case .sending, .notConfirmed: return true
    default: return false
    }
  }

  /// The turn the Mac made, once accepted.
  public var turnId: String? {
    switch self {
    case .accepted(let id), .acceptedWithError(let id, _): return id
    default: return nil
    }
  }
}

/// One send from the phone: a turn on an existing thread, or `thread.start` (when `start` is set,
/// `threadId` is the thread the phone minted). `id` is the operationId and the relay id, the same on
/// every retry, so the Mac makes at most one turn.
public struct PendingSend: Sendable, Equatable, Identifiable {
  public let id: String
  public let threadId: String
  public let text: String
  public let tappedAt: Date
  public internal(set) var state: SendState
  public let start: ThreadStart.Params?
  /// Commands sent for it so far; any after the first is a retry.
  public internal(set) var attempts = 0
  /// A send or retry is waiting for its reply.
  public internal(set) var inFlight = false
  /// The last attempt was lost with the phone's link: resend when it returns, within 30 s of the tap.
  public internal(set) var retryable = false
  /// A `turn.lookup` is waiting for its reply.
  public internal(set) var lookupInFlight = false
  /// No `turn.lookup` before this: 30 s after the tap, then 5 s after an `in_flight`.
  public internal(set) var nextLookupAt: Date
  /// The model's `linkGeneration` when the last attempt went out, so a link that dropped and came
  /// back before that attempt's reply still gets its retry.
  var linkGeneration = 0

  init(id: String, threadId: String, text: String, tappedAt: Date, start: ThreadStart.Params? = nil) {
    self.id = id
    self.threadId = threadId
    self.text = text
    self.tappedAt = tappedAt
    self.state = .sending
    self.start = start
    self.nextLookupAt = tappedAt.addingTimeInterval(SendRules.lookupAfter)
  }
}

/// Stop and an approval's answer from the phone (spec "Stop and approvals"). Never retried.
public enum ControlState: Sendable, Equatable {
  case waiting, notConfirmed, alreadyAnswered
  case failed(String)

  public var label: String {
    switch self {
    case .waiting: return RelayCopy.waiting
    case .notConfirmed: return RelayCopy.notConfirmed
    case .alreadyAnswered: return RelayCopy.alreadyAnswered
    case .failed(let reason): return reason
    }
  }
}

/// The relay's words, verbatim from the spec.
public enum RelayCopy {
  public static let sending = "Sending…"
  public static let notConfirmed = "Not confirmed: your Mac may not have received this."
  public static let didNotReach = "Didn't reach your Mac"
  public static let offlineTurn = "Not confirmed while your Mac is offline"
  public static let waiting = "Waiting for your Mac…"
  public static let alreadyAnswered = "Already answered"
  public static let connecting = "Connecting to the hub…"
  public static let reconnecting = "Reconnecting to your Mac…"
  public static let leftHub = "Your Mac has left the hub. Its threads come back when it joins again."
}

/// The send table's rules, apart from the model so they read as the spec does.
enum SendRules {
  /// A send is retried with the same id only this long after the tap.
  static let resendWindow: TimeInterval = 30
  /// `turn.lookup` no sooner than this after the tap: the command's deadline has then passed.
  static let lookupAfter: TimeInterval = 30
  /// After `in_flight`, ask again this much later.
  static let lookupAgain: TimeInterval = 5

  /// The state a reply leaves a send in, and whether a lost link may be retried. A retry's refusal
  /// does not undo the first attempt, which may have reached the Mac: only success, a turn, or
  /// `turn.lookup` settle it.
  static func settle(_ result: Result<String, WorkspaceError>, retry: Bool) -> (SendState, retryable: Bool) {
    switch result {
    case .success(let turnId):
      return (.accepted(turnId: turnId), false)
    case .failure(let error):
      if let turnId = error.details?["turnId"]?.stringValue {
        return (.acceptedWithError(turnId: turnId, error), false)
      }
      if notSent(error) { return retry ? (.notConfirmed, true) : (.refused(error), false) }
      if mayHaveArrived(error) { return (.notConfirmed, linkLost(error)) }
      return retry ? (.notConfirmed, false) : (.refused(error), false)
    }
  }

  /// The phone's link was down: nothing left the phone.
  static func notSent(_ error: WorkspaceError) -> Bool {
    error.code == .endpointUnavailable && error.details?["reason"]?.stringValue == "not_connected"
  }

  /// Sent, and no answer: the relay's or the hub's `relay_timeout`, or the client giving up.
  static func mayHaveArrived(_ error: WorkspaceError) -> Bool {
    error.code == .relayTimeout || (error.code == .endpointUnavailable && !notSent(error))
  }

  /// Lost with the phone's link (the app went to the background, the socket failed).
  static func linkLost(_ error: WorkspaceError) -> Bool {
    guard error.code == .relayTimeout, error.details?["local"]?.boolValue == true else { return false }
    let reason = error.details?["reason"]?.stringValue
    return reason == "link_dropped" || reason == "send_failed"
  }

  static func control(_ error: WorkspaceError) -> ControlState {
    if error.code == .staleRuntimeRequest { return .alreadyAnswered }
    if mayHaveArrived(error) { return .notConfirmed }
    return .failed(reason(error))
  }

  /// A refusal in words: the Mac's name and last-seen time for `device_offline`, else the message.
  static func reason(_ error: WorkspaceError, now: Date = Date()) -> String {
    if error.code == .deviceOffline, let name = error.details?["deviceName"]?.stringValue {
      if let seen = error.details?["lastSeenAt"]?.stringValue.flatMap(Timestamp.date(from:)) {
        return HostNoticeMessage.offline(name: name, lastSeen: seen, now: now)
      }
      return "\(name) is offline"
    }
    return error.message
  }
}

// MARK: - The model's sends through the hub (the phone)

extension WorkspaceModel {
  /// How long the client waits for a relayed command: past the relay's own answer (90 s for Stop and
  /// answers, 30 s for the rest), so the phone's "not confirmed" is what shows, never a client timeout.
  public static func relayTimeout(for method: WorkspaceProtocol.Method) -> Duration {
    switch method {
    case .turnInterrupt, .requestRespond: return .seconds(100)
    default: return .seconds(40)
    }
  }

  /// A sleep of `wait` on the model's clock from this moment. The deadline is fixed now, not when the
  /// task starts, so a clock that moves before the sleeper runs still wakes it on time.
  func sleeper(_ wait: Duration) -> @Sendable () async throws -> Void {
    let clock: any Clock<Duration> = self.clock
    return Self.sleeper(on: clock, wait)
  }

  private static func sleeper<C: Clock<Duration>>(
    on clock: C, _ wait: Duration
  )
    -> @Sendable () async throws -> Void
  {
    let deadline = clock.now.advanced(by: wait)
    return { try await clock.sleep(until: deadline, tolerance: nil) }
  }

  /// The phone sends through the hub; the Mac, whose coordinator owns its account, does not.
  var relaysThroughHub: Bool { accountSource == .host }

  /// The user's message as the transcript shows it until its turn's own message arrives: while
  /// sending, not confirmed, or not delivered. A refused one is removed (its reason shows instead).
  public func pendingMessage(for threadId: String) -> PendingSend? {
    guard let send = pendingSends[threadId] else { return nil }
    switch send.state {
    case .refused: return nil
    case .accepted(let turnId), .acceptedWithError(let turnId, _):
      return transcriptShows(turnId: turnId, threadId: threadId) ? nil : send
    default: return send
    }
  }

  /// What the send says under its message, or in place of it when refused; nil once accepted.
  public func sendStatus(for threadId: String) -> String? {
    switch pendingSends[threadId]?.state {
    case .sending?: return RelayCopy.sending
    case .notConfirmed?: return RelayCopy.notConfirmed
    case .didNotReach?: return RelayCopy.didNotReach
    case .refused(let error)?: return SendRules.reason(error, now: now())
    default: return nil
    }
  }

  /// Why Send is not offered for this thread right now, in words; nil when it is. The Mac has none.
  public func sendBlockedReason(for thread: ConversationThread) -> String? {
    if let reason = controlsDisabledReason(for: thread) { return reason }
    guard relaysThroughHub else { return nil }
    if let send = pendingSends[thread.id], send.state.isUnsettled { return sendStatus(for: thread.id) }
    return hubLinkNotice
  }

  /// Stop is offered: the Mac is reachable and no stop is waiting for it.
  public func canStop(_ thread: ConversationThread) -> Bool {
    controlsDisabledReason(for: thread) == nil && stopStates[thread.id] != .waiting
  }

  /// An approval's buttons are offered.
  public func canAnswer(_ request: RuntimeRequest) -> Bool {
    guard !busy, answerStates[request.id] != .waiting else { return false }
    let thread = threads.first { $0.id == request.threadId } ?? detail?.thread
    return thread.map { controlsDisabledReason(for: $0) == nil } ?? true
  }

  private func transcriptShows(turnId: String, threadId: String) -> Bool {
    guard let detail, detail.thread.id == threadId else { return false }
    return detail.items.contains { $0.turnId == turnId && $0.role == .user }
  }

  // MARK: Sending

  /// The phone's Send: the message shows as sending, the draft stays until the Mac accepts.
  func relaySend(threadId: String) async {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let thread = detail?.thread, thread.id == threadId,
      sendBlockedReason(for: thread) == nil
    else { return }
    let send = PendingSend(
      id: UUID().uuidString.lowercased(), threadId: threadId, text: text, tappedAt: now())
    pendingSends[threadId] = send
    await attempt(threadId: threadId, id: send.id)
  }

  /// Start a thread in a project from the phone (`thread.start`): the phone mints the thread id and
  /// tracks the send on it, with `turn.lookup` on that id. Accepted at once, the thread is listed and
  /// opened. Returns the send as its reply left it (nil when nothing was sent).
  @discardableResult
  public func startThread(
    projectId: String, connectionId: String, folder: String?, text: String
  ) async
    -> PendingSend?
  {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, client != nil, newThreadDisabledReason == nil else { return nil }
    let threadId = UUID().uuidString.lowercased()
    let params = ThreadStart.Params(
      threadId: threadId, projectId: projectId, connectionId: connectionId, folder: folder, text: text)
    let send = PendingSend(
      id: UUID().uuidString.lowercased(), threadId: threadId, text: text, tappedAt: now(), start: params)
    pendingSends[threadId] = send
    await attempt(threadId: threadId, id: send.id)
    let settled = pendingSends[threadId]
    if settled?.state.turnId != nil, threads.contains(where: { $0.id == threadId }) {
      await openThread(id: threadId)
    }
    return settled
  }

  /// One send of a pending message (the first, or a retry with the same id).
  private func attempt(threadId: String, id: String) async {
    guard var send = pendingSends[threadId], send.id == id, !send.inFlight, let client else { return }
    let retry = send.attempts > 0
    send.attempts += 1
    send.inFlight = true
    send.state = .sending
    send.linkGeneration = linkGeneration
    pendingSends[threadId] = send
    let result: Result<String, WorkspaceError>
    do {
      if let start = send.start {
        let started = try await client.request(
          ThreadStart.self, start,
          options: RequestOptions(operationId: id, timeout: Self.relayTimeout(for: .threadStart)))
        store(started.thread)
        result = .success(started.turn.id)
      } else {
        let sent = try await client.request(
          TurnSend.self, TurnSend.Params(threadId: threadId, text: send.text),
          options: RequestOptions(operationId: id, timeout: Self.relayTimeout(for: .turnSend)))
        result = .success(sent.turn.id)
      }
    } catch {
      result = .failure(WorkspaceError.from(error))
    }
    guard var current = pendingSends[threadId], current.id == id else { return }
    current.inFlight = false
    pendingSends[threadId] = current
    // A synced turn may have settled it while the reply was on its way.
    if current.state.turnId != nil { return }
    let (state, retryable) = SendRules.settle(result, retry: retry)
    if let turnId = state.turnId {
      accept(threadId: threadId, id: id, as: state, turnId: turnId)
      return
    }
    current.state = state
    current.retryable = retryable
    pendingSends[threadId] = current
    if state == .notConfirmed {
      // The link came back while this attempt was out: the return already passed it by.
      if retryable, hubLinkPhase == .connected, linkGeneration > current.linkGeneration { retryLostSends() }
      advancePendingSends()
    }
  }

  /// The Mac has the turn: clear the composer when it still holds what was sent.
  private func accept(threadId: String, id: String, as state: SendState, turnId: String) {
    guard var send = pendingSends[threadId], send.id == id else { return }
    send.state = state
    send.retryable = false
    pendingSends[threadId] = send
    if detail?.thread.id == threadId,
      composerText.trimmingCharacters(in: .whitespacesAndNewlines) == send.text
    {
      composerText = ""
    }
  }

  /// A synced or relayed turn carrying a pending send's id settles it as accepted.
  func resolvePendingSends(with turns: [Turn]) {
    guard !pendingSends.isEmpty else { return }
    for turn in turns {
      guard let send = pendingSends[turn.threadId], send.id == turn.operationId, send.state.turnId == nil
      else { continue }
      accept(threadId: turn.threadId, id: send.id, as: .accepted(turnId: turn.id), turnId: turn.id)
    }
  }

  /// The phone's link is back: resend what the link lost, only within 30 s of the tap.
  func retryLostSends() {
    for send in pendingSends.values
    where send.retryable && !send.inFlight && send.state == .notConfirmed
      && now().timeIntervalSince(send.tappedAt) < SendRules.resendWindow
    {
      Task { await attempt(threadId: send.threadId, id: send.id) }
    }
  }

  // MARK: Settling "not confirmed"

  /// Ask the Mac about every not-confirmed send that is due, once its Mac is online and the phone's
  /// link is up; then sleep until the next one is due. Only the Mac's answer declares a send lost.
  func advancePendingSends() {
    let current = now()
    for send in pendingSends.values
    where send.state == .notConfirmed && !send.inFlight && !send.lookupInFlight
      && send.nextLookupAt <= current && canLookUp(send)
    {
      pendingSends[send.threadId]?.lookupInFlight = true
      Task { await lookUp(threadId: send.threadId, id: send.id) }
    }
    scheduleSendTimer()
  }

  private func canLookUp(_ send: PendingSend) -> Bool {
    guard hubLinkPhase == .connected else { return false }
    let thread = threads.first { $0.id == send.threadId }
    return hostPhase(deviceId: thread?.ownerDeviceId ?? primaryHostId) == .connected
  }

  /// Wakes `advancePendingSends` when the next lookup falls due. Ones already due wait for presence.
  private func scheduleSendTimer() {
    sendTimer?.cancel()
    sendTimer = nil
    let current = now()
    guard
      let due = pendingSends.values.filter({
        $0.state == .notConfirmed && !$0.lookupInFlight && $0.nextLookupAt > current
      }).map(\.nextLookupAt).min()
    else { return }
    let sleep = sleeper(Duration.seconds(due.timeIntervalSince(current)))
    sendTimer = Task { [weak self] in
      guard (try? await sleep()) != nil, !Task.isCancelled else { return }
      self?.advancePendingSends()
    }
  }

  private func lookUp(threadId: String, id: String) async {
    let found: TurnLookup.Result?
    if let client {
      found = try? await client.request(
        TurnLookup.self, TurnLookup.Params(operationId: id, threadId: threadId),
        options: RequestOptions(timeout: Self.relayTimeout(for: .turnLookup)))
    } else {
      found = nil
    }
    guard var send = pendingSends[threadId], send.id == id else { return }
    send.lookupInFlight = false
    pendingSends[threadId] = send
    guard send.state == .notConfirmed else { return }
    switch found?.state {
    case .found?:
      let turnId = found?.turn?.id ?? ""
      accept(threadId: threadId, id: id, as: .accepted(turnId: turnId), turnId: turnId)
      return
    case .none?:
      send.state = .didNotReach
      send.retryable = false
    case .inFlight?, nil:
      // Still running on the Mac, or the lookup itself was not answered: ask again shortly.
      send.nextLookupAt = now().addingTimeInterval(SendRules.lookupAgain)
    }
    pendingSends[threadId] = send
    scheduleSendTimer()
  }

  /// Drop accepted sends whose turn's own message is now in the open transcript.
  func prunePendingSends() {
    guard let detail, let send = pendingSends[detail.thread.id], let turnId = send.state.turnId else {
      return
    }
    if transcriptShows(turnId: turnId, threadId: detail.thread.id) { pendingSends[detail.thread.id] = nil }
  }

  // MARK: Stop and answers

  /// The phone's Stop: "Waiting for your Mac…" up to 90 s, then the reply or "Not confirmed".
  func relayStop(threadId: String) async {
    guard let thread = threads.first(where: { $0.id == threadId }) ?? detail?.thread, canStop(thread),
      let client
    else { return }
    stopStates[threadId] = .waiting
    do {
      let result = try await client.request(
        TurnInterrupt.self, TurnInterrupt.Params(threadId: threadId),
        options: RequestOptions(
          operationId: UUID().uuidString.lowercased(), timeout: Self.relayTimeout(for: .turnInterrupt)))
      stopStates[threadId] = nil
      resolvePendingSends(with: [result.turn])
    } catch {
      stopStates[threadId] = SendRules.control(WorkspaceError.from(error))
    }
  }

  /// The phone's answer to a runtime request; "Already answered" when another surface was first.
  func relayRespond(_ params: RequestRespond.Params) async {
    let id = params.requestId
    guard answerStates[id] != .waiting, let client else { return }
    if let request = detail?.requests.first(where: { $0.id == id }), !canAnswer(request) { return }
    answerStates[id] = .waiting
    do {
      _ = try await client.request(
        RequestRespond.self, params,
        options: RequestOptions(
          operationId: UUID().uuidString.lowercased(), timeout: Self.relayTimeout(for: .requestRespond)))
      answerStates[id] = nil
    } catch {
      answerStates[id] = SendRules.control(WorkspaceError.from(error))
    }
  }
}
