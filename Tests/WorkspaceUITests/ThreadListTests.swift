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
    // A connection filter narrows the list; it does not pad it with empty projects.
    model.connectionFilter = "c2"
    #expect(model.sidebarSections.map(\.title) == ["Marketing site"])
  }

  @Test func projectNameIsTheDisplayNameAndNilForOther() async throws {
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

  @Test func rowSpeaksItsReasonAndConnection() async throws {
    // The row shows only the title and a runtime mark; why it sits there and where it runs are spoken
    // in its label (not a hint, which VoiceOver users can turn off), and a pinned row says so.
    let model = try await ListFixture.model()
    let asks = try #require(model.threads.first { $0.id == "asks" })
    let label = try #require(model.connection(id: asks.connectionId)?.label)
    #expect(model.band(of: asks) == .needsInput)
    #expect(
      ThreadRow.accessibilityLabel(model: model, thread: asks)
        == "\(asks.title), \(model.reasonLine(for: asks)), \(label)")
    var pinned = asks
    pinned.pinned = true
    #expect(ThreadRow.accessibilityLabel(model: model, thread: pinned).hasPrefix("Pinned, \(asks.title), "))
    var untitled = asks
    untitled.title = ""
    #expect(ThreadRow.accessibilityLabel(model: model, thread: untitled).hasPrefix("Untitled, "))
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

  @Test func onlyAWorkingDotPulsesAndReduceMotionStopsIt() {
    for band in [AttentionBand.needsInput, .unread, .quiet] {
      #expect(!AttentionDot.pulses(band: band, reduceMotion: false))
    }
    #expect(AttentionDot.pulses(band: .working, reduceMotion: false))
    #expect(!AttentionDot.pulses(band: .working, reduceMotion: true))
  }

  @Test func theWorkingRingStaysAsDarkAsTheQuietRingAtItsPaleSidePhase() {
    // Ink at the pulse floor over the page background versus the muted quiet ring, light and dark.
    func blend(_ ink: UInt32, over bg: UInt32) -> Double {
      let f = AttentionDot.pulseFloor
      func channel(_ shift: UInt32) -> Double {
        Double((ink >> shift) & 0xFF) * f + Double((bg >> shift) & 0xFF) * (1 - f)
      }
      return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
    func lum(_ hex: UInt32) -> Double {
      0.2126 * Double((hex >> 16) & 0xFF) + 0.7152 * Double((hex >> 8) & 0xFF) + 0.0722 * Double(hex & 0xFF)
    }
    let light = LLA.Palette.self
    // Light: a paler ring has higher luminance; allow a few levels of slack for the thicker stroke.
    #expect(blend(light.ink.light, over: light.surface.light) <= lum(light.muted.light) + 12)
    // Dark: a paler ring has lower luminance.
    #expect(blend(light.ink.dark, over: light.surface.dark) >= lum(light.muted.dark) - 12)
  }

  @Test func aListFailureShowsInTheSidebarUnlessTheDetailAlreadyShowsIt() async throws {
    let model = try await ListFixture.model()
    #expect(model.sidebarError() == nil)  // no error, no banner
    model.lastError = "That folder already belongs to another project."

    model.selectedThreadId = nil
    #expect(model.sidebarError() == "That folder already belongs to another project.")

    // An open thread shows it in the composer, so the list does not repeat it...
    model.selectedThreadId = "asks"
    #expect(model.sidebarError() == nil)
    // ...unless the detail is not on screen (the iPhone's single column).
    #expect(model.sidebarError(detailVisible: false) != nil)
    // A selection that no longer exists shows nothing in the detail.
    model.selectedThreadId = "gone"
    #expect(model.sidebarError() != nil)

    model.lastError = nil
    #expect(model.sidebarError(detailVisible: false) == nil)
  }
}
