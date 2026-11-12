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
      .databaseRestore, .databaseImportSQLite, .hubJoin, .hubLeave, .environmentCreate, .environmentUpdate,
      .environmentRename, .environmentDelete, .threadMarkRead, .threadStart, .settingsUpdate,
      .connectionUpdate,
      .accountPasskeyFinish, .accountAppleFinish, .accountCompleteProfile, .accountLogout,
      .accountAddPasskeyFinish, .accountRemoveIdentity, .accountDelete, .accountDismissNotice,
      .accountAppleLinkFinish, .credentialRemove, .threadDelete, .viewSettingsSet,
    ]
    for method in WorkspaceProtocol.Method.allCases {
      #expect(method.isMutation == mutations.contains(method), "\(method)")
    }
  }

  /// The account commands' secrets (a WebAuthn response, an Apple handoff) never print, and a log-out
  /// without `stopWork` refuses to stop work.
  @Test func accountParamsRedactTheirSecretsAndDefaultToNotStoppingWork() throws {
    let finish = AccountPasskeyFinish.Params(ceremonyId: "c", assertion: ["signature": "sig-secret-1"])
    #expect(!"\(finish)".contains("sig-secret-1"))
    #expect(!String(reflecting: finish).contains("sig-secret-1"))
    let apple = AccountAppleFinish.Params(handoff: "handoff-secret-2")
    #expect(!"\(apple)".contains("handoff-secret-2"))
    let added = AccountAddPasskeyFinish.Params(ceremonyId: "c", attestation: ["object": "att-secret-3"])
    #expect(!"\(added)".contains("att-secret-3"))
    let logout = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"account.logout","params":{}}"#
    )
    #expect(try logout.params(for: AccountLogout.self).stopWork == false)
    #expect(AccountStatus.method == .accountStatus)
  }

  @Test func environmentWireNamesAreTheNewOnes() throws {
    #expect(EnvironmentRename.method.rawValue == "environment.rename")
    #expect(EnvironmentList.method.rawValue == "environment.list")
    let thread = ConversationThread(
      id: "t1", connectionId: "c", nativeThreadId: "n1", createdAt: "2026-11-10T00:00:00Z",
      environmentId: "e1")
    let json = String(decoding: try JSONEncoder().encode(thread), as: UTF8.self)
    #expect(json.contains(#""environmentId":"e1""#) && !json.contains("projectId"))
  }

  @Test func environmentAndReadCommandsDecodeTheirParams() throws {
    func command(_ method: String, _ params: String) throws -> ParsedCommand {
      try parse(
        #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"\#(method)","params":\#(params)}"#
      )
    }
    let update = try command(
      "environment.update", #"{"environmentId":"p","name":"","addFolders":["/a"],"removeFolders":["/b"]}"#)
    #expect(
      try update.params(for: EnvironmentUpdate.self)
        == EnvironmentUpdate.Params(environmentId: "p", name: "", addFolders: ["/a"], removeFolders: ["/b"]))
    let bare = try command("environment.update", #"{"environmentId":"p"}"#)
    #expect(try bare.params(for: EnvironmentUpdate.self) == EnvironmentUpdate.Params(environmentId: "p"))
    #expect(
      try command("environment.create", #"{"name":"Site","folders":["/a"]}"#).params(
        for: EnvironmentCreate.self)
        == EnvironmentCreate.Params(name: "Site", folders: ["/a"]))
    #expect(
      try command("environment.rename", #"{"environmentId":"p","name":""}"#).params(
        for: EnvironmentRename.self)
        == EnvironmentRename.Params(environmentId: "p", name: ""))
    #expect(
      try command("environment.delete", #"{"environmentId":"p"}"#).params(for: EnvironmentDelete.self)
        == EnvironmentDelete.Params(environmentId: "p"))
    #expect(
      try command("thread.markRead", #"{"threadId":"t","turnId":"u"}"#).params(for: ThreadMarkRead.self)
        == ThreadMarkRead.Params(threadId: "t", turnId: "u"))
    #expect(
      try command("thread.markRead", #"{"threadId":"t"}"#).params(for: ThreadMarkRead.self)
        == ThreadMarkRead.Params(threadId: "t", turnId: nil))
    #expect(AdapterEvent.environmentChanged(environmentId: "p").payload["environmentId"]?.stringValue == "p")
    #expect(EventKind.environmentChanged.rawValue == "environment.changed")
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
