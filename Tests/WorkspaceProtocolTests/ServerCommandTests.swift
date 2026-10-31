import Foundation
import Testing

@testable import WorkspaceProtocol

private func parse(_ json: String) throws -> ParsedCommand { try parseCommand(Data(json.utf8)) }

@Suite struct ServerCommandTests {
  @Test func serverMutationsRequireAnOperationId() throws {
    #expect(throws: WorkspaceError.self) {
      try parse(
        #"{"protocolVersion":1,"kind":"command","requestId":"r","method":"server.start","params":{"serverId":"s"}}"#
      )
    }
    let list = try parse(#"{"protocolVersion":1,"kind":"command","requestId":"r","method":"server.list"}"#)
    #expect(list.method == .serverList)
    let logs = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","method":"server.logs","params":{"serverId":"s","lines":50}}"#
    )
    #expect(try logs.params(for: ServerLogs.self) == ServerLogs.Params(serverId: "s", lines: 50))
    let mutations: Set<WorkspaceProtocol.Method> = [
      .serverAdd, .serverStart, .serverRestart, .serverStop, .serverInspect,
    ]
    for method in [
      Method.serverAdd, .serverList, .serverStart, .serverStatus, .serverLogs, .serverRestart,
      .serverStop, .serverInspect,
    ] {
      #expect(method.isMutation == mutations.contains(method), "\(method)")
    }
  }

  @Test func serverAddParamsRoundTrip() throws {
    let params = ServerAdd.Params(
      projectPath: "/p", name: "research", launchMode: .development, envFilePath: "/p/.env", port: 3101)
    let decoded = try JSONValue(encoding: params).decode(ServerAdd.Params.self)
    #expect(decoded == params)
    let stop = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"server.stop","params":{"serverId":"s","force":true}}"#
    )
    #expect(try stop.params(for: ServerStop.self) == ServerStop.Params(serverId: "s", force: true))
    let add = try parse(
      #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"op","method":"connection.add","params":{"kind":"b4","serverId":"s","route":"/chat#agent"}}"#
    )
    #expect(try add.params(for: ConnectionAdd.self).serverId == "s")
  }

  @Test func localServerRoutesRoundTripAsJSON() throws {
    let route = LocalServerRoute(id: "/chat", kind: "agent", entryFile: "src/app/chat/index.ts")
    let server = LocalServer(
      id: "s", name: "research", projectPath: "/p", nodePath: "/n", cliPath: "/p/cli.js",
      launchMode: .source, routes: [route])
    let decoded = try JSONValue(encoding: server).decode(LocalServer.self)
    #expect(decoded == server)
    #expect(decoded.routes.first?.key == "/chat#agent")
    let event = try AdapterEvent.serverChanged(server)
    #expect(event.kind == .serverChanged)
    #expect(try event.payload["server"]?.decode(LocalServer.self) == server)
  }
}
