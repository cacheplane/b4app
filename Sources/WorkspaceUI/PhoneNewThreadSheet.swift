import Foundation
import SwiftUI
import WorkspaceProtocol

// MARK: - What the phone can start (M8c, "A new thread from the phone")

extension WorkspaceModel {
  /// The projects a thread can be started in from the phone: those whose owning Mac is known, the one
  /// with the newest thread activity first.
  var startProjects: [Project] { filterProjects.filter { $0.ownerDeviceId != nil } }

  /// The connections offered for a project: ready ones on the Mac that owns the project, being Codex
  /// or Claude, or a local B4 connection that serves this very project. Never a remote B4 (the phone
  /// has no route for it), another Mac's connection, or another project's B4.
  public func startConnections(for project: Project) -> [Connection] {
    guard let owner = project.ownerDeviceId else { return [] }
    return conversationReadyConnections.filter { connection in
      guard connection.ownerDeviceId == owner else { return false }
      switch connection.kind {
      case .codex, .claude: return true
      case .b4: return connection.b4Mode != .remote && connection.projectId == project.id
      }
    }
  }

  /// How a connection reads in the sheet: a B4 connection by its route's name, as the Mac titles its
  /// threads (`/research#agent` is "research"); the others by their label.
  public func startLabel(for connection: Connection) -> String {
    guard connection.kind == .b4, let key = connection.routeKey else { return connection.label }
    let route = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(
      String.init)
    let name = route.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
    return name.isEmpty ? connection.label : name
  }

  /// The folders a start may run in: a Codex or Claude thread runs in one of the project's folders; a
  /// B4 thread is bound to its connection's route and has none.
  public func startFolders(for project: Project, connection: Connection) -> [ProjectFolder] {
    connection.kind == .b4 ? [] : project.folders
  }

  /// The folder step is shown only when there is more than one folder to choose from.
  public func needsFolderChoice(for project: Project, connection: Connection) -> Bool {
    startFolders(for: project, connection: connection).count > 1
  }

  /// The notice about the Mac that owns the project: left the hub, offline, or the quiet reconnecting
  /// line. Nil on the Mac and when the Mac is reachable or not known.
  public func startNotice(for project: Project) -> HostNoticeMessage? {
    guard relaysThroughHub else { return nil }
    if hostDisconnected { return HostNoticeMessage(kind: .leftHub, text: RelayCopy.leftHub) }
    if case .reconnecting = hostPhase(deviceId: project.ownerDeviceId) {
      return HostNoticeMessage(kind: .reconnecting, text: RelayCopy.reconnecting)
    }
    return offlineNotice(deviceId: project.ownerDeviceId, fallbackName: nil)
  }

  /// Why a thread cannot be started in this project right now, in words: its own Mac is offline or has
  /// left the hub, or the phone's link is down. Nil while the Mac is reconnecting (the hub answers
  /// `device_offline` for a send in that window, as for any other) and whenever presence is unknown.
  public func startBlockedReason(for project: Project) -> String? {
    guard relaysThroughHub else { return nil }
    if let notice = startNotice(for: project), notice.kind != .reconnecting { return notice.text }
    return hubLinkNotice
  }

  /// Why New thread is off: no project can be started in. The phone checks each project's own Mac, so
  /// one Mac being offline leaves the other's projects open. The Mac's New thread is unchanged.
  public var newThreadEntryReason: String? {
    guard relaysThroughHub else {
      return conversationReadyConnections.isEmpty
        ? "Add a ready Codex connection first" : newThreadDisabledReason
    }
    let projects = startProjects
    let offered = projects.filter { !startConnections(for: $0).isEmpty }
    if offered.contains(where: { startBlockedReason(for: $0) == nil }) { return nil }
    if let reason = offered.lazy.compactMap({ self.startBlockedReason(for: $0) }).first { return reason }
    if let reason = newThreadDisabledReason { return reason }
    return projects.isEmpty
      ? "No projects yet. Start one on your Mac."
      : "Add a ready connection on your Mac first"
  }
}

// MARK: - The sheet's state

/// What the phone's new-thread sheet holds: the choices and the first message, and how the start went.
/// The model keeps the send; this reads it back, so a start that settles later (a retry, a lookup)
/// still closes the sheet, and a refused one leaves the sheet and the text as they were.
@MainActor @Observable
final class PhoneNewThreadDraft {
  let model: WorkspaceModel
  private(set) var projectId = ""
  private(set) var connectionId = ""
  /// The chosen folder path; used only when the connection has several to choose from, or one.
  private(set) var folder = ""
  var text = ""
  /// The thread the latest start minted.
  private(set) var startedThreadId: String?
  /// A start is out and has not returned.
  private(set) var submitting = false
  /// The Mac accepted the start. Kept apart from the send, which the model drops once the thread's own
  /// message shows.
  private var accepted = false
  /// Why the last Start did nothing, when the model refused it before sending.
  private(set) var refusal: String?

  init(model: WorkspaceModel) {
    self.model = model
    let projects = model.startProjects
    let pick =
      projects.first {
        model.startBlockedReason(for: $0) == nil && !model.startConnections(for: $0).isEmpty
      } ?? projects.first
    selectProject(pick?.id ?? "")
  }

  // MARK: Choices

  var projects: [Project] { model.startProjects }
  var project: Project? { model.projects.first { $0.id == projectId } }
  var connections: [Connection] { project.map { model.startConnections(for: $0) } ?? [] }
  var connection: Connection? { connections.first { $0.id == connectionId } }
  var folders: [ProjectFolder] {
    guard let project, let connection else { return [] }
    return model.startFolders(for: project, connection: connection)
  }
  var needsFolderChoice: Bool {
    guard let project, let connection else { return false }
    return model.needsFolderChoice(for: project, connection: connection)
  }

  func selectProject(_ id: String) {
    projectId = id
    if !connections.contains(where: { $0.id == connectionId }) {
      connectionId = connections.first?.id ?? ""
    }
    keepFolder()
  }

  func selectConnection(_ id: String) {
    connectionId = id
    keepFolder()
  }

  func selectFolder(_ path: String) { folder = path }

  private func keepFolder() {
    if !folders.contains(where: { $0.path == folder }) { folder = folders.first?.path ?? "" }
  }

  // MARK: Sending

  /// Why Start is off, in words: the project's Mac cannot be reached, or the choices give nothing to
  /// start. Nil when it can be sent.
  var blockedReason: String? {
    guard let project else { return nil }
    if let reason = model.startBlockedReason(for: project) { return reason }
    if !unsettled, let reason = model.unsettledStartReason { return reason }
    if connections.isEmpty { return "No ready connection on your Mac can start a thread in this project." }
    if let connection, connection.kind != .b4, folders.isEmpty {
      return "This project has no folder yet. Add one on your Mac."
    }
    return nil
  }

  /// An earlier start is still open: the Mac may yet run it, so a second one is not offered.
  private var unsettled: Bool {
    startedThreadId.flatMap { model.pendingSends[$0]?.state.isUnsettled } ?? false
  }

  var canSend: Bool {
    !submitting && !model.isStartingThread && !finished && !unsettled && blockedReason == nil
      && connection != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The words under the message: "Starting…" while it is out, then why it did not go through. Nil
  /// when nothing was started, and once it was accepted.
  var status: String? {
    if submitting { return RelayCopy.starting }
    guard let id = startedThreadId, let send = model.pendingSends[id] else { return refusal }
    switch send.state {
    case .sending: return RelayCopy.starting
    case .notConfirmed: return RelayCopy.notConfirmed
    case .didNotReach: return RelayCopy.didNotReach
    case .refused(let error): return SendRules.reason(error, now: model.now())
    case .accepted, .acceptedWithError: return nil
    }
  }

  /// Whether the status is a failure (shown in the danger color).
  var statusIsFailure: Bool {
    guard !submitting else { return false }
    guard let id = startedThreadId, let state = model.pendingSends[id]?.state else {
      return refusal != nil
    }
    switch state {
    case .refused, .didNotReach, .notConfirmed: return true
    default: return false
    }
  }

  /// The Mac accepted the start: the sheet closes and the thread is open.
  var finished: Bool {
    accepted || (startedThreadId.flatMap { model.pendingSends[$0]?.state.turnId } != nil)
  }

  func submit() async {
    guard canSend, let project, let connection else {
      refusal = blockedReason ?? RelayCopy.startRefused
      return
    }
    refusal = nil
    submitting = true
    defer { submitting = false }
    let send = await model.startThread(
      projectId: project.id, connectionId: connection.id, folder: folder.isEmpty ? nil : folder,
      text: text)
    startedThreadId = send?.threadId
    if send == nil { refusal = blockedReason ?? RelayCopy.startRefused }
    if send?.state.turnId != nil { accepted = true }
  }

  /// A start that was accepted later (a retry or a lookup) did not open the thread; open it now.
  func openStartedThread() async {
    guard let id = startedThreadId, model.selectedThreadId != id else { return }
    await model.openThread(id: id)
  }
}

// MARK: - The sheet

/// The phone's New thread: project → connection → folder (only when there are several) → the first
/// message. Mounted by the root view on the phone; the Mac keeps `NewThreadSheet`.
struct PhoneNewThreadSheet: View {
  @Bindable var model: WorkspaceModel
  @State private var draft: PhoneNewThreadDraft
  @Environment(\.dismiss) private var dismiss
  @Environment(\.showDetail) private var showDetail
  @FocusState private var messageFocused: Bool

  init(model: WorkspaceModel) {
    self.model = model
    self._draft = State(initialValue: PhoneNewThreadDraft(model: model))
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
          Button("Start") { Task { await draft.submit() } }
            .disabled(!draft.canSend)
            .accessibilityIdentifier("start-thread")
        }
      }
    }
    .tint(LLA.Color.accent)
    .interactiveDismissDisabled(draft.submitting)
    .onChange(of: draft.finished) { _, finished in
      guard finished else { return }
      Task {
        await draft.openStartedThread()
        showDetail()
        dismiss()
      }
    }
  }

  // MARK: Fields

  private var projectField: some View {
    field("Project") {
      Picker(
        "Project",
        selection: Binding(get: { draft.projectId }, set: { draft.selectProject($0) })
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
          selection: Binding(get: { draft.connectionId }, set: { draft.selectConnection($0) })
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
        "Folder", selection: Binding(get: { draft.folder }, set: { draft.selectFolder($0) })
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
