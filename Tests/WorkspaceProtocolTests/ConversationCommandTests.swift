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
      .connectionAdd, .connectionInspect, .connectionLogin, .threadCreate, .threadUpdate, .threadReconcile,
      .turnSend,
      .turnInterrupt, .turnAbandon, .requestRespond, .draftSave, .credentialAdd, .serverAdd, .serverStart,
      .serverRestart,
      .serverStop, .serverInspect, .workspaceStopLocalWork, .workspaceReconcile, .databaseBackup,
      .databaseRestore, .databaseImportSQLite,
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

  @Test func b4ConnectionParamsAndOptionalWorkingDirectoryRoundTrip() throws {
    let add = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"connection.add","params":{"kind":"b4","url":"http://127.0.0.1:8000","route":"/chat#agent","authReference":"secret:abc"}}"#
    )
    let params = try add.params(for: ConnectionAdd.self)
    #expect(params.kind == .b4)
    #expect(params.url == "http://127.0.0.1:8000")
    #expect(params.route == "/chat#agent")
    #expect(params.authReference == "secret:abc")
    #expect(params.executablePath == nil)
    let create = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"thread.create","params":{"connectionId":"c"}}"#
    )
    #expect(try create.params(for: ThreadCreate.self) == ThreadCreate.Params(connectionId: "c"))
    do {
      _ = try parse(
        #"{"protocolVersion":1,"kind":"command","requestId":"r","method":"credential.add","params":{"label":"x","value":"y"}}"#
      )
      Issue.record("credential.add without operationId must be rejected")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
  }
}
