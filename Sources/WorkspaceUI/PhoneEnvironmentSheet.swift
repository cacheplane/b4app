import Foundation
import SwiftUI
import WorkspaceClient
import WorkspaceProtocol

// MARK: - Environment edits from the phone

/// Which environment sheet the phone shows: a new environment, or one environment's name and folders.
public enum EnvironmentSheetRequest: Identifiable, Equatable, Sendable {
  case create
  case edit(environmentId: String)

  public var id: String {
    switch self {
    case .create: "create"
    case .edit(let environmentId): "edit:\(environmentId)"
    }
  }
}

extension WorkspaceModel {
  /// The Macs an environment can be made on: every Mac the hub lists, the one the list speaks for first,
  /// then by name.
  public var environmentMacs: [HostPresence] {
    let primary = primaryHostId
    return hostPresence.values.sorted { lhs, rhs in
      if (lhs.deviceId == primary) != (rhs.deviceId == primary) { return lhs.deviceId == primary }
      return (lhs.name, lhs.deviceId) < (rhs.name, rhs.deviceId)
    }
  }

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

  /// Why an environment cannot be created on, or have its folders changed on, the Mac `deviceId` now: it is
  /// offline or has left the hub, the phone's link is down, or no Mac is known. Nil on the Mac, and
  /// while the Mac is reconnecting (the hub then answers `device_offline` itself). A rename needs no
  /// Mac: it goes through the change log.
  public func environmentEditBlockedReason(deviceId: String?) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = environmentNotice(deviceId: deviceId), notice.kind != .reconnecting { return notice.text }
    if let link = hubLinkNotice { return link }
    return deviceId == nil ? RelayCopy.noMacForEnvironment : nil
  }

  /// Folders an environment on `deviceId`'s Mac can take without typing: those of that Mac's automatic
  /// environments (a folder of another manual environment is refused by the Mac), the most recently active
  /// first, less the ones `excluding` already lists.
  public func folderSuggestions(onMac deviceId: String?, excluding: [String] = []) -> [String] {
    guard let deviceId else { return [] }
    var seen = Set(excluding)
    var result: [String] = []
    for environment in filterEnvironments where environment.ownerDeviceId == deviceId && !environment.manual {
      for folder in environment.folders where seen.insert(folder.path).inserted { result.append(folder.path) }
    }
    return result
  }

  /// Create a manual environment on the Mac `deviceId`, through the hub. `environmentId` is the sheet's own,
  /// so trying again after a lost reply finds the environment the first try made.
  func createEnvironment(
    name: String, folders: [String], deviceId: String, environmentId: String
  ) async -> Result<WorkEnvironment, WorkspaceError> {
    await environmentEdit(.environmentCreate) {
      try await $0.request(
        EnvironmentCreate.self,
        EnvironmentCreate.Params(
          name: name, folders: folders, environmentId: environmentId, deviceId: deviceId),
        options: $1
      ).environment
    }
  }

  /// Save the phone's edit of `environment`. A name alone is a rename, written to the mirror at once and
  /// queued for the hub, so it works with the Mac offline; a folder change goes to the Mac with the
  /// name in one update, which the Mac validates.
  func editEnvironment(
    _ environment: WorkEnvironment, name: String, addFolders: [String], removeFolders: [String]
  ) async -> Result<WorkEnvironment, WorkspaceError> {
    if addFolders.isEmpty, removeFolders.isEmpty {
      guard name != environment.name else { return .success(environment) }
      return await environmentEdit(.environmentRename) {
        try await $0.request(
          EnvironmentRename.self, EnvironmentRename.Params(environmentId: environment.id, name: name),
          options: $1
        ).environment
      }
    }
    return await environmentEdit(.environmentUpdate) {
      try await $0.request(
        EnvironmentUpdate.self,
        EnvironmentUpdate.Params(
          environmentId: environment.id, name: name == environment.name ? nil : name,
          addFolders: addFolders.isEmpty ? nil : addFolders,
          removeFolders: removeFolders.isEmpty ? nil : removeFolders),
        options: $1
      ).environment
    }
  }

  /// Delete a manual environment on its Mac, through the hub.
  func deleteEnvironmentOnMac(id: String) async -> WorkspaceError? {
    guard let client else { return WorkspaceError(.endpointUnavailable, "Coordinator is not connected.") }
    do {
      _ = try await client.request(
        EnvironmentDelete.self, EnvironmentDelete.Params(environmentId: id),
        options: Self.mutation(timeout: Self.relayTimeout(for: .environmentDelete)))
    } catch {
      return WorkspaceError.from(error)
    }
    environments.removeAll { $0.id == id }
    if environmentFilter == .environment(id) { environmentFilter = .all }
    return nil
  }

  /// One environment command whose failure the sheet shows itself (never `lastError`); the environment it
  /// returns joins the list until the synced rows replace it.
  private func environmentEdit(
    _ method: WorkspaceProtocol.Method,
    _ body: (WorkspaceClient, RequestOptions) async throws -> WorkEnvironment
  ) async -> Result<WorkEnvironment, WorkspaceError> {
    guard let client else {
      return .failure(WorkspaceError(.endpointUnavailable, "Coordinator is not connected."))
    }
    do {
      let environment = try await body(client, Self.mutation(timeout: Self.relayTimeout(for: method)))
      merge(environment)
      return .success(environment)
    } catch {
      return .failure(WorkspaceError.from(error))
    }
  }
}

// MARK: - The sheet's state

/// What the phone's environment sheet holds: the Mac (for a new environment), the name, and the folders, and
/// how the save went. Folders are paths on the Mac; the phone never looks at a filesystem, so a typed
/// path is checked by the Mac when the sheet is saved.
@MainActor @Observable
final class PhoneEnvironmentDraft {
  let model: WorkspaceModel
  /// The environment being edited; nil for a new one.
  let environment: WorkEnvironment?
  /// A new environment's id, minted once per sheet, or the edited environment's.
  let environmentId: String
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

  init(model: WorkspaceModel, request: EnvironmentSheetRequest) {
    self.model = model
    switch request {
    case .create:
      environment = nil
      environmentId = UUID().uuidString.lowercased()
      name = ""
      folders = []
      // A Mac that can take the environment now, as the new-thread sheet opens on a startable environment.
      let macs = model.environmentMacs
      deviceId =
        (macs.first { model.environmentEditBlockedReason(deviceId: $0.deviceId) == nil } ?? macs.first)?
        .deviceId
    case .edit(let id):
      let environment = model.environments.first { $0.id == id }
      self.environment = environment
      environmentId = id
      name = environment?.name ?? ""
      folders = environment?.folders.map(\.path) ?? []
      deviceId = environment?.ownerDeviceId
    }
  }

  var isNew: Bool { environment == nil }
  var macs: [HostPresence] { model.environmentMacs }
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
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// An automatic environment keeps its folder (the Mac refuses removing one without adding another), so
  /// only a manual or new environment offers Remove.
  func canRemove(_ path: String) -> Bool {
    guard let environment, !environment.manual else { return true }
    return !environment.folders.contains { $0.path == path }
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

  /// Why Save is off, in words: the Mac cannot be reached for a change that needs it, or a new environment
  /// has no folder. Nil when it can be saved (or there is nothing to save).
  var blockedReason: String? {
    if !isNew, foldersChanged, deviceId == nil { return RelayCopy.environmentNotSynced }
    if isNew || foldersChanged, let reason = model.environmentEditBlockedReason(deviceId: deviceId) {
      return reason
    }
    if isNew, folders.isEmpty { return "Add a folder on \(macName)." }
    return nil
  }

  var canSave: Bool {
    guard !submitting, !finished, blockedReason == nil else { return false }
    guard let environment else { return !folders.isEmpty }
    return foldersChanged || trimmedName != environment.name
  }

  /// Delete is offered for a manual environment, which only its Mac can delete.
  var canDelete: Bool { environment?.manual == true }
  var deleteBlockedReason: String? {
    deviceId == nil ? RelayCopy.environmentNotSynced : model.environmentEditBlockedReason(deviceId: deviceId)
  }

  func submit() async {
    guard canSave else { return }
    failure = nil
    submitting = true
    defer { submitting = false }
    let result: Result<WorkEnvironment, WorkspaceError>
    if let environment {
      result = await model.editEnvironment(
        environment, name: trimmedName, addFolders: added, removeFolders: removed)
    } else if let deviceId {
      result = await model.createEnvironment(
        name: trimmedName, folders: folders, deviceId: deviceId, environmentId: environmentId)
    } else {
      return
    }
    switch result {
    case .success(let saved):
      if isNew { model.environmentFilter = .environment(saved.id) }
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
    if let error = await model.deleteEnvironmentOnMac(id: environment.id) {
      failure = SendRules.reason(error, now: model.now())
    } else {
      finished = true
    }
  }
}

// MARK: - The sheet

/// The phone's New environment and Edit environment: the Mac (only when there are several, for a new
/// environment), the name, the folders with the Mac's own folders offered, and a typed path. Mounted by
/// the root view on the phone; the Mac keeps `NewEnvironmentSheet` and its sidebar menus.
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
      .navigationTitle(draft.isNew ? "New environment" : "Edit environment")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.isNew ? "Create" : "Save") { Task { await draft.submit() } }
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
        Text("Its folders return to automatic environments. No threads are deleted.")
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
      .accessibilityIdentifier("environment-mac")
    }
  }

  private var nameField: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      Text("Name").llaSmallMuted()
      LLAField("Name", text: $draft.name)
        .disabled(draft.submitting)
        .accessibilityIdentifier("environment-name")
      Text("Leave it empty to use the first folder's name.").llaCaption()
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
      Text("Only an environment you made can be deleted. Its threads stay.").llaCaption()
    }
    .padding(.top, LLA.Space.m)
  }
}
