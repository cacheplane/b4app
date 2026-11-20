import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import Coordinator

func runtimeAck(_ connection: Connection, _ thread: ConversationThread, turn: String) -> AdapterEvent {
  AdapterEvent(
    kind: .turnAcknowledged, connectionId: connection.id,
    nativeIds: ["threadId": thread.nativeThreadId, "turnId": .init(turn)],
    payload: ["origin": "runtime", "status": "inProgress"])
}

func injecting() async throws -> (Harness, AsyncStream<AdapterEvent>.Continuation) {
  let (injected, deliver) = AsyncStream<AdapterEvent>.makeStream()
  let h = try await Harness.start(adapterFactory: { connection, environment, version, secrets in
    InjectingAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
      injected: injected)
  })
  return (h, deliver)
}

@Suite struct RuntimeTurnTests {
  struct Fixture {
    let h: Harness
    let deliver: AsyncStream<AdapterEvent>.Continuation
    let connection: Connection
    let thread: ConversationThread

    static func make() async throws -> Fixture {
      let (h, deliver) = try await injecting()
      let connection = try await h.addCodex()
      let thread = try await h.newThread(connection)
      let turn = try await h.send(thread, "hello there")
      _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
      return Fixture(h: h, deliver: deliver, connection: connection, thread: thread)
    }

    /// Delivers `event` and waits for the coordinator to publish an event of its kind.
    func send(_ event: AdapterEvent) async {
      let kind = event.kind
      let before = await h.events.events.filter { $0.event.kind == kind }.count
      deliver.yield(event)
      _ = await h.events.until { $0.filter { $0.kind == kind }.count > before }
    }

    func event(
      _ kind: EventKind, turn: String?, payload: JSONValue = [:], item: String? = nil
    )
      -> AdapterEvent
    {
      var ids = ["threadId": thread.nativeThreadId]
      if let turn { ids["turnId"] = turn }
      if let item { ids["itemId"] = item }
      return AdapterEvent(kind: kind, connectionId: connection.id, nativeIds: ids, payload: payload)
    }

    func message(turn: String?, id: String = "m-1") -> AdapterEvent {
      event(
        .messageCompleted, turn: turn,
        payload: [
          "role": "assistant", "type": "agentMessage",
          "item": ["text": "done"],
        ], item: id)
    }

    func turns() async throws -> [Turn] { try await h.read(thread).turns }
  }

  @Test func aRuntimeAcknowledgementMakesATurnRow() async throws {
    let f = try await Fixture.make()
    let itemsBefore = try await f.h.read(f.thread).items.count
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let turns = try await f.turns()
    #expect(turns.count == 2)
    let made = try #require(turns.first { $0.nativeTurnId == "rt-1" })
    #expect(made.origin == "runtime")
    #expect(made.operationId == "runtime:rt-1")
    #expect(made.status == .running)
    #expect(made.submission == .acknowledged)
    let published = try #require(
      await f.h.events.events.last { $0.event.kind == .turnAcknowledged }?.event)
    #expect(published.turnId == made.id)
    #expect(published.payload["turn"]?["id"]?.stringValue == made.id)
    #expect(try await f.h.read(f.thread).items.count == itemsBefore)
    await f.h.stop()
  }

  @Test func aRuntimeTurnTakesItsItemsAndItsEnd() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(f.message(turn: "rt-1"))
    await f.send(
      f.event(.turnFinished, turn: "rt-1", payload: ["outcome": "completed", "origin": "task-notification"]))
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == made.id)
    #expect(made.status == .terminal)
    #expect(made.outcome == .completed)
    #expect(made.origin == "task-notification")
    await f.h.stop()
  }

  @Test func aRepeatedRuntimeAcknowledgementMakesOneRow() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    #expect(try await f.turns().count == 2)
    await f.h.stop()
  }

  @Test func aRuntimeAcknowledgementDuringAnUnfinishedTurnMakesNoRow() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-2"))
    #expect(try await f.turns().count == 2)
    let first = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    await f.send(f.message(turn: "rt-2"))
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == first.id)
    await f.send(f.event(.turnFinished, turn: "rt-2", payload: ["outcome": "completed"]))
    let after = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    #expect(after.status == .running)
    await f.h.stop()
  }

  @Test func aFinishNamingAnUnknownTurnEndsNoTurn() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let before = try await f.turns()
    await f.send(f.event(.turnFinished, turn: "zz", payload: ["outcome": "completed"]))
    let after = try await f.turns()
    let running = try #require(after.first { $0.nativeTurnId == "rt-1" })
    #expect(running.status == .running)
    #expect(after.first?.updatedAt == before.first?.updatedAt)
    #expect(after == before)
    await f.h.stop()
  }

  @Test func anAcknowledgementWithoutOriginMakesNoRow() async throws {
    let f = try await Fixture.make()
    await f.send(f.event(.turnAcknowledged, turn: "rt-9", payload: ["status": "inProgress"]))
    #expect(try await f.turns().count == 1)
    await f.h.stop()
  }

  @Test func anEventNamingNoTurnStillJoinsTheActiveTurn() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(f.message(turn: nil))
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == made.id)
    await f.h.stop()
  }
}
