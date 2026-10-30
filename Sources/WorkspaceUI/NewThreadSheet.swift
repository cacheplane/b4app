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
      HStack {
        TextField("Working directory", text: $directory).textFieldStyle(.roundedBorder)
        Button("Choose…") { choosing = true }
      }
      TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
      Text("The directory is fixed for the life of the thread and is sent with every turn.")
        .font(.caption).foregroundStyle(.secondary)
      if let error = model.lastError { Text(error).font(.callout).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Create") {
          creating = true
          Task {
            await model.createThread(
              connectionId: connectionId, directory: directory, title: title.isEmpty ? nil : title)
            creating = false
            if model.lastError == nil { dismiss() }
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(connectionId.isEmpty || directory.isEmpty || creating)
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
}
