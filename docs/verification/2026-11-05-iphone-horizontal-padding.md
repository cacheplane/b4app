## 2026-11-05: iPhone notice, composer and control padding

The owner requested cleaning up the effective horizontal padding, then explicitly included the composer and thread controls. The branch is based on current main at `e352cae`.

### Effective insets and correction

- Home's connection notice started at 14 pt. It now uses the 16 pt page gutter, like sync and Mac notices.
- A thread's relay notice added a 16 pt inset inside `ComposerView`'s existing 16 pt page padding, producing a 32 pt outer inset. The phone now applies that page padding once. The Mac retains its existing relay-line inset; the active-turn row is unchanged.
- Home's new-thread field used a 12 pt outside margin, whereas thread and new-thread fields used 16 pt. The dock now uses the page margin too.
- Picker labels combined a 4 pt row inset with their own 8 pt inset, placing visible text 4 pt to the left of the draft text. On iOS the row inset is now derived from the field's 16 pt text inset minus the label's 8 pt inset. The result is a 16 pt outside gutter and a 16 pt inside text inset: draft and picker text align at x=32 pt. The Mac retains its existing picker spacing, and menu hit-area expansion is preserved.
- The sync banner now names the shared page-margin token. Its existing 16 pt geometry is retained. This change does not address the separately recorded truncated transport-error copy.

### Regression evidence

Five new Simulator tests cover connection notices on home/detail, the home dock's two margins, and field/control alignment on existing and new threads. Before the fixes, the notice tests failed with 14 and 32 pt instead of 16; the dock failed at 12 pt instead of 16. Rendered project-label ink measured about x=29 pt, including glyph bearings, against draft text at x=32 pt. Both label cases failed the 1.5 pt optical tolerance.

Menu and plain-label accessibility bounds differ, so the control assertions measure rendered foreground pixels rather than assuming that a menu's hit rectangle equals its visible label. The final screenshots were visually inspected on home, thread detail and the new-thread composer.

| Check | Result |
| --- | --- |
| Two notice-gutter regressions | Pass after both failed against the previous padding |
| Three composer/control regressions | Pass after dock and label failures were reproduced |
| Complete 18-test iPhone layout matrix | Pass: 18 tests, zero failures/skips, 490.550 seconds |
| Current-main `swift build` | Pass |
| Current-main complete `swift test` | Pass: 1,401 tests in 169 suites, 97.890 seconds on repeat |
| Shipping iOS Simulator and macOS app builds | `BUILD SUCCEEDED` |
| Strict Swift format and diff checks | Pass |
| Independent review | No remaining actionable findings |

The initial current-main package run executed 1,401 tests and failed the existing `HubSyncTests.joinPushesTheBacklogAndMarksItSynced` case at its two post-sign-out assertions. That case passed in isolation on unchanged code, then the complete 1,401-test repeat passed. No account-sync implementation or tests were changed by this UI cleanup.

The complete result bundle is `/tmp/b4app-padding-matrix.xcresult`. Focused bundles are `/tmp/b4app-padding-red.xcresult`, `/tmp/b4app-padding-green-final.xcresult`, `/tmp/b4app-control-ink-red.xcresult`, and `/tmp/b4app-composer-padding-green.xcresult`. Original before/after screenshots are under `.build/verification/2026-11-05-horizontal-padding/`. This is an isolated fixture UI gate, not a new physical iPhone or live-provider test. The owner passed physical step 5 on production build 2611050442 before this padding-only update; that result remains in `2026-11-05-iphone-step5-physical-retest.md`.
