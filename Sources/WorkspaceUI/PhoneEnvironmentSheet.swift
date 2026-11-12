import Foundation
import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

// MARK: - Environment edits from the phone

/// The environment the phone's sheet edits. There is no new environment: one is made on the Mac the first
/// time a thread starts in a folder (D-212).
public enum EnvironmentSheetRequest: Identifiable, Equatable, Sendable {
  case edit(environmentId: String)

  public var id: String {
    switch self {
    case .edit(let environmentId): "edit:\(environmentId)"
    }
  }
}

extension WorkspaceModel {
  /// The notice about the Mac whose folders an environment edit changes: left the hub, offline, or the
  /// quiet reconnecting line. Nil on the Mac.
  public func environmentNotice(deviceId: String?) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: deviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: deviceId, fallbackName: nil)
  }

  /// Why an environment cannot have its folders changed or be deleted on the Mac `deviceId` now: it is
  /// offline or has left the hub, the phone's link is down, or no Mac is known. Nil on the Mac, and
  /// while the Mac is reconnecting (the hub then answers `device_offline` itself). A rename needs no
  /// Mac: it goes through the change log.
  public func environmentEditBlockedReason(deviceId: String?) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = environmentNotice(deviceId: deviceId), notice.kind != .reconnecting { return notice.text }
    if let link = hubLinkNotice { return link }
    return deviceId == nil ? RelayCopy.noMacForEnvironment : nil
  }

  /// Folders an environment on `deviceId`'s Mac can take without typing: those of that Mac's other
  /// environments (adding one moves it, with its threads, D-212), the most recently active first, less the
  /// ones `excluding` already lists.
  public func folderSuggestions(onMac deviceId: String?, excluding: [String] = []) -> [String] {
    guard let deviceId else { return [] }
    var seen = Set(excluding)
    var result: [String] = []
    for environment in filterEnvironments where environment.ownerDeviceId == deviceId {
      for folder in environment.folders where seen.insert(folder.path).inserted { result.append(folder.path) }
    }
    return result
  }

}

// MARK: - The sheet's state

/// What the phone's environment sheet holds: the environment, its name and folders, and how the save went.
/// Folders are paths on the Mac; the phone never looks at a filesystem, so a typed path is checked by the
/// Mac when the sheet is saved.
@MainActor @Observable
final class PhoneEnvironmentDraft {
  let model: WorkspaceModel
  /// The environment being edited; nil when the list no longer has it.
  let environment: WorkEnvironment?
  let environmentId: String
  var name: String
  /// A path being typed, added with `addTyped()`.
  var typed = ""
  private(set) var folders: [String]
  let deviceId: String?
  private(set) var submitting = false
  /// Why the last save or delete did not go through, in words.
  private(set) var failure: String?
  /// The save or delete went through: the sheet closes.
  private(set) var finished = false

  init(model: WorkspaceModel, request: EnvironmentSheetRequest) {
    self.model = model
    switch request {
    case .edit(let id):
      let environment = model.environments.first { $0.id == id }
      self.environment = environment
      environmentId = id
      // The name shown, as the Mac's form starts (`EnvironmentCopy.nameToSave`).
      name = environment?.displayName ?? ""
      folders = environment?.folders.map(\.path) ?? []
      deviceId = environment?.ownerDeviceId
    }
  }

  /// The Mac's name, for "Folders on <Mac>".
  var macName: String {
    deviceId.flatMap { model.hostPresence[$0]?.name }.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac"
  }

  var added: [String] {
    folders.filter { path in !(environment?.folders.contains { $0.path == path } ?? false) }
  }
  var removed: [String] {
    (environment?.folders.map(\.path) ?? []).filter { !folders.contains($0) }
  }
  private var foldersChanged: Bool { !added.isEmpty || !removed.isEmpty }
  /// The name a save sends: what was typed, or the stored name when the field changes nothing.
  private var nameToSend: String {
    guard let environment else { return name }
    return EnvironmentCopy.nameToSave(name, for: environment) ?? environment.name
  }

  /// An environment keeps at least one folder (the Mac refuses an update that leaves none; Delete is the way
  /// to end it), so the last folder offers no Remove.
  func canRemove(_ path: String) -> Bool { folders.count > 1 }

  var suggestions: [String] { model.folderSuggestions(onMac: deviceId, excluding: folders) }

  func add(_ path: String) {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !folders.contains(path) else { return }
    folders.append(path)
    failure = nil
  }

  func addTyped() {
    add(typed)
    typed = ""
  }

  func remove(_ path: String) {
    guard canRemove(path) else { return }
    folders.removeAll { $0 == path }
    failure = nil
  }

  /// Why Save is off, in words: the Mac cannot be reached for a change that needs it. Nil when it can be
  /// saved (or there is nothing to save).
  var blockedReason: String? {
    guard foldersChanged else { return nil }
    if deviceId == nil { return RelayCopy.environmentNotSynced }
    return model.environmentEditBlockedReason(deviceId: deviceId)
  }

  var canSave: Bool {
    guard !submitting, !finished, blockedReason == nil, let environment, !folders.isEmpty else {
      return false
    }
    return foldersChanged || EnvironmentCopy.nameToSave(name, for: environment) != nil
  }

  /// Any environment can be deleted (D-212); only its Mac can do it.
  var canDelete: Bool { environment != nil }
  var deleteBlockedReason: String? {
    deviceId == nil ? RelayCopy.environmentNotSynced : model.environmentEditBlockedReason(deviceId: deviceId)
  }

  func submit() async {
    guard canSave else { return }
    failure = nil
    submitting = true
    defer { submitting = false }
    guard let environment else { return }
    let result = await model.editEnvironment(
      environment, name: nameToSend, addFolders: added, removeFolders: removed)
    switch result {
    case .success:
      finished = true
    case .failure(let error):
      failure = SendRules.reason(error, now: model.now())
    }
  }

  func delete() async {
    guard let environment, canDelete, deleteBlockedReason == nil, !submitting else { return }
    failure = nil
    submitting = true
    defer { submitting = false }
    if let error = await model.deleteEnvironment(id: environment.id) {
      failure = SendRules.reason(error, now: model.now())
    } else {
      finished = true
    }
  }
}

// MARK: - The sheet

/// The phone's Edit environment: the name, the folders with the Mac's own folders offered, a typed path,
/// and Delete. Mounted by the root view on the phone. The Mac edits an environment in its main view
/// (`EnvironmentForm`); neither makes one by hand, since starting a thread in a folder does (D-212).
struct PhoneEnvironmentSheet: View {
  @Bindable var model: WorkspaceModel
  @State private var draft: PhoneEnvironmentDraft
  @State private var confirmingDelete = false
  @Environment(\.dismiss) private var dismiss
  @FocusState private var pathFocused: Bool

  init(model: WorkspaceModel, request: EnvironmentSheetRequest) {
    self.model = model
    self._draft = State(initialValue: PhoneEnvironmentDraft(model: model, request: request))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let notice = model.environmentNotice(deviceId: draft.deviceId) { HostNotice(message: notice) }
          VStack(alignment: .leading, spacing: LLA.Space.l) {
            nameField
            foldersField
            statusLine
            if draft.canDelete { deleteButton }
          }
          .padding(LLA.Metrics.margin)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .background(LLA.Color.bg)
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Edit environment")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await draft.submit() } }
            .disabled(!draft.canSave)
            .accessibilityIdentifier("save-environment")
        }
      }
      .confirmationDialog(
        "Delete \u{201C}\(draft.environment?.displayName ?? "environment")\u{201D}?",
        isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Environment", role: .destructive) { Task { await draft.delete() } }
      } message: {
        Text(EnvironmentCopy.deleteMessage)
      }
    }
    .tint(LLA.Color.accent)
    .interactiveDismissDisabled(draft.submitting)
    .onChange(of: draft.finished) { _, finished in if finished { dismiss() } }
  }

  // MARK: Fields

  private var nameField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text("Name").llaSmallMuted()
      LLAField("Name", text: $draft.name)
        .disabled(draft.submitting)
        .accessibilityIdentifier("environment-name")
      Text(EnvironmentCopy.nameHint).llaCaption()
    }
  }

  private var foldersField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      Text("Folders on \(draft.macName)").llaSmallMuted()
      if draft.folders.isEmpty {
        Text("Threads started in a folder you add here join this environment.").llaCaption()
      }
      ForEach(draft.folders, id: \.self) { path in
        HStack(spacing: LLA.Space.s) {
          Text(path).llaCodeMuted().lineLimit(1).truncationMode(.head)
          Spacer(minLength: LLA.Space.s)
          if draft.canRemove(path) {
            Button("Remove") { draft.remove(path) }
              .buttonStyle(.llaLink)
              .accessibilityLabel("Remove \(path)")
          }
        }
        .frame(minHeight: LLA.Metrics.row)
      }
      HStack(spacing: LLA.Space.s) {
        LLAField("~/path/to/folder", text: $draft.typed)
          .focused($pathFocused)
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          #endif
          .autocorrectionDisabled()
          .onSubmit { draft.addTyped() }
          .accessibilityIdentifier("environment-folder-path")
        Button("Add") { draft.addTyped() }
          .buttonStyle(.llaSecondary)
          .disabled(draft.typed.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("add-environment-folder")
      }
      Text("A path on \(draft.macName). It's checked there when you save.").llaCaption()
      if !draft.suggestions.isEmpty {
        Text("Folders \(draft.macName) already knows").llaSmallMuted().padding(.top, LLA.Space.s)
        ForEach(draft.suggestions, id: \.self) { path in
          Button {
            draft.add(path)
          } label: {
            HStack(spacing: LLA.Space.s) {
              Image(systemName: "plus.circle").foregroundStyle(LLA.Color.accent).accessibilityHidden(true)
              Text(path).llaCodeMuted().lineLimit(1).truncationMode(.head)
              Spacer(minLength: 0)
            }
            .frame(minHeight: LLA.Metrics.row)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Add \(path)")
        }
      }
    }
  }

  /// "Saving…", why the save did not go through, or why Save is off.
  @ViewBuilder private var statusLine: some View {
    if draft.submitting {
      HStack(spacing: LLA.Space.s) {
        ProgressView().controlSize(.small).accessibilityHidden(true)
        Text("Waiting for \(draft.macName)…").llaSmallMuted()
      }
    } else if let failure = draft.failure {
      Text(failure)
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.danger)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("environment-status")
    } else if let reason = draft.blockedReason, model.environmentNotice(deviceId: draft.deviceId) == nil {
      Text(reason).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
    }
  }

  private var deleteButton: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Button("Delete Environment", role: .destructive) { confirmingDelete = true }
        .buttonStyle(.llaDanger)
        .disabled(draft.submitting || draft.deleteBlockedReason != nil)
        .accessibilityIdentifier("delete-environment")
      Text("Its threads move to \u{201C}No folder\u{201D}.").llaCaption()
    }
    .padding(.top, LLA.Space.m)
  }
}
