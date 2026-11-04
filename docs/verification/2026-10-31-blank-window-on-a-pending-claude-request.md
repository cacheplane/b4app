## 2026-10-31: blank window on a pending Claude request

Found in the owner's running app: a new Claude thread asked to run Bash, and when the thread opened the window went blank, sidebar and detail, with the toolbar still working; relaunching restored it until the thread was opened again. Root cause and rule in D-047.

| Check | How | Result |
| --- | --- | --- |
| Reproduce | The stored thread exported to `Tests/Fixtures/ui/waiting-thread.json`; the packaged app quit and a Debug build of the same tree launched against the running coordinator; env switches hid one part of the thread detail per round | Blank with the request card; rendered without it; rendered with the command text plain or selectable; blank again with only `fixedSize(horizontal: false, vertical: true)` on the command |
| Measure | `NSHostingController(rootView: ThreadsView(model:)).sizeThatFits(in: .zero)` on the mirrored thread | 184 points without the request, 4,749 with it; 822 with the `fixedSize` removed; 485 with the bounded list (then 240-point cap) |
| Near the limit | The rendering variant with the window dragged to 900 by 652 points | Not blank, but the sidebar's top was pushed out and the composer off the bottom |
| Regression test | `swift test --filter DetailMinimumSizeTests` against the unfixed views (`RuntimeRequestView`, `ThreadsView`, `ComposerView` stashed) | Fails: 4,749; 100,969; 201,733; 103,418 points at zero width, 650 at 610 wide for the banner variant |
| With the fix | The same | Pass, five variants (the long-draft case is folded into each) |
| Live | The Debug build with the fix, thread "test" opened, then the window dragged to its minimum | Renders: transcript, the whole command, Allow once / Allow for session / Deny, the composer with Stop and Send; the pending permission was left unanswered for the owner |
| Suite, lint, apps | `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift`, both `xcodebuild` schemes | Pass: 328 tests in 75 suites (324 before; the new test runs four variants); lint clean; macOS and iOS build |
