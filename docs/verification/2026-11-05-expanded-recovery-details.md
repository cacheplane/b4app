## 2026-11-05: Expanded recovery details stay inside the window

The owner expanded Details in the installed local app and the window layout broke. The accessibility tree retained the controls, but the screenshot showed an oversized, largely blank window with its content displaced. Collapsing Details immediately restored the normal layout.

The earlier recovery-notice checks rendered only the collapsed state. Expanded diagnostics were selectable, wrapped text outside a scroll region. The macOS split view's zero-width minimum-size measurement made that text report a 2,569-point minimum height. The new regression reproduces that measurement in both the 340- and 640-point expanded variants; the collapsed variants pass.

The diagnostic content now lives inside a scroll region bounded by the shared 120-point diagnostic-height token. The region can shrink to a control's height, preserving the composer and recovery actions at small window sizes. Its full text remains selectable and scrollable. The notice's ordinary disclosure state is explicitly bound so the same production view can be rendered collapsed and expanded.

Verification so far:

- Expanded/collapsed notice tests and the existing minimum-window suite passed (5 tests in 2 suites).
- Rendered both states at 340 and 640 points in light and dark. Inspected the expanded narrow/light and wide/dark renders: diagnostics wrap inside the card and the recovery controls remain below them.
- Added a regression using a long native diagnostic to verify that diagnostic length cannot determine the window's minimum height.

Final validation:

- `swift test`: 1,409 tests in 171 suites passed (140.898 s), including the long-diagnostic regression.
- The local macOS Release-Local build passed.
- Strict recursive Swift formatting, the docs index check, and `git diff --check` passed.

- `swift build` and the iOS Simulator build passed.

Installed the signed local package with the existing Developer ID and provisioning profiles; deep/strict signature verification and executable SHA-256 comparisons passed. Retained the previous bundle in `.b4app-update-3xhf0jis/Previous.app`. Started the installed background coordinator (pid 65814) before reopening the app, and left testing open with its existing draft intact. The research server retained pid 30391 and ready health before the handoff; no user message was sent and no native session was unarchived.

Expanded-state verification used the real SwiftUI view in the regression tests and light/dark renders. Restart cleared the app's transient error notice, so the installed app was checked for connection, normal layout, and draft retention without sending the draft to reproduce another rejection.
