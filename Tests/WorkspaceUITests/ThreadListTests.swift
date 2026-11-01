import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite(.serialized) @MainActor struct ThreadListTests {
  @Test func collapsedProjectsRoundTripThroughACommaJoinedString() {
    #expect(CollapsedProjects.parse("") == [])
    #expect(CollapsedProjects.parse("b,a,,b") == ["a", "b"])
    #expect(CollapsedProjects.encode(["b", "a"]) == "a,b")
    #expect(CollapsedProjects.encode([]) == "")
    #expect(CollapsedProjects.parse(CollapsedProjects.encode(["x", "other"])) == ["x", "other"])
  }

  @Test func dotLabelsNameTheBand() {
    #expect(AttentionBand.needsInput.dotLabel == "Needs your input")
    #expect(AttentionBand.unread.dotLabel == "Unread reply")
    #expect(AttentionBand.working.dotLabel == "Working")
    #expect(AttentionBand.quiet.dotLabel == "Quiet")
  }

  @Test func filterMenuListsProjectsByLatestActivityAndOtherOnlyWhenPresent() async throws {
    let model = try await ListFixture.model()
    // b4app's newest thread is at minute 58, Marketing site's at 50, and Docs has no threads.
    #expect(model.filterProjects.map(\.id) == [ListFixture.b4app, ListFixture.marketing, ListFixture.docs])
    #expect(model.hasOtherThreads)
    #expect(model.filterTitle == "All projects")
    model.projectFilter = .project(ListFixture.marketing)
    #expect(model.filterTitle == "Marketing site")
    model.projectFilter = .other
    #expect(model.filterTitle == "Other")
    model.projectFilter = .archived
    #expect(model.filterTitle == "Archived")
  }

  @Test func macSectionsKeepAnEmptyManualProjectSoItCanBeRenamedOrDeleted() async throws {
    let model = try await ListFixture.model()
    #expect(model.sidebarSections.map(\.title) == ["b4app", "Marketing site", "Docs", "Other"])
    #expect(model.sidebarSections.first { $0.id == ListFixture.docs }?.threads.isEmpty == true)
    // A search narrows the list; it does not pad it with empty projects.
    model.searchText = "pricing"
    #expect(model.sidebarSections.map(\.title) == ["Marketing site"])
  }

  @Test func flatRowsShowTheProjectNameOnlyWhenAsked() async throws {
    let model = try await ListFixture.model()
    let thread = try #require(model.threads.first { $0.id == "asks" })
    #expect(model.projectName(for: thread) == "b4app")
    let loose = try #require(model.threads.first { $0.id == "loose" })
    #expect(model.projectName(for: loose) == nil)
  }

  @Test func markAsUnreadIsOfferedOnlyForAReadReply() async throws {
    let model = try await ListFixture.model()
    func offered(_ id: String) -> Bool { model.canMarkUnread(model.threads.first { $0.id == id }!) }
    #expect(offered("quiet"))
    #expect(!offered("unread"))
    #expect(!offered("asks"))
    #expect(!offered("busy"))
  }

  @Test func newThreadNamesTheProjectOfTheChosenFolder() async throws {
    let model = try await ListFixture.model()
    #expect(
      NewThreadProject.describe(directory: "/Users/brian/repos/b4app/", projects: model.projects)
        == .joins("b4app"))
    #expect(
      NewThreadProject.describe(directory: "/Users/brian/repos/other", projects: model.projects)
        == .newProject)
    #expect(NewThreadProject.describe(directory: "", projects: model.projects) == .newProject)
  }

  @Test func diagnosticsWordsTheUploadCounts() {
    #expect(DiagnosticsView.uploads(0, "refused") == "None")
    #expect(DiagnosticsView.uploads(1, "waiting to upload") == "1 change waiting to upload")
    #expect(DiagnosticsView.uploads(2, "refused") == "2 changes refused")
  }
}
