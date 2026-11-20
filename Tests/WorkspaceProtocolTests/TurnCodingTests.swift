import Foundation
import Testing

@testable import WorkspaceProtocol

@Suite struct TurnCodingTests {
  private let old =
    #"{"id":"u1","threadId":"t1","operationId":"op1","nativeTurnId":null,"inputRef":null,"status":"terminal","submission":"acknowledged","outcome":"completed","createdAt":"2026-11-19T10:00:00Z","updatedAt":"2026-11-19T10:01:00Z"}"#

  @Test func aTurnWrittenBeforeTheFieldsReadsAsNoOpenWorkAndNoOrigin() throws {
    let turn = try JSONCoding.decoder.decode(Turn.self, from: Data(old.utf8))
    #expect(turn.openWork == 0)
    #expect(turn.origin == nil)
  }

  @Test func aNullOpenWorkReadsAsZero() throws {
    let json = old.replacingOccurrences(
      of: #""outcome":"completed""#, with: #""outcome":"completed","openWork":null,"origin":null"#)
    #expect(try JSONCoding.decoder.decode(Turn.self, from: Data(json.utf8)).openWork == 0)
  }

  @Test func theFieldsRoundTrip() throws {
    let turn = Turn(id: "u1", threadId: "t1", operationId: "op1", openWork: 2, origin: "task-notification")
    let back = try JSONCoding.decoder.decode(Turn.self, from: JSONCoding.encoder.encode(turn))
    #expect(back == turn)
  }
}
