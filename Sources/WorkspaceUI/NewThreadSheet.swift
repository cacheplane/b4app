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
    content
      .tint(LLA.Color.accent)
      .onAppear {
        if connectionId.isEmpty { connectionId = model.conversationReadyConnections.first?.id ?? "" }
        #if os(iOS)
          // The phone's home folder means nothing to the Mac that runs the thread: start from the
          // folder of the newest thread instead.
          if directory == NSHomeDirectory() {
            // B4 threads hold a route, not a folder.
            directory = Self.recentDirectory(
              in: model.threads.filter { model.connection(id: $0.connectionId)?.kind != .b4 })
          }
        #endif
        model.lastError = nil
      }
      .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
        if case .success(let url) = result { directory = url.path }
      }
  }

  #if os(macOS)
    private var content: some View {
      VStack(alignment: .leading, spacing: LLA.Space.l) {
        Text("New thread").llaDisplay()
        fields
        HStack(spacing: LLA.Space.s) {
          Spacer()
          Button("Cancel", action: cancel).buttonStyle(.llaSecondary).keyboardShortcut(.cancelAction)
          Button("Create", action: create)
            .buttonStyle(.llaPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
            .accessibilityIdentifier("create-thread")
        }
      }
      .padding(LLA.Metrics.margin)
      .frame(minWidth: 480)
      .background(LLA.Color.bg)
    }
  #else
    /// A form sheet in the iOS manner: the title in the bar, Cancel leading and Create trailing (HIG,
    /// Sheets), the fields scrolling under it at the phone's width.
    private var content: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: LLA.Space.l) { fields }
            .padding(LLA.Metrics.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LLA.Color.bg)
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
          ToolbarItem(placement: .confirmationAction) {
            Button("Create", action: create)
              .disabled(!canCreate)
              .accessibilityIdentifier("create-thread")
          }
        }
      }
    }

    /// The working folder of the newest thread that has one, or nothing.
    static func recentDirectory(in threads: [ConversationThread]) -> String {
      threads
        .filter { !($0.context ?? "").isEmpty }
        .max {
          ($0.activity?.lastActivityAt ?? $0.createdAt) < ($1.activity?.lastActivityAt ?? $1.createdAt)
        }?
        .context ?? ""
    }
  #endif

  @ViewBuilder private var fields: some View {
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
          #if os(macOS)
            // The phone's file picker sees the phone's files, not the Mac's.
            Button("Choose…") { choosing = true }.buttonStyle(.llaSecondary)
          #endif
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
        .fixedSize(horizontal: false, vertical: true)
    } else if let connection = selectedConnection {
      Text(
        "Runs route \(connection.routeKey ?? "?") on \(connection.target). The route is fixed for the life of the thread."
      )
      .llaCaption()
      .fixedSize(horizontal: false, vertical: true)
    }
    if let error = model.lastError {
      Text(error).font(LLAFont.small).foregroundStyle(LLA.Color.danger).fixedSize(
        horizontal: false, vertical: true)
    }
  }

  private var canCreate: Bool {
    !connectionId.isEmpty && !(needsDirectory && directory.isEmpty) && !creating
  }

  private func cancel() {
    model.lastError = nil
    dismiss()
  }

  private func create() {
    creating = true
    Task {
      await model.createThread(
        connectionId: connectionId, directory: needsDirectory ? directory : nil,
        title: title.isEmpty ? nil : title)
      creating = false
      if model.lastError == nil { dismiss() }
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
