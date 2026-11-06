import Foundation
import WorkspaceProtocol

/// Private authoring format. These fields are observations, not a publishable transcript.
public struct RecordedEvent: Codable, Sendable, Equatable {
  public var sourceSequence: Int
  public var elapsedMs: Double
  public var kind: EventKind
  public var turnId: String?
  public var fields: JSONValue
}

public enum RecordingFailure: String, Error, Sendable {
  case invalidState, nonemptyThread, notB4, setupActivity, gap, epochChanged
  case accountChanged, disconnected, threadDeleted, unsupportedEvent, malformedEvent
  case limitExceeded, timedOut, unsettled, aborted
}

/// Validates the global stream before filtering. No account, connection, grant, or
/// native-scope payload crosses this boundary. The CLI masks text before persistence.
struct RecordingBuffer: Sendable {
  let threadId: String
  let connectionId: String
  let maxBytes: Int
  private(set) var cursor = EventCursor()
  private(set) var events: [RecordedEvent] = []
  private var bytes = 0
  private var activeTurns: Set<String> = []
  private var pendingRequests: Set<String> = []
  var isSettled: Bool { activeTurns.isEmpty && pendingRequests.isEmpty }

  init(threadId: String, connectionId: String, maxBytes: Int) {
    self.threadId = threadId
    self.connectionId = connectionId
    self.maxBytes = maxBytes
  }

  mutating func begin(epoch: String, sequence: Int) { cursor.reset(epoch: epoch, sequence: sequence) }

  mutating func accept(_ envelope: EventEnvelope, elapsedMs: Double) throws {
    switch cursor.advance(epoch: envelope.epoch, sequence: envelope.sequence) {
    case .duplicate: return
    case .gap: throw RecordingFailure.gap
    case .epochChanged: throw RecordingFailure.epochChanged
    case .ok: break
    }
    let event = envelope.event
    if event.kind == .accountChanged { throw RecordingFailure.accountChanged }
    if event.kind == .connectionChanged, event.connectionId == connectionId,
      event.payload["transport"]?.stringValue != TransportStatus.connected.rawValue
    {
      throw RecordingFailure.disconnected
    }
    guard event.threadId == threadId else { return }
    var fields: [String: JSONValue] = [:]
    switch event.kind {
    case .threadUpdated:
      guard let thread = event.payload["thread"],
        (try? thread.decode(ConversationThread.self)) != nil
      else { throw RecordingFailure.malformedEvent }
      if let deleted = thread["userDeletedAt"], !deleted.isNull { throw RecordingFailure.threadDeleted }
      return
    case .turnAcknowledged, .turnStateChanged, .turnFinished:
      guard let value = event.payload["turn"], let turn = try? value.decode(Turn.self),
        turn.threadId == threadId, turn.id == event.turnId
      else { throw RecordingFailure.malformedEvent }
      fields = [
        "id": .string(turn.id), "status": .string(turn.status.rawValue),
        "submission": .string(turn.submission.rawValue),
        "outcome": turn.outcome.map { .string($0.rawValue) } ?? .null,
      ]
      if turn.status == .terminal { activeTurns.remove(turn.id) } else { activeTurns.insert(turn.id) }
    case .messageStarted, .messageCompleted, .toolStarted, .toolCompleted:
      guard let value = event.payload["displayItem"], let item = try? value.decode(DisplayItem.self),
        item.threadId == threadId, let turnId = item.turnId, turnId == event.turnId
      else { throw RecordingFailure.malformedEvent }
      fields = [
        "id": .string(item.id), "role": .string(item.role.rawValue),
        "type": .string(item.type), "provenance": .string(item.provenance.rawValue),
      ]
      if let native = item.nativeItemId { fields["nativeItemId"] = .string(native) }
      for key in ["text", "name", "input", "output", "status", "event", "data", "label"] {
        if let value = item.payload[key] { fields[key] = value }
      }
    case .messageDelta:
      guard let native = event.nativeIds["itemId"], let delta = event.payload["delta"]?.stringValue,
        event.turnId != nil
      else { throw RecordingFailure.malformedEvent }
      fields = ["nativeItemId": .string(native), "delta": .string(delta)]
    case .runtimeRequestOpened, .runtimeRequestResolved, .runtimeRequestExpired:
      guard let value = event.payload["runtimeRequest"], let request = try? value.decode(RuntimeRequest.self),
        request.threadId == threadId, request.turnId != nil, request.turnId == event.turnId
      else { throw RecordingFailure.malformedEvent }
      fields = [
        "id": .string(request.id), "kind": .string(request.kind.rawValue),
        "state": .string(request.state.rawValue),
      ]
      // The B4 prompt is renderable without the opaque approval grant or native request ID.
      let prompt = request.payload["request"]
      var display: [String: JSONValue] = [:]
      for key in ["toolName", "command", "path"] {
        if let value = prompt?[key] { display[key] = value }
      }
      if let preview = prompt?["detail"]?["argsPreview"] { display["argsPreview"] = preview }
      if !display.isEmpty { fields["prompt"] = .object(display) }
      // A resolution does not expose the answer in the current protocol.
      if request.state == .pending {
        pendingRequests.insert(request.id)
      } else {
        pendingRequests.remove(request.id)
      }
    default: throw RecordingFailure.unsupportedEvent
    }
    let recorded = RecordedEvent(
      sourceSequence: envelope.sequence, elapsedMs: elapsedMs,
      kind: event.kind, turnId: event.turnId, fields: .object(fields))
    let size = try JSONCoding.encoder.encode(recorded).count
    guard events.count < 50_000, size <= maxBytes - bytes else { throw RecordingFailure.limitExceeded }
    bytes += size
    events.append(recorded)
  }
}

public enum RecordingStatus: String, Sendable {
  case preparing, ready, recording, finishing, finished, invalid
}

/// Opt-in, fresh-thread recorder. Owns no files or coordinator state.
public actor RecordingSession {
  public private(set) var status: RecordingStatus = .preparing
  public private(set) var failure: RecordingFailure?
  private let client: WorkspaceClient
  private let threadId: String
  private let maxDuration: Duration
  private let maxBytes: Int
  private let waitForDeadline: @Sendable (Duration) async throws -> Void
  private var started = false
  private var buffer: RecordingBuffer?
  private var queued: [EventEnvelope] = []
  private var queuedBytes = 0
  private let clock = ContinuousClock()
  private var origin: ContinuousClock.Instant?
  private var tasks: [Task<Void, Never>] = []

  public init(
    client: WorkspaceClient, threadId: String, maxDuration: Duration = .seconds(900),
    maxBytes: Int = 20 * 1024 * 1024,
    waitForDeadline: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.client = client
    self.threadId = threadId
    self.maxDuration = maxDuration
    self.maxBytes = maxBytes
    self.waitForDeadline = waitForDeadline
  }

  public func start() async throws {
    guard !started, maxDuration > .zero, maxDuration <= .seconds(900), maxBytes > 0 else {
      throw RecordingFailure.invalidState
    }
    started = true
    let events = await client.events()
    let desync = await client.desync()
    tasks.append(
      Task { [weak self] in
        for await event in events { await self?.receive(event) }
        await self?.invalidate(.disconnected)
      })
    tasks.append(
      Task { [weak self] in
        for await reason in desync { await self?.invalidate(reason == .gap ? .gap : .epochChanged) }
      })
    tasks.append(
      Task { [weak self, maxDuration, waitForDeadline] in
        do { try await waitForDeadline(maxDuration) } catch { return }
        await self?.invalidate(.timedOut)
      })
    do {
      let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
      try checkValid()
      guard let thread = snapshot.threads.first(where: { $0.id == threadId }), thread.userDeletedAt == nil,
        let connection = snapshot.connections.first(where: { $0.id == thread.connectionId }),
        connection.kind == .b4
      else { throw RecordingFailure.notB4 }
      await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
      let read = try await client.request(ThreadRead.self, .init(threadId: threadId))
      try checkValid()
      guard read.thread.connectionId == connection.id, read.thread.userDeletedAt == nil,
        read.turns.isEmpty, read.items.isEmpty, read.requests.isEmpty,
        !snapshot.activeTurns.contains(where: { $0.threadId == threadId })
      else { throw RecordingFailure.nonemptyThread }
      let replay = try await client.request(
        EventsReplay.self, .init(epoch: snapshot.epoch, afterSequence: snapshot.sequence))
      try checkValid()
      var pending = RecordingBuffer(threadId: threadId, connectionId: connection.id, maxBytes: maxBytes)
      pending.begin(epoch: snapshot.epoch, sequence: snapshot.sequence)
      for event in (replay.events + queued).sorted(by: { $0.sequence < $1.sequence }) {
        guard event.epoch == snapshot.epoch else { throw RecordingFailure.epochChanged }
        if event.sequence > snapshot.sequence, event.event.threadId == threadId {
          throw RecordingFailure.setupActivity
        }
        try pending.accept(event, elapsedMs: 0)
      }
      queued.removeAll()
      queuedBytes = 0
      buffer = pending
      origin = clock.now
      status = .ready
    } catch {
      invalidate((error as? RecordingFailure) ?? .disconnected)
      throw failure ?? .invalidState
    }
  }

  /// A replay barrier includes events published before this explicit finish. Never
  /// fills missing deltas from a final snapshot. Active turns and prompts block it.
  public func finish() async throws -> [RecordedEvent] {
    try checkValid()
    guard status == .ready || status == .recording, let cursor = buffer?.cursor, let epoch = cursor.epoch
    else { throw RecordingFailure.invalidState }
    status = .finishing
    do {
      let replay = try await client.request(
        EventsReplay.self, .init(epoch: epoch, afterSequence: cursor.sequence))
      try checkValid()
      for event in replay.events { receive(event) }
      try checkValid()
      let audit = try await client.request(ThreadRead.self, .init(threadId: threadId))
      try checkValid()
      guard audit.thread.userDeletedAt == nil else { throw RecordingFailure.threadDeleted }
      guard audit.turns.allSatisfy({ $0.status == .terminal }),
        audit.requests.allSatisfy({ $0.state != .pending }),
        let buffer, buffer.isSettled
      else { throw RecordingFailure.unsettled }
      // A turn can finish between the replay barrier and this read. Reject an
      // unobserved turn instead of silently returning an incomplete recording.
      let observedTurns = Set(
        buffer.events.compactMap { event -> String? in
          guard [.turnAcknowledged, .turnStateChanged, .turnFinished].contains(event.kind) else { return nil }
          return event.turnId
        })
      guard observedTurns == Set(audit.turns.map(\.id)) else { throw RecordingFailure.unsettled }
      status = .finished
      stopTasks()
      return buffer.events
    } catch {
      invalidate((error as? RecordingFailure) ?? .disconnected)
      throw failure ?? .invalidState
    }
  }

  public func abort() { invalidate(.aborted) }

  private func checkValid() throws {
    if let failure { throw failure }
  }

  private func receive(_ event: EventEnvelope) {
    guard status != .finished, status != .invalid else { return }
    do {
      if status == .preparing {
        if event.event.kind == .accountChanged { throw RecordingFailure.accountChanged }
        let size = try JSONCoding.encoder.encode(event).count
        guard queued.count < 50_000, size <= maxBytes - queuedBytes else {
          throw RecordingFailure.limitExceeded
        }
        queuedBytes += size
        queued.append(event)
        return
      }
      guard let origin else { throw RecordingFailure.invalidState }
      let duration = origin.duration(to: clock.now).components
      let elapsedMs = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
      try buffer?.accept(event, elapsedMs: elapsedMs)
      if status == .ready, buffer?.events.isEmpty == false { status = .recording }
    } catch { invalidate((error as? RecordingFailure) ?? .malformedEvent) }
  }

  private func invalidate(_ reason: RecordingFailure) {
    guard status != .finished, status != .invalid else { return }
    failure = reason
    status = .invalid
    buffer = nil
    queued.removeAll()
    stopTasks()
  }

  private func stopTasks() {
    for task in tasks { task.cancel() }
    tasks.removeAll()
  }
}
