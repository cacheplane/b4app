import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// The words of the dense composer's one muted line, in place of its row of pickers: where a thread
/// starts, the runtime and model, and the permission when it is not the default. The picker row builds
/// its place and runtime text from the same statics, so the two never disagree.
struct ComposerSummary: Equatable {
  /// The environment (and folder); nil for a thread, whose place is already on screen.
  var place: String?
  /// "Claude Code · Opus" or a B4 agent's start label; nil with no connection, drawn as "No runtime".
  var runtime: String?
  /// The permission's label; nil when it is as configured, and for B4, whose route decides.
  var permission: String?

  /// The parts that exist, joined by " · ".
  var text: String {
    [place, runtime ?? Self.noRuntime, permission].compactMap { $0 }.joined(separator: " · ")
  }

  /// VoiceOver's sentence: every " · " (the place's and the runtime's) is read as a pause, and the
  /// permission is its label alone ("Plan mode"), since some labels already say "permissions".
  var spoken: String {
    var sentence = place.map { "Runs in " + $0.replacingOccurrences(of: " · ", with: ", ") } ?? "Runs"
    if let runtime {
      sentence += " with " + runtime.replacingOccurrences(of: " · ", with: ", ")
    } else {
      // A thread has no place to lead with: "Runs, no runtime" would read as a fragment.
      sentence = place == nil ? Self.noRuntime : sentence + ", no runtime"
    }
    if let permission { sentence += ", \(permission)" }
    return sentence
  }

  static let noRuntime = "No runtime"

  @MainActor static func draft(_ draft: NewThreadDraft, in model: WorkspaceModel) -> ComposerSummary {
    ComposerSummary(
      place: placeText(draft),
      runtime: draft.connection.map { runtimeText($0, model: draft.model, in: model) },
      permission: permissionText(draft.connection, chosen: draft.permission))
  }

  @MainActor static func thread(_ thread: ConversationThread, in model: WorkspaceModel) -> ComposerSummary {
    let connection = model.connection(id: thread.connectionId)
    return ComposerSummary(
      place: nil,
      runtime: connection.map { runtimeText($0, model: thread.model, in: model) },
      permission: permissionText(connection, chosen: thread.permission))
  }

  /// The environment's name, with the starting folder's name when it has several; a chosen folder (the
  /// Mac's "Choose folder…") by its own name until Send finds its environment; else "No folder".
  @MainActor static func placeText(_ draft: NewThreadDraft) -> String {
    if let chosen = draft.chosenFolder { return ComposerPickerRow.folderName(chosen) }
    guard let environment = draft.environment else { return "No folder" }
    guard draft.connection?.kind != .b4, environment.folders.count > 1, let folder = draft.folder else {
      return environment.displayName
    }
    return "\(environment.displayName) · \(ComposerPickerRow.folderName(folder))"
  }

  /// A thread's place: "No folder" when it has no environment, whatever its folder is called (a folder
  /// the Mac made for it); an environment not loaded (or gone) by the thread's folder.
  @MainActor static func placeText(_ thread: ConversationThread, in model: WorkspaceModel) -> String {
    guard let environmentId = thread.environmentId else { return "No folder" }
    let environment = model.environments.first { $0.id == environmentId }
    let b4 = model.connection(id: thread.connectionId)?.kind == .b4
    guard let environment else {
      guard !b4, let context = thread.context, !context.isEmpty else { return "No folder" }
      return ComposerPickerRow.folderName(context)
    }
    guard !b4, environment.folders.count > 1, let context = thread.context else {
      return environment.displayName
    }
    return "\(environment.displayName) · \(ComposerPickerRow.folderName(context))"
  }

  /// "Claude Code · Sonnet"; a B4 agent by its route's name; "No runtime" with no connection.
  @MainActor static func runtimeText(
    _ connection: Connection?, model chosen: String?, in model: WorkspaceModel
  ) -> String {
    guard let connection else { return noRuntime }
    if connection.kind == .b4 { return model.startLabel(for: connection) }
    return "\(connection.label) · \(ComposerPickerRow.modelName(chosen, in: connection))"
  }

  private static func permissionText(_ connection: Connection?, chosen: String?) -> String? {
    guard let connection, connection.kind != .b4, let chosen else { return nil }
    return RuntimeOptions.permissionLabel(chosen, kind: connection.kind)
  }
}
