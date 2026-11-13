#if os(macOS)
  import AppKit
  import Foundation
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// Which rows the Mac's sidebar draws tight under Dense, pinned by measuring the real list: the same
  /// model's `ThreadListView` at normal and at dense, its fitting height compared. Each tight row is
  /// `threadRow - threadRowTiny` (8 pt) shorter; any other row keeps its height.
  @Suite(.serialized) @MainActor struct ThreadListHeightTests {
    private static let shrink = LLA.Metrics.threadRow - LLA.Metrics.threadRowTiny

    private static func quiet(_ id: String, at minute: Int, environment: String? = nil) -> ConversationThread
    {
      ListFixture.thread(
        id, "Quiet \(id)", environment: environment, turn: "t-\(id)", status: .terminal, outcome: .completed,
        read: "t-\(id)", at: minute)
    }

    private static func working(_ id: String, at minute: Int) -> ConversationThread {
      ListFixture.thread(id, "Working \(id)", environment: nil, turn: "t-\(id)", status: .running, at: minute)
    }

    /// One of each top-list state: approve, reply, failed, finished.
    private static let topList: [ConversationThread] = [
      ListFixture.approving,
      ListFixture.thread(
        "reply", "Reply", environment: nil, turn: "t-r", status: .waitingForUser, pending: 1, at: 50),
      ListFixture.thread(
        "failed", "Failed", environment: nil, turn: "t-f", status: .terminal, outcome: .failed, at: 49),
      ListFixture.thread(
        "finished", "Finished", environment: nil, turn: "t-d", status: .terminal, outcome: .completed, at: 48),
    ]

    private static func archived(_ id: String, at minute: Int) -> ConversationThread {
      var thread = quiet(id, at: minute)
      thread.archived = true
      return thread
    }

    /// A connected model over `threads`, showing `settings`.
    private static func model(
      _ threads: [ConversationThread], _ settings: ViewSettings
    ) async throws -> (WorkspaceModel, ScriptedTransport) {
      let transport = ScriptedTransport()
      transport.set(
        connections: [Connection(id: "c1", kind: .codex, label: "Codex", target: "codex", status: .ready)],
        threads: threads, environments: ListFixture.environments)
      let model = WorkspaceModel(transportProvider: { transport })
      let now = Date(timeIntervalSince1970: ListFixture.base + 60 * 60)
      model.now = { now }
      model.connect()
      let link = await model.settledLink()
      try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
      try await show(settings, model, transport)
      return (model, transport)
    }

    private static func show(
      _ settings: ViewSettings, _ model: WorkspaceModel, _ transport: ScriptedTransport
    ) async throws {
      transport.emit(try .viewSettingsChanged(settings))
      try await waitUntil("\(settings)") { model.viewSettings == settings }
    }

    /// The list's fitting height at the sidebar's width.
    private static func height(_ model: WorkspaceModel, open: Bool) -> CGFloat {
      let host = NSHostingView(
        rootView: ThreadListView(model: model, showsStowed: .constant(open))
          .padding(.horizontal, ThreadRow.sidebarPadding)
          .frame(width: LLA.Metrics.sidebarWidth))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    /// The heights at normal and at dense, for the same model and the same other settings.
    private static func heights(
      _ threads: [ConversationThread], _ settings: ViewSettings, open: Bool = false,
      selected: String? = nil
    ) async throws -> (normal: CGFloat, dense: CGFloat) {
      var settings = settings
      settings.density = .normal
      let (model, transport) = try await model(threads, settings)
      model.selectedThreadId = selected
      let normal = height(model, open: open)
      settings.density = .dense
      try await show(settings, model, transport)
      #expect(model.tightQuietRows)
      let dense = height(model, open: open)
      await model.disconnect()
      return (normal, dense)
    }

    @Test func shownDrawsEveryQuietRowTight() async throws {
      let threads = (0..<5).map { Self.quiet("q\($0)", at: 10 + $0) }
      let (normal, dense) = try await Self.heights(threads, ViewSettings())
      #expect(normal > 0)
      #expect(normal - dense == 5 * Self.shrink)
    }

    @Test func collapsedOpenedDrawsTheStowedAndTheSelectedRowsTightButNotItsOwnRow() async throws {
      let threads = (0..<4).map { Self.quiet("q\($0)", at: 10 + $0) } + [Self.working("w", at: 30)]
      let (normal, dense) = try await Self.heights(
        threads, ViewSettings(quietThreads: .collapsed), open: true, selected: "q0")
      // Four stowed (three quiet, one working) and the selected row; "4 more, 1 working" keeps its height.
      #expect(normal - dense == 5 * Self.shrink)
      // Closed: only the selected row shrinks.
      let (closedNormal, closedDense) = try await Self.heights(
        threads, ViewSettings(quietThreads: .collapsed), open: false, selected: "q0")
      #expect(closedNormal - closedDense == Self.shrink)
    }

    @Test func hiddenOpenedDrawsTheWorkingRowsTight() async throws {
      let threads =
        (0..<3).map { Self.working("w\($0)", at: 30 + $0) }
        + (0..<4).map { Self.quiet("q\($0)", at: 10 + $0) }
      let (normal, dense) = try await Self.heights(threads, ViewSettings(quietThreads: .hidden), open: true)
      #expect(normal > 0)
      #expect(normal - dense == 3 * Self.shrink)
    }

    @Test func theTopListKeepsItsHeight() async throws {
      for mode in ViewSettings.QuietThreads.allCases {
        let (normal, dense) = try await Self.heights(Self.topList, ViewSettings(quietThreads: mode))
        #expect(normal > 0)
        #expect(normal == dense, "\(mode)")
      }
    }

    @Test func byEnvironmentKeepsItsHeight() async throws {
      let threads =
        (0..<3).map { Self.quiet("q\($0)", at: 10 + $0, environment: ListFixture.b4app) }
        + [Self.quiet("loose", at: 5)]
      let (normal, dense) = try await Self.heights(threads, ViewSettings(arrangement: .byEnvironment))
      #expect(normal > 0)
      #expect(normal == dense)
    }

    @Test func archivedRowsKeepTheirHeight() async throws {
      let threads =
        Self.topList + [Self.quiet("q0", at: 10), Self.quiet("q1", at: 11)]
        + (0..<3).map { Self.archived("a\($0)", at: $0) }
      let (normal, dense) = try await Self.heights(threads, ViewSettings(showArchived: true))
      // Only the two quiet rows shrink; the top list and the three archived rows do not.
      #expect(normal - dense == 2 * Self.shrink)
      let (archivedOnlyNormal, archivedOnlyDense) = try await Self.heights(
        Self.topList + (0..<3).map { Self.archived("a\($0)", at: $0) }, ViewSettings(showArchived: true))
      #expect(archivedOnlyNormal == archivedOnlyDense)
    }
  }
#endif
