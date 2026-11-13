import SwiftUI
import UniformTypeIdentifiers
import WorkspaceProtocol

/// What the Mac's environment form and the phone's environment sheet say and decide alike (D-212).
enum EnvironmentCopy {
  static let nameHint = "Taken from the folder name. Change it to anything."
  static let foldersHint = "Agents start in the first folder and can work in the others."
  static let firstFolderTag = "Threads start here"
  static let deleteMessage = "Its threads move to \u{201C}No folder\u{201D}. Nothing on disk is touched."

  static func threadCount(_ count: Int) -> String {
    switch count {
    case 0: "No threads"
    case 1: "1 thread"
    default: "\(count) threads"
    }
  }

  /// The name to save for what was typed, or nil when it changes nothing. The field starts with the name
  /// shown (`displayName`), so leaving the generated name as it is saves nothing; an empty field saves the
  /// empty name, which shows the first folder's name again.
  static func nameToSave(_ typed: String, for environment: WorkEnvironment) -> String? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == environment.name { return nil }
    if environment.name.isEmpty, trimmed == environment.displayName { return nil }
    return trimmed
  }

  /// The threads the list holds in `environmentId`.
  static func threadCount(in environmentId: String, threads: [ConversationThread]) -> Int {
    threads.count(where: { $0.environmentId == environmentId })
  }
}

#if os(macOS)
  /// The Mac's environment form, in the main view where a thread shows (D-212; the design's "Editing an
  /// environment", mockup `grouped-v13`): the name as a heading and the thread count, the name field, the
  /// folders (the first is where threads start, the others can be removed), Add folder…, Done, and at the
  /// foot Delete environment, confirmed in place. Each change saves as it is made; a failure shows under
  /// the folders and changes nothing.
  struct EnvironmentForm: View {
    @Bindable var model: WorkspaceModel
    let environment: WorkEnvironment
    @State private var name = ""
    @State private var failure: String?
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var choosingFolder = false
    @FocusState private var nameFocused: Bool

    /// The form's width at most and its insets (the mockup's 520, 40 and 32).
    static let maxWidth: CGFloat = 520
    static let inset = EdgeInsets(top: 32, leading: 40, bottom: 32, trailing: 40)
    static let folderRow: CGFloat = 36

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(environment.displayName)
            .llaDisplay()
            .lineLimit(2)
            .accessibilityAddTraits(.isHeader)
          Text(
            EnvironmentCopy.threadCount(
              EnvironmentCopy.threadCount(in: environment.id, threads: model.threads))
          )
          .llaSmallMuted()
          .padding(.top, LLA.Space.xs)
          section("Name") {
            nameField
            hint(EnvironmentCopy.nameHint)
          }
          .padding(.top, 28)
          section("Folders") {
            folderList
            Button("Add folder\u{2026}") { choosingFolder = true }
              .buttonStyle(FormButtonStyle())
              .disabled(saving)
              .padding(.top, 10)
              .accessibilityIdentifier("environment-add-folder")
            hint(EnvironmentCopy.foldersHint)
          }
          if let failure {
            Text(failure)
              .font(LLAFont.small)
              .foregroundStyle(LLA.Color.danger)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, LLA.Space.m)
              .accessibilityIdentifier("environment-failure")
          }
          Button("Done", action: done)
            .buttonStyle(FormButtonStyle(kind: .primary))
            .padding(.top, failure == nil ? 0 : LLA.Space.xl)
            .accessibilityIdentifier("environment-done")
          deleteArea
            .padding(.top, LLA.Space.xxl)
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .padding(Self.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(LLA.Color.bg)
      .navigationTitle("Environment")
      .accessibilityIdentifier("environment-form")
      .onAppear { reset() }
      .onChange(of: environment.id) { reset() }
      // The name saves when the field is left, as the design's "changes save as they are made" asks.
      .onChange(of: nameFocused) { _, focused in if !focused { saveName() } }
      .onChange(of: environment.displayName) { _, shown in if !nameFocused { name = shown } }
      .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
        guard case .success(let url) = result else { return }
        edit(addFolders: [url.path])
      }
    }

    // MARK: Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(LLAFont.sans(13, weight: .semibold, relativeTo: .subheadline))
          .foregroundStyle(LLA.Color.ink)
          .padding(.bottom, 6)
        content()
      }
    }

    private func hint(_ text: String) -> some View {
      Text(text)
        .llaCaption()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
        .padding(.bottom, LLA.Space.xl)
    }

    private var nameField: some View {
      TextField("Name", text: $name)
        .textFieldStyle(.plain)
        .focused($nameFocused)
        .font(LLAFont.sans(13))
        .foregroundStyle(LLA.Color.ink)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.bg))
        .overlay(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
            .strokeBorder(nameFocused ? LLA.Color.ink : LLA.Color.rule, lineWidth: nameFocused ? 1.5 : 1)
        )
        .focusEffectDisabled()
        .onSubmit(saveName)
        .accessibilityIdentifier("environment-form-name")
    }

    /// The folders in a bordered list, oldest first: the first tagged "Threads start here", each other with
    /// Remove.
    private var folderList: some View {
      VStack(spacing: 0) {
        ForEach(Array(environment.folders.enumerated()), id: \.element.id) { index, folder in
          if index > 0 { Hairline() }
          HStack(spacing: 10) {
            Text(PlacePalette.shownPath(folder.path))
              .font(LLAFont.mono(12, relativeTo: .footnote))
              .foregroundStyle(LLA.Color.ink)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(folder.path)
            if index == 0 {
              Text(EnvironmentCopy.firstFolderTag)
                .font(LLAFont.sans(11, weight: .medium, relativeTo: .caption2))
                .foregroundStyle(LLA.Color.muted)
                .fixedSize()
                .padding(.horizontal, LLA.Space.s)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 9, style: .circular).stroke(LLA.Color.rule))
                .layoutPriority(1)
            } else {
              Button("Remove") { edit(removeFolders: [folder.path]) }
                .buttonStyle(QuietTextButtonStyle())
                .disabled(saving)
                .accessibilityLabel("Remove \(PlacePalette.shownPath(folder.path))")
                .accessibilityIdentifier("environment-remove-folder")
            }
          }
          .padding(.horizontal, 10)
          .frame(height: Self.folderRow)
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).strokeBorder(LLA.Color.rule)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("environment-folders")
    }

    /// "Delete environment…", quiet; once pressed, what it does and the two answers, in place of a sheet.
    @ViewBuilder private var deleteArea: some View {
      if confirmingDelete {
        VStack(alignment: .leading, spacing: LLA.Space.s) {
          Text("Delete \u{201C}\(environment.displayName)\u{201D}?")
            .font(LLAFont.smallStrong)
            .foregroundStyle(LLA.Color.ink)
          Text(EnvironmentCopy.deleteMessage).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
          HStack(spacing: LLA.Space.s) {
            Button("Delete Environment", role: .destructive, action: delete)
              .buttonStyle(FormButtonStyle(kind: .danger))
              .disabled(saving)
              .accessibilityIdentifier("environment-delete-confirm")
            Button("Cancel") { confirmingDelete = false }
              .buttonStyle(FormButtonStyle())
              .keyboardShortcut(.cancelAction)
          }
          .padding(.top, LLA.Space.xs)
        }
        .transition(.opacity)
      } else {
        Button("Delete environment\u{2026}") { confirmingDelete = true }
          .buttonStyle(QuietTextButtonStyle(destructive: true))
          .disabled(saving)
          .accessibilityIdentifier("environment-delete")
      }
    }

    // MARK: Actions

    private func reset() {
      name = environment.displayName
      failure = nil
      confirmingDelete = false
    }

    private func saveName() {
      guard let toSave = EnvironmentCopy.nameToSave(name, for: environment) else { return }
      let environment = environment
      Task {
        let result = await model.editEnvironment(environment, name: toSave)
        finish(result)
        if case .success(let saved) = result, !nameFocused { name = saved.displayName }
      }
    }

    private func edit(addFolders: [String] = [], removeFolders: [String] = []) {
      let environment = environment
      saving = true
      Task {
        finish(
          await model.editEnvironment(
            environment, name: environment.name, addFolders: addFolders, removeFolders: removeFolders))
        saving = false
      }
    }

    private func finish(_ result: Result<WorkEnvironment, WorkspaceError>) {
      switch result {
      case .success: failure = nil
      case .failure(let error): failure = SendRules.reason(error, now: model.now())
      }
    }

    private func delete() {
      let id = environment.id
      saving = true
      Task {
        if let error = await model.deleteEnvironment(id: id) {
          failure = SendRules.reason(error, now: model.now())
        }
        saving = false
      }
    }

    private func done() {
      saveName()
      model.closeEnvironmentForm()
    }
  }

  /// The form's buttons: 28 high, radius 8, 13 pt medium; bordered, ink-filled (Done), or bordered in the
  /// danger colour (the confirmed delete).
  private struct FormButtonStyle: ButtonStyle {
    enum Kind { case bordered, primary, danger }
    var kind: Kind = .bordered

    func makeBody(configuration: Configuration) -> some View {
      Label(kind: kind, configuration: configuration)
    }

    private struct Label: View {
      let kind: Kind
      let configuration: Configuration
      @Environment(\.isEnabled) private var isEnabled
      @State private var hovering = false

      var body: some View {
        configuration.label
          .font(LLAFont.sans(13, weight: .medium, relativeTo: .subheadline))
          .foregroundStyle(foreground)
          .lineLimit(1)
          .padding(.horizontal, LLA.Space.m)
          .frame(height: 28)
          .background(
            RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(fill)
          )
          .overlay {
            if kind != .primary {
              RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
                .strokeBorder(kind == .danger ? LLA.Color.danger.opacity(0.5) : LLA.Color.rule)
            }
          }
          .contentShape(Rectangle())
          .opacity(configuration.isPressed ? 0.8 : 1)
          .opacity(isEnabled ? 1 : 0.45)
          .onHover { hovering = $0 }
      }

      private var fill: Color {
        switch kind {
        case .primary: LLA.Color.ink
        case .bordered, .danger: hovering ? LLA.Color.surfaceRaised : LLA.Color.bg
        }
      }

      private var foreground: Color {
        switch kind {
        case .primary: LLA.Color.bg
        case .bordered: LLA.Color.ink
        case .danger: LLA.Color.danger
        }
      }
    }
  }

  /// Words that act: muted (or the danger colour) at rest, ink (or a deeper hover) under the pointer.
  private struct QuietTextButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
      Label(destructive: destructive, configuration: configuration)
    }

    private struct Label: View {
      let destructive: Bool
      let configuration: Configuration
      @Environment(\.isEnabled) private var isEnabled
      @State private var hovering = false

      var body: some View {
        configuration.label
          .font(LLAFont.small)
          .foregroundStyle(destructive ? LLA.Color.danger : hovering ? LLA.Color.ink : LLA.Color.muted)
          .underline(destructive && hovering)
          .contentShape(Rectangle())
          .opacity(configuration.isPressed ? 0.7 : 1)
          .opacity(isEnabled ? 1 : 0.45)
          .onHover { hovering = $0 }
      }
    }
  }
#endif
