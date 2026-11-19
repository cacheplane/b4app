## 2026-11-18: The activity line

D-255, `docs/superpowers/specs/2026-11-18-activity-line-design.md`. Branch `blove/activity-line`, from the plan commit f9d9deff to head 581bbddc, then this record. The commits: b2268722 and d1124194 (one transcript), a0115069 and ac093a7c (the line), 58589d6e and 8bf0f4ad (step rows), 50f1d86c (`endedAt`), 9880a19b and 91ed2210 (Claude Code's sub-agent frames), 264b3706 (sub-agent rows), 1c782c7a (captures), 6c7e72b1 (the quiet output block), and 0cd0f403, 3b50f468 and 581bbddc (the final review's findings).

### Before

- A thread drew two ways by the density setting: normal drew every item with a card for each tool, dense drew one steps line. Neither line had a mark or a time, and a step had no duration.
- A Claude Code sub-agent's frames became ordinary items of the turn, with nothing to say they belonged to a call (defect 11 of the hill climb).

### After

All runs on an Apple M1 Max, debug, in this checkout.

- The full `swift test`, once, in one process, with the shared test PostgreSQL started inside the run: 2,252 tests in 253 suites, failed with 12 issues in 6 tests, none in code this branch changed (no file under `Sources/WorkspaceMirror`, `Tests/WorkspaceMirrorTests` or `Tests/WorkspaceClientTests` is in the diff since f9d9deff). They were not investigated. History, as far as it is supported: on the previous branch (the streaming foundation, pull request 230) a local full run had the same six tests failing (named in `docs/verification/2026-11-17-streaming-text-foundation.md`, line 18); they failed the same way when their suites were run again alone there, their cause was not looked into, and CI on that pull request passed. They were not run against main. The six: `RecordingSessionTests.rejectsGapEpochAndAccountChanges` (`WorkspaceClientTests`), and in `WorkspaceMirrorTests` `MirrorTransportTests.transportRenamesAndPublishes` and `.publishAnnouncesUsage`, `MirrorRelayTests.presenceBecomesHostPresenceEvents`, `MirrorViewSettingsTests.aPulledChangeUpdatesTheMirrorAndEmitsChanged` and `.changingShowArchivedOnThePhoneLeavesTinyStored` (four of them hit a 60 s time limit in this run's output). Every other test passed, among them `WorkspaceUITests`, `ClaudeAdapterTests`, `CoordinatorTests` and `StreamingMarkdownTests`.
- `./Scripts/test-ios-layout.sh` (the iOS layout UI tests on this checkout's own Simulator): 3 tests passed, 0 failed, 0 skipped.
- `swift test --filter WorkspaceUITests`, at 0cd0f403: 816 tests in 82 suites passed. After 581bbddc, `swift test --filter 'DenseTranscript|StepRow'`: 126 tests in 5 suites passed. `swift test --filter ClaudeAdapterTests`: 108 tests in 12 suites passed (0cd0f403). `swift test --filter SessionServiceTests`: 25 tests in 3 suites passed (3b50f468).
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` after `./Scripts/generate-project.sh`: succeeded at the end of tasks 1, 3, 6 and the final fix wave.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift` and `Scripts/docs-index.sh --check`: pass (run for this commit).
- Captures: `ListSnapshotTests.activityLine` with `B4APP_SNAPSHOT_DIR` set, at 2x: nine cases (`running-closed`, `sent`, `open-agent`, `open-step-output`, `failed-closed`, `failed-open`, `agent-output`, `stopped-open`, `plan-running`) at the Mac's 720 pt and the phone's 390 pt, light and dark, thirty-six files `docs/screenshots/transcript-activity-<case>-<mac|phone>-<light|dark>.png`, and `transcript-markdown-<mac|phone>-<light|dark>.png` regenerated (four). Task 7 read the original thirty-six against the design's sketches. After the output fix the `open-step-output` and `agent-output` groups were read; after the final fixes the `open-agent` group; the reviewers read eight more between them. The rest of the rewritten files, and the four regenerated markdown captures, were not each read again. The running clocks in them are the fixed start offset plus the seconds between building the fixture and drawing it, and the working mark is at whatever angle it had; ended rows use fixed timestamps.
- What the live recording showed: the Claude Code 2.1.282 run with one sub-agent, 97 frames, scrubbed to the 38-frame fixture `Tests/ClaudeAdapterTests/Fixtures/subagent-run.jsonl`. Its shape is in D-255 and `docs/compatibility.md`. It was recorded by the controller with the owner's login (one real turn of inference, outside the test suite, which stays fixture-only). The scrub was checked by search for home paths, the owner's name, email addresses, keys, organisation and account ids: only `/work/proj`, `session-1` and random frame ids remain.

### The tests, by task

- One transcript (b2268722, d1124194): the window, the badge words, the running line and the settling rules were kept by moving them from `PlainTranscriptTests` into `DenseTranscriptTests` before that file was deleted.
- The line and its clock (a0115069, ac093a7c): `ActivityTimeTests`; `theClockCountsAndTheProjectionDoesNot` hosts the line for 1.3 s and asserts that `projections(of:)` is unchanged across one tick; `aLateAcknowledgementLeavesAnEndedTurnAlone` (coordinator) fails without the guard.
- Step rows (58589d6e, 8bf0f4ad): `StepRowTests` and `StepRowViewTests` (a mutation check, the output drawn above the row, failed the scroll test by 72 pt).
- `endedAt` (50f1d86c): `aCompletedToolItemRecordsWhenItEnded`.
- Claude Code (9880a19b, 91ed2210): `ClaudeSubAgentTests` replays the whole recording; before the change 4 of 6 failed. Text and thinking frames, and a streamed sub-agent frame, are covered by hand-written frames, marked in the test as not observed live.
- Sub-agent rows (264b3706): 13 cases in `DenseTranscriptTests` failed before the tree existed, with 41 issues.
- The output block and the final review (6c7e72b1, 0cd0f403, 3b50f468, 581bbddc): each fix has a test that failed first, recorded in the task reports (the 20-line cut, the block's left edge, the held view after `Show all`, the Codex agent's title, an orphan sub-agent message not being the answer, the line's `Expanded` value, the parent fallback for a use never seen, the turn with an unknown submission having no duration).

### Tests deleted or replaced

Each was made false by the one transcript, or was replaced by a test of the same fact in the new form.

- Deleted: `PlainTranscriptTests.swift` whole (its window, badge-word and settling cases were moved first), and in it `everyItemIsDrawnInTheOrderGiven`, `aStoppedTurnsOpenStepIsUnfinished`, `aTurnWhoseOutcomeIsUnknownHasAnUnknownStep`, `theLineStandsWithItsTurn`, `aTurnWithNoItemsKeepsItsNoteAtTheEnd`, `aTurnsNoteFollowsItsLastItem` (moved as `aTurnsNoteFollowsItsTurn`), `aRunningTurnEndsInALineThatSaysWorking` (replaced by `everyRunningStatusHasAWorkingLine`), `theLineNamesTheNewestOpenStep`, `aTurnWaitingForAnAnswerSaysSo`, `onlyARunningTurnHasALine`; `normalDensityIsTodaysTranscript`; `switchingDensityLetsGoOfTheHold`; `aListStandsWhereItWasWritten`; `aDenseTurnWaitingWithNothingFoldedSaysSo` (removed in a0115069, replaced by `everyRunningStatusHasAWorkingLine`); `aDenseThreadIsTheStoredDensity` (it asserted `denseThread`); `aThreadFromHistoryIsDenseToo` (now `aThreadFromHistoryDrawsAsAThreadWithATurn`); `aRunningTurnWhoseListHasNoStepInProgressSaysItIsWorking` (D-246's rule, now `aRunningTurnsListFollowsItsLine`); `aRunningTurnShowsItsListAfterTheStepsLine` and `aRunningTurnWithOnlyAListDrawsTheListAlone` (now `aRunningTurnShowsItsListAfterItsLine`); `aRunningTurnWithNothingYetHasNoStepsLine` and `aRunningTurnWithNothingYetSaysWorking` (now `aRunningTurnAlwaysHasItsLine` and `aRunningTurnWithNoItemsHasItsLine`); `displayIsTheSecondPageOnBothPlatforms` (now `displayIsTheSecondPageOnTheMacOnly`).
- Renamed, same fact: `denseIsShorterByTheFoldedSteps` to `aTurnIsTheMessageTheLineAndTheAnswer`; `anOpenTurnIsAsTallAsNormalPlusTheLine` to `anOpenTurnIsItsLineAndOneRowPerStep`; `aFailedTurnsNoteIsDrawnAtBothDensities` to `aFailedTurnsNoteIsDrawn`; `anEmptyListIsNotDrawnAtEitherDensity` to `anEmptyListIsNotDrawn`; `withNothingToggledNormalDensityScrollsAsToday` to `withNothingToggledTheTranscriptFollowsItsStream`; `theBadgeWordsAreWordsAndUnknownStatusesAreShownAsTheyAre` to `theStateWordsAreWordsAndUnknownStatusesAreSpokenAsTheyAre` (now `Running`); `theCardTitleIsUnchanged` to `theStepTitleIsTheCardsWas`; `theNameIsTheLabelThenTheCardTitleCutAt120` to `theNameIsTheLabelThenTheStepTitleCutAt120`; `aLongRunningNameKeepsTheLineOneLineHigh` to `aLongRunningNameKeepsTheLineOneRowHigh`.
- Normal density's captures in `SnapshotTests` (`thread-normal`, `thread-normal-running`, `thread-normal-sent`, `thread-normal-plan`, `thread-normal-plan-stopped`, `thread-normal-stopped`, and the `thread-code-reply` block whose only render was normal) were removed with the code that drew them.

### Captures removed

Sixteen files in `docs/screenshots` were deleted, each made false by the new transcript: `transcript-running-line-normal`, `transcript-plan-normal`, `transcript-markdown-{mac,phone}-normal-{light,dark}` (four), `transcript-plan-stopped`, `transcript-stopped-turn-before`, `transcript-stopped-turn-after`, `transcript-running-line-sent-dense`, `transcript-running-line-sent-dark`, `transcript-plan-dense-running`, and `transcript-markdown-{mac,phone}-dense-{light,dark}` (four, regenerated under the names above). They showed tool cards, normal density, or the old steps line. Older files still name them: D-234, D-239, `docs/verification/2026-11-15-a-running-turn-says-what-it-is-doing.md`, `docs/verification/2026-11-16-a-plan-is-one-row-per-turn.md`, `docs/verification/2026-11-17-streaming-text-foundation.md`, `docs/research/2026-11-14-agent-chat-hill-climb.md`, and the plans `docs/superpowers/plans/2026-11-18-activity-line.md` and `docs/superpowers/plans/2026-11-16-plans-and-task-lists.md`. Those files are history and were not edited; a link there no longer resolves. `transcript-code-copied`, `-code-reply-before`, `-code-reply-after` and `-jump-to-latest` show no tool rows or line and were kept.

### Not checked

- The working mark's motion and the clock in the running app: a capture is one frame, and the hosted tests read the clock's text and count projections, not frames.
- VoiceOver on a device. The rows' labels, values and traits are read from the accessibility tree in hosted tests on macOS.
- A phone in the hand. The phone-width captures are rendered on macOS, where `LLA.Metrics.row` is 0, so real phone rows are at least 44 pt tall and look different; the long-line, `Show all` and one-line-high tests ran at 390 pt on macOS.
- The Claude Code transcript on disk: the design reads it as not holding a sub-agent's lines, so history would show no sub-agent steps; the recording is a stream, and nothing here observed the transcript.
- A live Codex sub-agent. The `collabAgentToolCall` payload shape is believed, not recorded; the title from the prompt and the row that opens to its payload were written for it.
- A Claude Code sub-agent's own text or thinking frames, a sub-agent inside a sub-agent, two at once, one run in the background, and a streamed sub-agent frame: the one recording has none of them, and the tests that cover them use hand-written frames.
- A step whose opened output is the raw payload now includes `endedAt` and, for a sub-agent's item, `parentNativeItemId`; no capture shows that fallback.
- Frame time of the running app with a long running turn, and the pacing of the clock's tick on a loaded machine.

### Known rough edges

- Pressing `Show` on a turn with more than about 150 rows can push the pressed line out of the drawn window (D-237's window cuts inside an opened turn or agent).
- A sub-agent's full prompt is not shown anywhere once it has a result.
- A child row settles with the turn of the row it stands under, not its own.
- A turn ended by a reconcile or an abandon, and a turn whose acknowledgement was late, show no duration.
- A duplicate `turnFinished` can make a duration read long.
- If the design's reading of the on-disk transcript is right (not observed), history never holds a sub-agent's steps, so a thread rebuilt only from history shows the agent call with its result and no children.
- Old threads have neither `endedAt` nor `parentNativeItemId`: no step times, and sub-agent steps flat.
- `Show` and `Hide` sit after the time on an agent row, so the times of an agent row and a step row do not line up in one column, as in the approved mockup.
- A plan's own in-progress mark and the line's working mark are both drawn in one running turn.
- "Turn failed." is drawn in the danger colour and was before this work, besides `N failed`, a failed step's cross and its title.
- A step's endedAt is when the coordinator processed the event, not when the adapter made it.

### Process

The whole-branch review and its fix wave ran before these records, so they are written once against head 581bbddc. The reviews of tasks 1 to 7b each found issues that were fixed in a round before the next task began; the final review found three (a turn ended by a reconcile showing a long duration, `Show all` not holding the view, a Codex agent being a bare row) and four minors, all fixed or recorded above. This record's own review is a scoped check by the controller.
