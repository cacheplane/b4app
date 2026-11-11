import SwiftUI
import WorkspaceProtocol

/// Rename an environment. An empty name restores the folder-name display.
struct RenameEnvironmentSheet: View {
  @Bindable var model: WorkspaceModel
  let environment: WorkEnvironment
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var saving = false

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.l) {
      Text("Rename environment").llaDisplay()
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
            await model.renameEnvironment(id: environment.id, name: name.trimmingCharacters(in: .whitespaces))
            saving = false
            if model.lastError == nil { dismiss() }
          }
        }
        .buttonStyle(.llaPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(saving)
        .accessibilityIdentifier("rename-environment")
      }
    }
    .padding(LLA.Metrics.margin)
    .frame(minWidth: 420)
    .background(LLA.Color.bg)
    .onAppear {
      name = environment.name
      model.lastError = nil
    }
  }
}
