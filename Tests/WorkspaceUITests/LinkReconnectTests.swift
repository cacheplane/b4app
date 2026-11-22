import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

/// Hands out one transport per connect, in order; a `nil` entry fails that connect.
nonisolated private final class TransportQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [ScriptedTransport?]
  private(set) var connects = 0

  init(_ queue: [ScriptedTransport?]) { self.queue = queue }

  var count: Int { lock.withLock { connects } }

  func next() throws -> any WorkspaceTransport {
    let transport = lock.withLock { () -> ScriptedTransport?? in
      connects += 1
      return queue.isEmpty ? .some(nil) : queue.removeFirst()
    }
    ConditionNudge.post()
    guard let transport = transport ?? nil else {
      throw WorkspaceError(.endpointUnavailable, "no coordinator")
    }
    return transport
  }
}

private func thread(_ id: String) -> ConversationThread {
  ConversationThread(
    id: id, connectionId: "c1", nativeThreadId: "n-\(id)", nativeScope: "owner@example.com", title: id,
    context: "/tmp")
}

/// The coordinator restarts (an update, `coordinator restart`, a crash) and its socket closes. The
/// Mac connects again by itself, so a thread made meanwhile, from the CLI or elsewhere, is listed.
@Suite(.serialized) @MainActor struct LinkReconnectTests {
  @Test func aClosedLinkConnectsAgainByItself() async throws {
    let first = ScriptedTransport()
    first.set(threads: [thread("before")])
    let second = ScriptedTransport()
    second.set(threads: [thread("before"), thread("made-meanwhile")])
    let transports = TransportQueue([first, second])
    let clock = TestClock()
    let model = WorkspaceModel(transportProvider: { try transports.next() })
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)

    await first.close()
    try await waitUntil("the next attempt waits") { model.link == .unavailable && clock.sleepingCount > 0 }
    clock.advance(by: WorkspaceModel.reconnectDelays[0])
    try await waitUntil("connected again") { model.link == .ready && transports.count == 2 }
    #expect(model.threads.map(\.id).sorted() == ["before", "made-meanwhile"])
    await model.disconnect()
  }

  @Test func aFailedAttemptTriesAgainLater() async throws {
    let first = ScriptedTransport()
    let second = ScriptedTransport()
    second.set(threads: [thread("made-meanwhile")])
    let transports = TransportQueue([first, nil, second])
    let clock = TestClock()
    let model = WorkspaceModel(transportProvider: { try transports.next() })
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)

    await first.close()
    try await waitUntil("the first attempt waits") { clock.sleepingCount > 0 }
    clock.advance(by: WorkspaceModel.reconnectDelays[0])
    try await waitUntil("the second attempt waits") { transports.count == 2 && clock.sleepingCount > 0 }
    #expect(model.link == .unavailable)
    clock.advance(by: WorkspaceModel.reconnectDelays[1])
    try await waitUntil("connected again") { model.link == .ready && transports.count == 3 }
    #expect(model.threads.map(\.id) == ["made-meanwhile"])
    await model.disconnect()
  }

  @Test func disconnectingStopsTheAttempts() async throws {
    let first = ScriptedTransport()
    let transports = TransportQueue([first])
    let clock = TestClock()
    let model = WorkspaceModel(transportProvider: { try transports.next() })
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)

    await first.close()
    try await waitUntil("the next attempt waits") { clock.sleepingCount > 0 }
    await model.disconnect()
    try await waitUntil("the wait is cancelled") { clock.sleepingCount == 0 }
    clock.advance(by: .seconds(60))
    #expect(transports.count == 1)
    #expect(model.link == .unavailable)
  }
}
