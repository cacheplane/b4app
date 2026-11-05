import Foundation
import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

// MARK: - Project edits from the phone

/// Which project sheet the phone shows: a new project, or one project's name and folders.
public enum ProjectSheetRequest: Identifiable, Equatable, Sendable {
  case create
  case edit(projectId: String)

  public var id: String {
    switch self {
    case .create: "create"
    case .edit(let projectId): "edit:\(projectId)"
    }
  }
}

extension WorkspaceModel {
  /// The Macs a project can be made on: every Mac the hub lists, the one the list speaks for first,
  /// then by name.
  public var projectMacs: [HostPresence] {
    let primary = primaryHostId
    return hostPresence.values.sorted { lhs, rhs in
      if (lhs.deviceId == primary) != (rhs.deviceId == primary) { return lhs.deviceId == primary }
      return (lhs.name, lhs.deviceId) < (rhs.name, rhs.deviceId)
    }
  }

  /// The notice about the Mac whose folders a project edit changes: left the hub, offline, or the
  /// quiet reconnecting line. Nil on the Mac.
  public func projectNotice(deviceId: String?) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: deviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: deviceId, fallbackName: nil)
  }

  /// Why a project cannot be created on, or have its folders changed on, the Mac `deviceId` now: it is
  /// offline or has left the hub, the phone's link is down, or no Mac is known. Nil on the Mac, and
  /// while the Mac is reconnecting (the hub then answers `device_offline` itself). A rename needs no
  /// Mac: it goes through the change log.
  public func projectEditBlockedReason(deviceId: String?) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = projectNotice(deviceId: deviceId), notice.kind != .reconnecting { return notice.text }
    if let link = hubLinkNotice { return link }
    return deviceId == nil ? RelayCopy.noMacForProject : nil
  }

  /// Folders a project on `deviceId`'s Mac can take without typing: those of that Mac's automatic
  /// projects (a folder of another manual project is refused by the Mac), the most recently active
  /// first, less the ones `excluding` already lists.
  public func folderSuggestions(onMac deviceId: String?, excluding: [String] = []) -> [String] {
    guard let deviceId else { return [] }
    var seen = Set(excluding)
    var result: [String] = []
    for project in filterProjects where project.ownerDeviceId == deviceId && !project.manual {
      for folder in project.folders where seen.insert(folder.path).inserted { result.append(folder.path) }
    }
    return result
  }

  /// Create a manual project on the Mac `deviceId`, through the hub. `projectId` is the sheet's own,
  /// so trying again after a lost reply finds the project the first try made.
  func createProject(
    name: String, folders: [String], deviceId: String, projectId: String
  ) async -> Result<Project, WorkspaceError> {
    await projectEdit(.projectCreate) {
      try await $0.request(
        ProjectCreate.self,
        ProjectCreate.Params(name: name, folders: folders, projectId: projectId, deviceId: deviceId),
        options: $1
      ).project
    }
  }

  /// Save the phone's edit of `project`. A name alone is a rename, written to the mirror at once and
  /// queued for the hub, so it works with the Mac offline; a folder change goes to the Mac with the
  /// name in one update, which the Mac validates.
  func editProject(
    _ project: Project, name: String, addFolders: [String], removeFolders: [String]
  ) async -> Result<Project, WorkspaceError> {
    if addFolders.isEmpty, removeFolders.isEmpty {
      guard name != project.name else { return .success(project) }
      return await projectEdit(.projectRename) {
        try await $0.request(
          ProjectRename.self, ProjectRename.Params(projectId: project.id, name: name), options: $1
        ).project
      }
    }
    return await projectEdit(.projectUpdate) {
      try await $0.request(
        ProjectUpdate.self,
        ProjectUpdate.Params(
          projectId: project.id, name: name == project.name ? nil : name,
          addFolders: addFolders.isEmpty ? nil : addFolders,
          removeFolders: removeFolders.isEmpty ? nil : removeFolders),
        options: $1
      ).project
    }
  }

  /// Delete a manual project on its Mac, through the hub.
  func deleteProjectOnMac(id: String) async -> WorkspaceError? {
    guard let client else { return WorkspaceError(.endpointUnavailable, "Coordinator is not connected.") }
    do {
      _ = try await client.request(
        ProjectDelete.self, ProjectDelete.Params(projectId: id),
        options: Self.mutation(timeout: Self.relayTimeout(for: .projectDelete)))
    } catch {
      return WorkspaceError.from(error)
    }
    projects.removeAll { $0.id == id }
    if projectFilter == .project(id) { projectFilter = .all }
    return nil
  }

  /// One project command whose failure the sheet shows itself (never `lastError`); the project it
  /// returns joins the list until the synced rows replace it.
  private func projectEdit(
    _ method: WorkspaceProtocol.Method,
    _ body: (WorkspaceClient, RequestOptions) async throws -> Project
  ) async -> Result<Project, WorkspaceError> {
    guard let client else {
      return .failure(WorkspaceError(.endpointUnavailable, "Coordinator is not connected."))
    }
    do {
      let project = try await body(client, Self.mutation(timeout: Self.relayTimeout(for: method)))
      merge(project)
      return .success(project)
    } catch {
      return .failure(WorkspaceError.from(error))
    }
  }
}

// MARK: - The sheet's state

/// What the phone's project sheet holds: the Mac (for a new project), the name, and the folders, and
/// how the save went. Folders are paths on the Mac; the phone never looks at a filesystem, so a typed
/// path is checked by the Mac when the sheet is saved.
@MainActor @Observable
final class PhoneProjectDraft {
  let model: WorkspaceModel
  /// The project being edited; nil for a new one.
  let project: Project?
  /// A new project's id, minted once per sheet, or the edited project's.
  let projectId: String
  var name: String
  /// A path being typed, added with `addTyped()`.
  var typed = ""
  private(set) var folders: [String]
  private(set) var deviceId: String?
  private(set) var submitting = false
  /// Why the last save or delete did not go through, in words.
  private(set) var failure: String?
  /// The save or delete went through: the sheet closes.
  private(set) var finished = false

  init(model: WorkspaceModel, request: ProjectSheetRequest) {
    self.model = model
    switch request {
    case .create:
      project = nil
      projectId = UUID().uuidString.lowercased()
      name = ""
      folders = []
      deviceId = model.projectMacs.first?.deviceId
    case .edit(let id):
      let project = model.projects.first { $0.id == id }
      self.project = project
      projectId = id
      name = project?.name ?? ""
      folders = project?.folders.map(\.path) ?? []
      deviceId = project?.ownerDeviceId
    }
  }

  var isNew: Bool { project == nil }
  var macs: [HostPresence] { model.projectMacs }
  /// The Mac's name, for "Folders on <Mac>".
  var macName: String {
    deviceId.flatMap { model.hostPresence[$0]?.name }.flatMap { $0.isEmpty ? nil : $0 } ?? "your Mac"
  }

  var added: [String] { folders.filter { path in !(project?.folders.contains { $0.path == path } ?? false) } }
  var removed: [String] {
    (project?.folders.map(\.path) ?? []).filter { !folders.contains($0) }
  }
  private var foldersChanged: Bool { !added.isEmpty || !removed.isEmpty }
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// An automatic project keeps its folder (the Mac refuses removing one without adding another), so
  /// only a manual or new project offers Remove.
  func canRemove(_ path: String) -> Bool {
    guard let project, !project.manual else { return true }
    return !project.folders.contains { $0.path == path }
  }

  var suggestions: [String] { model.folderSuggestions(onMac: deviceId, excluding: folders) }

  func selectMac(_ id: String) {
    guard isNew, id != deviceId else { return }
    // The previous Mac's own folders are not on this one; a typed path may be on either, so it stays.
    let previous = Set(model.folderSuggestions(onMac: deviceId))
    deviceId = id
    folders.removeAll { previous.contains($0) }
  }

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

  /// Why Save is off, in words: the Mac cannot be reached for a change that needs it, or a new project
  /// has no folder. Nil when it can be saved (or there is nothing to save).
  var blockedReason: String? {
    if !isNew, foldersChanged, deviceId == nil { return RelayCopy.projectNotSynced }
    if isNew || foldersChanged, let reason = model.projectEditBlockedReason(deviceId: deviceId) {
      return reason
    }
    if isNew, folders.isEmpty { return "Add a folder on \(macName)." }
    return nil
  }

  var canSave: Bool {
    guard !submitting, !finished, blockedReason == nil else { return false }
    guard let project else { return !folders.isEmpty }
    return foldersChanged || trimmedName != project.name
  }

  /// Delete is offered for a manual project, which only its Mac can delete.
  var canDelete: Bool { project?.manual == true }
  var deleteBlockedReason: String? {
    deviceId == nil ? RelayCopy.projectNotSynced : model.projectEditBlockedReason(deviceId: deviceId)
  }

  func submit() async {
    guard canSave else { return }
    failure = nil
    submitting = true
    defer { submitting = false }
    let result: Result<Project, WorkspaceError>
    if let project {
      result = await model.editProject(
        project, name: trimmedName, addFolders: added, removeFolders: removed)
    } else if let deviceId {
      result = await model.createProject(
        name: trimmedName, folders: folders, deviceId: deviceId, projectId: projectId)
    } else {
      return
    }
    switch result {
    case .success(let saved):
      if isNew { model.projectFilter = .project(saved.id) }
      finished = true
    case .failure(let error):
      failure = SendRules.reason(error, now: model.now())
    }
  }

  func delete() async {
    guard let project, canDelete, deleteBlockedReason == nil, !submitting else { return }
    failure = nil
    submitting = true
    defer { submitting = false }
    if let error = await model.deleteProjectOnMac(id: project.id) {
      failure = SendRules.reason(error, now: model.now())
    } else {
      finished = true
    }
  }
}

// MARK: - The sheet

/// The phone's New project and Edit project: the Mac (only when there are several, for a new
/// project), the name, the folders with the Mac's own folders offered, and a typed path. Mounted by
/// the root view on the phone; the Mac keeps `NewProjectSheet` and its sidebar menus.
struct PhoneProjectSheet: View {
  @Bindable var model: WorkspaceModel
  @State private var draft: PhoneProjectDraft
  @State private var confirmingDelete = false
  @Environment(\.dismiss) private var dismiss
  @FocusState private var pathFocused: Bool

  init(model: WorkspaceModel, request: ProjectSheetRequest) {
    self.model = model
    self._draft = State(initialValue: PhoneProjectDraft(model: model, request: request))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if let notice = model.projectNotice(deviceId: draft.deviceId) { HostNotice(message: notice) }
          VStack(alignment: .leading, spacing: LLA.Space.l) {
            if draft.isNew, draft.macs.count > 1 { macField }
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
      .navigationTitle(draft.isNew ? "New project" : "Edit project")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.isNew ? "Create" : "Save") { Task { await draft.submit() } }
            .disabled(!draft.canSave)
            .accessibilityIdentifier("save-project")
        }
      }
      .confirmationDialog(
        "Delete \u{201C}\(draft.project?.displayName ?? "project")\u{201D}?", isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Project", role: .destructive) { Task { await draft.delete() } }
      } message: {
        Text("Its folders return to automatic projects. No threads are deleted.")
      }
    }
    .tint(LLA.Color.accent)
    .interactiveDismissDisabled(draft.submitting)
    .onChange(of: draft.finished) { _, finished in if finished { dismiss() } }
  }

  // MARK: Fields

  private var macField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text("Mac").llaSmallMuted()
      Picker("Mac", selection: Binding(get: { draft.deviceId ?? "" }, set: { draft.selectMac($0) })) {
        ForEach(draft.macs, id: \.deviceId) { mac in Text(mac.name).tag(mac.deviceId) }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .tint(LLA.Color.ink)
      .frame(maxWidth: .infinity, minHeight: LLA.Metrics.control, alignment: .leading)
      .padding(.horizontal, 10)
      .background(
        RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).fill(LLA.Color.surface)
      )
      .overlay(RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous).stroke(LLA.Color.rule))
      .accessibilityIdentifier("project-mac")
    }
  }

  private var nameField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text("Name").llaSmallMuted()
      LLAField("Name", text: $draft.name)
        .disabled(draft.submitting)
        .accessibilityIdentifier("project-name")
      Text("Leave it empty to use the first folder's name.").llaCaption()
    }
  }

  private var foldersField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      Text("Folders on \(draft.macName)").llaSmallMuted()
      if draft.folders.isEmpty {
        Text("Threads started in a folder you add here join this project.").llaCaption()
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
          .accessibilityIdentifier("project-folder-path")
        Button("Add") { draft.addTyped() }
          .buttonStyle(.llaSecondary)
          .disabled(draft.typed.trimmingCharacters(in: .whitespaces).isEmpty)
          .accessibilityIdentifier("add-project-folder")
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
        .accessibilityIdentifier("project-status")
    } else if let reason = draft.blockedReason, model.projectNotice(deviceId: draft.deviceId) == nil {
      Text(reason).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
    }
  }

  private var deleteButton: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Button("Delete Project", role: .destructive) { confirmingDelete = true }
        .buttonStyle(.llaDanger)
        .disabled(draft.submitting || draft.deleteBlockedReason != nil)
        .accessibilityIdentifier("delete-project")
      Text("Only a project you made can be deleted. Its threads stay.").llaCaption()
    }
    .padding(.top, LLA.Space.m)
  }
}
