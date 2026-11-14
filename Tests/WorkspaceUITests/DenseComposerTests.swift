#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing
  import WorkspaceProtocol

  @testable import WorkspaceUI

  /// The dense composer on the Mac: one muted line where the picker row was, in a thread and on the
  /// new-thread screen; the new-thread status taking the line's row while it shows. Read from hosted
  /// views through their accessibility identifiers, in a real (offscreen) window.
  @Suite(.serialized) @MainActor struct DenseComposerTests {
    private static let pickers = ["picker-place", "picker-permission", "picker-runtime"]

    private static func reply(_ settings: ViewSettings) throws -> ScriptedTransport.Reply {
      .result(try JSONValue(encoding: settings))
    }

    /// The snapshot fixture's model at `density`.
    private func listModel(
      _ density: ViewSettings.Density
    ) async throws -> (WorkspaceModel, ScriptedTransport) {
      let transport = ScriptedTransport()
      transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: density))])
      let model = try await ListFixture.model(transport)
      #expect(model.viewSettings.density == density)
      return (model, transport)
    }

    /// The Mac's model of the new-thread tests (`Phone.macModel`) at `density`.
    private func macModel(
      _ density: ViewSettings.Density, connections: [Connection] = Phone.macConnections
    ) async throws -> (WorkspaceModel, ScriptedTransport) {
      let transport = ScriptedTransport()
      transport.script(.viewSettingsGet, [try Self.reply(ViewSettings(density: density))])
      let model = try await Phone.macModel(transport, connections: connections)
      #expect(model.viewSettings.density == density)
      return (model, transport)
    }

    /// A thread's composer under the fixture's Claude thread, in the reading column.
    private func threadComposer(_ model: WorkspaceModel) throws -> HostedScreen {
      let thread = try #require(model.threads.first { $0.id == "busy" })
      let detail = ThreadDetail(thread: thread, turns: [], items: [], requests: [])
      return HostedScreen(ComposerView(model: model, detail: detail), size: CGSize(width: 720, height: 240))
    }

    private func newThread(_ model: WorkspaceModel) -> HostedScreen {
      HostedScreen(NewThreadView(model: model), size: CGSize(width: 720, height: 480))
    }

    // MARK: the setting

    @Test func denseComposerFollowsTheDensityOnTheMac() async throws {
      let (model, transport) = try await listModel(.normal)
      #expect(!model.denseComposer)
      transport.emit(try .viewSettingsChanged(ViewSettings(density: .dense)))
      try await waitUntil("dense") { model.viewSettings.density == .dense }
      #expect(model.denseComposer)
      await model.disconnect()
    }

    // MARK: in a thread

    @Test func aDenseThreadComposerDrawsTheLineAndNoPickers() async throws {
      let (model, _) = try await listModel(.dense)
      let screen = try threadComposer(model)
      defer { screen.close() }
      try await screen.until("the line") { screen.has("composer-summary") }
      for picker in Self.pickers { #expect(!screen.has(picker), "\(picker)") }
      #expect(screen.has("send"))
      #expect(screen.has("composer"))
      let thread = try #require(model.threads.first { $0.id == "busy" })
      #expect(screen.label("composer-summary") == ComposerSummary.thread(thread, in: model).spoken)
      await model.disconnect()
    }

    @Test func aNormalThreadComposerIsUnchanged() async throws {
      let (model, _) = try await listModel(.normal)
      let screen = try threadComposer(model)
      defer { screen.close() }
      try await screen.until("the pickers") { Self.pickers.allSatisfy(screen.has) }
      #expect(!screen.has("composer-summary"))
      await model.disconnect()
    }

    // MARK: on the new-thread screen

    @Test func aDenseNewThreadDrawsTheLineAndNoPickers() async throws {
      let (model, _) = try await macModel(.dense)
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the line") { screen.has("composer-summary") }
      for picker in Self.pickers { #expect(!screen.has(picker), "\(picker)") }
      #expect(screen.has("send"))
      #expect(screen.has("composer"))
      #expect(
        screen.label("composer-summary") == ComposerSummary.draft(model.newThreadDraft, in: model).spoken)
      await model.disconnect()
    }

    @Test func aNormalNewThreadIsUnchanged() async throws {
      let (model, _) = try await macModel(.normal)
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the pickers") { Self.pickers.allSatisfy(screen.has) }
      #expect(!screen.has("composer-summary"))
      await model.disconnect()
    }

    /// Text, not a control: nothing under it is a button or takes a click, and it reads as static text.
    /// The source is checked too, as the accessibility tree does not show a tap gesture.
    @Test func theLineIsNotAControl() async throws {
      let summary = ComposerSummary(place: "b4app", runtime: "Claude Code · Opus", permission: "Plan")
      let screen = HostedScreen(ComposerSummaryLine(summary: summary), size: CGSize(width: 480, height: 40))
      defer { screen.close() }
      try await screen.until("the line") { screen.has("composer-summary") }
      let line = try #require(screen.element("composer-summary"))
      #expect(line.role == .staticText)
      #expect(line.label == summary.spoken)
      #expect(line.children.isEmpty)
      #expect(line.customActions.isEmpty)
      #expect(screen.controls.isEmpty, "\(screen.controls)")
      // No NSControl (a button, a pop-up) is drawn under the line either.
      #expect(!screen.hasControlView)

      let source = try String(contentsOf: Self.source("NewThread/ComposerSummaryLine.swift"), encoding: .utf8)
      for control in ["Button", "Menu", "Gesture", "onTap", "onHover", "Toggle", "Link"] {
        #expect(!source.contains(control), "\(control)")
      }
    }

    private static func source(_ path: String, file: StaticString = #filePath) -> URL {
      URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/WorkspaceUI/\(path)")
    }

    @Test func theLineChangesWhenACommandChangesTheChoice() async throws {
      let (model, transport) = try await macModel(.dense)
      let draft = model.newThreadDraft
      draft.selectFolder("/work/atlas", in: "p1")
      draft.selectRuntime(connectionId: "codex-1", model: nil)
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the line") { screen.label("composer-summary")?.contains("Codex") == true }
      let outcome = await model.run(
        .draftRuntime, target: .draft, argument: "claude-1" + WorkspaceModel.choiceSeparator + "opus")
      #expect(outcome == .completed("Claude Code \u{00B7} Opus"))
      try await screen.until("the new runtime") {
        screen.label("composer-summary") == "Runs in Atlas \u{00B7} atlas with Claude Code, Opus"
      }
      #expect(transport.recorded(.threadStart).isEmpty)
      #expect(transport.recorded(.turnSend).isEmpty)
      await model.disconnect()
    }

    // MARK: the status takes the row

    @Test func startingTakesTheRowAndTheLineReturns() async throws {
      let (model, transport) = try await macModel(.dense)
      let draft = model.newThreadDraft
      draft.selectFolder("/work/atlas", in: "p1")
      draft.text = "Find the flaky test"
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the line") { screen.has("composer-summary") }

      transport.script(.threadStart, [.hold])
      let task = Task { await draft.send() }
      try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
      #expect(draft.submitting)
      try await screen.until("Starting…") { screen.has("new-thread-status") }
      #expect(!screen.has("composer-summary"))
      #expect(screen.label("new-thread-status")?.contains(RelayCopy.starting) == true)

      // Accepted: no status, and the line is back where it was.
      let pending = try #require(model.pendingSends.values.first { $0.state == .sending })
      var thread = PhoneFixture.thread(pending.threadId, owner: nil)
      thread.environmentId = "p1"
      thread.context = "/work/atlas"
      transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
      transport.release(.threadStart, with: Phone.started(thread, pending.id))
      await task.value
      #expect(draft.status == nil)
      try await screen.until("the line again") { screen.has("composer-summary") }
      #expect(!screen.has("new-thread-status"))
      await model.disconnect()
    }

    @Test func aFailedStartTakesTheRow() async throws {
      let (model, transport) = try await macModel(.dense)
      let draft = model.newThreadDraft
      draft.selectFolder("/work/atlas", in: "p1")
      draft.text = "Find the flaky test"
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the line") { screen.has("composer-summary") }
      transport.script(
        .threadStart, [.failure(WorkspaceError(.protocolInvalid, "That folder is not in this environment."))])
      await draft.send()
      #expect(draft.statusIsFailure)
      try await screen.until("the failure") { screen.has("new-thread-status") }
      #expect(!screen.has("composer-summary"))
      let status = try #require(draft.status)
      #expect(
        screen.label("new-thread-status")?.contains(status) == true,
        "\(screen.label("new-thread-status") ?? "")")
      #expect(!screen.has("new-thread-reason"))
      await model.disconnect()
    }

    @Test func aBlockedReasonSitsUnderTheLine() async throws {
      let (model, _) = try await macModel(.dense, connections: [])
      let draft = model.newThreadDraft
      let reason = try #require(draft.blockedReason)
      let screen = newThread(model)
      defer { screen.close() }
      try await screen.until("the line and the reason") {
        screen.has("composer-summary") && screen.has("new-thread-reason")
      }
      #expect(!screen.has("new-thread-status"))
      let line = try #require(screen.frame("composer-summary"))
      let under = try #require(screen.frame("new-thread-reason"))
      // Screen coordinates: y grows upward, so the line under has the smaller y.
      #expect(under.maxY <= line.minY + 0.5, "line \(line), reason \(under)")
      #expect(screen.label("new-thread-reason") == reason || screen.value("new-thread-reason") == reason)
      await model.disconnect()
    }

    // MARK: the line's width

    @Test func aLongPlaceIsCutAndTheRuntimeIsWhole() async throws {
      let place = String(repeating: "a-very-long-folder-name-", count: 5)
      #expect(place.count == 120)
      let summary = ComposerSummary(place: place, runtime: "Claude Code · Opus", permission: "Bypass")
      let rest = ComposerSummaryLine.rest(summary)
      #expect(rest == " · Claude Code · Opus · Bypass")

      var restWidth: CGFloat = 0
      var line = ComposerSummaryLine(summary: summary)
      line.restWidth = { restWidth = $0 }
      let host = NSHostingView(rootView: line.frame(width: 320))
      host.layoutSubtreeIfNeeded()
      let ideal = NSHostingView(rootView: Text(rest).font(LLAFont.caption).lineLimit(1)).fittingSize.width
      #expect(restWidth > 0)
      #expect(abs(restWidth - ideal) < 0.5, "drawn \(restWidth), ideal \(ideal)")

      let oneLine = NSHostingView(rootView: ComposerSummaryLine(summary: ComposerSummary(runtime: "Codex")))
        .fittingSize.height
      #expect(host.fittingSize.height == oneLine)
    }
  }

  // MARK: - Reading a hosted screen

  /// A view in an offscreen window (`SnapshotWindow`), read through the accessibility tree SwiftUI builds
  /// for it: the elements by identifier, their labels, frames and roles. SwiftUI builds the tree only for
  /// an app an assistive client has asked about, so the app is marked as one first.
  @MainActor final class HostedScreen {
    private let window: SnapshotWindow<AnyView>

    init<V: View>(_ view: V, size: CGSize) {
      NSApplication.shared.accessibilitySetValue(
        true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
      window = SnapshotWindow(
        rootView: AnyView(view.frame(width: size.width, height: size.height)), untitled: true, size: size)
      window.host.layoutSubtreeIfNeeded()
    }

    func close() { window.close() }

    /// Whether any AppKit control is drawn in the window's views.
    var hasControlView: Bool {
      func any(_ view: NSView) -> Bool { view is NSControl || view.subviews.contains(where: any) }
      return any(window.host)
    }

    /// One element of the tree. SwiftUI's nodes answer the accessibility methods without declaring the
    /// protocol in Swift, so they are called through `AnyObject`.
    struct Element {
      let object: AnyObject
      var role: NSAccessibility.Role? { object.accessibilityRole?() ?? nil }
      var identifier: String? { object.accessibilityIdentifier?() }
      /// What VoiceOver reads: SwiftUI gives static text its words as the value, a control as its label.
      var label: String? {
        if let label = object.accessibilityLabel?() ?? nil, !label.isEmpty { return label }
        if let title = object.accessibilityTitle?() ?? nil, !title.isEmpty { return title }
        return value
      }
      var value: String? {
        let read: (() -> Any?)? = object.accessibilityValue
        return read?() as? String
      }
      var frame: CGRect? { object.accessibilityFrame?() }
      var children: [Element] {
        ((object.accessibilityChildren?() ?? nil) ?? []).map { Element(object: $0 as AnyObject) }
      }
      var customActions: [NSAccessibilityCustomAction] { (object.accessibilityCustomActions?() ?? nil) ?? [] }
    }

    /// Every element under the hosting view, depth first.
    var elements: [Element] {
      var found: [Element] = []
      func walk(_ element: Element) {
        found.append(element)
        element.children.forEach(walk)
      }
      walk(Element(object: window.host))
      return found
    }

    func element(_ id: String) -> Element? { elements.first { $0.identifier == id } }
    func has(_ id: String) -> Bool { element(id) != nil }
    func label(_ id: String) -> String? { element(id)?.label }
    func value(_ id: String) -> String? { element(id)?.value }
    func frame(_ id: String) -> CGRect? { element(id)?.frame }

    /// The roles of the elements that are buttons, menus or other controls.
    var controls: [NSAccessibility.Role] {
      let roles: Set<NSAccessibility.Role> = [
        .button, .menuButton, .popUpButton, .checkBox, .radioButton, .link, .menu, .menuItem, .slider,
      ]
      return elements.compactMap(\.role).filter(roles.contains)
    }

    /// Returns once `condition` holds after a layout pass. The timeout only ends a test that would
    /// otherwise hang.
    func until(_ what: String, _ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(60)
      while true {
        window.host.layoutSubtreeIfNeeded()
        if condition() { return }
        guard ContinuousClock.now < deadline else {
          throw WorkspaceError(.internalError, "timed out waiting for \(what)")
        }
        turnRunLoop()
        await Task.yield()
      }
    }

    /// Synchronous by design: `RunLoop.run` is unavailable from async code.
    private func turnRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
  }
#endif
