## 2026-11-17: Streaming text foundation

D-251, the text half of `docs/superpowers/specs/2026-11-17-streaming-text-foundation-design.md`. Branch `blove/b4app-chat-ui-rendering-2710a2`, fifteen commits from f2b4e8c9 to c14aa603 plus this record's. It adds the `StreamingMarkdown` target and changes `WorkspaceUI` (the stream, the store, the block views; `MarkdownBlocks` removed). No wire, storage, sync or `MirrorTransport` change. Nothing has been pushed.

### Before

- Every delta reassigned `ThreadDetail` and re-ran the transcript's grouping; nothing paced the deltas (D-237's per-token cost).
- Headings, lists, quotes and tables in a reply were literal text; only fenced code was a block (D-236; defect 17 of the hill climb).
- On the phone, a relay gap blanked the live text and then showed it again whole.

### After

- `swift test --filter StreamingMarkdownTests`: 85 tests in 8 suites passed (debug). They cover each block kind and nesting, each row of the design's projection table at every step of a growing input, split invariance over the corpus (every two-way split, one character at a time, seeded random splits, and every prefix), seeded adversarial input, and the two stress cases below.
- `swift test --filter WorkspaceUITests`: 760 tests in 79 suites passed (debug). Among them `MessageStreamTests` and `MessageStreamStoreTests` (pacing, the drain on completion, Reduce Motion and off screen, a final text that extends or differs, the phone's gap sequences with nothing removed or replayed), `MarkdownViewTests` (each block kind in the column, a wide table scrolling inside its block, soft and hard breaks, a streamed reply and the same reply from history drawing the same, `aTokenDoesNotRerunTheGrouping` at both densities), `LinkPolicyTests`, `MirrorModelTests`, and the ported scroll and hold tests. The opt-in `SnapshotTests` suite (`B4APP_SNAPSHOT_DIR`) is skipped by that run.
- Captures, `ListSnapshotTests.markdownReply` with `B4APP_SNAPSHOT_DIR` set, at 2x, each read after it was written: one finished reply using every block kind (two headings, a paragraph with bold, inline code and a link, a nested ordered list three levels deep, a task list, a quote, a table with left, right and centre columns, fenced Swift code, a break) after a question and one command. `docs/screenshots/transcript-markdown-mac-normal-{light,dark}.png` and `-mac-dense-` (720 by 740 pt), and `-phone-normal-` and `-phone-dense-` (390 by 840 pt; the macOS view at a phone's width, not the iOS app). No overlapping or clipped text and no raw markdown in any of the eight. Two things seen: the emphasis in the quote draws upright, because the bundled sans has no italic face; and in dark the code block has no visible box, because `codeBg` and `surface` share one dark colour (unchanged since 5bbbef75, not this work).
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator, after `./Scripts/generate-project.sh`: both succeeded.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean. `swift build`: succeeded. `Scripts/docs-index.sh --check`: passes.

### Timings

On an Apple M1 Max.

- **The parser, optimised.** `swift test -c release -Xswiftc -enable-testing --filter StreamingMarkdownTests` builds but runs no test: in a release build the test runner starts the `agent-workspace` executable's entry point, which rejects `--test-bundle-path`. The parser's sources were instead compiled with `swiftc -O` beside a small program running the stress cases, three runs each:
  - 100,000 characters of the corpus's mixed reply pushed one at a time, the document read every 16 pushes, then finished: 0.33 to 0.34 s (about 3.4 µs a character).
  - One 100,000-character line with no newline, pushed 64 characters at a time with a read after each push: 0.72 to 0.73 s.
  - The same program unoptimised (`-Onone`): 1.32 to 1.33 s and 0.77 s. The debug test run above: 2.56 s (halves 1.74 s and 0.82 s) and 0.98 s.
- **A single long line grows faster than linearly.** With the same `-O` program, a line of 25,000, 50,000, 100,000 and 200,000 characters in 64-character pushes took 0.056, 0.18, 0.72 and 2.84 s with a read per push, and 0.025, 0.093, 0.36 and 1.42 s with no reads: four times the time for twice the length, so a push into an open line costs in proportion to that line's length. `oneLongLineWithNoNewlineStaysLinear` asserts only a total under 4 s and does not catch this. A line breaks it: the mixed reply, whose lines are short, scales linearly. At 10,000 characters on one line a push costs about 0.05 ms. Not fixed here.
- **A tick in a hosted transcript, debug.** `StreamingTickTimingTests` hosts `TranscriptView` (normal density, 720 by 480 pt) over 150 rows, the last a running reply; it streams every block kind three times over (1,366 characters) 24 characters a tick with a paced store and a `ManualTicker`, then completes it and ticks until the reveal stops. Each tick's time is the reveal and parse plus the layout passes before and after one turn of the run loop. Three runs, 66 ticks each: median 6.9 to 7.0 ms, 95th percentile 11.3 to 11.9 ms, worst 15.5 to 16.4 ms. The test asserts the worst tick is under 250 ms, a guard against a gross regression only. This is a hosted view in a test process, debug build, not a frame-time measurement of the running app, and it does not separate our code's time from SwiftUI's and AppKit's; the release build of this test cannot run, for the reason above.

### Not verified

- The design's budget, no frame over 16 ms from our code on the Mac in a release build: not measured. The running app was not profiled with Instruments, on the Mac or an iPhone Simulator.
- The pacing numbers (a twelfth of the backlog a tick, the drain within 9 ticks) on a live stream: not tuned. This is gate step 3, waiting on the owner (his Mac and a live Claude Code session); the numbers are the design's first guess.
- Any live runtime session: no Codex, Claude Code or B4 reply was streamed through this code. The phone's relay-gap handling is tested with the sequences the design reads from `MirrorTransport`, not over a real relay.
- An iPhone on hardware, and the iOS app at all beyond its build: the phone-width captures are the macOS view.
- VoiceOver: the task marks' "Done" and "Not done", headings as headers, and tables were not heard. Dynamic Type at accessibility sizes was not looked at.
- CI: nothing has been pushed. The full `swift test` (the PostgreSQL group) was not run for this record; this work changes no code it covers.
