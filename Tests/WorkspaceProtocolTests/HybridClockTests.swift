import Foundation
import Synchronization
import Testing

@testable import WorkspaceProtocol

@Suite struct HybridClockTests {
  @Test func hlcSortsByMillisThenCounterThenDevice() {
    #expect(HLC(millis: 1, counter: 9, deviceId: "b") < HLC(millis: 2, counter: 0, deviceId: "a"))
    #expect(HLC(millis: 2, counter: 0, deviceId: "a") < HLC(millis: 2, counter: 1, deviceId: "a"))
    #expect(HLC(millis: 2, counter: 0, deviceId: "a") < HLC(millis: 2, counter: 0, deviceId: "b"))
    #expect(HLC(rawValue: "0192e0f1a2b3-0000-dev")?.millis == 0x0192_e0f1_a2b3)
    #expect(HLC(rawValue: "not-a-clock") == nil)
  }

  @Test func textIsLowercaseHexAndASortedString() {
    let hlc = HLC(millis: 0x0192_e0f1_a2b3, counter: 0xAB, deviceId: "01a194cf-0d12-7418-b3b5-5559dbee2441")
    #expect(hlc.rawValue == "0192e0f1a2b3-00ab-01a194cf-0d12-7418-b3b5-5559dbee2441")
    let a = HLC(millis: 9, counter: 0, deviceId: "x")
    let b = HLC(millis: 10, counter: 0, deviceId: "x")
    #expect(a.rawValue < b.rawValue && a < b)
  }

  @Test func aDeviceIdMayContainDashes() throws {
    let hlc = try #require(HLC(rawValue: "0192e0f1a2b3-0007-01a194cf-0d12-7418-b3b5-5559dbee2441"))
    #expect(hlc.counter == 7)
    #expect(hlc.deviceId == "01a194cf-0d12-7418-b3b5-5559dbee2441")
    #expect(hlc.rawValue == "0192e0f1a2b3-0007-01a194cf-0d12-7418-b3b5-5559dbee2441")
  }

  @Test func rejectsUppercaseWrongLengthAndEmptyDevice() {
    #expect(HLC(rawValue: "0192E0F1A2B3-0000-dev") == nil)
    #expect(HLC(rawValue: "192e0f1a2b3-0000-dev") == nil)
    #expect(HLC(rawValue: "0192e0f1a2b3-000-dev") == nil)
    #expect(HLC(rawValue: "0192e0f1a2b3-00000-dev") == nil)
    #expect(HLC(rawValue: "0192e0f1a2b3-0000-") == nil)
    #expect(HLC(rawValue: "0192e0f1a2b3-0000") == nil)
    #expect(HLC(rawValue: "0192e0f1a2bg-0000-dev") == nil)
  }

  @Test func codableAsASingleString() throws {
    let hlc = HLC(millis: 5, counter: 1, deviceId: "dev")
    let data = try JSONCoding.encoder.encode([hlc])
    #expect(String(decoding: data, as: UTF8.self) == #"["000000000005-0001-dev"]"#)
    #expect(try JSONCoding.decoder.decode([HLC].self, from: data) == [hlc])
    #expect(throws: DecodingError.self) {
      try JSONCoding.decoder.decode([HLC].self, from: Data(#"["nope"]"#.utf8))
    }
  }

  @Test func clampsAClockFarAhead() {
    // Within five minutes (300 000 ms) of the wall stays; beyond it is rewritten.
    let far = HLC(millis: 1_000_000, counter: 7, deviceId: "p")
    #expect(far.clamped(toWall: 600_000) == HLC(millis: 600_000, counter: 0, deviceId: "p"))
    #expect(HLC(millis: 800_000, counter: 7, deviceId: "p").clamped(toWall: 600_000).millis == 800_000)
    #expect(HLC(millis: 900_000, counter: 7, deviceId: "p").clamped(toWall: 600_000).millis == 900_000)
    #expect(HLC(millis: 900_001, counter: 7, deviceId: "p").clamped(toWall: 600_000).millis == 600_000)
  }

  @Test func nextIsMonotonicWhenTheWallStandsStillOrGoesBack() {
    let walls = Mutex<[UInt64]>([100, 100, 90])
    let clock = HybridClock(deviceId: "d") { walls.withLock { $0.removeFirst() } }
    let first = clock.next()
    let second = clock.next()
    let third = clock.next()
    #expect(first < second && second < third)
    #expect(first.millis == 100 && first.counter == 0)
    #expect(third.millis == 100 && third.counter == 2)
    #expect([first, second, third].allSatisfy { $0.deviceId == "d" })
  }

  @Test func nextFollowsTheWallForward() {
    let walls = Mutex<[UInt64]>([100, 250])
    let clock = HybridClock(deviceId: "d") { walls.withLock { $0.removeFirst() } }
    _ = clock.next()
    #expect(clock.next() == HLC(millis: 250, counter: 0, deviceId: "d"))
  }

  @Test func theCounterRollsIntoTheNextMillisecondInsteadOfWrapping() {
    let clock = HybridClock(deviceId: "d") { 100 }
    clock.observe(HLC(millis: 100, counter: UInt16.max, deviceId: "z"))
    let next = clock.next()
    #expect(next > HLC(millis: 100, counter: UInt16.max, deviceId: "z"))
    #expect(next.millis == 101 && next.counter == 0)
  }

  @Test func observeAdvancesPastARemoteClock() {
    let clock = HybridClock(deviceId: "a") { 100 }
    let remote = HLC(millis: 500, counter: 3, deviceId: "z")
    clock.observe(remote)
    #expect(clock.next() > remote)
  }

  @Test func observingAnOlderClockChangesNothing() {
    let clock = HybridClock(deviceId: "a") { 100 }
    clock.observe(HLC(millis: 500, counter: 3, deviceId: "z"))
    clock.observe(HLC(millis: 400, counter: 9, deviceId: "z"))
    #expect(clock.next() == HLC(millis: 500, counter: 4, deviceId: "a"))
  }

  @Test func theDeviceIdCanChange() {
    let clock = HybridClock(deviceId: "old") { 100 }
    clock.deviceId = "new"
    #expect(clock.deviceId == "new")
    #expect(clock.next().deviceId == "new")
  }

  @Test func concurrentCallsNeverRepeat() async {
    let clock = HybridClock(deviceId: "d") { 100 }
    let all = await withTaskGroup(of: [HLC].self) { group in
      for _ in 0..<8 { group.addTask { (0..<200).map { _ in clock.next() } } }
      return await group.reduce(into: []) { $0 += $1 }
    }
    #expect(Set(all).count == 1600)
  }

  @Test func phoneWritableListIsExact() {
    #expect(
      SyncColumns.phoneWritable == [
        "threads": ["title", "pinned", "archived", "readTurnId"],
        "projects": ["name"],
        "drafts": ["threadId", "text", "updatedAt"],
      ])
    var expected = SyncColumns.phoneWritable
    expected["threads", default: []].insert("projectId")
    #expect(SyncColumns.clocked == expected)
    #expect(SyncColumns.isPhoneWritable(table: "threads", column: "pinned"))
    #expect(SyncColumns.isPhoneWritable(table: "drafts", column: "text"))
    #expect(!SyncColumns.isPhoneWritable(table: "threads", column: "projectId"))
    #expect(!SyncColumns.isPhoneWritable(table: "threads", column: "context"))
    #expect(!SyncColumns.isPhoneWritable(table: "turns", column: "status"))
  }
}
