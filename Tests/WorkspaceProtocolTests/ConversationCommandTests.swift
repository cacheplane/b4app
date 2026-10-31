import Foundation
import Testing

@testable import WorkspaceProtocol

private func parse(_ json: String) throws -> ParsedCommand { try parseCommand(Data(json.utf8)) }

@Suite struct ConversationCommandTests {
  @Test func turnSendIsAMutationAndThreadReadIsNot() throws {
    do {
      _ = try parse(
        #"{"protocolVersion":1,"kind":"command","requestId":"r","method":"turn.send","params":{"threadId":"t","text":"hi"}}"#
      )
      Issue.record("turn.send without operationId must be rejected")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    let read = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","method":"thread.read","params":{"threadId":"t"}}"#
    )
    #expect(try read.params(for: ThreadRead.self).threadId == "t")
    let send = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"turn.send","params":{"threadId":"t","text":"hi"}}"#
    )
    #expect(try send.params(for: TurnSend.self) == TurnSend.Params(threadId: "t", text: "hi"))
  }

  @Test func everyNewMethodDeclaresItsMutationFlag() {
    let mutations: Set<WorkspaceProtocol.Method> = [
      .connectionAdd, .connectionInspect, .connectionLogin, .threadCreate, .threadUpdate, .turnSend,
      .turnInterrupt, .requestRespond, .draftSave,
    ]
    for method in WorkspaceProtocol.Method.allCases {
      #expect(method.isMutation == mutations.contains(method), "\(method)")
    }
  }

  @Test func requestRespondDecodesDecisionsAndAnswers() throws {
    let decision = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"request.respond","params":{"requestId":"q","decision":"allow_once"}}"#
    )
    #expect(try decision.params(for: RequestRespond.self).decision == .allowOnce)
    let answers = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"request.respond","params":{"requestId":"q","answers":{"color":["red"]}}}"#
    )
    #expect(try answers.params(for: RequestRespond.self).answers == ["color": ["red"]])
    let bad = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"request.respond","params":{"requestId":"q","decision":"maybe"}}"#
    )
    #expect(throws: WorkspaceError.self) { try bad.params(for: RequestRespond.self) }
  }
}
