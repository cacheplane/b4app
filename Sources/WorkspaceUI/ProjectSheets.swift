import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// Create a manual project: a name and the folders whose threads belong to it. The Mac's, with its
/// folder picker; the phone has `PhoneProjectSheet`, which names folders on the Mac by path.
struct NewProjectSheet: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var folders: [String] = []
  @State private var choosing = false
  @State private var creating = false

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.l) {
      Text("New project").llaDisplay()
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text("Name").llaSmallMuted()
        LLAField("Name", text: $name)
        Text("Leave it empty to use the first folder's name.").llaCaption()
      }
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text("Folders").llaSmallMuted()
        if folders.isEmpty {
          Text("Threads started in a folder you add here join this project.").llaCaption()
        }
        ForEach(folders, id: \.self) { path in
          HStack(spacing: LLA.Space.s) {
            Text(path).llaCodeMuted().lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Remove") { folders.removeAll { $0 == path } }.buttonStyle(.llaLink)
          }
        }
        Button("Add Folder…") { choosing = true }.buttonStyle(.llaSecondary)
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
            let created = await model.createProject(
              name: name.trimmingCharacters(in: .whitespaces), folders: folders)
            creating = false
            if created != nil { dismiss() }
          }
        }
        .buttonStyle(.llaPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled((name.trimmingCharacters(in: .whitespaces).isEmpty && folders.isEmpty) || creating)
        .accessibilityIdentifier("create-project")
      }
    }
    .padding(LLA.Metrics.margin)
    .frame(minWidth: 480)
    .background(LLA.Color.bg)
    .onAppear { model.lastError = nil }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result, !folders.contains(url.path) { folders.append(url.path) }
    }
  }
}

/// Rename a project. An empty name restores the folder-name display.
struct RenameProjectSheet: View {
  @Bindable var model: WorkspaceModel
  let project: Project
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var saving = false

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.l) {
      Text("Rename project").llaDisplay()
      VStack(alignment: .leading, spacing: LLA.Space.xs) {
        Text("Name").llaSmallMuted()
        LLAField("Name", text: $name)
        Text("Leave it empty to show the first folder's name.").llaCaption()
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
        Button("Rename") {
          saving = true
          Task {
            await model.renameProject(id: project.id, name: name.trimmingCharacters(in: .whitespaces))
            saving = false
            if model.lastError == nil { dismiss() }
          }
        }
        .buttonStyle(.llaPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(saving)
        .accessibilityIdentifier("rename-project")
      }
    }
    .padding(LLA.Metrics.margin)
    .frame(minWidth: 420)
    .background(LLA.Color.bg)
    .onAppear {
      name = project.name
      model.lastError = nil
    }
  }
}
