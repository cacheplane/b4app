import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

@Suite struct FakeHubWritesTests {
  private func enrolled() -> EnrollResponse {
    EnrollResponse(
      deviceId: "dev-1", token: "tok", org: OrgInfo(slug: "o", name: "O"),
      user: UserInfo(username: "u", displayName: "U"))
  }

  private func fake(platform: String, name: String = "Device") async throws -> FakeHubAPI {
    let fake = FakeHubAPI(enrollmentCodes: ["ABCD2345": enrolled()])
    _ = try await fake.enroll(EnrollRequest(code: "ABCD2345", deviceName: name, platform: platform))
    return fake
  }

  private func update(
    _ seq: Int, table: String = "threads", column: String, value: JSONValue = "x", hlc: String? = nil
  ) -> SyncChange {
    SyncChange(
      deviceSeq: seq, wall: seq, table: table, rowId: "r\(seq)", op: "update", column: column, value: value,
      hlc: hlc)
  }

  @Test func meEchoesTheEnrollRequest() async throws {
    let phone = try await fake(platform: "ios", name: "Brian's iPhone")
    let me = try await phone.me()
    #expect(me.deviceName == "Brian's iPhone" && me.platform == "ios")
    #expect(me.deviceId == "dev-1")

    // The last enroll wins.
    await phone.addEnrollmentCode("WXYZ2345", enrolled())
    _ = try await phone.enroll(EnrollRequest(code: "WXYZ2345", deviceName: "Mac", platform: "macos"))
    let again = try await phone.me()
    #expect(again.deviceName == "Mac" && again.platform == "macos")
  }

  @Test func pushReportsRejectedPhoneColumns() async throws {
    let phone = try await fake(platform: "ios")
    let batch = [
      update(1, column: "title"),
      update(2, column: "status"),
      update(3, table: "environments", column: "name"),
      update(4, table: "environments", column: "createdAt"),
      SyncChange(deviceSeq: 5, wall: 5, table: "threads", rowId: "r5", op: "delete"),
      SyncChange(deviceSeq: 6, wall: 6, table: "drafts", rowId: "r6", op: "insert", value: .object([:])),
      SyncChange(deviceSeq: 7, wall: 7, table: "threads", rowId: "r7", op: "insert", value: .object([:])),
      // The view settings row, which a phone may insert and update, as it may a draft.
      SyncChange(
        deviceSeq: 8, wall: 8, table: "viewSettings", rowId: "view", op: "insert", value: .object([:])),
      SyncChange(
        deviceSeq: 9, wall: 9, table: "viewSettings", rowId: "view", op: "update", column: "quietThreads",
        value: "x"),
    ]

    let response = try await phone.push(batch)

    #expect(response.acceptedThrough == 9)
    #expect(
      response.rejected.map(\.deviceSeq) == [2, 4, 5, 7])
    #expect(response.rejected.allSatisfy { $0.code == "column_not_writable" })
    // A rejected change is not in the feed.
    #expect(await phone.stored.map(\.deviceSeq) == [1, 3, 6, 8, 9])
  }

  @Test func aSettingsChangeUnderAnotherRowIdIsRefused() async throws {
    for platform in ["macos", "ios"] {
      let device = try await fake(platform: platform)
      let response = try await device.push([
        SyncChange(
          deviceSeq: 1, wall: 1, table: "viewSettings", rowId: "other", op: "insert", value: .object([:]))
      ])
      #expect(response.rejected == [RejectedChange(deviceSeq: 1, code: "invalid_row_id")])
      #expect(await device.stored.filter { $0.table == "viewSettings" }.isEmpty)

      // The row's own id is accepted.
      let accepted = try await device.push([
        SyncChange(
          deviceSeq: 2, wall: 2, table: "viewSettings", rowId: "view", op: "insert", value: .object([:]))
      ])
      #expect(accepted.rejected.isEmpty)
      #expect(await device.stored.filter { $0.table == "viewSettings" }.map(\.rowId) == ["view"])
    }
  }

  @Test func aMacMayWriteAnything() async throws {
    let mac = try await fake(platform: "macos")
    let response = try await mac.push([
      update(1, column: "status"),
      SyncChange(deviceSeq: 2, wall: 2, table: "threads", rowId: "t", op: "delete"),
    ])
    #expect(response.rejected.isEmpty && response.acceptedThrough == 2)
    #expect(await mac.stored.count == 2)
  }

  @Test func setPlatformChangesTheWriteRule() async throws {
    let device = try await fake(platform: "macos")
    await device.setPlatform("cli")
    let response = try await device.push([update(1, column: "status")])
    #expect(response.rejected == [RejectedChange(deviceSeq: 1, code: "column_not_writable")])
  }

  @Test func anOversizedValueAndABadClockAreRejectedPerChange() async throws {
    let mac = try await fake(platform: "macos")
    let big = JSONValue.string(String(repeating: "a", count: 2_097_152))
    let response = try await mac.push([
      update(1, column: "title", value: big),
      update(2, column: "title", hlc: "not-a-clock"),
      update(3, column: "title", hlc: "019a396c76e8-0000-dev-1"),
    ])
    #expect(
      response.rejected == [
        RejectedChange(deviceSeq: 1, code: "payload_too_large"),
        RejectedChange(deviceSeq: 2, code: "invalid_clock"),
      ])
    #expect(response.acceptedThrough == 3)
    let stored = await mac.stored
    #expect(stored.map(\.deviceSeq) == [3] && stored[0].hlc == "019a396c76e8-0000-dev-1")
  }

  @Test func aStoredChangeWithoutAClockGetsTheDerivedOne() async throws {
    let mac = try await fake(platform: "macos")
    _ = try await mac.push([
      SyncChange(deviceSeq: 1, wall: 1_761_900_001_000, table: "threads", rowId: "t", op: "delete")
    ])
    #expect(await mac.stored.first?.hlc == "019a396c76e8-0000-dev-1")
  }

  @Test func snapshotAndDevicesAreSettable() async throws {
    let fake = FakeHubAPI()
    let empty = try await fake.snapshot()
    #expect(empty.changes.isEmpty && empty.clocks.isEmpty && empty.next == 0)

    let snapshot = SnapshotResponse(
      changes: [
        StoredChange(
          hubSeq: 0, deviceId: "d", deviceSeq: 0, wall: 0, table: "threads", rowId: "t", op: "insert",
          value: .object([:]))
      ],
      clocks: [ColumnClock(table: "threads", rowId: "t", column: "title", hlc: "000000000001-0000-d")],
      next: 9)
    await fake.setSnapshot(snapshot)
    #expect(try await fake.snapshot() == snapshot)

    let devices = [
      DeviceInfo(id: "d", name: "Mac", platform: "macos", lastSeenAt: "2026-10-31T12:00:00.000000Z")
    ]
    await fake.setDevices(devices)
    #expect(try await fake.devices() == devices)
  }

  @Test func failNextAppliesToSnapshotAndDevices() async throws {
    let fake = FakeHubAPI()
    let gone = HubError(kind: "request_error", code: "resync_required", message: "Gone.", status: 410)
    await fake.setFailNext(gone)
    do {
      _ = try await fake.snapshot()
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == gone)
    }
    await fake.setFailNext(gone)
    do {
      _ = try await fake.devices()
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == gone)
    }
  }

  /// `setFailNextPull` is for the pull alone: another call made first does not take it, and a parked
  /// pull wakes and answers with it.
  @Test func failNextPullSkipsOtherCallsAndWakesAParkedPull() async throws {
    let fake = FakeHubAPI()
    let unauthorized = HubError(
      kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401)
    let parked = Task { try await fake.pull(after: 0, limit: 10, wait: 30) }
    await fake.untilPulling(1)
    await fake.setFailNextPull(unauthorized)
    _ = try await fake.devices()
    do {
      _ = try await parked.value
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == unauthorized)
    }
    // Used once: the next pull answers.
    _ = try await fake.pull(after: 0, limit: 10, wait: 0)
  }

  /// `setFailNextPush` is for the push alone and is used once.
  @Test func failNextPushSkipsOtherCalls() async throws {
    let fake = FakeHubAPI()
    let unauthorized = HubError(
      kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401)
    await fake.setFailNextPush(unauthorized)
    _ = try await fake.devices()
    _ = try await fake.pull(after: 0, limit: 10, wait: 0)
    do {
      _ = try await fake.push([])
      Issue.record("expected the injected failure")
    } catch let error as HubError {
      #expect(error == unauthorized)
    }
    _ = try await fake.push([])
  }
}
