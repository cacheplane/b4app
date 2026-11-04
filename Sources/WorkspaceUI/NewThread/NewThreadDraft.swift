import Foundation
import Observation
import WorkspaceProtocol

/// The new-thread composer's state, the same on the Mac and the phone: where the thread starts (a
/// project and its starting folder, or on the Mac a folder chosen outside every project), the runtime
/// connection, model, and permission, and the first message.
///
/// The choices open on this device's last ones (`NewThreadMemory`, the spec's "Defaults"), falling
/// back past anything that no longer exists, and the unsent text is kept in that memory as it changes.
/// The model keeps the send; this reads it back, so a start that settles later (a retry, a lookup)
/// still finishes the draft, and a refused one leaves the choices and the text as they were.
@MainActor @Observable
final class NewThreadDraft {
  unowned let workspace: WorkspaceModel
  private(set) var projectId: String?
  /// The starting folder, one of the project's folders; nil with no project.
  private(set) var folder: String?
  /// A folder from "Choose folder…" that is none of a project's folders (the Mac only). Its project is
  /// found or made by the coordinator on Send, never before, so an abandoned draft leaves none behind.
  private(set) var chosenFolder: String?
  private(set) var connectionId: String?
  /// A `RuntimeModel.id`; nil for the runtime's default.
  private(set) var model: String?
  /// A `PermissionOption.id` of the connection's runtime; nil for "As configured".
  private(set) var permission: String?
  var text = "" {
    didSet {
      guard text != oldValue else { return }
      NewThreadMemory.update(workspace.preferences) { $0.text = text }
    }
  }
  /// The thread the latest start minted.
  private(set) var startedThreadId: String?
  /// A start is out and has not returned.
  private(set) var submitting = false
  /// The Mac accepted the start. Kept apart from the send, which the model drops once the thread's own
  /// message shows.
  private var accepted = false
  /// Why the last Send did nothing, when the model refused it before sending.
  private(set) var refusal: String?

  /// A draft on this device's last choices; `projectId`, when it names a project a thread can start
  /// in, replaces only the remembered project.
  init(model: WorkspaceModel, projectId: String?) {
    workspace = model
    let memory = NewThreadMemory.load(from: model.preferences)
    text = memory.text
    place(in: defaultProject(projectId, memory), memory)
    apply(defaultRuntime(memory, allowRemote: projectId == nil))
  }

  // MARK: Choices

  var projects: [Project] { workspace.startProjects }
  var project: Project? { projectId.flatMap { id in workspace.projects.first { $0.id == id } } }

  /// The runtimes offered here: a project's connections, or with none (a chosen folder) the ones that
  /// need no project; on the Mac, remote B4 last.
  var connections: [Connection] {
    guard let project else { return workspace.startConnectionsWithoutProject }
    return workspace.startConnections(for: project) + workspace.remoteB4Connections
  }

  var connection: Connection? { connections.first { $0.id == connectionId } }

  /// A remote B4 connection is chosen: no project, no folder, no permission.
  var isRemoteB4: Bool { connection.map { $0.kind == .b4 && $0.b4Mode == .remote } ?? false }

  var folders: [ProjectFolder] {
    guard let project, let connection else { return [] }
    return workspace.startFolders(for: project, connection: connection)
  }

  var needsFolderChoice: Bool {
    guard let project, let connection else { return false }
    return workspace.needsFolderChoice(for: project, connection: connection)
  }

  /// Start in a project: its remembered folder (or its first), and the runtime kept when the project
  /// offers it, otherwise the project's own defaults.
  func selectProject(_ id: String) {
    guard let project = workspace.startProjects.first(where: { $0.id == id }) else { return }
    let memory = NewThreadMemory.load(from: workspace.preferences)
    place(in: project, memory)
    if connection == nil || isRemoteB4 { apply(defaultRuntime(memory, allowRemote: false)) }
  }

  /// Start in one of a project's folders; choosing the folder chooses the project.
  func selectFolder(_ folder: String, in projectId: String) {
    selectProject(projectId)
    guard self.projectId == projectId, project?.folders.contains(where: { $0.path == folder }) == true
    else { return }
    self.folder = folder
  }

  /// "Choose folder…" (the Mac): a project's own folder starts in that project; any other folder starts
  /// with no project, on a Codex or Claude connection.
  func chooseFolder(_ path: String) {
    guard !workspace.relaysThroughHub else { return }
    if let project = workspace.startProjects.first(where: { $0.folders.contains { $0.path == path } }) {
      selectFolder(path, in: project.id)
      return
    }
    projectId = nil
    folder = nil
    chosenFolder = path
    if connection == nil || connection?.kind == .b4 {
      apply(defaultRuntime(NewThreadMemory.load(from: workspace.preferences), allowRemote: false))
    }
  }

  /// Choose a runtime connection and its model. Another runtime resets the permission to "As
  /// configured"; a B4 agent has neither model nor permission, and a remote one has no project.
  func selectRuntime(connectionId id: String, model chosen: String?) {
    guard let next = connections.first(where: { $0.id == id }) else { return }
    let previousKind = connection?.kind
    connectionId = id
    model = next.kind == .b4 ? nil : chosen
    if next.kind == .b4 || previousKind != next.kind { permission = nil }
    if isRemoteB4 {
      projectId = nil
      folder = nil
      chosenFolder = nil
    } else if projectId == nil, chosenFolder == nil {
      // Leaving a remote B4: the thread needs a place again.
      let memory = NewThreadMemory.load(from: workspace.preferences)
      place(in: defaultProject(nil, memory), memory)
    }
  }

  /// Choose a permission of the chosen runtime; nil is "As configured". Another runtime's is ignored.
  func selectPermission(_ id: String?) {
    guard let kind = connection?.kind, kind != .b4 else { return }
    if let id, !RuntimeOptions.permissions(for: kind).contains(where: { $0.id == id }) { return }
    permission = id
  }

  /// Keep the choices that are still offered and fill in the rest from memory, as a new draft would:
  /// for a draft made before the projects and connections loaded, or one whose choice went away.
  func refreshChoices() {
    let memory = NewThreadMemory.load(from: workspace.preferences)
    if !isRemoteB4, chosenFolder == nil {
      if let project {
        if !project.folders.contains(where: { $0.path == folder }) { place(in: project, memory) }
      } else {
        place(in: defaultProject(nil, memory), memory)
      }
    }
    if connection == nil { apply(defaultRuntime(memory, allowRemote: projectId == nil)) }
  }

  // MARK: Defaults

  /// The project asked for, else the remembered one, else the newest. The phone takes the remembered
  /// or newest only among projects whose Mac can take a start now, as its sheet always has.
  private func defaultProject(_ requested: String?, _ memory: NewThreadMemory) -> Project? {
    let projects = workspace.startProjects
    if let requested, let project = projects.first(where: { $0.id == requested }) { return project }
    let candidates =
      workspace.relaysThroughHub
      ? projects.filter {
        workspace.startBlockedReason(for: $0) == nil && !workspace.startConnections(for: $0).isEmpty
      } : projects
    return candidates.first { $0.id == memory.projectId } ?? candidates.first ?? projects.first
  }

  private func place(in project: Project?, _ memory: NewThreadMemory) {
    projectId = project?.id
    chosenFolder = nil
    folder = project.flatMap { project in
      let paths = project.folders.map(\.path)
      let remembered = memory.folderByProject[project.id].flatMap { paths.contains($0) ? $0 : nil }
      return remembered ?? paths.first
    }
  }

  /// The runtime last used in this project, else the last used anywhere, else the first offered with
  /// its default model and "As configured". A remembered remote B4 is taken only when no project was
  /// asked for, since it would leave the project.
  private func defaultRuntime(_ memory: NewThreadMemory, allowRemote: Bool) -> RuntimeChoice? {
    let offered = connections.filter { allowRemote || !($0.kind == .b4 && $0.b4Mode == .remote) }
    let remembered = [projectId.flatMap { memory.runtimeByProject[$0] }, memory.lastRuntime]
    for case let choice? in remembered {
      guard let connection = offered.first(where: { $0.id == choice.connectionId }) else { continue }
      return Self.valid(choice, for: connection)
    }
    return offered.first.map { RuntimeChoice(connectionId: $0.id) }
  }

  /// A remembered choice with what the connection no longer takes dropped: a model it does not list
  /// (when it lists any), a permission of another runtime, either for B4.
  private static func valid(_ choice: RuntimeChoice, for connection: Connection) -> RuntimeChoice {
    guard connection.kind != .b4 else { return RuntimeChoice(connectionId: connection.id) }
    var choice = choice
    if let model = choice.model, let models = connection.models, !models.contains(where: { $0.id == model }) {
      choice.model = nil
    }
    if let permission = choice.permission,
      !RuntimeOptions.permissions(for: connection.kind).contains(where: { $0.id == permission })
    {
      choice.permission = nil
    }
    return choice
  }

  private func apply(_ choice: RuntimeChoice?) {
    connectionId = choice?.connectionId
    model = choice?.model
    permission = choice?.permission
    if isRemoteB4 {
      projectId = nil
      folder = nil
      chosenFolder = nil
    }
  }

  // MARK: Sending

  /// Why Send is off, in words: the project's Mac cannot be reached, an earlier start is still open, or
  /// the choices give nothing to start. Nil when it can be sent.
  var blockedReason: String? {
    if let project, let reason = workspace.startBlockedReason(for: project) { return reason }
    if !unsettled, let reason = workspace.unsettledStartReason { return reason }
    let phone = workspace.relaysThroughHub
    guard let connection else {
      if project == nil, chosenFolder == nil { return phone ? nil : "Choose a folder to start in." }
      return phone
        ? "No ready connection on your Mac can start a thread in this project."
        : "No ready connection can start a thread in this project."
    }
    if connection.kind != .b4, chosenFolder == nil, folder == nil {
      if project == nil { return "Choose a folder to start in." }
      return phone
        ? "This project has no folder yet. Add one on your Mac." : "This project has no folder yet."
    }
    return nil
  }

  /// An earlier start is still open: the Mac may yet run it, so a second one is not offered.
  private var unsettled: Bool {
    startedThreadId.flatMap { workspace.pendingSends[$0]?.state.isUnsettled } ?? false
  }

  var canSend: Bool {
    !submitting && !workspace.isStartingThread && !unsettled && blockedReason == nil
      && connection != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The words under the message: "Starting…" while it is out, then why it did not go through. Nil
  /// when nothing was started, and once it was accepted.
  var status: String? {
    if submitting { return RelayCopy.starting }
    guard let id = startedThreadId, let send = workspace.pendingSends[id] else { return refusal }
    switch send.state {
    case .sending: return RelayCopy.starting
    case .notConfirmed: return RelayCopy.notConfirmed
    case .didNotReach: return RelayCopy.didNotReach
    case .refused(let error): return SendRules.reason(error, now: workspace.now())
    case .accepted, .acceptedWithError: return nil
    }
  }

  /// Whether the status is a failure (shown in the danger color).
  var statusIsFailure: Bool {
    guard !submitting else { return false }
    guard let id = startedThreadId, let state = workspace.pendingSends[id]?.state else {
      return refusal != nil
    }
    switch state {
    case .refused, .didNotReach, .notConfirmed: return true
    default: return false
    }
  }

  /// The Mac accepted the latest start: the thread exists and is open (or opens with
  /// `openStartedThread`). False again once another start goes out.
  var finished: Bool {
    accepted || (startedThreadId.flatMap { workspace.pendingSends[$0]?.state.turnId } != nil)
  }

  /// Send: create the thread and start its first turn in one command. The text and the choices stay
  /// until the Mac accepts (then the model clears the text and remembers the choices).
  func send() async {
    guard canSend, let connection else {
      refusal = blockedReason ?? RelayCopy.startRefused
      return
    }
    refusal = nil
    accepted = false
    startedThreadId = nil
    submitting = true
    defer { submitting = false }
    let b4 = connection.kind == .b4
    let sent = await workspace.startThread(
      projectId: projectId, connectionId: connection.id, folder: b4 ? nil : chosenFolder ?? folder,
      model: b4 ? nil : model, permission: b4 ? nil : permission, text: text)
    startedThreadId = sent?.threadId
    if sent == nil { refusal = blockedReason ?? RelayCopy.startRefused }
    if sent?.state.turnId != nil { accepted = true }
  }

  /// A start that was accepted later (a retry or a lookup) did not open the thread; open it now.
  func openStartedThread() async {
    guard let id = startedThreadId, workspace.selectedThreadId != id else { return }
    await workspace.openThread(id: id)
  }

  /// The Mac accepted a start of `text`: clear the field if it still holds what was sent.
  fileprivate func started(text sent: String) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines) == sent { text = "" }
  }
}

// MARK: - The model's draft

extension WorkspaceModel {
  /// The new-thread composer's draft, made on first use (after the app sets `preferences`) and kept
  /// until the account ends.
  var newThreadDraft: NewThreadDraft {
    if let draft = newThreadDraftStorage { return draft }
    let draft = NewThreadDraft(model: self, projectId: nil)
    newThreadDraftStorage = draft
    return draft
  }

  /// A start the Mac accepted, however it settled (its reply, a retry, a lookup, the synced turn): its
  /// choices become this device's last ones and the unsent text that was sent is cleared.
  func newThreadStarted(_ start: ThreadStart.Params, text: String) {
    let thread = threads.first { $0.id == start.threadId }
    NewThreadMemory.update(preferences) { memory in
      memory.remember(start, thread: thread)
      if memory.text.trimmingCharacters(in: .whitespacesAndNewlines) == text { memory.text = "" }
    }
    newThreadDraftStorage?.started(text: text)
  }

  /// The workspace was forgotten: the draft is made again for whatever loads next. Its remembered
  /// text stays; only `forgetNewThreadText` (a real sign-out or switch) removes it.
  func forgetNewThreadDraft() {
    newThreadDraftStorage = nil
  }

  /// The signed-in account ended or changed: its unsent text goes (it may name the account's work).
  /// Not at a launch that reads "signed out" before anyone was signed in, so a draft survives that.
  func forgetNewThreadText() {
    newThreadDraftStorage?.text = ""
    NewThreadMemory.update(preferences) { $0.text = "" }
  }
}
