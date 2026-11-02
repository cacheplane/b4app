import Foundation
import Testing

@testable import WorkspaceProtocol

@Suite struct ThreadDeleteTests {
  @Test func threadDeleteIsAMutationAndAllowlisted() {
    #expect(Method(rawValue: "thread.delete")?.isMutation == true)
    #expect(ThreadDelete.method == .threadDelete)
  }

  @Test func aThreadDecodesWithoutUserDeletedAt() throws {
    let json =
      #"{"id":"t","connectionId":"c","nativeThreadId":"n","nativeScope":"","title":"x","pinned":false,"archived":false,"continuity":"available","createdAt":"a","updatedAt":"b"}"#
    let thread = try JSONDecoder().decode(ConversationThread.self, from: Data(json.utf8))
    #expect(thread.userDeletedAt == nil)
    var deleted = thread
    deleted.userDeletedAt = "2026-11-02T12:00:00.000Z"
    let again = try JSONDecoder().decode(ConversationThread.self, from: JSONEncoder().encode(deleted))
    #expect(again.userDeletedAt == "2026-11-02T12:00:00.000Z")
  }

  @Test func userDeletedAtIsPhoneWritable() {
    #expect(SyncColumns.isPhoneWritable(table: "threads", column: "userDeletedAt"))
  }

  @Test func aSummaryRoundTrips() throws {
    let summary = ThreadDeleteSummary(kind: .claude, waiting: 1, unsupported: 2)
    #expect(
      try JSONDecoder().decode(ThreadDeleteSummary.self, from: JSONEncoder().encode(summary)) == summary)
  }
}
