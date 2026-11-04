import Foundation
import SwiftUI
import WorkspaceProtocol

// MARK: - The sheet

/// The phone's New thread: project → connection → folder (only when there are several) → the first
/// message. Mounted by the root view on the phone; the Mac keeps `NewThreadSheet`.
struct PhoneNewThreadSheet: View {
  @Bindable var model: WorkspaceModel
  @State private var draft: NewThreadDraft
  @Environment(\.dismiss) private var dismiss
  @Environment(\.showDetail) private var showDetail
  @FocusState private var messageFocused: Bool

  init(model: WorkspaceModel) {
    self.model = model
    self._draft = State(initialValue: NewThreadDraft(model: model, projectId: nil))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let project = draft.project, let notice = model.startNotice(for: project) {
            HostNotice(message: notice)
          }
          VStack(alignment: .leading, spacing: LLA.Space.l) {
            if draft.projects.isEmpty {
              Text("No projects yet. Start one on your Mac.").llaSmallMuted()
            } else {
              projectField
              connectionField
              if draft.needsFolderChoice { folderField }
              messageField
              statusLine
            }
          }
          .padding(LLA.Metrics.margin)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(LLA.Color.bg)
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("New thread")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Start") { Task { await draft.send() } }
            .disabled(!draft.canSend)
            .accessibilityIdentifier("start-thread")
        }
      }
    }
    .tint(LLA.Color.accent)
    .interactiveDismissDisabled(draft.submitting)
    .onChange(of: draft.finished) { _, finished in
      guard finished else { return }
      // Move the compact split view to the thread's detail as the sheet closes, the way the search
      // sheet does (select, show the detail, close), then make sure the thread is the open one.
      showDetail()
      dismiss()
      Task { await draft.openStartedThread() }
    }
    // Once the sheet is gone, move to the detail again: a column change made while the sheet still
    // covers the split view can be lost, and this one cannot.
    .onDisappear { if draft.finished { showDetail() } }
  }

  // MARK: Fields

  private var projectField: some View {
    field("Project") {
      Picker(
        "Project",
        selection: Binding(get: { draft.projectId ?? "" }, set: { draft.selectProject($0) })
      ) {
        ForEach(draft.projects) { project in Text(project.displayName).tag(project.id) }
      }
      .accessibilityIdentifier("new-thread-project")
    }
  }

  @ViewBuilder private var connectionField: some View {
    if draft.connections.isEmpty {
      Text("No ready connection on your Mac can start a thread in this project.").llaSmallMuted()
        .fixedSize(horizontal: false, vertical: true)
    } else {
      field("Connection") {
        Picker(
          "Connection",
          selection: Binding(
            get: { draft.connectionId ?? "" }, set: { draft.selectRuntime(connectionId: $0, model: nil) })
        ) {
          ForEach(draft.connections) { connection in
            Text(model.startLabel(for: connection)).tag(connection.id)
          }
        }
        .accessibilityIdentifier("new-thread-connection")
      }
    }
  }

  private var folderField: some View {
    field("Folder") {
      Picker(
        "Folder",
        selection: Binding(
          get: { draft.folder ?? "" }, set: { draft.selectFolder($0, in: draft.projectId ?? "") })
      ) {
        ForEach(draft.folders) { folder in Text(folder.path).tag(folder.path) }
      }
      .accessibilityIdentifier("new-thread-folder")
    }
  }

  private var messageField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text("Message").llaSmallMuted()
      TextField("What should it do?", text: $draft.text, axis: .vertical)
        .textFieldStyle(.plain)
        .focused($messageFocused)
        .lineLimit(4...10)
        .font(LLAFont.body)
        .foregroundStyle(LLA.Color.ink)
        .padding(10)
        .frame(minHeight: LLA.Metrics.control, alignment: .topLeading)
        .background(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.surface)
        )
        .overlay(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
            .stroke(messageFocused ? LLA.Color.accent : LLA.Color.rule, lineWidth: messageFocused ? 2 : 1)
        )
        .disabled(draft.submitting)
        .accessibilityIdentifier("new-thread-message")
    }
  }

  /// "Starting…", the reason a start did not go through, or why Start is off.
  @ViewBuilder private var statusLine: some View {
    if let status = draft.status {
      HStack(spacing: LLA.Space.s) {
        if draft.submitting { ProgressView().controlSize(.small).accessibilityHidden(true) }
        Text(status)
          .font(LLAFont.small)
          .foregroundStyle(draft.statusIsFailure ? LLA.Color.danger : LLA.Color.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("new-thread-status")
    } else if let reason = draft.blockedReason, !draft.connections.isEmpty,
      draft.project.flatMap(model.startNotice(for:)) == nil
    {
      Text(reason).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
    }
  }

  /// A heading over a control drawn as a field: the surface fill and rule border of `LLAField`, at the
  /// phone's 44 pt target.
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text(title).llaSmallMuted()
      content()
        .labelsHidden()
        .pickerStyle(.menu)
        .font(LLAFont.body)
        .tint(LLA.Color.ink)
        .frame(maxWidth: .infinity, minHeight: LLA.Metrics.control, alignment: .leading)
        .padding(.horizontal, 10)
        .background(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.surface)
        )
        .overlay(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).stroke(LLA.Color.rule)
        )
    }
  }
}
