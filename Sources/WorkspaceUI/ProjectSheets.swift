import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// Create a manual project: a name and the folders whose threads belong to it. The Mac only; the
/// phone's mirror refuses project writes.
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
        Button("Cancel") { dismiss() }.buttonStyle(.llaSecondary).keyboardShortcut(.cancelAction)
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
    .padding(LLA.Space.xl)
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
        Button("Cancel") { dismiss() }.buttonStyle(.llaSecondary).keyboardShortcut(.cancelAction)
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
    .padding(LLA.Space.xl)
    .frame(minWidth: 420)
    .background(LLA.Color.bg)
    .onAppear {
      name = project.name
      model.lastError = nil
    }
  }
}

/// Which project a new thread's folder lands in, as far as the app can tell from the project list.
/// The coordinator decides for real (it canonicalizes the path); this only words the sheet.
enum NewThreadProject: Equatable {
  case joins(String)
  case newProject

  static func describe(directory: String, projects: [Project]) -> NewThreadProject {
    let wanted = normalized(directory)
    guard !wanted.isEmpty else { return .newProject }
    for project in projects where project.folders.contains(where: { normalized($0.path) == wanted }) {
      return .joins(project.displayName)
    }
    return .newProject
  }

  private static func normalized(_ path: String) -> String {
    var value = path.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return "" }
    value = (value as NSString).standardizingPath
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }
}
