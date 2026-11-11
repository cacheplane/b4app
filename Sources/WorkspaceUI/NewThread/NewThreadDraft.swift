import Foundation
import Observation
import WorkspaceProtocol

/// The new-thread composer's state, the same on the Mac and the phone: where the thread starts (an
/// environment and its starting folder, "No folder" (a folder the Mac makes for the thread), or on the Mac
/// a folder chosen outside every environment), the runtime connection, model, and permission, and the first
/// message.
///
/// The choices open on this device's last ones (`NewThreadMemory`, the spec's "Defaults"), falling
/// back past anything that no longer exists, and the unsent text is kept in that memory as it changes.
/// The model keeps the send; this reads it back, so a start that settles later (a retry, a lookup)
/// still finishes the draft, and a refused one leaves the choices and the text as they were.
@MainActor @Observable
final class NewThreadDraft {
  unowned let workspace: WorkspaceModel
  private(set) var environmentId: String?
  /// The starting folder, one of the environment's folders; nil with no environment.
  private(set) var folder: String?
  /// A folder from "Choose folder…" that is none of an environment's folders (the Mac only). Its environment is
  /// found or made by the coordinator on Send, never before, so an abandoned draft leaves none behind.
  private(set) var chosenFolder: String?
  /// "No folder" was chosen by hand, so a refresh keeps it rather than taking the remembered environment
  /// (which a draft made before the environments loaded could not yet find).
  private var choseNoFolder = false
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

  /// A draft on this device's last choices; `environmentId`, when it names an environment a thread can start
  /// in, replaces only the remembered environment.
  init(model: WorkspaceModel, environmentId: String?) {
    workspace = model
    let memory = NewThreadMemory.load(from: model.preferences)
    text = memory.text
    place(in: defaultEnvironment(environmentId, memory), memory)
    apply(defaultRuntime(memory, allowRemote: environmentId == nil))
  }

  // MARK: Choices

  var environments: [WorkEnvironment] { workspace.startEnvironments }
  var environment: WorkEnvironment? {
    environmentId.flatMap { id in workspace.environments.first { $0.id == id } }
  }

  /// The runtimes offered here: an environment's connections, or with none ("No folder" or a chosen folder)
  /// the ones that need no environment; on the Mac, remote B4 last.
  var connections: [Connection] {
    guard let environment else { return workspace.startConnectionsWithoutEnvironment }
    return workspace.startConnections(for: environment) + workspace.remoteB4Connections
  }

  var connection: Connection? { connections.first { $0.id == connectionId } }

  /// A remote B4 connection is chosen: no environment, no folder, no permission.
  var isRemoteB4: Bool { connection.map { $0.kind == .b4 && $0.b4Mode == .remote } ?? false }

  /// "No folder": a Codex or Claude thread in a folder the Mac makes for it. No environment and no chosen
  /// folder, and not a remote B4 (which has no folder of its own to make).
  var isNoFolder: Bool { environmentId == nil && chosenFolder == nil && !isRemoteB4 }

  var folders: [EnvironmentFolder] {
    guard let environment, let connection else { return [] }
    return workspace.startFolders(for: environment, connection: connection)
  }

  var needsFolderChoice: Bool {
    guard let environment, let connection else { return false }
    return workspace.needsFolderChoice(for: environment, connection: connection)
  }

  /// Start in an environment: its remembered folder (or its first), and the runtime kept when the environment
  /// offers it, otherwise the environment's own defaults.
  func selectEnvironment(_ id: String) {
    guard let environment = workspace.startEnvironments.first(where: { $0.id == id }) else { return }
    let memory = NewThreadMemory.load(from: workspace.preferences)
    place(in: environment, memory)
    if connection == nil || isRemoteB4 { apply(defaultRuntime(memory, allowRemote: false)) }
  }

  /// Start in one of an environment's folders; choosing the folder chooses the environment.
  func selectFolder(_ folder: String, in environmentId: String) {
    selectEnvironment(environmentId)
    guard self.environmentId == environmentId,
      environment?.folders.contains(where: { $0.path == folder }) == true
    else { return }
    self.folder = folder
  }

  /// The path of a folder the system's file picker handed back, in the form the coordinator keys a
  /// environment's folders by (`SessionService.canonicalDirectory`): symlinks resolved, `..` collapsed, no
  /// trailing slash. So an environment's folder reached through a link is still that environment's.
  static func folderPath(of url: URL) -> String {
    var path = url.standardizedFileURL.resolvingSymlinksInPath().path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  /// "Choose folder…" (the Mac): an environment's own folder starts in that environment; any other folder starts
  /// with no environment, on a Codex or Claude connection. `path` is `folderPath(of:)`.
  func chooseFolder(_ path: String) {
    guard !workspace.relaysThroughHub else { return }
    if let environment = workspace.startEnvironments.first(where: { $0.folders.contains { $0.path == path } })
    {
      selectFolder(path, in: environment.id)
      return
    }
    environmentId = nil
    folder = nil
    chosenFolder = path
    choseNoFolder = false
    if connection == nil || connection?.kind == .b4 {
      apply(defaultRuntime(NewThreadMemory.load(from: workspace.preferences), allowRemote: false))
    }
  }

  /// "No folder": no environment and no chosen folder. A runtime not offered with no folder (this
  /// environment's B4 agent) gives way to the default one.
  func selectNoFolder() {
    environmentId = nil
    folder = nil
    chosenFolder = nil
    choseNoFolder = true
    if connection == nil || connection?.kind == .b4 {
      apply(defaultRuntime(NewThreadMemory.load(from: workspace.preferences), allowRemote: false))
    }
  }

  /// Choose a runtime connection and its model. Another runtime resets the permission to "As
  /// configured"; a B4 agent has neither model nor permission, and a remote one has no environment.
  func selectRuntime(connectionId id: String, model chosen: String?) {
    guard let next = connections.first(where: { $0.id == id }) else { return }
    let previousKind = connection?.kind
    let wasRemoteB4 = isRemoteB4
    connectionId = id
    model = next.kind == .b4 ? nil : chosen
    if next.kind == .b4 || previousKind != next.kind { permission = nil }
    if isRemoteB4 {
      environmentId = nil
      folder = nil
      chosenFolder = nil
    } else if wasRemoteB4 {
      // Leaving a remote B4: the thread takes the default place again, which may be "No folder".
      let memory = NewThreadMemory.load(from: workspace.preferences)
      place(in: defaultEnvironment(nil, memory), memory)
    }
  }

  /// Choose a permission of the chosen runtime; nil is "As configured". Another runtime's is ignored.
  func selectPermission(_ id: String?) {
    guard let kind = connection?.kind, kind != .b4 else { return }
    if let id, !RuntimeOptions.permissions(for: kind).contains(where: { $0.id == id }) { return }
    permission = id
  }

  /// Keep the choices that are still offered and fill in the rest from memory, as a new draft would:
  /// for a draft made before the environments and connections loaded, or one whose choice went away.
  func refreshChoices() {
    let memory = NewThreadMemory.load(from: workspace.preferences)
    if !isRemoteB4, chosenFolder == nil {
      if let environment {
        if !environment.folders.contains(where: { $0.path == folder }) { place(in: environment, memory) }
      } else if !choseNoFolder {
        place(in: defaultEnvironment(nil, memory), memory)
      }
    }
    if connection == nil {
      apply(defaultRuntime(memory, allowRemote: environmentId == nil && !choseNoFolder))
    }
  }

  // MARK: Defaults

  /// The environment asked for, else the remembered one while it still exists, else none: "No folder".
  private func defaultEnvironment(_ requested: String?, _ memory: NewThreadMemory) -> WorkEnvironment? {
    let environments = workspace.startEnvironments
    if let requested, let environment = environments.first(where: { $0.id == requested }) {
      return environment
    }
    return memory.environmentId.flatMap { id in environments.first { $0.id == id } }
  }

  private func place(in environment: WorkEnvironment?, _ memory: NewThreadMemory) {
    environmentId = environment?.id
    chosenFolder = nil
    choseNoFolder = false
    folder = environment.flatMap { environment in
      let paths = environment.folders.map(\.path)
      let remembered = memory.folderByEnvironment[environment.id].flatMap { paths.contains($0) ? $0 : nil }
      return remembered ?? paths.first
    }
  }

  /// The runtime last used in this environment, else the last used anywhere, else the first offered with
  /// its default model and "As configured". A remembered remote B4 is taken only when no environment was
  /// asked for, since it would leave the environment.
  private func defaultRuntime(_ memory: NewThreadMemory, allowRemote: Bool) -> RuntimeChoice? {
    let offered = connections.filter { allowRemote || !($0.kind == .b4 && $0.b4Mode == .remote) }
    let remembered = [environmentId.flatMap { memory.runtimeByEnvironment[$0] }, memory.lastRuntime]
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
      environmentId = nil
      folder = nil
      chosenFolder = nil
    }
  }

  // MARK: Sending

  /// Why Send is off, in words: the Mac it would go to cannot be reached (the environment's, or for "No
  /// folder" on the phone the primary Mac), an earlier start is still open, or the choices give nothing to
  /// start. Nil when it can be sent.
  var blockedReason: String? {
    if let environment, let reason = workspace.startBlockedReason(for: environment) { return reason }
    if isNoFolder, let reason = workspace.startBlockedReason(forDevice: workspace.primaryHostId) {
      return reason
    }
    if !unsettled, let reason = workspace.unsettledStartReason { return reason }
    let phone = workspace.relaysThroughHub
    guard let connection else {
      if environment == nil, chosenFolder == nil { return phone ? nil : "Choose a folder to start in." }
      return phone
        ? "No ready connection on your Mac can start a thread in this environment."
        : "No ready connection can start a thread in this environment."
    }
    if environment != nil, connection.kind != .b4, folder == nil {
      return phone
        ? "This environment has no folder yet. Add one on your Mac." : "This environment has no folder yet."
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
  /// until the Mac accepts (then the model clears the text and remembers the choices). A second Send
  /// while this draft's start is out does nothing, so no refusal is left to show once it settles.
  func send() async {
    guard !submitting else { return }
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
      environmentId: environmentId, connectionId: connection.id, folder: b4 ? nil : chosenFolder ?? folder,
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
    let draft = NewThreadDraft(model: self, environmentId: nil)
    newThreadDraftStorage = draft
    return draft
  }

  /// A start the Mac accepted, however it settled (its reply, a retry, a lookup, the synced turn): its
  /// choices become this device's last ones and the unsent text that was sent is cleared.
  func newThreadStarted(_ start: ThreadStart.Params, text: String) {
    let thread = threads.first { $0.id == start.threadId }
    let remoteB4 =
      connection(id: start.connectionId).map { $0.kind == .b4 && $0.b4Mode == .remote } ?? false
    NewThreadMemory.update(preferences) { memory in
      memory.remember(start, thread: thread, remoteB4: remoteB4)
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
