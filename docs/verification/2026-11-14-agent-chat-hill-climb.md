## 2026-11-14: the transcript hill climb (four experiments, the rubric and what was not checked)

D-233 to D-236: four changes to how a thread reads, each kept because a check that failed on the baseline passes on the candidate and nothing that passed stopped passing. Branch `blove/agent-chat-ui-hill-climb-8f7ca1` from `main` 9bb7c974; the audit, capability matrix and defect list are in `docs/research/2026-11-14-agent-chat-hill-climb.md`. No hub, store, mirror or wire change, and no migration. The whole experience is not accepted by this record: six rubric checks fail, twenty-four are untested, and one hard gate (R14.1, VoiceOver) was never run.

### What ran, and on what

- macOS 26.5 (25F71), arm64, Swift 6.3.3, Xcode 26.6, debug build, default text size, light and dark. Hosted-view tests use a 720 by 480 pt window; captures are 720 by 560 pt at 2x.
- Evidence tiers used: reading the source; pure tests of the adapters' translators and the transcript's projections; the real `TranscriptView` hosted in a window; scripted captures looked over by the author (a model, not a person).
- Tiers not used: a live runtime (Codex 0.166.0, Claude Code 2.1.282 and B4 0.15.8 are installed and none was run), the running app on a Mac or a phone, VoiceOver or any assistive technology, Instruments, a human reader.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`: run as CI does, after a clean rebuild, on 9dc208e5. Everything but `WorkspaceStorageTests` and `CoordinatorTests`: 1445 tests in 162 suites passed. `WorkspaceStorageTests` and `CoordinatorTests`: 512 of 514 passed; `KeepAwakeTests.settingsAreServedOverTheSocketAndDiagnosticsShowTheAssertion` and `PairingSocketTests.pairIsRoutedAndNeverReplayedFromTheOperationCache` each timed out on `diagnostics.read` (15 s) in that process, and both suites passed when run alone (9 tests). Neither is touched by this change. An earlier run in this checkout failed seven unrelated suites: the incremental build was stale (a test binary and `WorkspaceProtocol` disagreed on `EventKind`'s cases), the baseline passed them in a fresh checkout, and the clean rebuild cleared it.
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator: both exit 0.
- `Scripts/docs-index.sh --check`: passes with this record and D-233 to D-236.
- The scroll suite (`TranscriptScrollTests`, twelve tests in thirteen cases) five times in a row: passed five of five.
- Not run: `Scripts/test-ios-layout.sh`, the hub's `cargo test` (nothing under `Hub/` changed), the live suites.

### Experiments

Each record: the problem, the hypothesis, the change, the measure chosen before the change, the result, the decision.

**E1 (D-233), commit 07273327.** Problem: with nothing opened, the stream pulled a reader who had scrolled back to the end (defect 1). Hypothesis: treating an upward scroll as the hold D-223 already has lets a reader stay, and one button brings them back. Measure, fixed first: the scroll origin after twenty streamed lines and a new step, and after the turn ends, must be within 0.5 pt of where the reader was; guardrails: the ten existing scroll tests. Result: baseline 764.5 pt (dense), 794 pt (normal) and 540 pt (turn end) away; candidate 0 in all three, and scrolling to the end follows again. The first candidate rule (top edge moved up) broke `sendingAMessageReleasesTheHold`; the rule gained "same height" and "end marker out of view" and all pass. Decision: kept. Coverage: macOS hosted view only; iOS untested.

**E2 (D-234), commit 99e913b4.** Problem: normal density drew a stopped turn's open step as `inProgress` and every note at the end of the thread (defect 2). Hypothesis: one settle and one projection for both densities removes the false "in progress" and puts each note with its turn. Measure: for the scripted stopped, failed, unknown and history turns, the drawn status of each step equals the ledger's, and each note follows its own turn; guardrails: every dense test, the closed dense captures. Result: baseline capture shows "inProgress" in the accent colour and "Turn stopped." under the next turn's answer; candidate shows "Unfinished" and the note under its turn. The new projection's tests cannot run on the baseline (the API is new), so the baseline evidence is the capture and the source. Closed dense captures are byte-identical. Decision: kept.

**E3 (D-235), commit b958a6cb.** Problem: B4 history restored failed and unanswered calls as completed, `error: null` was a failure, and the card dumped its payload (defects 3 to 5). Hypothesis: one failure rule for live and history, and a card that reads the payload's fields, keep the recorded outcome. Measure: the two adapter tests' expectations; guardrails: the B4 adapter and session suites. Result: five expectations fail on the baseline (three history statuses, the null error, B4's failed step) and none on the candidate; eighty-five B4 tests pass. The card's reader is new API, tested on the candidate only. Decision: kept.

**E4 (D-236), commit 99a558b0.** Problem: a fenced block was not a block, and what a reader copied from it was wrong (defect 6). Hypothesis: cutting the reply into prose and code gives a readable block at every moment of the stream and an exact Copy. Measure: the cut of the scripted replies equals the hand-written blocks at every prefix, and the code equals the lines between the fences; guardrails: a reply with no fence measures as before, a wide line does not widen the reply, the scroll suite. Result: baseline capture reads "bash swift test --filter SyncTests" as inline code and shows an open fence's backticks; candidate draws both as blocks. Cost: a selection no longer crosses a block's edge. Decision: kept; the cost is recorded in D-236.

Budget: four experiments, four kept, none reverted. No candidate was compared on preference.

### The corpus

`TranscriptCorpusTests` scripts threads as display items and turns and keeps a ledger beside each, written by hand: every invocation, its recorded outcome, and the rows a reader must see at normal density and at dense with every turn closed. It then checks that each invocation is drawn exactly once with that outcome at normal density and at dense with every turn open. It starts at display items: there is no path from a native frame to a display item without PostgreSQL, so adapter behaviour is in the adapter suites.

| Family | Where | Tier |
| --- | --- | --- |
| F01 fragmented text and final snapshot | `SessionTests`, `ClaudeEventsTests` (existing) | Coordinator and adapter fixtures |
| F02 streaming Markdown, code, Unicode | `MarkdownBlocksTests`, `CodeFenceViewTests` | Pure, hosted view |
| F03 repeated and concurrent tools | `TranscriptCorpusTests` F03 | Projection |
| F04 arguments, permission, execution | Not scripted; "In progress" is the neutral word (D-234) | Untested |
| F05 empty and falsy results | `B4TranslatorTests`, `ToolEvidenceTests` | Adapter, pure |
| F06 plans and tasks | None: no presentation exists | Untested |
| F07 delegation | None | Untested |
| F08 approve, deny, duplicate, expiry | `SessionTests` (existing) | Coordinator fixtures; the card untested |
| F09 questions in a turn | `SessionTests`, `ClaudeSessionTests` (existing) | Coordinator fixtures |
| F10 failure, prefix, retry | `TranscriptCorpusTests` F10 | Projection |
| F11 stop | `TranscriptCorpusTests` F11, `PlainTranscriptTests` | Projection |
| F12 disconnect, unknown outcome | `TranscriptCorpusTests` F12 | Projection; replay untested |
| F13 restore and import | `TranscriptCorpusTests` F13, `B4TranslatorTests` | Projection, adapter |
| F14 reading back while output arrives | `TranscriptScrollTests`, `TranscriptReadingTests` | Hosted view, macOS |
| F15 remeasure, resize, text size, keyboard | Existing scroll tests for opening and closing; the rest none | Mostly untested |
| F16 drafts across threads | Existing draft tests | Fixtures |
| F17 long history, large output | None | Untested |
| F18 unknown shapes | `TranscriptCorpusTests` F18, `ToolEvidenceTests` | Projection |
| F19 keyboard, IME, VoiceOver, contrast, motion | `ComposerTextViewTests` (existing) for keys and IME | VoiceOver untested |
| F20 a whole workflow | `TranscriptCorpusTests` F20 | Projection |

Reserved coverage, written after the four changes were chosen and by the same author, so not blind: `reservedAStoppedTurnBesideARunningOne` and `reservedHistoryWithAnOpenCallBeforeALiveTurn`. Both passed on their first run against the kept changes.

### The rubric

Forty-five checks, each Pass, Fail or Untested after the four changes, with the baseline's status where it differs. "Fixture" is a pure or hosted test; "source" is reading the code. A check is Pass here only for the cells its evidence names; where the only evidence is macOS, the phone is untested and the check is marked so. Hard gates, fixed before the first experiment, are the eleven marked (gate).

| Check | Status | Evidence and scope |
| --- | --- | --- |
| R01.1 identity and owner (gate) | Untested | Projection: Pass (corpus, every invocation once). Claude Code text ids differ between live and history (risk 12); no fixture |
| R01.2 streaming, snapshot, reconnect, corrections (gate) | Untested | Final text and a late decline: existing fixtures pass. B4 reattach gap: no fixture |
| R01.3 ordering, parallelism, retry, parents (gate) | Untested | Retry and concurrent steps: Pass (corpus). Claude Code parent ids are never read (defect 11) |
| R02.1 state dimensions distinct (gate) | Pass | Turn status, step status and request state are separate and drawn separately; fixture |
| R02.2 no unsupported success or execution claim (gate) | Pass (was Fail) | D-234, D-235; fixture, both densities, B4 history. Live runtimes untested |
| R02.3 unsupported and missing capabilities fall back | Fail | Codex plan updates and command output deltas are dropped silently (defect 10); source. S2 |
| R03.1 request, response, answer, summary findable | Pass | Corpus F20, both densities |
| R03.2 compression keeps blockers, failures, changes | Pass (was Fail at normal density) | Notes with their turn (D-234); dense line names failed and declined |
| R03.3 expansion keeps chronology and disclosure | Untested | Chronology: Pass (corpus). A card's open state is row state in a lazy stack; not tested |
| R04.1 running state names the activity | Fail | Normal density has no running line; nothing between send and first item (defect 7). S2 |
| R04.2 counts and progress measure what they say | Pass | Existing dense tests; no percentage exists |
| R04.3 activity readable and ends correctly | Untested | Ended turns: Pass (D-234). Rapid updates not tested |
| R05.1 tool summaries and targets | Pass | Titles, fixture |
| R05.2 arguments, output, exit code inspectable, limits labelled | Pass (was Fail) | D-235; fixture. Timing is not shown; the opened card was not seen on screen |
| R05.3 empty, custom, unknown results safe | Pass (was Fail) | D-235; fixture |
| R06.1 plans, tasks, operations, outcomes distinct | Fail | No plan or task presentation (defect 10). S2 |
| R06.2 plan revisions and task identity | Untested | Nothing to test |
| R06.3 child work keeps owner and place | Untested | Defect 11 |
| R07.1 decisions visible, scoped, supported choices only (gate) | Fail | "Allow for session" where the runtime applies once (defect 8); `multiSelect` unread. Source. S2 |
| R07.2 decision states never confused or sent twice (gate) | Pass | Coordinator refuses a second answer (existing fixture). The Mac's buttons come back briefly (defect 14, S1) |
| R07.3 stop and recovery keep request and confirmation apart (gate) | Pass | `stopping` and terminal are separate (existing fixtures); open steps read Unfinished (D-234) |
| R08.1 partial and final Markdown readable | Pass (was Fail) | D-236; fenced code only. Headings, lists and tables are literal (defect 17) |
| R08.2 code, output, tables, diffs: copy and inspection | Fail | Copy exists for fenced code only; no table rendering. S1 |
| R08.3 rich output bounded, accessible, safely routed | Untested | |
| R09.1 reading suspends follow; return restores it | Untested | macOS hosted view: Pass (was Fail), D-233. The phone untested |
| R09.2 expansion, output, reflow keep the anchor | Untested | macOS: opening, closing, stream and turn end pass. Text size and resize not tested |
| R09.3 selection, position, focus survive updates | Untested | |
| R10.1 composer matches runtime capabilities | Pass | Existing fixtures; no queue or steer exists and none is offered |
| R10.2 drafts and optimistic messages reconcile (gate) | Pass | Existing draft and send fixtures, in the full run |
| R10.3 keys, multiline, paste, IME | Untested | macOS keys and IME: existing fixtures pass. Paste and the phone's keyboard not tested here |
| R11.1 restore keeps available facts | Untested | B4 history: Pass (was Fail), D-235. Claude Code history: risk 12 |
| R11.2 reading never executes or reopens (gate) | Pass | The projections are pure; history load only reads; existing fixture "lost acks are never retried" |
| R11.3 reconnect, compaction, runtime loss explained | Untested | |
| R12.1 latency within budget | Untested | No budget was measured or set |
| R12.2 no unnecessary parsing or layout | Untested | `Equatable` blocks (D-236) are unmeasured |
| R12.3 memory and tasks bounded | Untested | |
| R13.1 macOS behaviour | Untested | Not driven in the running app |
| R13.2 iOS behaviour | Untested | Built only |
| R13.3 shared semantics, deliberate platform handling | Pass | One projection for both; source |
| R14.1 VoiceOver and keyboard can identify and act (gate) | Untested | Labels exist in source; VoiceOver was not run |
| R14.2 announcements and focus | Fail | Nothing is announced (defect 9). Source. S2 |
| R14.3 text scale, contrast, non-colour cues, motion | Untested | Status is now a word, not only a colour (D-234); sizes and contrast not run |
| R15.1 hierarchy and surfaces | Untested | Captures looked over by a model only |
| R15.2 readable in both densities and themes | Untested | As above |
| R15.3 a reviewer finds work, blocker, changes, evidence, next action | Untested | No reviewer study |

Counts after the changes: 15 Pass, 6 Fail, 24 Untested, none N/A. Tested coverage (Pass + Fail over all) 21 of 45, 47%; acceptance coverage (Pass over all) 15 of 45, 33%. At the baseline the same table reads 10 Pass, 11 Fail, 24 Untested (acceptance 22%): R02.2, R03.2, R05.2, R05.3 and R08.1 moved from Fail to Pass. R09.1 and R11.1 had failing cells that now pass and stay Untested for the cells nobody ran.

Hard gates: R02.1, R02.2, R07.2, R07.3, R10.2 and R11.2 pass at the fixture tier. R07.1 fails (S2, defect 8). R01.1, R01.2, R01.3 and R14.1 are untested, which blocks any claim about them. No S4 defect was found. No change in this record touches a decision, an approval or what is sent to a runtime.

### Not checked

- Any live runtime, the running Mac app, the phone, a device.
- VoiceOver, keyboard-only use of the transcript, Dynamic Type sizes, high contrast, Reduce Motion.
- Performance of any kind: no latency, memory or layout measurement was taken, and no budget was set.
- "Jump to latest" and Copy were never pressed; the pasteboard write was not observed.
- A human reader. The captures were read by the model that made the changes.

### Next

The highest-value next experiment is a running line at normal density and in the gap before the first item (defect 7, R04.1), followed by announcements for a new request, a failure and a turn's end (defect 9, R14.2) checked with VoiceOver by a person. The harness worth building first is a corpus that feeds native frames through the adapter, `SessionService` and the projection in one pass, so R01 can be tested instead of read.
