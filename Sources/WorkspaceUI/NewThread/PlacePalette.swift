import Foundation
import WorkspaceProtocol

/// The list the place palette shows (the thread list and environments design, "Starting a thread"),
/// apart from the views that draw it: one row per environment, then one indented row per folder of an
/// environment with several, so a thread can start in any of them. An environment's own row starts in
/// its first folder.
enum PlacePalette {
  /// Where a draft starts, as the palette checks it.
  enum Place: Equatable {
    case environment(String, folder: String?)
    /// A folder from "Choose folder…" that no environment has yet.
    case chosenFolder(String)
    case noFolder
  }

  struct Row: Equatable, Identifiable {
    var id: String
    var environmentId: String
    var title: String
    /// The folder choosing this row starts in; nil for an environment with no folder.
    var folder: String?
    /// The path shown at the right: the folder's.
    var path: String?
    var indented: Bool
    var checked: Bool
  }

  /// The rows for `environments`, in their order, that match `filter`: an environment whose name
  /// matches keeps all its folders; otherwise only the folders whose path matches, under the
  /// environment's row. A path matches as written or as shown (`shownPath`, "~/repos"). Case is
  /// ignored, and so is space around the filter.
  static func rows(
    _ environments: [WorkEnvironment], filter: String, place: Place, home: String = NSHomeDirectory()
  ) -> [Row] {
    let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ text: String) -> Bool { needle.isEmpty || text.localizedCaseInsensitiveContains(needle) }
    func matchesPath(_ path: String) -> Bool { matches(path) || matches(shownPath(path, home: home)) }

    var rows: [Row] = []
    for environment in environments {
      let name = environment.displayName
      let first = environment.folders.first?.path
      let several = environment.folders.count > 1
      let folders = matches(name) ? environment.folders : environment.folders.filter { matchesPath($0.path) }
      guard matches(name) || !folders.isEmpty else { continue }
      let current: String?? = {
        if case .environment(let id, let folder) = place, id == environment.id { return .some(folder) }
        return .none
      }()
      rows.append(
        Row(
          id: environment.id, environmentId: environment.id, title: name, folder: first, path: first,
          indented: false,
          // With several folders the check sits on the folder, unless none is chosen yet.
          checked: current != nil && (!several || current == .some(nil))))
      guard several else { continue }
      for folder in folders {
        rows.append(
          Row(
            id: "\(environment.id):\(folder.path)", environmentId: environment.id,
            title: ComposerPickerRow.folderName(folder.path), folder: folder.path, path: folder.path,
            indented: true, checked: current == .some(folder.path)))
      }
    }
    return rows
  }

  /// `path` with the home folder written as "~", as the palette shows it.
  static func shownPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard !home.isEmpty, home != "/" else { return path }
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  /// The line in the list's place when there are no rows: no environments at all (a blank filter), or
  /// none that match. "Choose a folder below" only where the footer offers it.
  static func emptyLine(filter: String, canChooseFolder: Bool) -> String {
    let blank = filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let line = blank ? "No environments yet." : "Nothing matches."
    return canChooseFolder ? line + " Choose a folder below." : line
  }

  /// The row highlighted when the palette opens or its filter changes: the checked one, else the first.
  static func initialHighlight(_ rows: [Row]) -> Int {
    rows.firstIndex(where: \.checked) ?? 0
  }

  /// Move a highlight by `delta`, staying inside `0..<count`.
  static func step(_ index: Int, by delta: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index + delta, 0), count - 1)
  }
}

extension NewThreadDraft {
  /// Where this draft starts, as the place palette checks it.
  var palettePlace: PlacePalette.Place {
    if let chosenFolder { return .chosenFolder(chosenFolder) }
    if let environmentId { return .environment(environmentId, folder: folder) }
    return .noFolder
  }

  /// Start where a palette row says: its folder in its environment, or the environment when it has none.
  func choose(_ row: PlacePalette.Row) {
    if let folder = row.folder {
      selectFolder(folder, in: row.environmentId)
    } else {
      selectEnvironment(row.environmentId)
    }
  }
}
