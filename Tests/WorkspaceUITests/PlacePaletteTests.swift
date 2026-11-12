import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The place palette's list (the thread list and environments design, "Starting a thread"): one row per
/// environment, then one indented row per folder of an environment with several; a filter; a check on
/// the current place; a highlight that the arrow keys move.
@Suite struct PlacePaletteTests {
  static func environment(_ id: String, _ name: String, _ paths: [String]) -> WorkEnvironment {
    WorkEnvironment(
      id: id, name: name, createdAt: "2026-11-01T00:00:00Z", updatedAt: "2026-11-01T00:00:00Z",
      folders: paths.enumerated().map {
        EnvironmentFolder(
          id: "\(id)-\($0.offset)", environmentId: id, path: $0.element,
          createdAt: "2026-11-01T00:00:0\($0.offset)Z")
      })
  }

  static let b4app = environment("b4app", "b4app", ["/Users/me/repos/b4app"])
  static let infra = environment(
    "infra", "infra", ["/Users/me/repos/infra", "/Users/me/repos/infra-modules"])
  static let all = [b4app, infra]

  @Test func eachEnvironmentIsARowAndSeveralFoldersAreIndentedUnderIt() {
    let rows = PlacePalette.rows(Self.all, filter: "", place: .noFolder)
    #expect(rows.map(\.title) == ["b4app", "infra", "infra", "infra-modules"])
    #expect(rows.map(\.indented) == [false, false, true, true])
    // An environment's own row starts in its first folder and shows that folder's path.
    #expect(rows[1].folder == "/Users/me/repos/infra")
    #expect(rows[1].path == "/Users/me/repos/infra")
    #expect(rows[3].folder == "/Users/me/repos/infra-modules")
    #expect(rows.allSatisfy { $0.environmentId == ($0.title == "b4app" ? "b4app" : "infra") })
  }

  @Test func theCurrentPlaceIsChecked() {
    let single = PlacePalette.rows(
      Self.all, filter: "", place: .environment("b4app", folder: "/Users/me/repos/b4app"))
    #expect(single.map(\.checked) == [true, false, false, false])
    // With several folders the check is on the folder, not on the environment's own row.
    let second = PlacePalette.rows(
      Self.all, filter: "", place: .environment("infra", folder: "/Users/me/repos/infra-modules"))
    #expect(second.map(\.checked) == [false, false, false, true])
    #expect(PlacePalette.rows(Self.all, filter: "", place: .noFolder).allSatisfy { !$0.checked })
    #expect(
      PlacePalette.rows(Self.all, filter: "", place: .chosenFolder("/tmp/x")).allSatisfy { !$0.checked })
  }

  @Test func theFilterMatchesNamesAndPathsIgnoringCase() {
    #expect(PlacePalette.rows(Self.all, filter: "B4", place: .noFolder).map(\.title) == ["b4app"])
    // A folder's match keeps its environment's row, so the folder still reads under its environment.
    #expect(
      PlacePalette.rows(Self.all, filter: "modules", place: .noFolder).map(\.title) == [
        "infra", "infra-modules",
      ])
    // The environment's name keeps all its folders.
    #expect(
      PlacePalette.rows(Self.all, filter: "infra", place: .noFolder).map(\.title) == [
        "infra", "infra", "infra-modules",
      ])
    #expect(PlacePalette.rows(Self.all, filter: "  repos/b4  ", place: .noFolder).map(\.title) == ["b4app"])
    #expect(PlacePalette.rows(Self.all, filter: "nothing", place: .noFolder).isEmpty)
  }

  @Test func pathsShowTheHomeAsATilde() {
    #expect(PlacePalette.shownPath("/Users/me/repos/b4app", home: "/Users/me") == "~/repos/b4app")
    #expect(PlacePalette.shownPath("/Users/me", home: "/Users/me") == "~")
    #expect(PlacePalette.shownPath("/Users/meta/x", home: "/Users/me") == "/Users/meta/x")
    #expect(PlacePalette.shownPath("/opt/work", home: "/Users/me") == "/opt/work")
  }

  @Test func theHighlightStartsOnTheCheckedRowAndStaysInTheList() {
    let rows = PlacePalette.rows(
      Self.all, filter: "", place: .environment("infra", folder: "/Users/me/repos/infra-modules"))
    #expect(PlacePalette.initialHighlight(rows) == 3)
    #expect(PlacePalette.initialHighlight(PlacePalette.rows(Self.all, filter: "", place: .noFolder)) == 0)
    #expect(PlacePalette.step(3, by: 1, count: rows.count) == 3)
    #expect(PlacePalette.step(0, by: -1, count: rows.count) == 0)
    #expect(PlacePalette.step(1, by: 1, count: rows.count) == 2)
    #expect(PlacePalette.step(0, by: 1, count: 0) == 0)
  }
}
