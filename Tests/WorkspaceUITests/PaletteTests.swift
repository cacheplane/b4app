import Foundation
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

private func thread(
  _ id: String, _ title: String, minute: Int, connection: String = "claude", environment: String? = nil,
  archived: Bool = false, pending: Int = 0, approvals: Int = 0, status: TurnStatus = .terminal,
  outcome: TurnOutcome? = nil, read: Bool = true, model: String? = nil
) -> ConversationThread {
  let at = String(format: "2026-11-01T10:%02d:00Z", minute)
  return ConversationThread(
    id: id, connectionId: connection, nativeThreadId: "n-\(id)", title: title, archived: archived,
    createdAt: at, updatedAt: at, environmentId: environment, readTurnId: read ? "u-\(id)" : nil,
    activity: ThreadActivity(
      latestTurnId: "u-\(id)", latestTurnStatus: status, latestTurnOutcome: outcome,
      pendingRequests: pending, pendingApprovals: approvals, lastActivityAt: at),
    model: model)
}

private let claude = Connection(
  id: "claude", kind: .claude, label: "Claude Code", target: "/bin/claude",
  models: RuntimeOptions.claudeModels, status: .ready)
private let codex = Connection(
  id: "codex", kind: .codex, label: "Codex", target: "/bin/codex", status: .ready)
private let b4app = WorkEnvironment(
  id: "e1", name: "b4app", folders: [EnvironmentFolder(id: "f1", environmentId: "e1", path: "/r/b4app")])
private let hub = WorkEnvironment(
  id: "e2", name: "hub-infra", folders: [EnvironmentFolder(id: "f2", environmentId: "e2", path: "/r/hub")])

private let fixtureThreads = [
  thread("quiet", "Relay reconnect backoff", minute: 9, environment: "e1", model: "sonnet"),
  thread(
    "approve", "Release notes draft", minute: 1, connection: "codex", environment: "e1", pending: 1,
    approvals: 1),
  thread(
    "failed", "Hub migration dry run", minute: 2, connection: "codex", environment: "e2", outcome: .failed),
  thread("dup1", "Pricing page research", minute: 5, environment: "e1", status: .running),
  thread("dup2", "Pricing page research", minute: 4, connection: "codex"),
  thread("gone", "Pricing research, first pass", minute: 8, archived: true),
]

private func updated(_ thread: ConversationThread) throws -> AdapterEvent {
  AdapterEvent(
    kind: .threadUpdated, connectionId: thread.connectionId, threadId: thread.id,
    payload: ["thread": try JSONValue(encoding: thread)])
}

@MainActor
private func connected(
  threads: [ConversationThread] = fixtureThreads, transport: ScriptedTransport = ScriptedTransport(),
  claudeCommands: [RuntimeCommand]? = nil
) async throws -> (WorkspaceModel, ScriptedTransport) {
  var claude = claude
  claude.commands = claudeCommands
  transport.set(connections: [claude, codex], threads: threads, environments: [b4app, hub])
  for thread in threads {
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
  }
  let model = WorkspaceModel(transportProvider: { transport })
  model.draftSaveDelay = .seconds(30)
  model.connect()
  try #require(await model.settledLink() == .ready)
  return (model, transport)
}

/// One turn of the run loop, for a view drawn in a test's own window.
@MainActor private func pumpRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

@Suite struct FuzzyMatchTests {
  private func score(_ query: String, _ title: String, also: [String] = []) -> Int? {
    FuzzyMatch.match(
      FuzzyMatch.terms(query), title: FuzzyMatch.Text(title), also: also.map(FuzzyMatch.Text.init))?.score
  }

  @Test func plainerMatchesRankHigher() throws {
    let exact = try #require(score("archive", "Archive"))
    let prefix = try #require(score("arch", "Archive"))
    let word = try #require(score("notes", "Release notes draft"))
    let inside = try #require(score("lease", "Release notes draft"))
    let scattered = try #require(score("rnd", "Release notes draft"))
    #expect(exact > prefix && prefix > word && word > inside && inside > scattered)
  }

  @Test func everyTermMustBeFoundAndCaseAndAccentsAreIgnored() {
    #expect(score("PRICING page", "Pricing page research") != nil)
    #expect(score("pricing zebra", "Pricing page research") == nil)
    #expect(score("resume", "Résumé review") != nil)
  }

  @Test func scatteredLettersMustStartAWordAndStayClose() {
    // "rnd" starts at "Release"; "eao" would start inside a word.
    #expect(score("eao", "Release notes draft") == nil)
    #expect(score("rd", "Release a very long title that ends") == nil)
    #expect(score("x", "Release") == nil)
  }

  @Test func aliasesCountWholeAndSecondaryWordsCountHalf() throws {
    let alias = try #require(score("unpin", "Pin", also: ["unpin"]))
    let secondary = try #require(score("hub", "APNs withdraw ledger", also: ["hub-infra"]))
    #expect(alias == FuzzyMatch.Score.exact)
    #expect(secondary == FuzzyMatch.Score.prefix / 2)
  }

  @Test func matchedRunsFollowTheOriginalText() {
    let hit = FuzzyMatch.match(FuzzyMatch.terms("pri res"), title: FuzzyMatch.Text("Pricing page research"))
    let runs = FuzzyMatch.runs(of: "Pricing page research", matched: hit?.positions ?? [])
    #expect(runs.map(\.text) == ["Pri", "cing page ", "res", "earch"])
    #expect(runs.map(\.matched) == [true, false, true, false])
  }
}

@Suite @MainActor struct CommandCatalogTests {
  @Test func identifiersShortcutsAndSlashNamesAreUnambiguous() {
    let all = CommandCatalog.all
    #expect(Set(all.map(\.id)).count == all.count)
    let shortcuts = all.compactMap(\.shortcutLabel)
    #expect(Set(shortcuts).count == shortcuts.count)
    #expect(CommandCatalog.definition(.find).shortcut == KeyboardShortcut("k"))
    #expect(
      CommandCatalog.definition(.commands).shortcut == KeyboardShortcut("p", modifiers: [.command, .shift]))
    #expect(CommandCatalog.definition(.newThread).shortcut == KeyboardShortcut("n"))
    // A slash name may repeat only across targets that are never offered together (thread and draft).
    for target in [["thread."], ["draft."]] {
      let names = all.filter { id in target.contains { id.id.rawValue.hasPrefix($0) } }.compactMap(\.slash)
      #expect(Set(names).count == names.count)
    }
  }

  @Test func aThreadsCommandsFollowItsRuntimeAndState() async throws {
    let (model, _) = try await connected()
    let claudeThread = model.commands(for: .thread("quiet"))
    #expect(claudeThread.contains(.threadModel) && claudeThread.contains(.threadPermission))
    #expect(!claudeThread.contains(.threadStop) && !claudeThread.contains(.threadAbandon))
    #expect(model.title(of: .threadOpen, target: .thread("approve")) == "Review request")
    #expect(model.title(of: .threadOpen, target: .thread("quiet")) == "Open thread")
    #expect(model.currentValue(of: .threadModel, target: .thread("quiet")) == "Sonnet")
    #expect(model.availability(of: .threadMarkUnread, target: .thread("quiet")) == .available)
    #expect(model.availability(of: .threadMarkUnread, target: .thread("approve")).reason != nil)
    #expect(model.availability(of: .threadPin, target: .thread("nope")).reason != nil)
    await model.disconnect()
  }

  @Test func modelChoicesAreTheComposerPickersOwn() async throws {
    let (model, _) = try await connected()
    let choices = model.choices(for: .threadModel, target: .thread("quiet"))
    let picker = PickerMenus.models(claude, chosen: "sonnet", isChosenConnection: true, forThread: true)
    #expect(choices.map(\.title) == picker.map(\.title))
    #expect(choices.first { $0.isCurrent }?.title == "Sonnet")
    #expect(model.effectNote(of: .threadModel, target: .thread("quiet")) == "Applies from the next turn")
    await model.disconnect()
  }

  @Test func aCommandIsCheckedAgainWhenItRuns() async throws {
    let (model, transport) = try await connected()
    // The account changed while the palette was open.
    #expect(
      await model.run(.threadPin, target: .thread("quiet"), generation: -1)
        == .failed("The account changed. Nothing was done."))
    // The thread went away.
    #expect(await model.run(.threadPin, target: .thread("nope")) == .failed("This thread is no longer here."))
    #expect(transport.calls(.threadUpdate).isEmpty)
    // A refusal is a failure, and what the coordinator said is kept.
    transport.script(.threadUpdate, [.failure(WorkspaceError(.internalError, "disk full"))])
    #expect(await model.run(.threadPin, target: .thread("quiet")) == .failed("disk full"))
    // An answer applies at once.
    var pinned = fixtureThreads[0]
    pinned.pinned = true
    transport.script(.threadUpdate, [.result(try JSONValue(encoding: ThreadCreate.Result(thread: pinned)))])
    #expect(await model.run(.threadPin, target: .thread("quiet")) == .completed("Pinned"))
    #expect(model.thread(id: "quiet")?.pinned == true)
    #expect(model.title(of: .threadPin, target: .thread("quiet")) == "Unpin")
    await model.disconnect()
  }
}

@Suite @MainActor struct PaletteModelTests {
  @Test func emptyFindLeadsWithWhatNeedsTheOwner() async throws {
    let (model, _) = try await connected()
    let palette = PaletteModel(workspace: model, purpose: .find)
    let sections = palette.sections
    #expect(sections.map(\.title) == ["Needs you", "Recent", "Suggested"])
    #expect(sections[0].items.map(\.title) == ["Release notes draft", "Hub migration dry run"])
    #expect(sections[0].items[0].primary == "Review request")
    #expect(sections[2].items.map(\.title) == ["New thread", "Commands"])
    // Archived threads are not suggested.
    #expect(!palette.items.contains { $0.title.hasPrefix("Pricing research") })
    await model.disconnect()
  }

  @Test func typedRelevanceBeatsAttentionAndDuplicatesAreToldApart() async throws {
    let (model, _) = try await connected()
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("pricing")
    let threads = palette.items.filter { if case .thread = $0.kind { true } else { false } }
    // The two live duplicates first (the working one leads by attention), the archived match last.
    #expect(threads.map(\.id) == ["thread:dup1", "thread:dup2", "thread:gone"])
    #expect(threads[0].secondary == "b4app \u{00B7} Claude Code")
    #expect(threads[1].secondary == "No folder \u{00B7} Codex")
    #expect(threads[2].trailing == "Archived")
    // A title that matches outranks the thread that needs approval but only matches by environment.
    palette.setQuery("relay")
    #expect(palette.items.first?.id == "thread:quiet")
    palette.setQuery("hub")
    #expect(palette.items.first?.title == "Hub migration dry run")
    #expect(palette.items.contains { $0.kind == .command(.environmentNewThread, .environment("e2")) })
    await model.disconnect()
  }

  @Test func theSelectionIsKeptByIdentityWhileTheListChanges() async throws {
    let (model, transport) = try await connected()
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("pricing")
    palette.move(by: 1)
    #expect(palette.selected?.id == "thread:dup2")
    // Background activity reorders the matches: the other duplicate finishes and needs a read.
    var finished = fixtureThreads[3]
    finished.activity?.latestTurnStatus = .terminal
    finished.readTurnId = nil
    transport.emit(try updated(finished))
    try await waitUntil("the update") { model.state(of: model.thread(id: "dup1")!) == .finished }
    #expect(palette.selected?.id == "thread:dup2")
    // The selected thread is deleted elsewhere: the selection falls to the first row, never to nothing.
    var deleted = fixtureThreads[4]
    deleted.userDeletedAt = "2026-11-01T11:00:00Z"
    transport.emit(try updated(deleted))
    try await waitUntil("the delete") { model.thread(id: "dup2") == nil }
    #expect(palette.selected?.id == "thread:dup1")
    await model.disconnect()
  }

  @Test func aLeadingAngleOrSlashEntersCommandsAndBackspaceLeaves() async throws {
    let (model, _) = try await connected()
    for prefix in [">", "/"] {
      let palette = PaletteModel(workspace: model, purpose: .find)
      palette.setQuery(prefix)
      #expect(palette.page == .root(.commands))
      #expect(palette.query.isEmpty)
      #expect(palette.crumbs == ["Commands"])
      #expect(palette.deleteBackward())
      #expect(palette.page == .root(.find))
    }
    // Anywhere but first, the characters are text.
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("a/b")
    #expect(palette.page == .root(.find))
    #expect(palette.query == "a/b")
    await model.disconnect()
  }

  @Test func actionsAndArgumentsStackAndEscapeUnwindsOneLevel() async throws {
    let (model, _) = try await connected()
    model.selectedThreadId = "quiet"
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("relay")
    palette.showActions()
    #expect(palette.page == .actions(.thread("quiet")))
    #expect(palette.crumbs == ["Relay reconnect backoff"])
    palette.setQuery("model")
    #expect(palette.selected?.title == "Choose model\u{2026}")
    #expect(palette.selected?.trailing == "Sonnet")
    #expect(palette.primaryLabel == "Choose model")
    await palette.activate()
    #expect(palette.page == .choices(.threadModel, .thread("quiet")))
    #expect(palette.crumbs == ["Relay reconnect backoff", "Model"])
    #expect(palette.context == "Applies from the next turn")
    #expect(palette.back())
    // The level below kept its own text and selection.
    #expect(palette.query == "model")
    #expect(palette.back())
    #expect(palette.query == "relay")
    #expect(!palette.back())
    await model.disconnect()
  }

  @Test func aFailureKeepsThePageTheTextAndTheSelection() async throws {
    let (model, transport) = try await connected()
    let palette = PaletteModel(workspace: model, purpose: .find)
    var finished: [String] = []
    palette.onFinish = { finished.append($0) }
    palette.setQuery("relay")
    palette.showActions()
    palette.setQuery("rename")
    await palette.activate()
    #expect(palette.page == .text(.threadRename, .thread("quiet")))
    #expect(palette.query == "Relay reconnect backoff")
    palette.setQuery("Relay backoff honours Retry-After")
    transport.script(.threadUpdate, [.failure(WorkspaceError(.internalError, "not saved"))])
    await palette.activate()
    #expect(palette.feedback == .failed("not saved"))
    #expect(palette.primaryLabel == "Try again")
    #expect(palette.query == "Relay backoff honours Retry-After")
    #expect(finished.isEmpty)
    // The second try goes through: the palette finishes and the title is the new one.
    var renamed = fixtureThreads[0]
    renamed.title = "Relay backoff honours Retry-After"
    transport.script(.threadUpdate, [.result(try JSONValue(encoding: ThreadCreate.Result(thread: renamed)))])
    await palette.activate()
    #expect(finished == ["Renamed"])
    #expect(transport.calls(.threadUpdate).last?["title"]?.stringValue == "Relay backoff honours Retry-After")
    await model.disconnect()
  }

  @Test func anUnavailableRowStaysListedSaysWhyAndDoesNothing() async throws {
    let (model, transport) = try await connected()
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("release")
    palette.showActions()
    palette.setQuery("unread")
    #expect(palette.selected?.isAvailable == false)
    #expect(palette.context == "Only a reply you have read can be marked unread.")
    #expect(!palette.primaryEnabled)
    await palette.activate()
    #expect(transport.calls(.threadMarkRead).isEmpty)
    await model.disconnect()
  }

  @Test func aDraftSurvivesThePaletteAndUseAsMessageNeverOverwritesOne() async throws {
    let (model, _) = try await connected()
    await model.openThread(id: "quiet")
    model.composerText = "line one\nline two"
    model.presentPalette(.find)
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("why does the widget show a stale badge")
    let message = try #require(palette.items.last)
    #expect(message.kind == .command(.useAsMessage, .workspace))
    #expect(message.availability.reason == "There is already a draft here. It is never overwritten.")
    await palette.activate()
    model.dismissPalette()
    #expect(model.composerText == "line one\nline two")
    #expect(!model.showSearch)
    // With no draft, the text moves and nothing is sent.
    model.composerText = ""
    let empty = PaletteModel(workspace: model, purpose: .find)
    var spoken: [String] = []
    empty.onFinish = { spoken.append($0) }
    empty.setQuery("why does the widget show a stale badge")
    empty.select(try #require(empty.items.last).id)
    await empty.activate()
    #expect(model.composerText == "why does the widget show a stale badge")
    #expect(spoken == ["Moved to the draft. Nothing was sent."])
    await model.disconnect()
  }

  @Test func closingThePaletteAsksForTheCursorBackWhereWritingHappens() async throws {
    let (model, _) = try await connected()
    #if os(macOS)
      let newThread = model.newThreadFocusRequest
      model.presentPalette(.commands)
      model.dismissPalette()
      #expect(model.newThreadFocusRequest == newThread + 1)
      model.selectedThreadId = "quiet"
      let composer = model.composerFocusRequest
      model.presentPalette(.find)
      model.dismissPalette()
      #expect(model.composerFocusRequest == composer + 1)
    #endif
    await model.disconnect()
  }

  /// Local filtering on a large workspace. The product's budget is 50 ms; run alone, a debug build
  /// is inside it. The bound here is twice that, because beside the whole package's suites on a
  /// loaded machine the best try has measured 55 to 65 ms, and a test that fails by load teaches nothing.
  @Test func filteringALargeWorkspaceIsFast() async throws {
    let words = ["relay", "pricing", "migration", "sidebar", "passkey", "widget", "ledger", "release"]
    let many = (0..<3000).map { n in
      thread(
        "t\(n)", "\(words[n % words.count].capitalized) \(words[(n / 8) % words.count]) number \(n)",
        minute: n % 60, environment: n % 2 == 0 ? "e1" : "e2")
    }
    let (model, _) = try await connected(threads: many)
    let palette = PaletteModel(workspace: model, purpose: .find)
    palette.setQuery("p")
    _ = palette.items  // builds the index once, as opening the palette does
    let clock = ContinuousClock()
    var slowest = Duration.zero
    for query in ["pr", "pri", "pric led", "migration 29", "zzz"] {
      // The best of several tries, stopping at the first inside the budget, so the suites running
      // beside this one (the whole package, on a loaded machine) do not decide the result.
      var best = Duration.seconds(1)
      for _ in 0..<25 where best >= .milliseconds(50) {
        palette.setQuery("")
        palette.setQuery(query)
        best = min(best, clock.measure { _ = palette.items })
      }
      slowest = max(slowest, best)
    }
    #expect(slowest < .milliseconds(100), "slowest keystroke took \(slowest)")
    await model.disconnect()
  }
}

@Suite @MainActor struct SlashControllerTests {
  @Test func onlyASlashTypedIntoAnEmptyDraftOpensCompletions() async throws {
    let (model, _) = try await connected()
    let slash = SlashController(workspace: model, target: .thread("quiet"))
    // Pasted text that starts with a slash is a message.
    slash.textChanged(from: "", to: "/usr/local/bin/codex")
    #expect(!slash.isShowing)
    slash.textChanged(from: "", to: "/model")
    #expect(!slash.isShowing)
    // A slash typed after other text is a message.
    slash.textChanged(from: "see ", to: "see /")
    #expect(!slash.isShowing)
    // Typed first into an empty draft, it lists this thread's commands.
    slash.textChanged(from: "", to: "/")
    #expect(slash.isShowing)
    #expect(
      slash.items.compactMap(\.command) == ["/model", "/permissions", "/pin", "/archive", "/unread", "/new"])
    slash.textChanged(from: "/", to: "/pe")
    #expect(slash.items.compactMap(\.command) == ["/permissions"])
    #expect(slash.selected?.primary == "Choose permissions")
    // An alias reaches it too.
    slash.textChanged(from: "/pe", to: "/mode")
    #expect(slash.items.compactMap(\.command) == ["/model", "/permissions"])
    // A token nothing answers to shows nothing: Return sends it as text.
    slash.textChanged(from: "/mode", to: "/modex")
    #expect(!slash.isShowing)
    // Leaving the token closes; coming back by deleting does not reopen on a path.
    slash.textChanged(from: "/modex", to: "/mode x")
    #expect(slash.state == .closed)
    await model.disconnect()
  }

  @Test func pickingASettingListsItsValuesAndEscapeStepsBack() async throws {
    let (model, transport) = try await connected()
    let slash = SlashController(workspace: model, target: .thread("quiet"))
    slash.textChanged(from: "", to: "/")
    slash.textChanged(from: "/", to: "/mo")
    // The token leaves the draft; the values list in its place.
    #expect(await slash.choose() == .text(""))
    slash.textChanged(from: "/mo", to: "")
    #expect(slash.state == .choices(.threadModel))
    #expect(slash.items.map(\.title) == ["Opus", "Sonnet", "Haiku"])
    #expect(slash.items.first { $0.isCurrent }?.title == "Sonnet")
    #expect(slash.context == "Applies from the next turn")
    // Escape puts the slash back and lists the commands again; a second Escape closes.
    #expect(slash.dismiss() == "/")
    #expect(slash.state == .commands)
    #expect(slash.dismiss() == nil)
    #expect(slash.state == .closed)
    // Choosing a value is the composer picker's own call.
    slash.textChanged(from: "", to: "/")
    slash.textChanged(from: "/", to: "/model")
    _ = await slash.choose()
    slash.textChanged(from: "/model", to: "")
    var changed = fixtureThreads[0]
    changed.model = "opus"
    transport.script(.threadUpdate, [.result(try JSONValue(encoding: ThreadCreate.Result(thread: changed)))])
    _ = await slash.choose()
    #expect(transport.calls(.threadUpdate).last?["model"]?.stringValue == "opus")
    #expect(slash.state == .closed)
    #expect(model.thread(id: "quiet")?.model == "opus")
    await model.disconnect()
  }

  @Test func aDraftsCommandsAreItsOwn() async throws {
    let (model, _) = try await connected()
    let slash = SlashController(workspace: model, target: .draft)
    slash.textChanged(from: "", to: "/")
    #expect(slash.items.compactMap(\.command) == ["/environment", "/model", "/permissions"])
    slash.textChanged(from: "/", to: "/env")
    _ = await slash.choose()
    slash.textChanged(from: "/env", to: "")
    #expect(slash.items.map(\.title) == ["b4app", "hub-infra", "No folder"])
    slash.select("choice:")
    _ = await slash.choose()
    #expect(model.newThreadDraft.isNoFolder)
    await model.disconnect()
  }

  // MARK: Runtime commands

  private static let reported = [
    RuntimeCommand(name: "context", description: "Show what is using the context window"),
    RuntimeCommand(
      name: "compact", description: "Summarize the conversation", argumentHint: "[instructions]"),
    RuntimeCommand(
      name: "superpowers:brainstorming", description: "Work out what to build", aliases: ["brainstorming"]),
    // The app has its own /model; the runtime's never shadows it.
    RuntimeCommand(name: "model", description: "Claude Code's own model command"),
  ]

  @Test func aRuntimesCommandsFollowTheAppsOnItsOwnThreads() async throws {
    let (model, _) = try await connected(claudeCommands: Self.reported)
    let slash = SlashController(workspace: model, target: .thread("quiet"))
    slash.textChanged(from: "", to: "/")
    #expect(
      slash.items.compactMap(\.command) == [
        "/model", "/permissions", "/pin", "/archive", "/unread", "/new", "/context", "/compact",
        "/superpowers:brainstorming",
      ])
    // A name that starts with the token, then a plugin's command by its own name or its alias.
    slash.textChanged(from: "/", to: "/co")
    #expect(slash.items.compactMap(\.command) == ["/context", "/compact"])
    #expect(slash.selected?.primary == "Run /context")
    #expect(slash.context == "Claude Code runs it as a message")
    slash.textChanged(from: "/co", to: "/brain")
    #expect(slash.items.compactMap(\.command) == ["/superpowers:brainstorming"])
    // A Codex thread lists none of Claude Code's.
    let other = SlashController(workspace: model, target: .thread("approve"))
    other.textChanged(from: "", to: "/")
    #expect(!other.items.contains { $0.isRuntime })
    await model.disconnect()
  }

  @Test func aRuntimeCommandIsSentOrCompletedNeverRunByTheApp() async throws {
    let (model, transport) = try await connected(claudeCommands: Self.reported)
    let slash = SlashController(workspace: model, target: .thread("quiet"))
    // One that takes nothing more is the message.
    slash.textChanged(from: "", to: "/")
    slash.textChanged(from: "/", to: "/cont")
    #expect(await slash.choose() == .send("/context"))
    #expect(slash.state == .closed)
    // One that takes more is completed in the draft, and the rest is typed there.
    slash.textChanged(from: "", to: "/")
    slash.textChanged(from: "/", to: "/comp")
    #expect(slash.selected?.primary == "Add to message")
    #expect(await slash.choose() == .text("/compact "))
    slash.textChanged(from: "/comp", to: "/compact ")
    #expect(!slash.isShowing)
    // Nothing reached the coordinator: the composer sends, as it sends any message.
    #expect(transport.calls(.turnSend).isEmpty)
    await model.disconnect()
  }

  @Test func thePaletteListsARuntimesCommandsAndOnlyDraftsThem() async throws {
    let (model, transport) = try await connected(claudeCommands: Self.reported)
    await model.openThread(id: "quiet")
    let palette = PaletteModel(workspace: model, purpose: .commands)
    let section = try #require(palette.sections.last)
    #expect(section.title == "Claude Code")
    #expect(section.items.map(\.title) == ["/context", "/compact", "/superpowers:brainstorming"])
    palette.setQuery("brainstorm")
    let row = try #require(palette.items.first)
    #expect(row.kind == .runtime("/superpowers:brainstorming "))
    #expect(row.primary == "Add to draft")
    palette.select(row.id)
    await palette.activate()
    #expect(model.composerText == "/superpowers:brainstorming ")
    #expect(transport.calls(.turnSend).isEmpty)
    // A draft already there is never overwritten.
    let again = PaletteModel(workspace: model, purpose: .commands)
    again.setQuery("context")
    #expect(again.items.first?.isAvailable == false)
    await model.disconnect()
  }

  #if os(macOS)
    /// A runtime's argument hint can be a line long (Claude Code's `/code-review` names six levels and
    /// three flags). The row cuts it; it never makes the list wider than the card, which showed as rows
    /// running off both edges.
    @Test func aLongArgumentHintIsCutInsideTheCard() async throws {
      let hint =
        "[low|medium|high|xhigh|max|ultra] [--fix] [--comment] [<pr#>|<branch>|<path>] [--max-findings <n>]"
      let commands = [
        RuntimeCommand(
          name: "code-review", description: String(repeating: "Review the current diff for bugs. ", count: 4),
          argumentHint: hint)
      ]
      let (model, _) = try await connected(claudeCommands: commands)
      await model.openThread(id: "quiet")
      let palette = PaletteModel(workspace: model, purpose: .commands)
      palette.setQuery("code-review")
      #expect(palette.items.first?.trailing == hint)
      let size = CGSize(width: MacPalette.width, height: 200)
      let window = SnapshotWindow(
        rootView: PaletteView(model: model, palette: palette, floating: true)
          .frame(width: size.width, height: size.height, alignment: .top)
          .environment(\.isInFloatingPanel, true),
        untitled: true, size: size)
      defer { window.close() }
      window.appearance = NSAppearance(named: .aqua)
      for _ in 0..<10 { pumpRunLoop() }
      window.host.layoutSubtreeIfNeeded()
      let rep = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
      window.host.cacheDisplay(in: window.host.bounds, to: rep)
      let scale = CGFloat(rep.pixelsWide) / size.width
      // The row is the band under the 36 pt field and its rule. Inside the card's 8 pt list inset and
      // the row's own padding there is nothing but the card's fill: text that reached those margins
      // would be a row wider than the card.
      func ink(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Int {
        var count = 0
        for px in Int(x.lowerBound * scale)...Int(x.upperBound * scale) {
          for py in Int(y.lowerBound * scale)...Int(y.upperBound * scale) {
            guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
            if color.brightnessComponent < 0.6 { count += 1 }
          }
        }
        return count
      }
      let band: ClosedRange<CGFloat> = 50...66
      #expect(ink(x: 3...12, y: band) == 0, "the row runs off the card's leading edge")
      #expect(ink(x: 588...597, y: band) == 0, "the row runs off the card's trailing edge")
      // And the row is there: its title, in ink, where a row's title starts.
      #expect(ink(x: 40...140, y: band) > 20)
      await model.disconnect()
    }
  #endif
}
