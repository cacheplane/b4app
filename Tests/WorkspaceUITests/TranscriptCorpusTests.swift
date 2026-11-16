import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// Scripted threads with a ledger written beside them, by hand: which invocations exist, what each
/// one's recorded outcome is, and what a reader must see at each density, closed and open. The
/// ledger is the oracle; the transcript's own words are only compared with it. Scenario ids (F03,
/// F10, ...) are the families in `docs/research/2026-11-14-agent-chat-hill-climb.md`.
@Suite struct TranscriptCorpusTests {
  // MARK: the ledger

  /// One tool invocation as the scenario scripted it, independent of what is drawn.
  struct Invocation {
    var id: String
    var title: String
    /// The word its badge must draw once the scenario's turn states are taken into account.
    var outcome: String
  }

  struct Scenario {
    var name: String
    var items: [DisplayItem]
    var turns: [Turn]
    var live: [String: String] = [:]
    var invocations: [Invocation]
    /// Normal density, top to bottom.
    var normal: [String]
    /// Dense, every turn closed.
    var dense: [String]
  }

  // MARK: reading what is drawn

  /// One string per drawn row, through the words the views draw.
  private func drawn(
    _ entries: [DenseTranscript.Entry], live: [String: String], open: Set<String> = []
  )
    -> [String]
  {
    entries.map { entry in
      switch entry {
      case .item(let item):
        switch item.role {
        case .user: return "user: \(item.payload["text"]?.stringValue ?? "")"
        case .assistant where item.type == "agentMessage":
          return "reply: \(item.nativeItemId.flatMap { live[$0] } ?? item.payload["text"]?.stringValue ?? "")"
        case .assistant: return "working: \(item.type)"
        case .tool:
          let status = item.payload["status"]?.stringValue.map(DenseTranscript.statusLabel) ?? "no status"
          return "\(DenseTranscript.title(of: item)) [\(status)]"
        case .system: return "system: \(item.type)"
        }
      case .line(let line): return "line: \(line.spoken(open: open.contains(line.group)))"
      case .note(let turn): return "note: \(TurnNoteRow(turn: turn).text)"
      case .running(let line): return "running: \(line.text)"
      }
    }
  }

  private func normal(_ scenario: Scenario) -> [String] {
    drawn(DenseTranscript.plain(items: scenario.items, turns: scenario.turns), live: scenario.live)
  }

  private func dense(_ scenario: Scenario, open: Set<String> = []) -> [String] {
    drawn(
      DenseTranscript.entries(items: scenario.items, turns: scenario.turns, open: open), live: scenario.live,
      open: open)
  }

  /// The ledger's checks, the same for every scenario.
  private func check(_ scenario: Scenario) {
    #expect(normal(scenario) == scenario.normal, "\(scenario.name): normal density")
    #expect(dense(scenario) == scenario.dense, "\(scenario.name): dense, closed")
    // Every invocation is drawn exactly once with its recorded outcome: at normal density, and at
    // dense with every turn open. Nothing is merged, dropped or doubled.
    let groups = Set(
      scenario.turns.map(\.id) + scenario.items.compactMap(\.turnId) + scenario.items.map { "h-\($0.id)" })
    for (density, rows) in [("normal", normal(scenario)), ("dense, open", dense(scenario, open: groups))] {
      for invocation in scenario.invocations {
        let expected = "\(invocation.title) [\(invocation.outcome)]"
        #expect(
          rows.filter { $0 == expected }.count == 1,
          "\(scenario.name), \(density): \(invocation.id) should be drawn once as \(expected)")
      }
      let toolRows = rows.filter { $0.hasSuffix("]") }
      #expect(toolRows.count == scenario.invocations.count, "\(scenario.name), \(density): tool rows")
      // Opening a turn hides nothing a closed one showed, except the line's own word.
      let replies = scenario.dense.filter { $0.hasPrefix("reply:") || $0.hasPrefix("note:") }
      for row in replies { #expect(rows.contains(row), "\(scenario.name), \(density): lost \(row)") }
    }
  }

  // MARK: building scenarios

  private func item(
    _ id: String, _ turn: String?, _ role: DisplayItemRole, _ type: String, native: String? = nil,
    _ payload: [String: JSONValue]
  ) -> DisplayItem {
    DisplayItem(
      id: id, threadId: "th", turnId: turn, nativeItemId: native, role: role, type: type,
      payload: .object(payload), sequence: 0, provenance: turn == nil ? .snapshot : .live)
  }
  private func ask(_ id: String, _ turn: String?, _ text: String) -> DisplayItem {
    item(id, turn, .user, "userMessage", ["text": .string(text)])
  }
  private func reply(_ id: String, _ turn: String?, _ text: String, native: String? = nil) -> DisplayItem {
    item(id, turn, .assistant, "agentMessage", native: native, ["text": .string(text)])
  }
  private func run(_ id: String, _ turn: String?, _ command: String, _ status: String) -> DisplayItem {
    item(
      id, turn, .tool, "commandExecution", native: "native-\(id)",
      ["command": .string(command), "status": .string(status)])
  }
  private func turn(
    _ id: String, _ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed
  )
    -> Turn
  { Turn(id: id, threadId: "th", operationId: "op-\(id)", status: status, outcome: outcome) }

  private func numbered(_ items: [DisplayItem]) -> [DisplayItem] {
    items.enumerated().map { index, item in
      var copy = item
      copy.sequence = index + 1
      return copy
    }
  }

  // MARK: the development corpus

  /// F03: the same command three times, two of them still open together.
  @Test func repeatedAndConcurrentInvocationsStayApart() {
    check(
      Scenario(
        name: "F03",
        items: numbered([
          ask("u1", "t1", "Run the tests on both targets."),
          run("k1", "t1", "swift test", "completed"),
          run("k2", "t1", "swift test", "inProgress"),
          run("k3", "t1", "swift test --filter Sync", "inProgress"),
        ]),
        turns: [turn("t1", .running, nil)],
        invocations: [
          Invocation(id: "k1", title: "swift test", outcome: "Completed"),
          Invocation(id: "k2", title: "swift test", outcome: "In progress"),
          Invocation(id: "k3", title: "swift test --filter Sync", outcome: "In progress"),
        ],
        normal: [
          "user: Run the tests on both targets.", "swift test [Completed]", "swift test [In progress]",
          "swift test --filter Sync [In progress]", "running: swift test --filter Sync",
        ],
        // The running line names the newest open step; it gives no count while the turn runs.
        dense: ["user: Run the tests on both targets.", "line: swift test --filter Sync, Show"]))
  }

  /// F10: a failed step after a successful one, then a second turn that tries again and passes.
  @Test func aFailureKeepsItsSuccessfulPrefixAndTheRetryIsItsOwnInvocation() {
    check(
      Scenario(
        name: "F10",
        items: numbered([
          ask("u1", "t1", "Migrate staging."),
          run("k1", "t1", "migrate status", "completed"),
          run("k2", "t1", "migrate up", "failed"),
          ask("u2", "t2", "Try again."),
          run("k3", "t2", "migrate up", "completed"),
          reply("a2", "t2", "The migration is applied."),
        ]),
        turns: [turn("t1", .terminal, .failed), turn("t2")],
        invocations: [
          Invocation(id: "k1", title: "migrate status", outcome: "Completed"),
          Invocation(id: "k2", title: "migrate up", outcome: "Failed"),
          Invocation(id: "k3", title: "migrate up", outcome: "Completed"),
        ],
        normal: [
          "user: Migrate staging.", "migrate status [Completed]", "migrate up [Failed]", "note: Turn failed.",
          "user: Try again.", "migrate up [Completed]", "reply: The migration is applied.",
        ],
        dense: [
          "user: Migrate staging.", "line: 2 steps, 1 failed, Show", "note: Turn failed.", "user: Try again.",
          "line: 1 step, Show", "reply: The migration is applied.",
        ]))
  }

  /// F11: Stop while a command was open and a reply was streaming. The stored step is still
  /// `inProgress`; nothing recorded says it finished.
  @Test func aStoppedTurnNeverShowsARunningStep() {
    check(
      Scenario(
        name: "F11",
        items: numbered([
          ask("u1", "t1", "Run everything."),
          reply("m1", "t1", "Starting with the build."),
          run("k1", "t1", "swift build", "completed"),
          run("k2", "t1", "swift test", "inProgress"),
        ]),
        turns: [turn("t1", .terminal, .cancelled)],
        invocations: [
          Invocation(id: "k1", title: "swift build", outcome: "Completed"),
          Invocation(id: "k2", title: "swift test", outcome: "Unfinished"),
        ],
        normal: [
          "user: Run everything.", "reply: Starting with the build.", "swift build [Completed]",
          "swift test [Unfinished]", "note: Turn stopped.",
        ],
        dense: ["user: Run everything.", "line: 2 steps, Show", "note: Turn stopped."]))
  }

  /// F12: the runtime went away mid-turn. The turn's outcome is unknown and so is its open step's.
  @Test func anUnknownOutcomeIsNotDrawnAsRunningOrEnded() {
    check(
      Scenario(
        name: "F12",
        items: numbered([
          ask("u1", "t1", "Deploy."),
          run("k1", "t1", "deploy --env staging", "inProgress"),
        ]),
        turns: [turn("t1", .reconciling, nil)],
        invocations: [Invocation(id: "k1", title: "deploy --env staging", outcome: "Unknown")],
        normal: ["user: Deploy.", "deploy --env staging [Unknown]"],
        dense: ["user: Deploy.", "line: 1 step, Show"]))
  }

  /// F18: an item type and a status the app does not know, and a turn the list does not know.
  @Test func unknownShapesAreDrawnAsTheyAreAndNeverAsSuccess() {
    check(
      Scenario(
        name: "F18",
        items: numbered([
          ask("u1", "t9", "What changed?"),
          item("x1", "t9", .tool, "plan_update", ["status": "completed"]),
          item("x2", "t9", .tool, "commandExecution", ["command": "git log", "status": "somethingNew"]),
          item("s1", "t9", .system, "contextCompaction", [:]),
          reply("a1", "t9", "Two commits."),
        ]),
        turns: [],
        invocations: [
          Invocation(id: "x1", title: "plan_update", outcome: "Completed"),
          Invocation(id: "x2", title: "git log", outcome: "somethingNew"),
        ],
        normal: [
          "user: What changed?", "plan_update [Completed]", "git log [somethingNew]",
          "system: contextCompaction", "reply: Two commits.",
        ],
        // The capability item is working, not a step: one step is counted.
        dense: [
          "user: What changed?", "line: 1 step, Show", "reply: Two commits.", "system: contextCompaction",
        ]
      ))
  }

  /// F20: a whole piece of work: an interim message, a failing test, a change, a passing test, the
  /// answer. Closed, the reader has the request, that one step failed, and the answer.
  private var workflow: Scenario {
    Scenario(
      name: "F20",
      items: numbered([
        ask("u1", "t1", "Fix the failing sync test."),
        reply("m1", "t1", "I will reproduce it first."),
        run("k1", "t1", "swift test --filter SyncTests", "failed"),
        item(
          "k2", "t1", .tool, "fileChange", native: "native-k2",
          ["status": "completed", "changes": [["path": "Sources/Sync.swift", "diff": "+retry()"]]]),
        run("k3", "t1", "swift test --filter SyncTests", "completed"),
        reply("a1", "t1", "The sync test passes now; the retry was missing."),
      ]),
      turns: [turn("t1")],
      invocations: [
        Invocation(id: "k1", title: "swift test --filter SyncTests", outcome: "Failed"),
        Invocation(id: "k2", title: "File change (1 file)", outcome: "Completed"),
        Invocation(id: "k3", title: "swift test --filter SyncTests", outcome: "Completed"),
      ],
      normal: [
        "user: Fix the failing sync test.", "reply: I will reproduce it first.",
        "swift test --filter SyncTests [Failed]", "File change (1 file) [Completed]",
        "swift test --filter SyncTests [Completed]",
        "reply: The sync test passes now; the retry was missing.",
      ],
      dense: [
        "user: Fix the failing sync test.", "line: 3 steps, 1 failed, Show",
        "reply: The sync test passes now; the retry was missing.",
      ])
  }

  @Test func aWholeWorkflowKeepsRequestFailureChangeAndAnswer() { check(workflow) }

  /// F13: the same work read back from history, where rows have no turn. The same facts are drawn;
  /// reading them back is a projection and nothing else.
  @Test func theSameWorkRestoredFromHistoryDrawsTheSameFacts() {
    var restored = workflow
    restored.name = "F13"
    restored.items = restored.items.map { item in
      var copy = item
      copy.turnId = nil
      copy.provenance = .snapshot
      return copy
    }
    restored.turns = []
    check(restored)
  }

  // MARK: reserved coverage

  // Written after the four changes were chosen, by the same author, so "reserved" and not blind:
  // combinations the development corpus does not hold.

  /// A stopped turn with a declined and an open step, then a running turn with two open steps and a
  /// reply streaming a fenced block.
  @Test func reservedAStoppedTurnBesideARunningOne() {
    let fence = "```"
    let scenario = Scenario(
      name: "R1",
      items: numbered([
        ask("u1", "t1", "Clean and rebuild."),
        run("k1", "t1", "rm -rf .build", "declined"),
        run("k2", "t1", "swift build", "inProgress"),
        ask("u2", "t2", "Just build."),
        run("k3", "t2", "swift build", "inProgress"),
        run("k4", "t2", "swift build", "inProgress"),
        reply("a2", "t2", "", native: "n2"),
      ]),
      turns: [turn("t1", .terminal, .cancelled), turn("t2", .running, nil)],
      live: ["n2": "Building:\n\n\(fence)bash\nswift build"],
      invocations: [
        Invocation(id: "k1", title: "rm -rf .build", outcome: "Declined"),
        Invocation(id: "k2", title: "swift build", outcome: "Unfinished"),
      ],
      normal: [
        "user: Clean and rebuild.", "rm -rf .build [Declined]", "swift build [Unfinished]",
        "note: Turn stopped.",
        "user: Just build.", "swift build [In progress]", "swift build [In progress]",
        "reply: Building:\n\n\(fence)bash\nswift build", "running: swift build",
      ],
      dense: [
        "user: Clean and rebuild.", "line: 2 steps, 1 declined, Show", "note: Turn stopped.",
        "user: Just build.",
        "line: swift build, Show", "reply: Building:\n\n\(fence)bash\nswift build",
      ])
    #expect(normal(scenario) == scenario.normal)
    #expect(dense(scenario) == scenario.dense)
    // The two open steps of the running turn are two rows, and the stopped turn's open step is not
    // one of them.
    #expect(normal(scenario).filter { $0 == "swift build [In progress]" }.count == 2)
    #expect(normal(scenario).filter { $0 == "swift build [Unfinished]" }.count == 1)
    // The streaming reply's block is open: code, no Copy yet.
    #expect(
      MarkdownBlocks.split(scenario.live["n2"] ?? "")
        == [.prose("Building:"), .code(language: "bash", text: "swift build", closed: false)])
  }

  /// A history whose last call has no result, followed by a live turn that completed: the history
  /// call is unfinished, the live one is not touched, and no note is invented for history.
  @Test func reservedHistoryWithAnOpenCallBeforeALiveTurn() {
    let scenario = Scenario(
      name: "R2",
      items: numbered([
        ask("h1", nil, "Search the docs."),
        item("c1", nil, .tool, "toolCall", ["name": "search", "input": "relay", "status": "inProgress"]),
        ask("u2", "t2", "Search again."),
        item(
          "c2", "t2", .tool, "toolCall",
          ["name": "search", "input": "relay", "status": "completed", "output": ""]),
        reply("a2", "t2", "Nothing matched."),
      ]),
      turns: [turn("t2")],
      invocations: [
        Invocation(id: "c1", title: "search: relay", outcome: "Unfinished"),
        Invocation(id: "c2", title: "search: relay", outcome: "Completed"),
      ],
      normal: [
        "user: Search the docs.", "search: relay [Unfinished]", "user: Search again.",
        "search: relay [Completed]",
        "reply: Nothing matched.",
      ],
      dense: [
        "user: Search the docs.", "line: 1 step, Show", "user: Search again.", "line: 1 step, Show",
        "reply: Nothing matched.",
      ])
    check(scenario)
    // The completed call's empty result is a result, not a missing one.
    #expect(ToolEvidence.detail(of: scenario.items[3]).output == .empty)
    #expect(ToolEvidence.detail(of: scenario.items[1]).output == .none)
  }
}
