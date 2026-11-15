## 2026-11-15: the transcript lays out every row it draws

D-237: the transcript is a plain stack over a thread's latest 150 rows, with "Show earlier" above them, in place of a lazy stack. Branch `blove/tall-message-opens-at-end` from `main` 32630d06. `WorkspaceUI` and tests only: no hub, store, mirror or wire change, and no migration.

### The defect, on main

- In the harness app (`./Scripts/test-macos-smoke.sh -only-testing:WorkspaceSmokeTests/ReadingSmokeTests/testATallFirstMessageOpensAtItsEnd`, the shipped root view over a real coordinator, 1100 by 700 pt): a thread of a question, one 120-line reply, a reply with a fenced block and a last line opened with lines 37 to 57 of the tall reply in view. The accessibility tree held one text for the whole transcript, 2,878 pt tall, reaching 1,500 pt past the scroll view's end, and the scroller read 1. The last message was never laid out. The test fails on `main`'s `TranscriptView.swift`.
- Hosted: `TranscriptScrollTests.aShortThreadStillFollowsItsStream` fails on `main` when run by itself (the view rests 1,532 pt above the end, not held) and passes when the suite runs it after other tests. A trace of the scroll geometry showed the content's height go from 1,842 pt to 382 pt after the stream grew it.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`, as CI runs it: `WorkspaceStorageTests` and `CoordinatorTests`, 514 tests in 67 suites passed; everything else, 1451 tests in 162 suites passed.
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator: both exit 0.
- The hosted transcript suites (`TranscriptScrollTests`, `DenseTranscriptViewTests`, `TranscriptReadingTests`, `PlainTranscriptTests`, `TranscriptCorpusTests`, `CodeFenceViewTests`): 57 tests passed, twice in a row; `aThreadWithAVeryTallReplyOpensAtItsEnd` and `aShortThreadStillFollowsItsStream` also pass run by themselves.
- In the harness app with a plain stack and no window (an experiment before the window was written): `testATallFirstMessageOpensAtItsEnd` and `testJumpToLatestAndCopyCode` passed.
- `Scripts/docs-index.sh --check`: passes with this record and D-237.

### Not checked

- The three app journeys on the final code (`testATallFirstMessageOpensAtItsEnd` with its scroll back, `testJumpToLatestAndCopyCode`, `testALongThreadShowsEarlierRowsOnRequest`). After the experiment above the Mac reported "Automation Mode is disabled. This device requires user authentication to enable Automation Mode", and the runner timed out enabling it; approving that is the owner's. "Show earlier" has not been pressed in the running app.
- The phone, a release build's layout time, VoiceOver on "Show earlier", a thread of thousands of rows in the running app.
- The other smoke journeys were not rerun; the host seeds the reading thread only for `ReadingSmokeTests`.
