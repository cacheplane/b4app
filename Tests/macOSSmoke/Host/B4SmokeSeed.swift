import Foundation
import WorkspaceClient
import WorkspaceProtocol

enum B4SmokeSeed {
  static func create(root: URL, client: WorkspaceClient) async throws -> String {
    let manifest = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("b4-runtime.json")))
    guard manifest["state"]?.stringValue == "ready", let raw = manifest["url"]?.stringValue,
      let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
      let project = manifest["projectPath"]?.stringValue,
      URL(fileURLWithPath: project).deletingLastPathComponent().standardizedFileURL == root,
      URL(fileURLWithPath: project).lastPathComponent.hasPrefix("b4aimock-")
    else { throw WorkspaceError(.protocolInvalid, "Invalid private real-B4 fixture manifest") }
    let options = RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60))
    let connection = try await client.request(
      ConnectionAdd.self,
      .init(kind: .b4, label: "Real B4 fixture runtime", url: url.absoluteString, route: "/chat#agent"),
      options: options
    ).connection
    let thread = try await client.request(
      ThreadCreate.self, .init(connectionId: connection.id, title: "Real B4 recovery fixture"),
      options: .init(operationId: UUID().uuidString, timeout: .seconds(60))
    ).thread
    _ = try await client.request(
      DraftSave.self, .init(threadId: thread.id, text: "smoke-ui-stream"),
      options: .init(operationId: UUID().uuidString))
    return thread.id
  }
}
