import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// Pick a connection and a working directory for a new native thread.
struct NewThreadSheet: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var connectionId = ""
  @State private var directory = NSHomeDirectory()
  @State private var title = ""
  @State private var choosing = false
  @State private var creating = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New thread").font(.title2).bold()
      Picker("Connection", selection: $connectionId) {
        ForEach(model.conversationReadyConnections) { connection in
          Text("\(connection.label) (\(connection.kind.rawValue))").tag(connection.id)
        }
      }
      if needsDirectory {
        HStack {
          TextField("Working directory", text: $directory).textFieldStyle(.roundedBorder)
          Button("Choose…") { choosing = true }
        }
      }
      TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
      if needsDirectory {
        Text("The directory is fixed for the life of the thread and is sent with every turn.")
          .font(.caption).foregroundStyle(.secondary)
      } else if let connection = selectedConnection {
        Text(
          "Runs route \(connection.routeKey ?? "?") on \(connection.target). The route is fixed for the life of the thread."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.lastError { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create") {
          creating = true
          Task {
            await model.createThread(
              connectionId: connectionId, directory: needsDirectory ? directory : nil,
              title: title.isEmpty ? nil : title)
            creating = false
            if model.lastError == nil { dismiss() }
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(connectionId.isEmpty || (needsDirectory && directory.isEmpty) || creating)
        .accessibilityIdentifier("create-thread")
      }
    }
    .padding(20)
    .frame(minWidth: 460)
    .onAppear {
      if connectionId.isEmpty { connectionId = model.conversationReadyConnections.first?.id ?? "" }
      model.lastError = nil
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { directory = url.path }
    }
  }

  private var selectedConnection: Connection? { model.connection(id: connectionId) }
  /// Harness threads bind to a directory; B4 threads bind to the connection's route.
  private var needsDirectory: Bool { selectedConnection?.kind != .b4 }
}
