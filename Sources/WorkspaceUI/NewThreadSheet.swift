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
    VStack(alignment: .leading, spacing: LLA.Space.l) {
      Text("New thread").llaDisplay()
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text("Connection").llaSmallMuted()
        Picker("Connection", selection: $connectionId) {
          ForEach(model.conversationReadyConnections) { connection in
            Text("\(connection.label) (\(connection.kind.rawValue))").tag(connection.id)
          }
        }
        .labelsHidden()
        .font(LLAFont.body)
      }
      if needsDirectory {
        VStack(alignment: .leading, spacing: LLA.Space.xs) {
          Text("Working directory").llaSmallMuted()
          HStack(spacing: LLA.Space.s) {
            LLAField("Working directory", text: $directory)
            Button("Choose…") { choosing = true }.buttonStyle(.llaSecondary)
          }
          Text(projectNote).llaCaption().accessibilityIdentifier("new-thread-project")
        }
      }
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text("Title (optional)").llaSmallMuted()
        LLAField("Title", text: $title)
      }
      if needsDirectory {
        Text("The directory is fixed for the life of the thread and is sent with every turn.").llaCaption()
      } else if let connection = selectedConnection {
        Text(
          "Runs route \(connection.routeKey ?? "?") on \(connection.target). The route is fixed for the life of the thread."
        )
        .llaCaption()
      }
      if let error = model.lastError {
        Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack(spacing: LLA.Space.s) {
        Spacer()
        Button("Cancel") {
          model.lastError = nil
          dismiss()
        }.buttonStyle(.llaSecondary).keyboardShortcut(.cancelAction)
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
        .buttonStyle(.llaPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(connectionId.isEmpty || (needsDirectory && directory.isEmpty) || creating)
        .accessibilityIdentifier("create-thread")
      }
    }
    .padding(LLA.Space.xl)
    .frame(minWidth: 480)
    .background(LLA.Color.bg)
    .onAppear {
      if connectionId.isEmpty { connectionId = model.conversationReadyConnections.first?.id ?? "" }
      model.lastError = nil
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { directory = url.path }
    }
  }

  /// Which project the chosen folder lands in, as far as the project list tells; the coordinator decides.
  private var projectNote: String {
    switch NewThreadProject.describe(directory: directory, projects: model.projects) {
    case .joins(let name): return "Joins the project \u{201C}\(name)\u{201D}."
    case .newProject: return "Starts a new project from this folder."
    }
  }

  private var selectedConnection: Connection? { model.connection(id: connectionId) }
  /// Harness threads bind to a directory; B4 threads bind to the connection's route.
  private var needsDirectory: Bool { selectedConnection?.kind != .b4 }
}
